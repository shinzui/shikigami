module Shikigami.WorkspaceAdapterSpec (tests) where

import Data.Aeson (object)
import Data.Either (isLeft)
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (Behavior (Skill))
import Shikigami.Agent.DeclarationValue
import Shikigami.Capability.Catalog
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider
import Shikigami.Execution.Coordinate qualified as ExecutionValue
import Shikigami.Execution.Policy.Types
import Shikigami.Trigger.Schedule (parseCron)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "workspace durable adapter admission"
    [ testCase "generic durable resolution still refuses installed mutation descriptors" $ do
        registry <- right (installDurableAdapters [adapter] emptyCapabilityProviderRegistry)
        catalog <- right (mkCapabilityCatalog [descriptor])
        assertBool "generic gate retained" (isLeft (resolveCapabilityOverlays catalog allow subject [capability]))
        resolveGovernedCapabilityOverlays (durableAdapterInstalled registry) catalog allow subject [capability] @?= Right (mkResolvedCapabilitySet [descriptor]),
      testCase "copying a descriptor without its exact adapter cannot grant mutation" $ do
        catalog <- right (mkCapabilityCatalog [descriptor])
        assertBool "no adapter" (isLeft (resolveGovernedCapabilityOverlays (durableAdapterInstalled emptyCapabilityProviderRegistry) catalog allow subject [capability]))
        registry <- right (installDurableAdapters [adapter] emptyCapabilityProviderRegistry)
        changed <- right (mkCapabilityRevision "2")
        let other = CapabilityDescriptor capability changed [CapabilityToolDescriptor "edit" IdempotentMutation]
        changedCatalog <- right (mkCapabilityCatalog [other])
        assertBool "revision mismatch" (isLeft (resolveGovernedCapabilityOverlays (durableAdapterInstalled registry) changedCatalog allow subject [capability]))
        durableAdapterInstalled registry (CapabilityDescriptor capability revision [CapabilityToolDescriptor "other" IdempotentMutation]) @?= False,
      testCase "duplicate revisions and incomplete recovery contracts fail installation" $ do
        assertBool "duplicate exact adapter" (isLeft (installDurableAdapters [adapter, adapter] emptyCapabilityProviderRegistry))
        assertBool "missing tool contract" (isLeft (installDurableAdapters [DurableAdapter descriptor [] unavailable] emptyCapabilityProviderRegistry))
        let invalid = DurableToolContract (ExecutionValue.executionCoordinate "edit") "Edit." (object []) RepeatableObservation NoInvoiceCost
        assertBool "mutation cannot borrow observation recovery" (isLeft (installDurableAdapters [DurableAdapter descriptor [invalid] unavailable] emptyCapabilityProviderRegistry)),
      testCase "installed adapters do not replace declaration or policy authorization" $ do
        registry <- right (installDurableAdapters [adapter] emptyCapabilityProviderRegistry)
        catalog <- right (mkCapabilityCatalog [descriptor])
        resolveGovernedCapabilityOverlays (durableAdapterInstalled registry) catalog allow subject [] @?= Right emptyResolvedCapabilitySet
        assertBool "policy denial survives adapter installation" (isLeft (resolveGovernedCapabilityOverlays (durableAdapterInstalled registry) catalog (\_ _ -> Left (CapabilityAuthorizationDenied capability "denied")) subject [capability]))
    ]
  where
    capability = either (error . show) id (mkCapabilityId "workspace.edit")
    revision = either (error . show) id (mkCapabilityRevision "1")
    descriptor = CapabilityDescriptor capability revision [CapabilityToolDescriptor "edit" IdempotentMutation]
    adapter = DurableAdapter descriptor [DurableToolContract (ExecutionValue.executionCoordinate "edit") "Edit." (object []) IdempotentEffect NoInvoiceCost] unavailable
    unavailable _ _ _ = assertFailure "admission invoked an adapter callback" >> fail "unreachable"
    subject = ResolutionSubject (fmap declarationCoordinate ((Just "worker"))) Durable (Skill (declarationCoordinate ("fixture"))) Nothing
    allow _ _ = Right ()
    right :: (Show e) => Either e a -> IO a
    right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
