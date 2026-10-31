-- Total concept-owned technical identity bindings.
module Shikigami.WorkerSession.Bindings where

import Data.Aeson (Value (String))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Keiro.Codec.Nominal (NominalBinding (..), NominalFixture (..), NominalFixtureCases (..))
import Shikigami.WorkerSession.Types (WorkerSessionId (..))

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
