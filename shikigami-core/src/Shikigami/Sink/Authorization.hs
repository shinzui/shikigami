{-# LANGUAGE DataKinds #-}

-- | Exact kernel 'EmitOutput' actions for fully-resolved outbox dispatches.
--
-- An output of a dotted kind (@kawa.digest@, @kizashi.signal@, ...) is
-- delivered to the target its adapter names from the output's configuration
-- and address. The composed authority decides the action; an adapter such as
-- the Kikan-En one maps it onto its own vocabulary.
module Shikigami.Sink.Authorization
  ( authorizeOutput,
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Authority
  ( Action (EmitOutput),
    Authority,
    AuthorityFailure (..),
    Decision,
    OutputKind,
    mkOutputTarget,
  )

-- | Decide @EmitOutput kind target@ for an identity. A target the adapter
-- could not name is an invalid coordinate, decided by nobody.
authorizeOutput :: Authority -> AgentIdentity -> OutputKind -> Either Text (NonEmpty Text) -> IO (Either AuthorityFailure Decision)
authorizeOutput authorizer identity kind segments =
  case (identityText identity, mkOutputTarget =<< segments) of
    (Left problem, _) -> pure (Left (InvalidCoordinates problem))
    (_, Left problem) -> pure (Left (InvalidCoordinates problem))
    (Right principal, Right target) -> authorizer.decide (declarationCoordinate principal) (EmitOutput kind target)
