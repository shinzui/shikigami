-- Total concept-owned technical identity bindings.
module Shikigami.WorkerSession.Bindings where

import Data.Aeson (Value (String))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Keiro.Codec.Nominal (NominalBinding (..), NominalFixture (..), NominalFixtureCases (..))
import Shikigami.WorkerSession.Types (WorkerSessionId (value), workerSessionId)

initialWorkerSessionIdentity :: WorkerSessionId
initialWorkerSessionIdentity = workerSessionId ""

workerSessionIdentityBinding :: NominalBinding WorkerSessionId Text
workerSessionIdentityBinding = NominalBinding {nominalToRepresentation = \identity -> identity.value, nominalFromRepresentation = workerSessionId}

workerSessionIdentityCases :: NominalFixtureCases WorkerSessionId
workerSessionIdentityCases =
  NominalFixtureCases
    ( NominalFixture "empty" (String "") (workerSessionId "")
        :| [ NominalFixture "technical" (String "technical:identity-1") (workerSessionId "technical:identity-1"),
             NominalFixture "unicode" (String "identité-2") (workerSessionId "identité-2")
           ]
    )
