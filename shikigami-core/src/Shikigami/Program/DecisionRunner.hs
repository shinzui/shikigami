{-# LANGUAGE DataKinds #-}

-- | Invocation-local Handan adapter. The wrapper sits below Shikumi retries:
-- every transport attempt is admitted and durably accounted for independently.
module Shikigami.Program.DecisionRunner
  ( DecisionRuntime (..),
    DecisionAbort (..),
    decisionProviders,
    runDecisionProgram,
    runDecisionProgramWithAnswers,
    runDecisionProgramWithAccounting,
    streamDecisionProgramWithAnswers,
  )
where

import Baikai.Api (Api (..), renderApi)
import Baikai.Auth (ApiKeySource (ApiKeyLiteral))
import Baikai.Context (Context)
import Baikai.Context qualified as Context
import Baikai.Evidence qualified as Evidence
import Baikai.Message qualified as Message
import Baikai.Model qualified as Model
import Baikai.Options (Options)
import Baikai.Options qualified as Options
import Baikai.Provider.Claude.Api (claudeMessagesProvider)
import Baikai.Provider.OpenAI.Api (openaiChatProvider)
import Baikai.Provider.OpenAI.Responses (openaiResponsesProvider)
import Baikai.Provider.Registry
import Baikai.Provider.TypeSafe.Api (typesafeProvider)
import Baikai.Response (Response (..), responseError)
import Baikai.Stream (requireEvidenceOnTerminal)
import Baikai.Stream.Event (AssistantMessageEvent (..), TerminalPayload (..))
import Control.Applicative ((<|>))
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (Exception, SomeAsyncException, SomeException, catch, fromException, mask, throwIO, try)
import Control.Lens ((&), (.~))
import Control.Monad (unless, when)
import Data.Aeson (ToJSON, toJSON)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)
import Data.Typeable (Typeable)
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Generics (Generic)
import Handan.Runtime (Runtime (..), runProgramWith)
import Numeric.Natural (Natural)
import Shikigami.Attestation.Evidence (configureEvidenceCall)
import Shikigami.Attestation.PolicyValue
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile, ResolvedProfileView (..), resolvedProfileView)
import Shikigami.Behavior.Compatibility (validateResponseRequest)
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Behavior.Provider.Call (providerCallFor, validateProfileCall)
import Shikigami.Behavior.Provider.Coordinate (providerCoordinateText)
import Shikigami.Decision.Answer qualified as Answer
import Shikigami.Decision.Contract
import Shikigami.Decision.ModelCatalog
import Shikigami.Decision.StubProvider (decisionStubProvider)
import Shikigami.Log.Correlation (callCorrelationId)
import Shikigami.Program.Decision
import Shikumi.Error qualified as Shikumi
import Shikumi.LLM qualified as LLM
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Stream qualified as ShikumiStream
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

-- No Show or JSON: the catalog contains process-local secret bindings.
data DecisionRuntime = DecisionRuntime
  { runtime :: !Runtime,
    programs :: !ProgramRegistry,
    catalog :: !ModelCatalog,
    profile :: !(Maybe ResolvedProfile),
    hooks :: !DecisionCallHooks,
    providers :: ![ApiProvider],
    timeoutMicros :: !DecisionTimeout,
    callLimit :: !(Ceiling "decision-calls" Natural)
  }
  deriving stock (Generic)

newtype DecisionAbort = DecisionAbort DecisionFailure
  deriving stock (Show)

instance Exception DecisionAbort

-- | First-class released provider values; constructing an invocation never
-- mutates Baikai's process-global registry.
decisionProviders :: [ApiProvider]
decisionProviders = [decisionStubProvider, claudeMessagesProvider, openaiChatProvider, openaiResponsesProvider, typesafeProvider]

