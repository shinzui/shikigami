-- Total bindings for technical identities. Wire admission stays in generated codecs.
module Shikigami.DomainBindings where

import Data.Aeson (Value (String))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Keiro.Codec.Nominal (NominalBinding (..), NominalFixture (..), NominalFixtureCases (..))
import Shikigami.Execution.Transcript (ExecutionId (..))
import Shikigami.Objective.Types (ObjectiveId (..))
import Shikigami.WorkerSession.Types (WorkerSessionId (..))

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

initialWorkerSessionIdentity :: WorkerSessionId
initialWorkerSessionIdentity = WorkerSessionId ""

workerSessionIdentityBinding :: NominalBinding WorkerSessionId Text
workerSessionIdentityBinding = NominalBinding {nominalToRepresentation = \identity -> identity.value, nominalFromRepresentation = WorkerSessionId}

workerSessionIdentityCases :: NominalFixtureCases WorkerSessionId
workerSessionIdentityCases =
  NominalFixtureCases
    ( NominalFixture "empty" (String "") (WorkerSessionId "")
        :| [ NominalFixture "technical" (String "technical:identity-1") (WorkerSessionId "technical:identity-1"),
             NominalFixture "unicode" (String "identité-2") (WorkerSessionId "identité-2")
           ]
    )

initialObjectiveIdentity :: ObjectiveId
initialObjectiveIdentity = ObjectiveId ""

objectiveIdentityBinding :: NominalBinding ObjectiveId Text
objectiveIdentityBinding = NominalBinding {nominalToRepresentation = \identity -> identity.value, nominalFromRepresentation = ObjectiveId}

objectiveIdentityCases :: NominalFixtureCases ObjectiveId
objectiveIdentityCases =
  NominalFixtureCases
    ( NominalFixture "empty" (String "") (ObjectiveId "")
        :| [ NominalFixture "technical" (String "technical:identity-1") (ObjectiveId "technical:identity-1"),
             NominalFixture "unicode" (String "identité-2") (ObjectiveId "identité-2")
           ]
    )
