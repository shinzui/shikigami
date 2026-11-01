-- Total concept-owned technical identity bindings.
module Shikigami.Execution.Bindings where

import Data.Aeson (Value (String))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Keiro.Codec.Nominal (NominalBinding (..), NominalFixture (..), NominalFixtureCases (..))
import Shikigami.Execution.Transcript (ExecutionId (..), executionIdentity)

initialExecutionIdentity :: ExecutionId
initialExecutionIdentity = executionIdentity ""

executionIdentityBinding :: NominalBinding ExecutionId Text
executionIdentityBinding = NominalBinding {nominalToRepresentation = \identity -> identity.value, nominalFromRepresentation = executionIdentity}

executionIdentityCases :: NominalFixtureCases ExecutionId
executionIdentityCases =
  NominalFixtureCases
    ( NominalFixture "empty" (String "") (executionIdentity "")
        :| [ NominalFixture "technical" (String "technical:identity-1") (executionIdentity "technical:identity-1"),
             NominalFixture "unicode" (String "identité-2") (executionIdentity "identité-2")
           ]
    )
