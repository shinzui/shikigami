{-# LANGUAGE RankNTypes #-}

-- | Private per-assignment provider registry. Both blocking and streaming calls
-- pass the same durable admission boundary below any caller retry loop.
module Shikigami.Execution.SelectionRuntime (SelectionRuntime (..), buildExecutionEnv, PreparedSelectionCall (..), buildPreparedExecutionEnv, preparePinnedExecutionCall, narrowOutput, assignmentIdFor, conversationAssignmentIdFor, selectionTransaction, currentExecutionAuthority) where

import Baikai.Api (Api (..))
import Baikai.Auth (ApiKeySource (ApiKeyLiteral))
import Baikai.Context qualified as Context
import Baikai.Cost qualified as Cost
import Baikai.Error (invalidRequest)
import Baikai.Evidence qualified as Evidence
import Baikai.Message qualified as Message
import Baikai.Model qualified as Model
import Baikai.Options qualified as Options
import Baikai.Provider.Registry
import Baikai.Response (Response (..), errorResponse, responseError)
import Baikai.Stream (liftCompleteToStream)
import Baikai.Stream.Event (AssistantMessageEvent (..), TerminalPayload (..))
import Baikai.Usage qualified as Usage
import Control.Exception (mask, onException)
import Data.Aeson (object, toJSON, (.=))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (diffUTCTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Transaction (Transaction)
import Hasql.Transaction.Sessions qualified as Sessions
import Kioku.App (AppEnv, runAppIO)
import Kiroku.Store.Transaction qualified as StoreTransaction
import Shikigami.Attestation.CallFacts (CallComplianceFacts (..), factsFromTerminal)
import Shikigami.Attestation.Evidence (CallRelationship (RootCall), configureEvidenceCall)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ProfileResolutionError, ResolvedProfile (..))
import Shikigami.Behavior.Compatibility (validateResponseRequest)
import Shikigami.Behavior.Provider (withModelBinding)
import Shikigami.Behavior.Provider.Call (providerCallFor, validateProfileCall)
import Shikigami.Behavior.Run (BehaviorEnv (..))
import Shikigami.Decision.Contract (ModelAlias (..), ModelDescriptor (..), versionedDigest)
import Shikigami.Decision.ModelCatalog
import Shikigami.Execution.Attempt (ModelCallPreparation (..))
import Shikigami.Execution.Identity
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Selection
import Shikigami.Log.Correlation (RunCorrelationId, callCorrelationId)
import Shikigami.Prelude hiding ((.=))
import Shikigami.Store.ExecutionResources qualified as Resources
import Shikigami.Store.ExecutionSelection qualified as Calls
import Streamly.Data.Stream qualified as Stream

data SelectionRuntime = SelectionRuntime
  { catalog :: !ModelCatalog,
    profile :: !(Maybe ResolvedProfile),
    providers :: ![ApiProvider],
    baseEnv :: !BehaviorEnv,
    runId :: !RunCorrelationId,
    authorize :: !(IO (Either Text ())),
    transact :: !(forall a. Transaction a -> IO (Either Text a))
  }

assignmentIdFor :: Text -> Text
assignmentIdFor key = "assignment:" <> versionedDigest "shikigami.assignment/1" (toJSON key)

data PreparedSelectionCall = PreparedSelectionCall
  { receipt :: !Calls.CallReceipt,
    commit :: !(Calls.CallReceipt -> Calls.CallOutcome -> Maybe Response -> IO ())
  }

buildExecutionEnv :: SelectionRuntime -> ExecutionSelection -> IO (Either ExecutionSelectionFailure BehaviorEnv)
buildExecutionEnv = buildExecutionEnvWith Nothing

buildPreparedExecutionEnv :: SelectionRuntime -> ExecutionSelection -> PreparedSelectionCall -> IO (Either ExecutionSelectionFailure BehaviorEnv)
buildPreparedExecutionEnv env selection prepared = buildExecutionEnvWith (Just prepared) env selection

resolvePinnedEnv :: SelectionRuntime -> ExecutionSelection -> Either ExecutionSelectionFailure (ModelBinding, BehaviorEnv)
resolvePinnedEnv env selection = do
  fallback <- case selection.source of
    ProcessDefault -> defaultBinding env.baseEnv.model env.baseEnv.options
    DeclaredAlias -> either (const (Left PinnedBindingUnavailable)) Right (pinnedBinding env.catalog selection.descriptor)
  binding <- selectionBinding env.catalog fallback env.profile selection
  selected <- either (const (Left ExecutionOptionsIncompatible)) Right (withModelBinding binding env.baseEnv)
  let effective = (effectiveBindingOptions env.profile binding) {Options.apiKey = Options.apiKey selected.options}
  pure (binding, selected & #options .~ effective)

requestFingerprint :: ExecutionSelection -> Context.Context -> Options.Options -> Text
requestFingerprint selection context options = versionedDigest "shikigami.execution-model-request/1" (object ["assignment" .= selection.assignmentId, "selection" .= selection, "context" .= context, "options" .= options {Options.apiKey = Nothing, Options.evidence = Nothing, Options.metadata = Map.delete "shikigami_call_id" (Options.metadata options)}])

-- Preparation performs no reservation or external model IO. Its result is
-- admitted with the queue entry by the execution owner's transaction.
preparePinnedExecutionCall :: SelectionRuntime -> ExecutionSelection -> OperationId -> AttemptId -> Context.Context -> Maybe Int -> IO (Either Text (Resources.AttemptRequest, ModelCallPreparation))
preparePinnedExecutionCall env@SelectionRuntime {transact} selection operation attempt context maxOutput = case resolvePinnedEnv env selection of
  Left _ -> pure (Left "pinned execution binding is unavailable")
  Right (_, selected) -> case narrowOutput selected.options maxOutput of
    Left err -> pure (Left err)
    Right options -> do
      authority <- env.authorize
      case authority of
        Left _ -> pure (Left "fresh execution authority refused")
        Right () -> do
          root <- traverse (\root -> transact (Resources.inspectRootTx root)) selection.rootId
          pure do
            stored <- traverse (either (const (Left "execution resource storage is unavailable")) (either (const (Left "execution root is unavailable")) Right)) root
            let limits = Calls.callLimitsFor selection env.profile
            (quantities, policy) <- reservation limits stored selected.model options
            pure (Resources.AttemptRequest attempt operation quantities policy, ModelCallPreparation limits (requestFingerprint selection context options))

narrowOutput :: Options.Options -> Maybe Int -> Either Text Options.Options
narrowOutput options Nothing = Right options
narrowOutput options (Just wanted) = do
  unless (wanted > 0) (Left "requested output exceeds the pinned ceiling")
  let tokens = fromIntegral wanted
  unless (maybe True (tokens <=) (Options.maxTokens options)) (Left "requested output exceeds the pinned ceiling")
  pure options {Options.maxTokens = Just tokens}

buildExecutionEnvWith :: Maybe PreparedSelectionCall -> SelectionRuntime -> ExecutionSelection -> IO (Either ExecutionSelectionFailure BehaviorEnv)
buildExecutionEnvWith preparedCall env@SelectionRuntime {transact} selection = case resolvePinnedEnv env selection of
  Left refusal -> pure (Left refusal)
  Right (binding, selectedEnv) -> do
    handler <- case selection.source of
      ProcessDefault -> lookupApiProviderWith (fromMaybe globalProviderRegistry env.baseEnv.providerRegistry) (Model.api (bindingModel binding))
      DeclaredAlias -> pure $ case [p | p <- env.providers, p.apiTag == Model.api (bindingModel binding)] of [p] -> Just p; _ -> Nothing
    case handler of
      Nothing -> pure (Left PinnedBindingUnavailable)
      Just realHandler -> do
        realRegistry <- newProviderRegistryFrom [realHandler]
        consumed <- newIORef False
        private <- newProviderRegistryFrom [wrap consumed binding realHandler realRegistry]
        pure (Right (selectedEnv & #providerRegistry .~ Just private))
  where
    limits = Calls.callLimitsFor selection env.profile
    minimumStrength options =
      max
        (maybe Evidence.EvidenceRequestedOnly (\p -> p.profile.minimumEvidenceStrength) env.profile)
        ( case Options.evidence options of
            Just request -> case request.strictness of
              Evidence.EvidenceRequired strength -> strength
              Evidence.EvidenceBestEffort -> Evidence.EvidenceRequestedOnly
            Nothing -> Evidence.EvidenceRequestedOnly
        )

    wrap consumed binding handler registry =
      handler
        { complete = \model context options -> do
            fresh <- consume consumed
            if not fresh
              then errorResponseAt model "PreparedAttemptAlreadyConsumed"
              else mask \restore -> do
                prepared <- prepare binding handler model context options
                case prepared of
                  Left response -> do
                    forM_ preparedCall \prepared -> prepared.commit prepared.receipt (Calls.CallOutcome Calls.CallRefused Map.empty [] Nothing Nothing Nothing) (Just response)
                    pure response
                  Right (receipt, effective) -> do
                    response <-
                      restore (completeRequestWith registry model context effective)
                        `onException` finish receipt (unknownOutcome Nothing)
                    finishTerminal receipt (isJust (responseError response)) response.evidence (Just response)
                    pure response,
          stream = \model context options -> Stream.concatEffect do
            fresh <- consume consumed
            if not fresh
              then pure (liftCompleteToStream (\_ _ _ -> errorResponseAt model "PreparedAttemptAlreadyConsumed") model context options)
              else do
                prepared <- prepare binding handler model context options
                case prepared of
                  Left response -> do
                    forM_ preparedCall \prepared -> prepared.commit prepared.receipt (Calls.CallOutcome Calls.CallRefused Map.empty [] Nothing Nothing Nothing) (Just response)
                    pure (liftCompleteToStream (\_ _ _ -> pure response) model context options)
                  Right (receipt, effective) -> do
                    terminal <- newIORef False
                    let record event = do
                          case event of
                            EventDone payload -> finishTerminal receipt False payload.evidence (terminalResponse model payload) >> writeIORef terminal True
                            EventError payload -> finishTerminal receipt True payload.evidence (terminalResponse model payload) >> writeIORef terminal True
                            _ -> pure ()
                          pure event
                        abandoned = do
                          done <- readIORef terminal
                          unless done (finish receipt (unknownOutcome Nothing))
                    pure (Stream.finallyIO abandoned (Stream.mapM record (handler.stream model context effective)))
        }

    consume used = case preparedCall of
      Nothing -> pure True
      Just _ -> atomicModifyIORef' used (\already -> (True, not already))

    prepare binding handler model context options = do
      let refuse detail = Left <$> errorResponseAt model detail
          base = effectiveBindingOptions env.profile binding
          semantic value = toJSON value {Options.apiKey = Nothing, Options.evidence = Nothing, Options.maxTokens = Nothing, Options.timeoutMs = Nothing, Options.responseFormat = Nothing, Options.metadata = Map.delete "shikigami_call_id" (Options.metadata value)}
          within proposed ceiling = case ceiling of Nothing -> True; Just bound -> maybe False (<= bound) proposed
          compatible = do
            unless (Options.apiKey options == (ApiKeyLiteral . revealCredential <$> bindingCredential binding)) (Left "PinnedCredentialMismatch")
            unless (semantic options == semantic base && within (Options.maxTokens options) (Options.maxTokens base) && within (Options.timeoutMs options) (Options.timeoutMs base)) (Left "PinnedOptionsMismatch")
            when (isJust (Options.responseFormat base) && Options.responseFormat options /= Options.responseFormat base) (Left "PinnedResponseFormatMismatch")
            unless (model == bindingModel binding) (Left "PinnedTupleMismatch")
            unless (Options.thinking options == Options.thinking base && Options.headers options == Options.headers base) (Left "PinnedOptionsMismatch")
            forM_ env.profile \profile -> case validateProfileCall profile (providerCallFor model options) of Left _ -> Left "ExecutionProfileConflict"; Right () -> Right ()
            case validateResponseRequest model options context of Left _ -> Left "ExecutionOptionsIncompatible"; Right () -> Right ()
      case compatible of
        Left reason -> refuse reason
        Right () -> do
          authority <- env.authorize
          case authority of
            Left _ -> refuse "ExecutionAuthorityRefused"
            Right () -> do
              root <- traverse (transaction . Resources.inspectRootTx) selection.rootId
              case sequence root of
                Left err -> refuse (Text.pack (show err))
                Right state -> case reservation limits state model options of
                  Left err -> refuse err
                  Right (quantities, policy) -> do
                    let fingerprint = requestFingerprint selection context options
                    admitted <- case preparedCall of
                      Just prepared -> do
                        let receipt = prepared.receipt
                        if receipt.assignmentId == selection.assignmentId && receipt.rootId == selection.rootId && receipt.fingerprint == fingerprint && receipt.request.quantities == quantities && receipt.request.policy == policy
                          then pure (Right (Calls.NewCall receipt))
                          else pure (Left Calls.CallIdentityConflict)
                      Nothing -> do
                        uuid <- UUID.nextRandom
                        let request = Resources.AttemptRequest (AttemptId (UUID.toText uuid)) (OperationId ("model:" <> fingerprint)) quantities policy
                        admissionTime <- getCurrentTime
                        transaction (Calls.reserveSelectionCallTx selection limits request fingerprint admissionTime)
                    case admitted of
                      Left refusal -> refuse (Text.pack (show refusal))
                      Right (Calls.ExistingCall _) -> refuse "ExistingAttemptRequiresRecovery"
                      Right (Calls.NewCall receipt) -> do
                        fresh <- env.authorize
                        case fresh of
                          Left _ -> finish receipt (Calls.CallOutcome Calls.CallRefused Map.empty [] Nothing Nothing Nothing) >> refuse "ExecutionAuthorityRefused"
                          Right () -> do
                            dispatchTime <- getCurrentTime
                            finalRoot <- traverse (transaction . Resources.inspectRootTx) selection.rootId
                            let guardResult = do
                                  when (maybe False (dispatchTime >=) limits.cutoff) (Left Resources.CutoffReached)
                                  forM_ finalRoot (\stored -> stored >>= \root -> Resources.checkRoot dispatchTime root.revision root)
                            case guardResult of
                              Left err -> finish receipt (Calls.CallOutcome Calls.CallRefused Map.empty [] Nothing Nothing Nothing) >> refuse (Text.pack (show err))
                              Right () -> ready receipt (maybe [] pure limits.cutoff <> [root.envelope.cutoff | Just (Right root) <- [finalRoot]])
      where
        ready receipt deadlines = do
          current <- getCurrentTime
          let remaining = case deadlines of
                [] -> Nothing
                xs -> Just (max 1 (floor (diffUTCTime (minimum xs) current * 1000)))
              timeouts = maybe [] pure (Options.timeoutMs options) <> maybe [] pure remaining
              boundedOptions = options {Options.timeoutMs = case timeouts of [] -> Nothing; xs -> Just (minimum xs)}
              AttemptId attempt = receipt.request.attemptId
              strength = max (minimumStrength (bindingOptions binding)) (minimumStrength boundedOptions)
              correlated = configureEvidenceCall env.runId (callCorrelationId env.runId attempt 0) (fromInteger receipt.ordinal) Nothing strength boundedOptions
              effective = case Model.api model of
                AnthropicMessages -> correlated {Options.metadata = Options.metadata options}
                OpenAIChatCompletions -> correlated {Options.metadata = Options.metadata options}
                _ -> correlated
              compatible = case validateResponseRequest model effective context of Left _ -> False; Right () -> True
          if any (current >=) deadlines
            then finish receipt (Calls.CallOutcome Calls.CallRefused Map.empty [] Nothing Nothing Nothing) >> (Left <$> errorResponseAt model "CutoffReached")
            else
              if compatible && null (evidenceRefusals handler model effective)
                then pure (Right (receipt, effective))
                else finish receipt (Calls.CallOutcome Calls.CallRefused Map.empty [] Nothing Nothing Nothing) >> (Left <$> errorResponseAt model "ExecutionEvidenceOrOptionsUnsupported")

    transaction :: Transaction a -> IO a
    transaction action = transact action >>= either (const (ioError (userError "execution call store unavailable"))) pure
    finishTerminal receipt failed evidence response =
      let AttemptId attempt = receipt.request.attemptId
          ModelAlias alias = selection.descriptor.alias
          normalized = (\ev -> factsFromTerminal (callCorrelationId env.runId attempt 0) RootCall (fromMaybe selection.descriptor.modelId (Evidence.observedValue ev.observedModel)) (Just alias) ev & #relationshipKnown .~ False) <$> evidence
          outcome = outcomeFor failed evidence & #compliance .~ normalized
       in case preparedCall of
            Just prepared -> prepared.commit receipt outcome response
            Nothing -> finish receipt outcome
    finish :: Calls.CallReceipt -> Calls.CallOutcome -> IO ()
    finish receipt outcome = case preparedCall of
      Just prepared | outcome.phase /= Calls.CallRefused -> prepared.commit receipt outcome Nothing
      Just _ -> pure ()
      Nothing -> do
        result <- transaction (Calls.finishSelectionCallTx receipt outcome)
        case result of
          Right _ -> pure ()
          Left _ -> ioError (userError "execution call outcome conflict")

terminalResponse :: Model.Model -> TerminalPayload -> Maybe Response
terminalResponse model payload = case payload.message of
  Message.AssistantMessage message -> Just (Response message model (Model.api model) (Model.provider model) payload.responseId 0 payload.errorInfo payload.evidence)
  _ -> Nothing

errorResponseAt :: Model.Model -> Text -> IO Response
errorResponseAt model reason = do
  now <- getCurrentTime
  pure (errorResponse model now 0 (invalidRequest reason))

reservation :: Calls.CallLimits -> Maybe Resources.Root -> Model.Model -> Options.Options -> Either Text (Resources.Quantities, Resources.UsagePolicy)
reservation limits root model options = do
  let rootLimits = maybe Map.empty (\r -> r.envelope.limits) root
      finiteTokens = isJust limits.tokens || case Map.lookup Resources.Tokens rootLimits of Just (Resources.Limited _) -> True; _ -> False
      finiteCost = case Map.lookup Resources.CostMicroUsd rootLimits of Just (Resources.Limited _) -> True; _ -> False
  when finiteCost (Left "ExecutionResourceBoundUnsupported:CostMicroUsd")
  tokenCeiling <-
    if finiteTokens
      then case Options.maxTokens options of
        Just output | output > 0 && Model.contextWindow model > 0 -> Right (Just (toInteger output + toInteger (Model.contextWindow model)))
        _ -> Left "ExecutionResourceBoundUnsupported:Tokens"
      else Right Nothing
  let quantities = Map.fromList ([(Resources.ActiveWork, 1), (Resources.ModelAttempts, 1)] <> maybe [] (\n -> [(Resources.Tokens, n)]) tokenCeiling)
  pure (quantities, if finiteTokens then Resources.EnforcedCeiling else Resources.AdmittedUnknownUsage)

outcomeFor :: Bool -> Maybe Evidence.ModelCallEvidence -> Calls.CallOutcome
outcomeFor _failed evidence =
  let observed = evidence >>= (Evidence.observedValue . (.usage))
      knownTokens =
        observed >>= \usage -> case Usage.availability usage of
          Just facts | Set.null (Usage.missingCategories facts) && not (Usage.inconsistent facts) -> Just (toInteger (Usage.totalTokens usage))
          _ -> Nothing
      knownCost =
        observed >>= \usage ->
          let cost = Usage.cost usage; basis = Cost.basis cost
           in if Set.member Cost.ProviderReportedTotal (Cost.sources basis) && Set.null (Cost.estimateReasons basis) && Cost.usd cost >= 0
                then Just (ceiling (Cost.usd cost * 1000000))
                else Nothing
      known = Map.fromList (maybe [] (\n -> [(Resources.Tokens, n)]) knownTokens <> maybe [] (\n -> [(Resources.CostMicroUsd, n)]) knownCost)
      missing = [dimension | dimension <- [Resources.Tokens, Resources.CostMicroUsd], Map.notMember dimension known]
   in Calls.CallOutcome Calls.CallTerminal known missing (Text.take 256 <$> (evidence >>= (Evidence.observedValue . (.observedModel)))) (Text.take 256 . (.callId) <$> evidence) Nothing

unknownOutcome :: Maybe Evidence.ModelCallEvidence -> Calls.CallOutcome
unknownOutcome evidence = Calls.CallOutcome Calls.CallTransportUnknown Map.empty [Resources.Tokens, Resources.CostMicroUsd] (Text.take 256 <$> (evidence >>= (Evidence.observedValue . (.observedModel)))) (Text.take 256 . (.callId) <$> evidence) Nothing

-- Production shares its process-owned pool. Focused consumers may use AppEnv's
-- scoped store interpreter without inventing a second runtime owner.
selectionTransaction :: AppEnv -> Maybe Pool -> Transaction a -> IO (Either Text a)
selectionTransaction appEnv pool transaction = case pool of
  Just shared -> first (const "execution call store unavailable") <$> Pool.use shared (Sessions.transaction Sessions.ReadCommitted Sessions.Write transaction)
  Nothing -> first (const "execution call store unavailable") <$> runAppIO appEnv (StoreTransaction.runTransaction transaction)

conversationAssignmentIdFor :: Text -> Text -> Text
conversationAssignmentIdFor workflow message = assignmentIdFor (versionedDigest "shikigami.conversation-assignment/1" (object ["workflow" .= workflow, "message" .= message]))

-- Revalidate the exact pinned version's lifecycle, never the mutable default
-- profile. A changed digest cannot silently replace the recorded policy.
currentExecutionAuthority :: IO (Either Text ()) -> Maybe ResolvedProfile -> (Profile.ProfileId -> Maybe Profile.ProfileVersion -> IO (Either ProfileResolutionError ResolvedProfile)) -> IO (Either Text ())
currentExecutionAuthority identity profile resolve = do
  admitted <- identity
  case admitted of
    Left _ -> pure (Left "ExecutionAuthorityRefused")
    Right () -> case profile of
      Nothing -> pure (Right ())
      Just pinned -> do
        now <- getCurrentTime
        current <- resolve pinned.ref.profileId (Just pinned.ref.version)
        pure case current of
          Right actual | actual.ref == pinned.ref && pinned.profile.lifecycle == Profile.Active && now >= pinned.profile.validFrom && not (maybe False (now >=) pinned.profile.validUntil) -> Right ()
          _ -> Left "ExecutionProfileAuthorityRefused"
