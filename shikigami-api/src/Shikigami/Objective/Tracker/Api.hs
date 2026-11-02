{-# LANGUAGE DataKinds #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Shikigami.Objective.Tracker.Api where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.OpenApi (NamedSchema (..), ToSchema (..), fromAesonOptions, genericDeclareNamedSchema)
import Data.SOP (I (..), NS (..))
import Relay.Pagination (Connection)
import Relay.Pagination.Servant (RelayPage, RelayPageError)
import Servant.API
import Servant.API.Generic ((:-))
import Servant.API.MultiVerb
import Shikigami.Api.Problem
import Shikigami.Execution.Identity (OperationId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.HttpEnvelope (envelope, schemaValue)
import Shikigami.Objective.Tracker.Control.Types (ControlRequest)
import Shikigami.Objective.Tracker.Inspection (BindingView, RecordView)
import Shikigami.Prelude hiding ((.=))

data TrackerCommand = TrackerCommand {operationKey :: !OperationId, request :: !ControlRequest}
  deriving stock (Eq, Show, Generic)

instance ToJSON TrackerCommand where
  toJSON value = Aeson.object ["format" .= (V1 :: FormatVersion "tracker-http-envelope"), "operationKey" .= value.operationKey, "request" .= value.request]

instance FromJSON TrackerCommand where
  parseJSON = Aeson.withObject "tracker command" \fields -> do
    envelope ["format", "operationKey", "request"] fields
    TrackerCommand <$> fields .: "operationKey" <*> fields .: "request"

data OperationView = OperationView {operationKey :: !Text, state :: !Text, failure :: !(Maybe Text), receiptDigest :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance ToSchema OperationView where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema RecordView where
  declareNamedSchema _ =
    pure
      ( NamedSchema
          (Just "TrackerRecordPreview")
          ( schemaValue
              ( Aeson.object
                  ["type" .= ("object" :: Text), "additionalProperties" .= False, "required" .= (["identity", "digest", "preview", "truncated"] :: [Text]), "properties" .= Aeson.object ["identity" .= Aeson.object ["type" .= ("string" :: Text)], "digest" .= Aeson.object ["type" .= ("string" :: Text)], "preview" .= Aeson.object [], "truncated" .= Aeson.object ["type" .= ("boolean" :: Text)]]]
              )
          )
      )

instance ToSchema BindingView where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

-- The wire parser owns the closed tagged request. No identity/URL/credential
-- input is admitted; nested commands use the retained tracker command codec.
instance ToSchema TrackerCommand where
  declareNamedSchema _ =
    pure
      ( NamedSchema
          (Just "TrackerCommand")
          ( schemaValue
              ( Aeson.object
                  [ "type" .= ("object" :: Text),
                    "additionalProperties" .= False,
                    "required" .= (["format", "operationKey", "request"] :: [Text]),
                    "properties"
                      .= Aeson.object
                        [ "format" .= Aeson.object ["type" .= ("integer" :: Text), "enum" .= ([1] :: [Int])],
                          "operationKey" .= Aeson.object ["type" .= ("string" :: Text), "maxLength" .= (256 :: Int)],
                          "request" .= Aeson.object ["type" .= ("object" :: Text), "additionalProperties" .= False, "required" .= (["tag", "contents"] :: [Text]), "properties" .= Aeson.object ["tag" .= Aeson.object ["type" .= ("string" :: Text), "enum" .= (["RunCommand", "Observe", "Reconcile", "Verify"] :: [Text])], "contents" .= Aeson.object []]]
                        ]
                  ]
              )
          )
      )

type Responses a =
  '[ Respond 200 "Ok" a,
     Respond 202 "Accepted" a,
     RespondAs ProblemJSON 400 "Invalid" ProblemDetails,
     RespondAs ProblemJSON 403 "Denied" ProblemDetails,
     RespondAs ProblemJSON 404 "Missing" ProblemDetails,
     RespondAs ProblemJSON 409 "Conflict" ProblemDetails,
     RespondAs ProblemJSON 413 "TooLarge" ProblemDetails,
     RespondAs ProblemJSON 503 "NotAvailable" ProblemDetails
   ]

data Result a = Ok !a | Accepted !a | Invalid !ProblemDetails | Denied !ProblemDetails | Missing !ProblemDetails | Conflict !ProblemDetails | TooLarge !ProblemDetails | NotAvailable !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion (Responses a) (Result a) where
  toUnion = \case
    Ok body -> Z (I body)
    Accepted body -> S (Z (I body))
    Invalid body -> S (S (Z (I body)))
    Denied body -> S (S (S (Z (I body))))
    Missing body -> S (S (S (S (Z (I body)))))
    Conflict body -> S (S (S (S (S (Z (I body))))))
    TooLarge body -> S (S (S (S (S (S (Z (I body)))))))
    NotAvailable body -> S (S (S (S (S (S (S (Z (I body))))))))
  fromUnion = \case
    Z (I body) -> Ok body
    S (Z (I body)) -> Accepted body
    S (S (Z (I body))) -> Invalid body
    S (S (S (Z (I body)))) -> Denied body
    S (S (S (S (Z (I body))))) -> Missing body
    S (S (S (S (S (Z (I body)))))) -> Conflict body
    S (S (S (S (S (S (Z (I body))))))) -> TooLarge body
    S (S (S (S (S (S (S (Z (I body)))))))) -> NotAvailable body
    S (S (S (S (S (S (S (S (impossible)))))))) -> case impossible of {}

type PageResponses =
  '[ Respond 200 "PageOk" (Connection RecordView),
     Respond 400 "PageInvalid" RelayPageError,
     RespondAs ProblemJSON 404 "PageMissing" ProblemDetails,
     RespondAs ProblemJSON 413 "PageTooLarge" ProblemDetails,
     RespondAs ProblemJSON 503 "PageUnavailable" ProblemDetails
   ]

data PageResult = PageOk !(Connection RecordView) | PageInvalid !RelayPageError | PageMissing !ProblemDetails | PageTooLarge !ProblemDetails | PageUnavailable !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion (PageResponses) (PageResult) where
  toUnion = \case
    PageOk body -> Z (I body)
    PageInvalid body -> S (Z (I body))
    PageMissing body -> S (S (Z (I body)))
    PageTooLarge body -> S (S (S (Z (I body))))
    PageUnavailable body -> S (S (S (S (Z (I body)))))
  fromUnion = \case
    Z (I body) -> PageOk body
    S (Z (I body)) -> PageInvalid body
    S (S (Z (I body))) -> PageMissing body
    S (S (S (Z (I body)))) -> PageTooLarge body
    S (S (S (S (Z (I body))))) -> PageUnavailable body
    S (S (S (S (S (impossible))))) -> case impossible of {}

data TrackerApi mode = TrackerApi
  { list :: mode :- RelayPage 20 100 :> MultiVerb 'GET '[JSON] PageResponses PageResult,
    inspect :: mode :- Capture "bindingId" Text :> MultiVerb 'GET '[JSON] (Responses BindingView) (Result BindingView),
    observations :: mode :- Capture "bindingId" Text :> "observations" :> RelayPage 20 100 :> MultiVerb 'GET '[JSON] PageResponses PageResult,
    proposals :: mode :- Capture "bindingId" Text :> "proposals" :> RelayPage 20 100 :> MultiVerb 'GET '[JSON] PageResponses PageResult,
    deliveries :: mode :- Capture "bindingId" Text :> "deliveries" :> RelayPage 20 100 :> MultiVerb 'GET '[JSON] PageResponses PageResult,
    command :: mode :- "commands" :> ReqBody '[JSON] TrackerCommand :> MultiVerb 'POST '[JSON] (Responses OperationView) (Result OperationView),
    operation :: mode :- "operations" :> Capture "operationKey" Text :> MultiVerb 'GET '[JSON] (Responses OperationView) (Result OperationView)
  }
  deriving stock (Generic)
