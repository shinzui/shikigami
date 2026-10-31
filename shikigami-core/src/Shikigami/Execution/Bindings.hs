-- Total concept-owned technical identity bindings.
module Shikigami.Execution.Bindings where

import Data.Aeson (Value (String))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Keiro.Codec.Nominal (NominalBinding (..), NominalFixture (..), NominalFixtureCases (..))
import Shikigami.Execution.Transcript (ExecutionId (..))

initialExecutionIdentity :: ExecutionId
initialExecutionIdentity = ExecutionId ""

executionIdentityBinding :: NominalBinding ExecutionId Text
executionIdentityBinding = NominalBinding {nominalToRepresentation = \identity -> identity.value, nominalFromRepresentation = ExecutionId}

executionIdentityCases :: NominalFixtureCases ExecutionId
executionIdentityCases =
  NominalFixtureCases
    ( NominalFixture "empty" (String "") (ExecutionId "")
        :| [ NominalFixture "technical" (String "technical:identity-1") (ExecutionId "technical:identity-1"),
             NominalFixture "unicode" (String "identité-2") (ExecutionId "identité-2")
           ]
    )
