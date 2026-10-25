-- | One pure tuple projection and profile predicate for response, decision and
-- whole-run selection. Admission and final transport checks share these rules.
module Shikigami.Behavior.Provider.Call
  ( ProviderCall (..),
    ProfileViolation (..),
    providerCallFor,
    matchesCall,
    validateProfileCall,
    renderProfileViolation,
  )
where

import Baikai.Api (Api (..))
import Baikai.Model qualified as Model
import Baikai.Options (Options)
import Baikai.Options qualified as Options
import Baikai.ThinkingLevel (ThinkingLevel, renderThinkingLevel)
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile (..))

-- | The exact model-call tuple a 'BehaviorEnv' would put on the provider seam.
-- Thinking is optional because leaving it to the SDK is itself a policy fact,
-- not an invisible default.
data ProviderCall = ProviderCall
  { provider :: !Text,
    api :: !Text,
    endpointClass :: !Text,
    modelId :: !Text,
    thinking :: !(Maybe ThinkingLevel)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Permanent pre-dispatch refusals. Every constructor carries the offending
-- tuple and the immutable profile reference so an audit record can say both
-- what was attempted and which policy rejected it.
data ProfileViolation
  = ForbiddenCall !ProviderCall !Profile.SanctionedExecutionProfileRef
  | DefaultedThinkingForbidden !ProviderCall !Profile.SanctionedExecutionProfileRef
  | CliTransportForbidden !ProviderCall !Profile.SanctionedExecutionProfileRef
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

validateProfileCall :: ResolvedProfile -> ProviderCall -> Either ProfileViolation ()
validateProfileCall ResolvedProfile {profile, ref} call =
  let restrictions = profile.prohibitions
      permitted = any (matchesCall restrictions call) profile.allowedCalls
   in if call.endpointClass == "cli" && not restrictions.cliTransportsAllowed
        then Left (CliTransportForbidden call ref)
        else case call.thinking of
          Nothing | not restrictions.defaultedThinkingAllowed -> Left (DefaultedThinkingForbidden call ref)
          _
            | permitted -> Right ()
            | otherwise -> Left (ForbiddenCall call ref)

renderProfileViolation :: ProfileViolation -> Text
renderProfileViolation = \case
  ForbiddenCall call ref ->
    "sanctioned execution profile " <> renderProfileRef ref <> " forbids call " <> renderProviderCall call
  DefaultedThinkingForbidden call ref ->
    "sanctioned execution profile "
      <> renderProfileRef ref
      <> " forbids defaulted thinking for call "
      <> renderProviderCall call
  CliTransportForbidden call ref ->
    "sanctioned execution profile "
      <> renderProfileRef ref
      <> " forbids CLI transport for call "
      <> renderProviderCall call

providerCallFor :: Model.Model -> Options -> ProviderCall
providerCallFor model options =
  let (api, defaultEndpointClass) = callSurface (Model.api model)
      endpointClass
        | defaultEndpointClass == "https", not (Text.null (Model.baseUrl model)) = Text.takeWhile (/= ':') (Model.baseUrl model)
        | otherwise = defaultEndpointClass
   in ProviderCall
        { provider = Model.provider model,
          api,
          endpointClass,
          modelId = Model.modelId model,
          thinking = Options.thinking options
        }

callSurface :: Api -> (Text, Text)
callSurface = \case
  AnthropicMessages -> ("messages", "https")
  OpenAIChatCompletions -> ("chat-completions", "https")
  OpenAIResponses -> ("responses", "https")
  AnthropicMessagesCli -> ("messages", "cli")
  OpenAICompletionsCli -> ("completions", "cli")
  Custom "stub" -> ("stub", "in-process")
  Custom customApi -> (customApi, "custom")

matchesCall :: Profile.Prohibitions -> ProviderCall -> Profile.AllowedCall -> Bool
matchesCall restrictions call allowed =
  (.provider) call == (.provider) allowed
    && (.api) call == (.api) allowed
    && (.endpointClass) call == (.endpointClass) allowed
    && (.modelId) call == (.modelId) allowed
    && case (.thinking) call of
      Just requested -> requested == (.thinking) allowed
      Nothing -> (.defaultedThinkingAllowed) restrictions

renderProviderCall :: ProviderCall -> Text
renderProviderCall call =
  "(provider="
    <> (.provider) call
    <> ", api="
    <> (.api) call
    <> ", endpointClass="
    <> (.endpointClass) call
    <> ", model="
    <> (.modelId) call
    <> ", thinking="
    <> maybe "defaulted" renderThinkingLevel ((.thinking) call)
    <> ")"

renderProfileRef :: Profile.SanctionedExecutionProfileRef -> Text
renderProfileRef (Profile.SanctionedExecutionProfileRef profileId version digest) =
  profileIdText profileId
    <> " version "
    <> profileVersionText version
    <> " digest "
    <> profileDigestText digest

profileIdText :: Profile.ProfileId -> Text
profileIdText (Profile.ProfileId value) = value

profileVersionText :: Profile.ProfileVersion -> Text
profileVersionText (Profile.ProfileVersion value) = value

profileDigestText :: Profile.ProfileDigest -> Text
profileDigestText (Profile.ProfileDigest value) = value
