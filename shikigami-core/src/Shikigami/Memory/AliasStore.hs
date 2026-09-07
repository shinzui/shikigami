{-# LANGUAGE MultilineStrings #-}

-- | Shikigami-owned mappings from a verified principal to legacy Kioku scope
-- names. The mappings preserve history without mutating Kioku projections.
module Shikigami.Memory.AliasStore
  ( AgentScopeAlias (..),
    AliasReconciliation (..),
    aliasesForPrincipal,
    reconcileAlias,
  )
where

import Data.Bifunctor (first)
import Data.Functor.Contravariant ((>$<))
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shikigami.Agent.Principal (AgentPrincipal, principalText)
import Shikigami.Prelude

data AgentScopeAlias = AgentScopeAlias
  { principalId :: !Text,
    legacyAgentName :: !Text,
    createdAt :: !UTCTime,
    updatedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

data AliasReconciliation
  = AliasInserted !AgentScopeAlias
  | AliasAlreadyPresent !AgentScopeAlias
  | AliasConflict
      { legacyAgentName :: !Text,
        expectedPrincipalId :: !Text,
        existingPrincipalId :: !Text
      }
  deriving stock (Eq, Show, Generic)

aliasesForPrincipal :: Pool -> AgentPrincipal -> IO (Either Text [Text])
aliasesForPrincipal pool principal =
  renderUsage <$> Pool.use pool (Session.statement (principalText principal) aliasesStatement)

aliasesStatement :: Statement Text [Text]
aliasesStatement =
  preparable
    """
    SELECT legacy_agent_name
      FROM shikigami.agent_scope_aliases
     WHERE principal_id = $1
     ORDER BY legacy_agent_name
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

-- | Insert one alias idempotently. A name already owned by another principal
-- is returned as a conflict and is never reassigned.
reconcileAlias :: Pool -> AgentPrincipal -> Text -> IO (Either Text AliasReconciliation)
reconcileAlias pool principal rawLegacyName
  | Text.null legacyName = pure (Left "legacy agent name must not be empty")
  | otherwise = do
      let expected = principalText principal
      existing <- renderUsage <$> Pool.use pool (Session.statement legacyName lookupStatement)
      case existing of
        Left err -> pure (Left err)
        Right (Just row)
          | (.principalId) row == expected -> pure (Right (AliasAlreadyPresent row))
          | otherwise ->
              pure
                ( Right
                    AliasConflict
                      { legacyAgentName = legacyName,
                        expectedPrincipalId = expected,
                        existingPrincipalId = (.principalId) row
                      }
                )
        Right Nothing -> do
          insertedResult <- Pool.use pool (Session.statement (expected, legacyName) insertStatement)
          pure do
            (row, inserted) <- renderUsage insertedResult
            pure
              if (.principalId) row == expected
                then if inserted then AliasInserted row else AliasAlreadyPresent row
                else
                  AliasConflict
                    { legacyAgentName = legacyName,
                      expectedPrincipalId = expected,
                      existingPrincipalId = (.principalId) row
                    }
  where
    legacyName = Text.strip rawLegacyName

lookupStatement :: Statement Text (Maybe AgentScopeAlias)
lookupStatement =
  preparable
    """
    SELECT principal_id, legacy_agent_name, created_at, updated_at
      FROM shikigami.agent_scope_aliases
     WHERE legacy_agent_name = $1
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowMaybe aliasRow)

insertStatement :: Statement (Text, Text) (AgentScopeAlias, Bool)
insertStatement =
  preparable
    """
    INSERT INTO shikigami.agent_scope_aliases
        (principal_id, legacy_agent_name)
    VALUES ($1, $2)
    ON CONFLICT (legacy_agent_name) DO UPDATE
       SET legacy_agent_name = EXCLUDED.legacy_agent_name
    RETURNING principal_id, legacy_agent_name, created_at, updated_at,
              (xmax = 0) AS inserted
    """
    ( (fst >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.text))
    )
    (Decoders.singleRow ((,) <$> aliasRow <*> Decoders.column (Decoders.nonNullable Decoders.bool)))

aliasRow :: Decoders.Row AgentScopeAlias
aliasRow =
  AgentScopeAlias
    <$> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz)
    <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz)

renderUsage :: Either Pool.UsageError a -> Either Text a
renderUsage = first (Text.pack . show)