runDecisionProgram :: (Typeable i, Typeable o, ToJSON i) => DecisionRuntime -> PreparedDecision -> DecisionProgramRef i o -> i -> IO (Either DecisionFailure o)
runDecisionProgram env prepared ref input = fmap fst (runDecisionProgramWithAnswers env prepared ref input)

runDecisionProgramWithAnswers :: (Typeable i, Typeable o, ToJSON i) => DecisionRuntime -> PreparedDecision -> DecisionProgramRef i o -> i -> IO (Either DecisionFailure o, [DecisionAnswer])
runDecisionProgramWithAnswers = runWith Nothing CompleteDecision

-- | Accepted work owns one runtime permit. Serialize internal parallel nodes
-- at the transport boundary so each actual call consumes that same permit.
-- Root accounting still admits every retry/node independently.
runDecisionProgramWithAccounting :: (Typeable i, Typeable o, ToJSON i) => (Model.Model -> Context -> Options -> IO (Either DecisionFailure (Options, DecisionCallHooks))) -> DecisionRuntime -> PreparedDecision -> DecisionProgramRef i o -> i -> IO (Either DecisionFailure o, [DecisionAnswer])
runDecisionProgramWithAccounting accounting = runWith (Just accounting) CompleteDecision

-- | Use the released Shikumi streaming interpreter under the same admission,
-- invocation-local provider registry and acknowledged terminal boundary. Atomic
-- judgments emit status callbacks; their full raw answers are returned separately.
streamDecisionProgramWithAnswers :: (Typeable i, Typeable o, ToJSON i) => DecisionRuntime -> PreparedDecision -> DecisionProgramRef i o -> i -> (ShikumiStream.StreamEvent -> IO ()) -> IO (Either DecisionFailure o, [DecisionAnswer])
streamDecisionProgramWithAnswers env prepared ref input observe = runWith Nothing (StreamDecision observe) env prepared ref input

data DecisionExecution = CompleteDecision | StreamDecision (ShikumiStream.StreamEvent -> IO ())

