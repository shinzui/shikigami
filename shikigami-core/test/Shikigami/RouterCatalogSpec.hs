module Shikigami.RouterCatalogSpec (tests) where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    AmbiguousPolicy (ReturnAmbiguous),
    Behavior (..),
    ExpertiseDecl (..),
    IdentityDecl (..),
    NoMatchPolicy (ReturnNoMatch),
    RouterConfidence (RoutingMedium),
    RouterPolicy (..),
    Trigger (..),
    defaultMemoryPolicy,
  )
import Shikigami.Agent.ExpertiseKey (ExpertiseKey, parseExpertiseKey)
import Shikigami.Agent.Loader
  ( AgentLoadEntry (AgentLoadFailed, AgentLoaded),
    AgentLoadReport (..),
    LoadError (..),
  )
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Directory
  ( DirectorySnapshot,
    DirectorySourceKind (..),
    Lifecycle,
    PrincipalRecord (..),
    disabledDirectoryHandle,
    newDirectoryHandle,
    readDirectorySnapshot,
    refreshDirectory,
    staticDirectorySource,
  )
import Shikigami.Directory qualified as Directory
import Shikigami.Prelude
import Shikigami.Router.Catalog
import Shikigami.Router.Declaration (ValidatedRouterDeclaration, validateRouterDeclaration)
import Shikigami.Router.SelectionLimit (SelectionLimit, parseSelectionLimit)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "router catalog"
    [ testCase "declared candidates only" do
        snapshot <- configuredSnapshot [principalRecord "opentelemetry-reviewer" Directory.Active]
        let report =
              AgentLoadReport
                [ loaded "otel.dhall" (specialist "opentelemetry-reviewer" True Nothing),
                  loaded "disabled.dhall" (specialist "disabled-reviewer" False Nothing),
                  loaded "duplicate-a.dhall" (specialist "duplicate-reviewer" True Nothing),
                  loaded "duplicate-b.dhall" (specialist "duplicate-reviewer" True Nothing),
                  loaded "undeclared.dhall" (specialist "security-reviewer" True Nothing),
                  failed "/secret/failed-manifest.dhall" "secret Dhall diagnostic"
                ]
            catalog = build report snapshot ["opentelemetry-reviewer", "disabled-reviewer", "duplicate-reviewer", "missing-reviewer"]
        candidateNames catalog
          @?= ["opentelemetry-reviewer", "disabled-reviewer", "duplicate-reviewer", "missing-reviewer"]
        candidateAvailabilities catalog
          @?= [Available, Excluded Disabled, Excluded DuplicateDeclaration, Excluded MissingDeclaration]
        (.unassociatedLoadFailures) catalog @?= 1,
      testCase "one immutable lifecycle snapshot" do
        principalsRef <- newIORef [principalRecord "opentelemetry-reviewer" Directory.Active]
        directoryHandle <- newDirectoryHandle (readIORef principalsRef >>= staticDirectorySource)
        refreshDirectory directoryHandle >>= (@?= Right ())
        captured <- readDirectorySnapshot directoryHandle
        writeIORef principalsRef [principalRecord "opentelemetry-reviewer" Directory.Paused]
        refreshDirectory directoryHandle >>= (@?= Right ())
        current <- readDirectorySnapshot directoryHandle
        let report = AgentLoadReport [loaded "otel.dhall" (specialist "opentelemetry-reviewer" True Nothing)]
            capturedCatalog = build report captured ["opentelemetry-reviewer"]
            currentCatalog = build report current ["opentelemetry-reviewer"]
        candidateAvailabilities capturedCatalog @?= [Available]
        candidateAvailabilities currentCatalog @?= [Excluded Paused]
        assertBool "lifecycle change changes catalog version" ((.version) capturedCatalog /= (.version) currentCatalog),
      testCase "lifecycle exclusions are explicit" do
        snapshot <-
          configuredSnapshot
            [ principalRecord "active-reviewer" Directory.Active,
              principalRecord "paused-reviewer" Directory.Paused,
              principalRecord "deactivated-reviewer" Directory.Deactivated,
              principalRecord "explicit-handle" Directory.Active
            ]
        let names = ["active-reviewer", "paused-reviewer", "deactivated-reviewer", "unknown-reviewer", "disabled-reviewer", "explicit-handle"]
            declarations =
              [ specialist "active-reviewer" True Nothing,
                specialist "paused-reviewer" True Nothing,
                specialist "deactivated-reviewer" True Nothing,
                specialist "unknown-reviewer" True Nothing,
                specialist "disabled-reviewer" False Nothing,
                specialist "explicit-handle" True (Just "agent_unknown")
              ]
            catalog = build (reportOf declarations) snapshot names
        (.lifecycleSource) catalog @?= DirectoryFileSource
        candidateAvailabilities catalog
          @?= [ Available,
                Excluded Paused,
                Excluded Deactivated,
                Excluded UnknownPrincipal,
                Excluded Disabled,
                Excluded UnknownPrincipal
              ],
      testCase "configured unavailability fails closed while disabled mode is honest" do
        unavailableHandle <- newDirectoryHandle (pure (Left "directory offline"))
        unavailable <- readDirectorySnapshot unavailableHandle
        localEnabled <- readDirectorySnapshot disabledDirectoryHandle
        let declaration = specialist "reviewer" True Nothing
            disabledDeclaration = specialist "disabled-reviewer" False Nothing
            report = reportOf [declaration, disabledDeclaration]
            names = ["reviewer", "disabled-reviewer"]
            unavailableCatalog = build report unavailable names
            localCatalog = build report localEnabled names
            unavailableJson = renderCatalog unavailableCatalog
            localJson = renderCatalog localCatalog
        (.lifecycleSource) unavailableCatalog @?= DirectoryFileSource
        candidateAvailabilities unavailableCatalog @?= [Excluded LifecycleUnavailable, Excluded Disabled]
        assertBool "file mode is honestly attributed" ("directory-file" `Text.isInfixOf` unavailableJson)
        (.lifecycleSource) localCatalog @?= DirectoryDisabledSource
        candidateAvailabilities localCatalog @?= [Available, Excluded Disabled]
        assertBool "disabled mode is honestly attributed" ("local-enabled" `Text.isInfixOf` localJson)
        assertBool "neither shipped mode claims a live client" (not ("meibo-client" `Text.isInfixOf` (unavailableJson <> localJson))),
      testCase "duplicate declaration names fail closed without copied metadata" do
        snapshot <- configuredSnapshot [principalRecord "reviewer" Directory.Active]
        let catalog =
              build
                (reportOf [specialist "reviewer" True Nothing, specialistWithDescription "conflicting description" "reviewer" True Nothing])
                snapshot
                ["reviewer"]
        (.candidates) catalog
          @?= [ CandidateEntry
                  { name = fixtureAgentName "reviewer",
                    description = Nothing,
                    expertise = [],
                    availability = Excluded DuplicateDeclaration
                  }
              ],
      testCase "failed manifests contribute only an unassociated count" do
        snapshot <- configuredSnapshot [principalRecord "reviewer" Directory.Active]
        let declaration = (specialist "reviewer" True Nothing) {behavior = Deterministic {rule = "secret behavior prompt", params = Map.empty}}
            catalog =
              build
                (AgentLoadReport [loaded "reviewer.dhall" declaration, failed "/secret/path.dhall" "secret diagnostic"])
                snapshot
                ["reviewer"]
            rendered = Text.Encoding.decodeUtf8 (LBS.toStrict (encode catalog))
        (.unassociatedLoadFailures) catalog @?= 1
        assertBool "behavior body is redacted" (not ("secret behavior prompt" `Text.isInfixOf` rendered))
        assertBool "failure path is redacted" (not ("secret/path" `Text.isInfixOf` rendered))
        assertBool "failure diagnostic is redacted" (not ("secret diagnostic" `Text.isInfixOf` rendered)),
      testCase "identical snapshots have identical versions and JSON" do
        snapshot <- configuredSnapshot [principalRecord "reviewer" Directory.Active]
        let report = reportOf [specialist "reviewer" True Nothing]
            first = build report snapshot ["reviewer"]
            second = build report snapshot ["reviewer"]
        (.version) first @?= (.version) second
        encode first @?= encode second
        eitherDecode (encode first) @?= Right first,
      testCase "every model-visible change changes the catalog version" do
        activeSnapshot <- configuredSnapshot [principalRecord "reviewer" Directory.Active]
        pausedSnapshot <- configuredSnapshot [principalRecord "reviewer" Directory.Paused]
        let first = build (reportOf [specialist "reviewer" True Nothing]) activeSnapshot ["reviewer"]
            changedDescription = build (reportOf [specialistWithDescription "changed" "reviewer" True Nothing]) activeSnapshot ["reviewer"]
            changedLifecycle = build (reportOf [specialist "reviewer" True Nothing]) pausedSnapshot ["reviewer"]
            changedFailureCount = build (AgentLoadReport [loaded "reviewer.dhall" (specialist "reviewer" True Nothing), failed "broken.dhall" "broken"]) activeSnapshot ["reviewer"]
        assertBool "description changes version" ((.version) first /= (.version) changedDescription)
        assertBool "lifecycle changes version" ((.version) first /= (.version) changedLifecycle)
        assertBool "failure count changes version" ((.version) first /= (.version) changedFailureCount)
    ]

