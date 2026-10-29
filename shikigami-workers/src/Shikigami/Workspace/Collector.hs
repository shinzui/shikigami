{-# LANGUAGE ForeignFunctionInterface #-}

-- | Independent capture runs in its own service. Private files retain evidence
-- across controller restart; reading them confers no new execution authority.
module Shikigami.Workspace.Collector
  ( CollectorError (..),
    runCollector,
    readCollectorReceipt,
    readCollectorIdentity,
    reconcileCollector,
  )
where

import Control.Exception (IOException, catch)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Foreign.C
import Kioku.App (AppEnv, runAppIO)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessStore qualified as Store

data CollectorError = CollectorUnsupported | CollectorUnavailable | CollectorEvidenceConflict
  deriving stock (Eq, Show)

data CollectorIdentity = CollectorIdentity {bootId :: !Text, invocationId :: !Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON)

data CollectorFact = CollectorFact
  { version :: !Int,
    unit :: !Text,
    fingerprint :: !Text,
    bootId :: !Text,
    invocationId :: !Text,
    exitCode :: !Int,
    termination :: !ProcessTermination,
    stdoutBytes :: !Integer,
    stderrBytes :: !Integer,
    stdoutTruncated :: !Bool,
    stderrTruncated :: !Bool,
    descendantsEmpty :: !Bool,
    outputComplete :: !Bool
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON)

foreign import ccall safe "shikigami_workspace_collect" collect :: CString -> CString -> CString -> CInt -> CInt -> IO CInt

-- Unit/fingerprint and the private directory are derived by the supervisor.
-- The collector can observe/retain a unit but cannot launch repository code.
runCollector :: FilePath -> Text -> Text -> Int -> Int -> IO (Either CollectorError ())
runCollector directory unit fingerprint limit seconds
  | not (digestText fingerprint) || not (bounded unit) || limit < 1 || limit > 1048576 || seconds < 1 || seconds > 3660 = pure (Left CollectorEvidenceConflict)
  | otherwise = withCString directory \dir -> withCString (Text.unpack unit) \name -> withCString (Text.unpack fingerprint) \identity -> do
      result <- collect dir name identity (fromIntegral limit) (fromIntegral seconds)
      pure case result of 0 -> Right (); 78 -> Left CollectorUnsupported; _ -> Left CollectorUnavailable

readCollectorIdentity :: FilePath -> ProcessRecord -> IO (Either CollectorError (Maybe (Text, Text)))
readCollectorIdentity directory record = do
  loaded <- readPrivate directory "observed.json" 4096
  pure do
    bytes <- loaded
    traverse
      ( \body -> do
          identity <- either (const (Left CollectorEvidenceConflict)) Right (Aeson.eitherDecodeStrict @CollectorIdentity body)
          unless (Just identity.bootId == record.bootId && hostIdentity identity.bootId && hostIdentity identity.invocationId && maybe True (== identity.invocationId) record.invocationId) (Left CollectorEvidenceConflict)
          pure (identity.bootId, identity.invocationId)
      )
      bytes

readCollectorReceipt :: FilePath -> ProcessRecord -> IO (Either CollectorError (Maybe ProcessReceipt))
readCollectorReceipt directory record = do
  loaded <- readPrivate directory "complete.json" 4096
  case loaded of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right Nothing)
    Right (Just bytes) -> case Aeson.eitherDecodeStrict @CollectorFact bytes of
      Left _ -> pure (Left CollectorEvidenceConflict)
      Right fact
        | fact.version /= 1 || fact.unit /= record.unit || fact.fingerprint /= record.fingerprint -> pure (Left CollectorEvidenceConflict)
        | otherwise -> do
            out <- readPrivate directory "stdout" record.command.outputBytes
            err <- readPrivate directory "stderr" record.command.outputBytes
            pure do
              stdout <- out >>= maybe (Left CollectorUnavailable) Right
              stderr <- err >>= maybe (Left CollectorUnavailable) Right
              unless (toInteger (Bytes.length stdout) == fact.stdoutBytes && toInteger (Bytes.length stderr) == fact.stderrBytes) (Left CollectorEvidenceConflict)
              let receipt = ProcessReceipt record.operationId record.attemptId record.generation fact.fingerprint record.bindingDigest fact.unit fact.bootId fact.invocationId fact.exitCode fact.termination (captured "stdout" stdout fact.stdoutTruncated) (captured "stderr" stderr fact.stderrTruncated) fact.descendantsEmpty fact.outputComplete
              -- Only trusted unit evidence can establish the first invocation;
              -- ProcessStore pins it transactionally before receipt acceptance.
              unless (maybe True (== fact.invocationId) record.invocationId && validProcessReceipt (record & #invocationId .~ Just fact.invocationId) receipt) (Left CollectorEvidenceConflict)
              pure (Just receipt)
  where
    captured artifact body truncated = CapturedOutput artifact (versionedDigest "shikigami.workspace-output/1" (toJSON (Bytes.unpack body))) (toInteger (Bytes.length body)) truncated

-- Factual reconciliation deliberately does not require current execution
-- authority: revocation must not prevent original-attempt settlement. This
-- returns metadata only. Reading output for a caller still needs fresh access.
-- The directory must be derived from retained provider coordinates.
reconcileCollector :: AppEnv -> FilePath -> ProcessRecord -> IO (Either CollectorError (Maybe ProcessReceipt))
reconcileCollector env directory record = do
  identity <- readCollectorIdentity directory record
  receipt <- readCollectorReceipt directory record
  case (identity, receipt) of
    (Right observed, Right completed)
      | maybe True (\done -> maybe True (== (done.bootId, done.invocationId)) observed) completed -> do
          let coordinates = observed <|> ((\done -> (done.bootId, done.invocationId)) <$> completed)
          retained <- runAppIO env $ runTransaction do
            pinned <- case coordinates of
              Nothing -> pure (Right ())
              Just (boot, invocation) -> Store.observeProcessInvocationTx record boot invocation
            case pinned of
              Left err -> pure (Left err)
              Right () -> case completed of
                Nothing -> pure (Right Nothing)
                Just done -> Store.recordProcessReceiptTx done <&> fmap (const (Just done))
          pure (either (const (Left CollectorUnavailable)) (either (const (Left CollectorEvidenceConflict)) Right) retained)
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)
    _ -> pure (Left CollectorEvidenceConflict)

readPrivate :: FilePath -> Text -> Int -> IO (Either CollectorError (Maybe Bytes.ByteString))
readPrivate directory path limit = catch work (\(_ :: IOException) -> pure (Left CollectorUnavailable))
  where
    work = do
      private <- ensurePrivateDirectory directory
      case private of
        Left _ -> pure (Left CollectorUnavailable)
        Right () -> either (const (Left CollectorUnavailable)) Right <$> withContainedFile directory path (readContainedFile limit)
