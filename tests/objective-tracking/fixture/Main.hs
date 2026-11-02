-- Fixture-only producer and signed loopback authority. Never installed in the
-- production runtime; the runner supplies a disposable database and directory.
module Main (main) where

import Auth.Biscuit (toPublic)
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import En.Biscuit.Grant qualified as Grant
import En.Biscuit.Keys (parseSigningKeyText, renderIssuerKeySetText, singleKey)
import En.Biscuit.Mint (MintConfig (..), MintedGrant (..), mintObjectGrantWithExpiry)
import En.Check (CheckDecision (Allowed))
import En.Revision qualified as En
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..), Subject (SubjectId))
import Kikan.En.Action qualified as Kikan
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Network.HTTP.Types (status200, status403, status404)
import Network.Wai (Application, pathInfo, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), mkAgentPrincipal)
import Shikigami.Agent.Run.Key (parseRunKey)
import Shikigami.Agent.RunJob (RunRouteKind (ConversationWorkflowRoute))
import Shikigami.App.Config (Role (AdminRole), revealSecretText)
import Shikigami.App.Config.Load (ConfigOptions (..), DiagnosticMode (NoDiagnostic), requireDatabaseUrl, runAppConfig)
import Shikigami.Integration.Danwa (AddressedMessage (..))
import Shikigami.Sink.GrantStore (upsertGrant)
import Shikigami.Sink.Permission (SinkKind (SDanwaConversation))
import Shikigami.Trigger.Enqueue (addressedRunJob, enqueueRunJob)
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.FilePath ((</>))
import Text.Read (readMaybe)

main :: IO ()
main =
  getArgs >>= \case
    ["authority", prefix, rawPort]
      | Just port <- readMaybe rawPort,
        port >= 1024,
        port <= 65535 -> do
          application <- authorityApplication prefix
          runSettings (setHost "127.0.0.1" (setPort port defaultSettings)) application
    ["enqueue-conversation", configFile, conversation, message, content] -> withFixtureStore configFile \store -> do
      now <- getCurrentTime
      let actor = VerifiedIdentity (checked (mkAgentPrincipal "agent_01h000000000000000triage"))
          addressed = AddressedMessage (declarationCoordinate (Text.pack conversation)) (declarationCoordinate (Text.pack message)) Nothing (declarationCoordinate "human") (Text.pack content) (declarationCoordinate "fixture-participant") (declarationCoordinate ("fixture-envelope-" <> Text.pack message)) (declarationCoordinate "human") now
          job = addressedRunJob now actor (checked (mkAgentName "triage")) ConversationWorkflowRoute (Aeson.toJSON addressed) (checked (parseRunKey ("ir13-conversation-" <> Text.pack message)))
      void (requireRight =<< enqueueRunJob store.pool job)
      putStrLn "conversation turn enqueued through the production producer"
    ["grant-conversation", configFile] -> withFixtureStore configFile \store -> do
      let actor = VerifiedIdentity (checked (mkAgentPrincipal "agent_01h000000000000000triage"))
      requireRight =<< upsertGrant store.pool "triage" actor SDanwaConversation (Just "ir13-fixture")
    _ -> fail "usage: objective-tracking-fixture authority DIRECTORY PORT | enqueue-conversation CONFIG CONVERSATION MESSAGE CONTENT | grant-conversation CONFIG"

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (fail . show) pure

withFixtureStore :: FilePath -> (KirokuStore -> IO a) -> IO a
withFixtureStore configFile use = do
  config <- runAppConfig AdminRole (ConfigOptions [configFile] [] [] NoDiagnostic)
  connection <- revealSecretText <$> requireDatabaseUrl "objective-tracking-fixture" config
  withStore (defaultConnectionSettings connection) use

-- A fixed public fixture key signs the exact principal, action, audience and
-- request. The production verifier still checks every proof. No host credential
-- or authorization bypass is used.
authorityApplication :: FilePath -> IO Application
authorityApplication prefix = do
  (keyId, secret) <- requireRight (parseSigningKeyText "1:a2c4ead323536b925f3488ee83e0888b79c2761405ca7c0c9a018c7c1905eecc")
  Bytes.writeFile (prefix </> "issuer-public.txt") (Encoding.encodeUtf8 (renderIssuerKeySetText (singleKey keyId (toPublic secret))))
  pure \request respond -> do
    denied <- doesFileExist (prefix </> "deny-authority")
    case pathInfo request of
      ["v1", "agent-actions", "authorize"] | not denied && lookup "Authorization" (requestHeaders request) == Just "Bearer objective-fixture-token" -> do
        body <- strictRequestBody request
        case Aeson.eitherDecode body of
          Right (accepted :: Kikan.AuthorizeActionRequest)
            | Kikan.agentPrincipalText accepted.principal `elem` ["agent_01h000000000000000triage", "agent_01h000000000000000coordinator", "agent_01h000000000000000successor"] -> do
                now <- getCurrentTime
                let expiry = addUTCTime 30 now
                    grant = Grant.EnGrant (SubjectId (ObjectRef (ObjectType "agent") (Kikan.agentPrincipalText accepted.principal))) (RelationName (Kikan.actionOperation accepted.action)) (ObjectRef (ObjectType (Kikan.actionObjectType accepted.action)) (Kikan.actionObjectId accepted.action)) (En.ConsistencyToken "objective-fixture") (En.SchemaHash "objective-fixture-schema") expiry (Grant.Audience "shikigami") (Just (Grant.RequestId (Kikan.requestIdText accepted.requestId))) Nothing
                minted <- requireRight =<< mintObjectGrantWithExpiry (MintConfig secret keyId 30 (pure now)) expiry Allowed grant
                proof <- requireRight (Kikan.mkDecisionProof (Encoding.decodeUtf8 minted.token))
                consistency <- requireRight (Kikan.mkConsistencyToken "objective-fixture")
                -- Match Kikan's public issuer boundary. The frozen En source
                -- can report fractional metadata although Biscuit signs whole
                -- seconds; the verifier requires the response and token to agree.
                -- mori://shinzui/kikan-en, src/Kikan/En/Action/Server.hs
                -- (artifact URI pending).
                let signedExpiry = posixSecondsToUTCTime (fromInteger (round (utcTimeToPOSIXSeconds minted.expiresAt)))
                respond (json status200 (Aeson.toJSON (Kikan.IssuedActionProof proof signedExpiry [] consistency)))
          _ -> respond (json status403 refused)
      ["v1", "agent-actions", "authorize"] -> respond (json status403 refused)
      _ -> respond (json status404 refused)
  where
    json status body = responseLBS status [("Content-Type", "application/json")] (Aeson.encode body)
    refused = Aeson.object ["type" Aeson..= ("about:blank" :: Text.Text), "title" Aeson..= ("Fixture refusal" :: Text.Text), "status" Aeson..= (403 :: Int), "detail" Aeson..= ("fixture authority refused" :: Text.Text)]