build :: AgentLoadReport -> DirectorySnapshot -> [Text] -> CandidateCatalog
build report snapshot delegates =
  buildCandidateCatalog report snapshot (validatedRouter delegates)

validatedRouter :: [Text] -> ValidatedRouterDeclaration
validatedRouter delegates =
  case validateRouterDeclaration (routerDeclarationFixture delegates) of
    Left errors -> error ("invalid router test fixture: " <> show errors)
    Right validated -> validated

routerDeclarationFixture :: [Text] -> AgentDecl
routerDeclarationFixture delegates =
  AgentDecl
    { name = fixtureAgentName "architecture-practice-router",
      description = "Routes architecture practice reviews",
      trigger = Event {eventType = "proof.architecture-practice"},
      behavior = Deterministic {rule = "route", params = Map.empty},
      sinks = [],
      delegates = map fixtureAgentName delegates,
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing =
        Just
          RouterPolicy
            { maxSelections = fixtureSelectionLimit 1,
              minimumConfidence = RoutingMedium,
              onNoMatch = ReturnNoMatch,
              onAmbiguous = ReturnAmbiguous
            }
    }

specialist :: Text -> Bool -> Maybe Text -> AgentDecl
specialist name = specialistWithDescription ("Reviews " <> name) name

specialistWithDescription :: Text -> Text -> Bool -> Maybe Text -> AgentDecl
specialistWithDescription description name enabled declaredPrincipal =
  AgentDecl
    { name = fixtureAgentName name,
      description,
      trigger = Event {eventType = "proof.specialist"},
      behavior = Deterministic {rule = "review", params = Map.empty},
      sinks = [],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = IdentityDecl <$> declaredPrincipal,
      memory = defaultMemoryPolicy,
      enabled,
      expertise =
        [ ExpertiseDecl
            { key = fixtureExpertiseKey name,
              description = "Expertise for " <> name,
              aliases = [],
              evidenceHints = []
            }
        ],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

principalRecord :: Text -> Lifecycle -> PrincipalRecord
principalRecord handle lifecycle =
  PrincipalRecord
    { principalId = "agent_" <> handle,
      handle,
      lifecycle
    }

configuredSnapshot :: [PrincipalRecord] -> IO DirectorySnapshot
configuredSnapshot principals = do
  directoryHandle <- newDirectoryHandle (staticDirectorySource principals)
  refreshDirectory directoryHandle >>= \case
    Left problem -> assertFailure ("expected valid directory fixture: " <> show problem)
    Right () -> readDirectorySnapshot directoryHandle

reportOf :: [AgentDecl] -> AgentLoadReport
reportOf declarations =
  AgentLoadReport
    [loaded ("agent-" <> show position <> ".dhall") declaration | (position, declaration) <- zip [(1 :: Int) ..] declarations]

loaded :: FilePath -> AgentDecl -> AgentLoadEntry
loaded = AgentLoaded

failed :: FilePath -> Text -> AgentLoadEntry
failed path problem = AgentLoadFailed path (LoadError problem)

candidateNames :: CandidateCatalog -> [Text]
candidateNames CandidateCatalog {candidates} = [agentNameText name | CandidateEntry {name} <- candidates]

candidateAvailabilities :: CandidateCatalog -> [CandidateAvailability]
candidateAvailabilities CandidateCatalog {candidates} = [availability | CandidateEntry {availability} <- candidates]

renderCatalog :: CandidateCatalog -> Text
renderCatalog = Text.Encoding.decodeUtf8 . LBS.toStrict . encode

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureSelectionLimit :: Integer -> SelectionLimit
fixtureSelectionLimit = either (error . show) id . parseSelectionLimit . fromInteger

fixtureExpertiseKey :: Text -> ExpertiseKey
fixtureExpertiseKey = either (error . show) id . parseExpertiseKey