runWith :: (Typeable i, Typeable o, ToJSON i) => Maybe (Model.Model -> Context -> Options -> IO (Either DecisionFailure (Options, DecisionCallHooks))) -> DecisionExecution -> DecisionRuntime -> PreparedDecision -> DecisionProgramRef i o -> i -> IO (Either DecisionFailure o, [DecisionAnswer])
runWith accounting execution env prepared ref input = do
  answers <- newIORef []
  result <- case admission of
    Left refusal -> pure (Left refusal)
    Right (registered, binding, checkedInput) ->
      execute answers registered binding checkedInput `catch` \(DecisionAbort refusal) -> pure (Left refusal)
  observations <- readIORef answers
  pure (result, observations)
  where
    admission = do
      unlessEither (prepared.program == descriptor ref) ContractMismatch "prepared decision program identity differs"
      unlessEither (prepared.policy == ((\p -> (resolvedProfileView p).ref) <$> env.profile)) ContractMismatch "prepared decision policy differs"
      registered <- lookupProgram env.programs ref
      binding <- pinnedBinding env.catalog prepared.model
      unlessEither (not (Model.isJudgmentOnly (bindingModel binding)) || prepared.program.outputCapability == ClosedSetJudgment) ForbiddenModel "program does not declare closed-set judgment output"
      checked <- validateInput registered input
      unlessEither (toJSON checked == prepared.input) ContractMismatch "prepared decision input differs"
      pure (registered, binding, checked)
    execute answers registered binding checked = do
      let selected = bindingModel binding
      handler <- case [p | p <- env.providers, p.apiTag == Model.api selected] of
        [p] -> pure p
        _ -> abort UnavailableModel "selected decision provider is unavailable or ambiguous"
      realRegistry <- newProviderRegistryFrom [handler]
      count <- newIORef (0 :: Natural)
      actualHooks <- newIORef Map.empty
      serial <- newMVar ()
      let begin model context nodeOptions = do
            baseOptions <- finalOptions env binding model context nodeOptions
            (effective, hooks) <- maybe (pure (baseOptions, env.hooks)) (\make -> callback (make model context baseOptions)) accounting
            unless (null (evidenceRefusals handler model effective)) (abort ForbiddenModel "provider cannot uphold required decision evidence")
            ordinal <- atomicModifyIORef' count (\n -> (n + 1, n + 1))
            let localLimit = maybe (ceilingValue env.callLimit) (min (ceilingValue env.callLimit) . fromIntegral . ceilingValue) (env.profile >>= (\p -> (resolvedProfileView p).profile.limits.maxCalls))
            when (ordinal > localLimit) (abort CallLimitExceeded "decision provider call limit exceeded")
            token <- callback (hooks.beginCall (DecisionCallContext prepared prepared.model))
            atomicModifyIORef' actualHooks (\stored -> (Map.insert (attemptId token) hooks stored, ()))
            let correlation = callCorrelationId prepared.runId (decisionCallIdText (attemptId token)) 0
                minimumStrength = maybe Evidence.EvidenceRequestedOnly (\p -> (resolvedProfileView p).profile.minimumEvidenceStrength) env.profile
                correlated = configureEvidenceCall prepared.runId correlation (decisionCallOrdinalNumber (attemptOrdinal token)) Nothing minimumStrength effective
                -- These APIs do not accept arbitrary application metadata. The
                -- durable token/evidence association remains in finishCall.
                options = case Model.api selected of
                  AnthropicMessages -> (correlated & #metadata .~ (effective.metadata))
                  OpenAIChatCompletions -> (correlated & #metadata .~ (effective.metadata))
                  _ -> correlated
            case validateResponseRequest model options context of
              Left _ -> abort ForbiddenModel "final decision request is incompatible with its provider"
              Right () -> pure ()
            unless (null (evidenceRefusals handler model options)) (abort ForbiddenModel "final decision evidence request was refused")
            pure (token, options)
          finish token status evidence = do
            hooks <- readIORef actualHooks >>= maybe (abort EvidenceFailure "actual decision accounting is unavailable") pure . Map.lookup (attemptId token)
            _ <- callback (hooks.finishCall token status evidence)
            when (status == CallSucceeded && not (isJust evidence)) (abort EvidenceFailure "decision provider terminal evidence is missing")
            case evidence of
              Just terminal | status == CallSucceeded -> do
                let minimumStrength = maybe Evidence.EvidenceRequestedOnly (\p -> (resolvedProfileView p).profile.minimumEvidenceStrength) env.profile
                unless
                  ( terminal.strength >= minimumStrength
                      && terminal.requestedModel == providerCoordinateText prepared.model.modelId
                      && terminal.endpoint.provider == providerCoordinateText prepared.model.provider
                      && terminal.endpoint.api `elem` [renderApi (Model.api selected), providerCoordinateText prepared.model.api]
                      && terminal.status == Evidence.CallSucceeded
                  )
                  (abort EvidenceFailure "decision provider terminal does not uphold its admitted contract")
              _ -> pure ()
          observeAnswer token content = do
            snapshot <- either (abort OutputDecodeFailure) pure (Answer.captureAnswer content)
            case snapshot of
              Nothing -> pure ()
              Just snapshot -> do
                unless (prepared.program.outputCapability == ClosedSetJudgment) (abort OutputDecodeFailure "program received undeclared structured answer content")
                accepted <-
                  atomicModifyIORef'
                    answers
                    ( \previous ->
                        let next = previous <> [DecisionAnswer (attemptId token) snapshot]
                         in if any (\answer -> answer.callId == attemptId token) previous || sum (map (Answer.answerBytes . (\answer -> answer.snapshot)) next) > Answer.maxAnswerBytes
                              then (previous, False)
                              else (next, True)
                    )
                unless accepted (abort OutputDecodeFailure "structured answers exceed retained invocation bounds")
          complete model context options = case accounting of
            Nothing -> completeActual model context options
            Just _ -> withMVar serial (\_ -> completeActual model context options)
          completeActual model context options = case accounting of
            Nothing -> completeUsing id model context options
            Just _ -> mask (\restore -> completeUsing restore model context options)
          completeUsing restore model context options = do
            (token, effective) <- begin model context options
            response <- transportException token (restore (completeRequestWith realRegistry model context effective))
            finish token (if isJust (responseError response) then CallFailed else CallSucceeded) response.evidence
            unless (isJust (responseError response)) (observeAnswer token response.message.content)
            pure response
          stream model context options = Stream.concatEffect do
            (token, effective) <- begin model context options
            -- Terminal persistence happens before the consumer sees a terminal.
            -- Cancellation or a producer that never terminates leaves expectation
            -- unresolved. Blocking dispatch does not enter this wrapper too.
            pure $ Stream.mapM (terminal token effective) (handler.stream model context effective)
          terminal token effective event = do
            let checkedEvent = requireEvidenceOnTerminal effective event
            case checkedEvent of
              EventDone payload -> do
                finish token CallSucceeded payload.evidence
                case payload.message of
                  Message.AssistantMessage message -> observeAnswer token message.content
                  _ -> abort OutputDecodeFailure "successful terminal is not an assistant message"
              EventError payload -> finish token CallFailed payload.evidence
              _ -> pure ()
            pure checkedEvent
          transportException token action =
            action `catch` \(err :: SomeException) ->
              case fromException @SomeAsyncException err of
                Just _ -> case accounting of
                  Nothing -> throwIO err
                  Just _ -> finish token CallUnknown Nothing >> throwIO err
                Nothing -> finish token CallFailed Nothing >> throwIO err
          wrapper = (handler & #complete .~ (complete) & #stream .~ (stream))
      privateRegistry <- newProviderRegistryFrom [wrapper]
      let config = env.runtime.runtimeConfig
          retry = config.retryPolicy
          maxAttempts = maybe retry.maxAttempts (maybe retry.maxAttempts (fromInteger . min (toInteger retry.maxAttempts) . (+ 1) . toInteger . ceilingValue) . (\p -> (resolvedProfileView p).profile.limits.maxRetries)) env.profile
          invocation =
            env.runtime
              { runtimeDefaultModel = selected,
                runtimeConfig = config {LLM.registry = privateRegistry, LLM.retryPolicy = retry {LLM.maxAttempts = max 1 maxAttempts}}
              }
      let run = case execution of
            CompleteDecision -> runProgramWith invocation (executable registered) checked
            StreamDecision observe ->
              runEff
                . runErrorNoCallStack @Shikumi.ShikumiError
                . runConcurrent
                . runRouting selected
                . LLM.runLLMResilient invocation.runtimeConfig
                . routeLLM
                $ ShikumiStream.streamProgram (executable registered) checked (liftIO . observe)
      result <- timeout (decisionTimeoutMicros env.timeoutMicros) run
      case result of
        Nothing -> throwIO (TransientBehaviorFailure "decision provider attempt timed out")
        Just (Right output) -> pure (validateResult registered output)
        Just (Left err)
          | Shikumi.isTransient err -> throwIO (TransientBehaviorFailure "decision provider failed transiently")
          | otherwise -> pure (Left (classify err))

-- Callback exceptions are outside the transport exception/retry vocabulary.
-- In particular a callback throwing BaikaiError must never become retryable.
callback :: IO (Either DecisionFailure a) -> IO a
callback action = do
  result <- try @SomeException action
  case result of
    Left err -> case fromException @SomeAsyncException err of
      Just _ -> throwIO err
      Nothing -> abort EvidenceFailure "decision evidence callback is unavailable"
    Right (Left refusal) -> throwIO (DecisionAbort refusal)
    Right (Right value) -> pure value

abort :: FailureCode -> Text -> IO a
abort code = throwIO . DecisionAbort . decisionFailure code

unlessEither :: Bool -> FailureCode -> Text -> Either DecisionFailure ()
unlessEither condition code detail = unless condition (Left (decisionFailure code detail))

classify :: Shikumi.ShikumiError -> DecisionFailure
classify = \case
  Shikumi.InvalidJSON _ -> decisionFailure OutputDecodeFailure "decision output is not valid JSON"
  Shikumi.MissingField _ -> decisionFailure OutputDecodeFailure "decision output is missing a field"
  Shikumi.SchemaMismatch _ -> decisionFailure OutputDecodeFailure "decision output schema differs"
  Shikumi.ValidationFailure _ -> decisionFailure OutputValidationFailure "decision output validation failed"
  Shikumi.BudgetExceeded _ -> decisionFailure CallLimitExceeded "decision resource allowance exhausted"
  _ -> decisionFailure ProviderFailure "decision provider failed"

finalOptions :: DecisionRuntime -> ModelBinding -> Model.Model -> Context -> Options -> IO Options
finalOptions env binding actual context node = do
  let selected = bindingModel binding
      base = bindingOptions binding
      limits = (\p -> (resolvedProfileView p).profile.limits) <$> env.profile
      floorStrength = maybe Evidence.EvidenceRequestedOnly (\p -> (resolvedProfileView p).profile.minimumEvidenceStrength) env.profile
      minCap values = case catMaybes values of [] -> Nothing; xs -> Just (minimum xs)
      profileTokens = (>>= (fmap (fromIntegral . ceilingValue) . (\l -> l.maxTokens))) limits
      effective =
        ( node
            & #apiKey .~ (ApiKeyLiteral . revealCredential <$> bindingCredential binding)
            & #thinking .~ (base.thinking)
            & #maxTokens .~ (minCap [node.maxTokens, base.maxTokens, profileTokens])
            & #timeoutMs .~ (minCap [node.timeoutMs, base.timeoutMs, Just (max 1 (decisionTimeoutMicros env.timeoutMicros `div` 1000))])
            & #temperature .~ (node.temperature <|> base.temperature)
            & #topP .~ (node.topP <|> base.topP)
            & #stopSequences .~ (if null node.stopSequences then base.stopSequences else node.stopSequences)
            & #seed .~ (node.seed <|> base.seed)
            & #frequencyPenalty .~ (node.frequencyPenalty <|> base.frequencyPenalty)
            & #presencePenalty .~ (node.presencePenalty <|> base.presencePenalty)
            & #cacheRetention .~ (base.cacheRetention <|> node.cacheRetention)
            & #speed .~ (node.speed <|> base.speed)
            & #headers .~ (base.headers)
            & #evidence
              .~ ( Just
                     ( Evidence.evidenceRequest "decision-preflight"
                         & #strictness .~ Evidence.EvidenceRequired floorStrength
                     )
                 )
        )
  unless (actual == selected) (abort ForbiddenModel "program attempted to change the selected model or endpoint")
  when (isJust node.apiKey || not (Map.null node.headers)) (abort ForbiddenModel "program attempted a credential override")
  when (isJust node.thinking && node.thinking /= base.thinking) (abort ForbiddenModel "program attempted a thinking override")
  when (isJust base.cacheRetention && isJust node.cacheRetention && node.cacheRetention /= base.cacheRetention) (abort ForbiddenModel "program attempted a cache retention override")
  unless (null (Context.tools context) && not (isJust node.toolChoice)) (abort ForbiddenModel "decision programs may not call tools")
  case env.profile of
    Nothing -> pure ()
    Just pinned -> case validateProfileCall pinned (providerCallFor actual effective) of
      Left _ -> abort ForbiddenModel "pinned profile forbids the final decision tuple"
      Right () -> pure ()
  case validateResponseRequest actual effective context of
    Left _ -> abort ForbiddenModel "decision response request is incompatible with its provider"
    Right () -> pure ()
  pure effective
