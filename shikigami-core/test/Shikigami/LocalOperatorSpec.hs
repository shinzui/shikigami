module Shikigami.LocalOperatorSpec (tests) where

import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Unique (hashUnique, newUnique)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), IdentityDecl (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.DeclarationValue (agentEnablement, declarationCoordinate)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Authority
import Shikigami.Capability.Overlay (CapabilityId, mkCapabilityId)
import Shikigami.Repository (repositoryIdText)
import Shikigami.Trust.LocalOperator.Approvals
import Shikigami.Trust.LocalOperator.Authority
import Shikigami.Trust.LocalOperator.Grant
import Shikigami.Trust.Tier
import System.Directory (canonicalizePath, createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "LocalOperator"
    [ tierTests,
      approvalsTests,
      grantTests,
      authorityTests
    ]

tierTests :: TestTree
tierTests =
  testGroup
    "TrustTier"
    [ testCase "tier text round-trips and unknown text is refused" do
        mapM_ (\tier -> parseTrustTier (trustTierText tier) @?= Right tier) [minBound .. maxBound]
        assertBool "unknown tier" (isLeft (parseTrustTier "local"))
    ]

-- | A temporary Git checkout and a state directory, removed afterwards.
withCheckout :: (FilePath -> FilePath -> IO a) -> IO a
withCheckout use = do
  temporary <- getTemporaryDirectory
  unique <- hashUnique <$> newUnique
  let root = temporary </> ("shikigami-local-operator-spec-" <> show unique)
      checkout = root </> "repo"
      state = root </> "state"
  removePathForcibly root
  createDirectoryIfMissing True checkout
  (code, _, err) <- readProcessWithExitCode "git" ["init", "-q", checkout] ""
  unlessSuccess code err
  result <- use checkout state
  removePathForcibly root
  pure result
  where
    unlessSuccess ExitSuccess _ = pure ()
    unlessSuccess _ err = assertFailure ("git init failed: " <> err)

approvalsTests :: TestTree
approvalsTests =
  testGroup
    "approvals file"
    [ testCase "a missing file is an empty set of approvals" do
        loaded <- loadLocalApprovals testResolver "/nonexistent/shikigami/local-operator.dhall"
        loaded @?= Right emptyApprovals,
      testCase "a valid file decodes and an unknown capability is refused" $ withCheckout \checkout state -> do
        let path = state </> "approvals.dhall"
        createDirectoryIfMissing True state
        schema <- schemaPath
        writeFile path (approvalsFile schema checkout ["workspace.read"])
        loaded <- loadLocalApprovals testResolver path
        case loaded of
          Left problem -> assertFailure (Text.unpack (renderApprovalsError problem))
          Right approvals -> do
            fmap (\r -> repositoryIdText r.identity) approvals.repositories @?= ["mori://test/repo"]
            fmap (\a -> a.capabilities) approvals.approvals @?= [Set.fromList [capability "workspace.read"]]
        writeFile path (approvalsFile schema checkout ["workspace.teleport"])
        loadLocalApprovals testResolver path >>= \case
          Left UnknownCapability {} -> pure ()
          other -> assertFailure ("expected UnknownCapability, got " <> show other),
      testCase "a source that is not a Git top level is refused" $ withCheckout \checkout state -> do
        let path = state </> "approvals.dhall"
            nested = checkout </> "nested"
        createDirectoryIfMissing True nested
        createDirectoryIfMissing True state
        schema <- schemaPath
        writeFile path (approvalsFile schema nested ["workspace.read"])
        loadLocalApprovals testResolver path >>= \case
          Left RepositoryNotGitToplevel {} -> pure ()
          other -> assertFailure ("expected RepositoryNotGitToplevel, got " <> show other),
      testCase "an unlisted checkout is selected by path with the default placement" $ withCheckout \checkout _ -> do
        selected <- selectRepository testResolver emptyApprovals (SelectByPath checkout)
        case selected of
          Right repository -> do
            repository.placement @?= SeparateWorktree
            repository.base @?= "HEAD"
          Left problem -> assertFailure (Text.unpack (renderApprovalsError problem))
    ]

grantTests :: TestTree
grantTests =
  testGroup
    "grants"
    [ testCase "an approvals entry is the grant and is never prompted for" $ withCheckout \checkout state -> do
        (approvals, repository) <- approvedRepository checkout state ["workspace.read"]
        store <- openStore state
        (ask, asked) <- countingPrompt True
        grant <- resolveGrant ask approvals store noRecord (decl ["workspace.read"]) repository
        fmap (\g -> g.grantedBy) grant @?= Right FromApprovalsFile
        asked >>= (@?= 0),
      testCase "a request beyond its approvals entry is refused" $ withCheckout \checkout state -> do
        (approvals, repository) <- approvedRepository checkout state ["workspace.read"]
        store <- openStore state
        grant <- resolveGrant Unattended approvals store noRecord (decl ["workspace.read", "workspace.edit"]) repository
        grant @?= Left (RequestExceedsApproval (Set.fromList [capability "workspace.edit"])),
      testCase "an interactive yes is recorded, stored and not asked again" $ withCheckout \checkout state -> do
        repository <- either (fail . show) pure =<< selectRepository testResolver emptyApprovals (SelectByPath checkout)
        store <- openStore state
        (ask, asked) <- countingPrompt True
        recorded' <- newIORef (0 :: Int)
        let recordOnce _ = modifyIORef' recorded' (+ 1) >> pure (Right ())
        first' <- resolveGrant ask emptyApprovals store recordOnce (decl ["workspace.read"]) repository
        second <- resolveGrant ask emptyApprovals store recordOnce (decl ["workspace.read"]) repository
        assertBool "first grant confirmed" (either (const False) (\g -> case g.grantedBy of ConfirmedByOperator _ -> True; _ -> False) first')
        fmap (\g -> g.digest) second @?= fmap (\g -> g.digest) first'
        asked >>= (@?= 1)
        readIORef recorded' >>= (@?= 1),
      testCase "a no is a refusal and nothing is stored" $ withCheckout \checkout state -> do
        repository <- either (fail . show) pure =<< selectRepository testResolver emptyApprovals (SelectByPath checkout)
        store <- openStore state
        (ask, _) <- countingPrompt False
        resolveGrant ask emptyApprovals store noRecord (decl ["workspace.read"]) repository >>= (@?= Left OperatorDeclined)
        store.list >>= \listed -> fmap length listed @?= Right 0,
      testCase "an unattended run with no stored grant is refused" $ withCheckout \checkout state -> do
        repository <- either (fail . show) pure =<< selectRepository testResolver emptyApprovals (SelectByPath checkout)
        store <- openStore state
        resolveGrant Unattended emptyApprovals store noRecord (decl ["workspace.read"]) repository >>= \case
          Left NoStoredGrant {} -> pure ()
          other -> assertFailure ("expected NoStoredGrant, got " <> show other),
      testCase "any change to the declaration changes its digest" $ withCheckout \checkout _ -> do
        repository <- either (fail . show) pure =<< selectRepository testResolver emptyApprovals (SelectByPath checkout)
        let original = decl ["workspace.read"]
            edited = original {description = "x"}
        assertBool "digest changes" (grantDigest original repository /= grantDigest edited repository),
      testCase "a failing record refuses the confirmation and stores nothing" $ withCheckout \checkout state -> do
        repository <- either (fail . show) pure =<< selectRepository testResolver emptyApprovals (SelectByPath checkout)
        store <- openStore state
        (ask, _) <- countingPrompt True
        resolveGrant ask emptyApprovals store (\_ -> pure (Left "record unavailable")) (decl ["workspace.read"]) repository
          >>= (@?= Left (GrantUnavailable "record unavailable"))
        store.list >>= \listed -> fmap length listed @?= Right 0
    ]

authorityTests :: TestTree
authorityTests =
  testGroup
    "local authority"
    [ testCase "granted capabilities are approved and everything else is refused" $ withCheckout \checkout state -> do
        (approvals, repository) <- approvedRepository checkout state ["workspace.read"]
        store <- openStore state
        grant <- either (fail . show) pure =<< resolveGrant Unattended approvals store noRecord (decl ["workspace.read"]) repository
        let selection = LocalSelection {agent = agentName, principals = Set.fromList [principal], grant}
            read' = either (error . Text.unpack) id (invokeToolAction "workspace.read" "1" "read")
            edit = either (error . Text.unpack) id (invokeToolAction "workspace.edit" "local-1" "replace")
            emit = either (error . Text.unpack) id (EmitOutput <$> mkOutputKind "kizashi.signal" <*> mkOutputTarget (pure "person"))
        decideLocalAction selection principal read' @?= Approved grant.digest
        decideLocalAction selection principal edit @?= Refused (CapabilityNotGranted "workspace.edit")
        decideLocalAction selection (declarationCoordinate "someone_else") read' @?= Refused ForeignPrincipal
        decideLocalAction selection principal emit @?= Refused (OutsideGrant "emit_output")
        (localOperatorAuthority selection).source @?= DecidedByOperator
        refused <- (localOperatorAuthority selection).decide principal edit
        assertBool "a refusal is a policy denial" (case refused of Left PolicyDenied {} -> True; _ -> False)
    ]

agentName :: AgentName
agentName = either (error . Text.unpack) id (mkAgentName "local-maintainer")

principal :: Principal
principal = declarationCoordinate "principal_local_maintainer"

capability :: Text -> CapabilityId
capability = either (error . show) id . mkCapabilityId

decl :: [Text] -> AgentDecl
decl capabilities =
  AgentDecl
    { name = agentName,
      description = "",
      trigger = Event {eventType = declarationCoordinate "local.maintenance.requested"},
      behavior = Skill {path = declarationCoordinate "agents/skills/local-maintainer"},
      sinks = [],
      delegates = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = capability <$> capabilities,
      identity = Just IdentityDecl {principal},
      memory = defaultMemoryPolicy,
      enabled = agentEnablement True,
      expertise = [],
      routing = Nothing
    }

approvalsFile :: FilePath -> FilePath -> [Text] -> String
approvalsFile schema checkout capabilities =
  unlines
    [ "let L = " <> schema,
      "in  L.Approvals::{",
      "    , repositories = [ L.Repository::{ identity = \"mori://test/repo\", source = Some \"" <> checkout <> "\" } ]",
      "    , agents = [ L.AgentApproval::{ agent = \"local-maintainer\", repository = \"mori://test/repo\", capabilities = " <> show (Text.unpack <$> capabilities) <> " } ]",
      "    }"
    ]

-- | The checked-in schema, by absolute path: Dhall resolves a relative
-- import against the importing file, which lives in a temporary directory.
schemaPath :: IO FilePath
schemaPath = canonicalizePath "../schema/LocalOperator.dhall"

approvedRepository :: FilePath -> FilePath -> [Text] -> IO (LocalApprovals, LocalRepository)
approvedRepository checkout state capabilities = do
  createDirectoryIfMissing True state
  let path = state </> "approvals.dhall"
  schema <- schemaPath
  writeFile path (approvalsFile schema checkout capabilities)
  approvals <- either (fail . Text.unpack . renderApprovalsError) pure =<< loadLocalApprovals testResolver path
  repository <- either (fail . Text.unpack . renderApprovalsError) pure =<< selectRepository testResolver approvals (SelectByPath checkout)
  pure (approvals, repository)

openStore :: FilePath -> IO GrantStore
openStore state = either (fail . show) pure =<< openGrantStore state

noRecord :: LocalGrant -> IO (Either Text ())
noRecord _ = pure (Right ())

countingPrompt :: Bool -> IO (Interaction, IO Int)
countingPrompt answer = do
  count <- newIORef 0
  pure (Interactive (\_ -> modifyIORef' count (+ 1) >> pure answer), readIORef count)

-- | A Git-only resolver: these tests use no Mori registry.
testResolver :: CheckoutResolver
testResolver =
  CheckoutResolver
    { toplevelOf = \directory -> do
        (code, out, err) <- readProcessWithExitCode "git" ["-C", directory, "rev-parse", "--show-toplevel"] ""
        pure case (code, lines out) of
          (ExitSuccess, [top]) -> Right top
          _ -> Left (Text.pack err),
      moriPath = \_ -> pure (Left "no Mori registry in tests"),
      moriIdentity = \_ -> pure Nothing
    }
