{-# LANGUAGE DataKinds #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Authenticated objective metadata and closed, versioned command documents.
module Shikigami.Objective.Api where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.OpenApi (NamedSchema (..), Schema, ToSchema (..), fromAesonOptions, genericDeclareNamedSchema)
import Data.SOP (I (..), NS (..))
import Servant.API
import Servant.API.Generic ((:-))
import Servant.API.MultiVerb
import Shikigami.Api.Problem
import Shikigami.Execution.Identity (OperationId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Command (Command)
import Shikigami.Objective.Inspection (AssignmentView, CriterionView, EvidenceView, ObjectiveView, ReportedResultView)
import Shikigami.Objective.Types (CreateRequest, StateRevision)
import Shikigami.Prelude hiding ((.=))

-- Unknown codec versions and authority fields are refused before admission.
data ObjectiveCreate = ObjectiveCreate {operationKey :: !OperationId, request :: !CreateRequest}
  deriving stock (Eq, Show, Generic)

data ObjectiveCommand = ObjectiveCommand {operationKey :: !OperationId, expectedRevision :: !(StateRevision "objective"), command :: !Command}
  deriving stock (Eq, Show, Generic)

instance ToJSON ObjectiveCreate where
  toJSON value = Aeson.object ["format" .= (V1 :: FormatVersion "objective-http-envelope"), "operationKey" .= value.operationKey, "request" .= value.request]

instance FromJSON ObjectiveCreate where
  parseJSON = Aeson.withObject "objective creation" \fields -> do
    envelope ["format", "operationKey", "request"] fields
    ObjectiveCreate <$> fields .: "operationKey" <*> fields .: "request"

instance ToJSON ObjectiveCommand where
  toJSON value = Aeson.object ["format" .= (V1 :: FormatVersion "objective-http-envelope"), "operationKey" .= value.operationKey, "expectedRevision" .= value.expectedRevision, "command" .= value.command]

instance FromJSON ObjectiveCommand where
  parseJSON = Aeson.withObject "objective command" \fields -> do
    envelope ["format", "operationKey", "expectedRevision", "command"] fields
    ObjectiveCommand <$> fields .: "operationKey" <*> fields .: "expectedRevision" <*> fields .: "command"

envelope :: [Key] -> Aeson.Object -> Parser ()
envelope allowed fields = do
  unless (all (`elem` allowed) (KeyMap.keys fields)) (fail "unknown envelope field")
  void (fields .: "format" :: Parser (FormatVersion "objective-http-envelope"))

data ReceiptView = ReceiptView {objectiveId :: !Text, operationId :: !Text, fingerprint :: !Text, revision :: !Integer, payloadDigest :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PrincipalView = PrincipalView {kind :: !Text, identity :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data HistoryView = HistoryView {receipt :: !ReceiptView, actor :: !PrincipalView, command :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ObjectivePage = ObjectivePage {items :: ![ObjectiveView], next :: !(Maybe Text)}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data HistoryPage = HistoryPage {items :: ![HistoryView], next :: !(Maybe Integer)}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance ToSchema ReceiptView where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema PrincipalView where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema HistoryView where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema AssignmentView where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema CriterionView where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema EvidenceView where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema ReportedResultView where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema ObjectiveView where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema ObjectivePage where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema HistoryPage where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

type CreateResponses =
  '[ Respond 201 "Created" ReceiptView,
     Respond 200 "Replayed" ReceiptView,
     RespondAs ProblemJSON 400 "CreateInvalid" ProblemDetails,
     RespondAs ProblemJSON 403 "CreateDenied" ProblemDetails,
     RespondAs ProblemJSON 404 "CreateMissing" ProblemDetails,
     RespondAs ProblemJSON 409 "CreateConflict" ProblemDetails,
     RespondAs ProblemJSON 413 "CreateTooLarge" ProblemDetails,
     RespondAs ProblemJSON 503 "CreateUnavailable" ProblemDetails
   ]

data CreateResult = Created !ReceiptView | Replayed !ReceiptView | CreateInvalid !ProblemDetails | CreateDenied !ProblemDetails | CreateMissing !ProblemDetails | CreateConflict !ProblemDetails | CreateTooLarge !ProblemDetails | CreateUnavailable !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion CreateResponses CreateResult where
  toUnion = \case
    Created body -> Z (I body)
    Replayed body -> S (Z (I body))
    CreateInvalid body -> S (S (Z (I body)))
    CreateDenied body -> S (S (S (Z (I body))))
    CreateMissing body -> S (S (S (S (Z (I body)))))
    CreateConflict body -> S (S (S (S (S (Z (I body))))))
    CreateTooLarge body -> S (S (S (S (S (S (Z (I body)))))))
    CreateUnavailable body -> S (S (S (S (S (S (S (Z (I body))))))))
  fromUnion = \case
    Z (I body) -> Created body
    S (Z (I body)) -> Replayed body
    S (S (Z (I body))) -> CreateInvalid body
    S (S (S (Z (I body)))) -> CreateDenied body
    S (S (S (S (Z (I body))))) -> CreateMissing body
    S (S (S (S (S (Z (I body)))))) -> CreateConflict body
    S (S (S (S (S (S (Z (I body))))))) -> CreateTooLarge body
    S (S (S (S (S (S (S (Z (I body)))))))) -> CreateUnavailable body
    S (S (S (S (S (S (S (S (impossible)))))))) -> case impossible of {}

type ReadResponses =
  '[ Respond 200 "Found" ObjectiveView,
     RespondAs ProblemJSON 400 "ReadInvalid" ProblemDetails,
     RespondAs ProblemJSON 403 "ReadDenied" ProblemDetails,
     RespondAs ProblemJSON 404 "ReadMissing" ProblemDetails,
     RespondAs ProblemJSON 409 "ReadConflict" ProblemDetails,
     RespondAs ProblemJSON 413 "ReadTooLarge" ProblemDetails,
     RespondAs ProblemJSON 503 "ReadUnavailable" ProblemDetails
   ]

data ReadResult = Found !ObjectiveView | ReadInvalid !ProblemDetails | ReadDenied !ProblemDetails | ReadMissing !ProblemDetails | ReadConflict !ProblemDetails | ReadTooLarge !ProblemDetails | ReadUnavailable !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion ReadResponses ReadResult where
  toUnion = \case
    Found body -> Z (I body)
    ReadInvalid body -> S (Z (I body))
    ReadDenied body -> S (S (Z (I body)))
    ReadMissing body -> S (S (S (Z (I body))))
    ReadConflict body -> S (S (S (S (Z (I body)))))
    ReadTooLarge body -> S (S (S (S (S (Z (I body))))))
    ReadUnavailable body -> S (S (S (S (S (S (Z (I body)))))))
  fromUnion = \case
    Z (I body) -> Found body
    S (Z (I body)) -> ReadInvalid body
    S (S (Z (I body))) -> ReadDenied body
    S (S (S (Z (I body)))) -> ReadMissing body
    S (S (S (S (Z (I body))))) -> ReadConflict body
    S (S (S (S (S (Z (I body)))))) -> ReadTooLarge body
    S (S (S (S (S (S (Z (I body))))))) -> ReadUnavailable body
    S (S (S (S (S (S (S (impossible))))))) -> case impossible of {}

type ListResponses =
  '[ Respond 200 "Listed" ObjectivePage,
     RespondAs ProblemJSON 400 "ListInvalid" ProblemDetails,
     RespondAs ProblemJSON 403 "ListDenied" ProblemDetails,
     RespondAs ProblemJSON 404 "ListMissing" ProblemDetails,
     RespondAs ProblemJSON 409 "ListConflict" ProblemDetails,
     RespondAs ProblemJSON 413 "ListTooLarge" ProblemDetails,
     RespondAs ProblemJSON 503 "ListUnavailable" ProblemDetails
   ]

data ListResult = Listed !ObjectivePage | ListInvalid !ProblemDetails | ListDenied !ProblemDetails | ListMissing !ProblemDetails | ListConflict !ProblemDetails | ListTooLarge !ProblemDetails | ListUnavailable !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion ListResponses ListResult where
  toUnion = \case
    Listed body -> Z (I body)
    ListInvalid body -> S (Z (I body))
    ListDenied body -> S (S (Z (I body)))
    ListMissing body -> S (S (S (Z (I body))))
    ListConflict body -> S (S (S (S (Z (I body)))))
    ListTooLarge body -> S (S (S (S (S (Z (I body))))))
    ListUnavailable body -> S (S (S (S (S (S (Z (I body)))))))
  fromUnion = \case
    Z (I body) -> Listed body
    S (Z (I body)) -> ListInvalid body
    S (S (Z (I body))) -> ListDenied body
    S (S (S (Z (I body)))) -> ListMissing body
    S (S (S (S (Z (I body))))) -> ListConflict body
    S (S (S (S (S (Z (I body)))))) -> ListTooLarge body
    S (S (S (S (S (S (Z (I body))))))) -> ListUnavailable body
    S (S (S (S (S (S (S (impossible))))))) -> case impossible of {}

type HistoryResponses =
  '[ Respond 200 "HistoryFound" HistoryPage,
     RespondAs ProblemJSON 400 "HistoryInvalid" ProblemDetails,
     RespondAs ProblemJSON 403 "HistoryDenied" ProblemDetails,
     RespondAs ProblemJSON 404 "HistoryMissing" ProblemDetails,
     RespondAs ProblemJSON 409 "HistoryConflict" ProblemDetails,
     RespondAs ProblemJSON 413 "HistoryTooLarge" ProblemDetails,
     RespondAs ProblemJSON 503 "HistoryUnavailable" ProblemDetails
   ]

data HistoryResult = HistoryFound !HistoryPage | HistoryInvalid !ProblemDetails | HistoryDenied !ProblemDetails | HistoryMissing !ProblemDetails | HistoryConflict !ProblemDetails | HistoryTooLarge !ProblemDetails | HistoryUnavailable !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion HistoryResponses HistoryResult where
  toUnion = \case
    HistoryFound body -> Z (I body)
    HistoryInvalid body -> S (Z (I body))
    HistoryDenied body -> S (S (Z (I body)))
    HistoryMissing body -> S (S (S (Z (I body))))
    HistoryConflict body -> S (S (S (S (Z (I body)))))
    HistoryTooLarge body -> S (S (S (S (S (Z (I body))))))
    HistoryUnavailable body -> S (S (S (S (S (S (Z (I body)))))))
  fromUnion = \case
    Z (I body) -> HistoryFound body
    S (Z (I body)) -> HistoryInvalid body
    S (S (Z (I body))) -> HistoryDenied body
    S (S (S (Z (I body)))) -> HistoryMissing body
    S (S (S (S (Z (I body))))) -> HistoryConflict body
    S (S (S (S (S (Z (I body)))))) -> HistoryTooLarge body
    S (S (S (S (S (S (Z (I body))))))) -> HistoryUnavailable body
    S (S (S (S (S (S (S (impossible))))))) -> case impossible of {}

type CommandResponses =
  '[ Respond 200 "CommandAccepted" ReceiptView,
     RespondAs ProblemJSON 400 "CommandInvalid" ProblemDetails,
     RespondAs ProblemJSON 403 "CommandDenied" ProblemDetails,
     RespondAs ProblemJSON 404 "CommandMissing" ProblemDetails,
     RespondAs ProblemJSON 409 "CommandConflict" ProblemDetails,
     RespondAs ProblemJSON 413 "CommandTooLarge" ProblemDetails,
     RespondAs ProblemJSON 503 "CommandUnavailable" ProblemDetails
   ]

data CommandResult = CommandAccepted !ReceiptView | CommandInvalid !ProblemDetails | CommandDenied !ProblemDetails | CommandMissing !ProblemDetails | CommandConflict !ProblemDetails | CommandTooLarge !ProblemDetails | CommandUnavailable !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion CommandResponses CommandResult where
  toUnion = \case
    CommandAccepted body -> Z (I body)
    CommandInvalid body -> S (Z (I body))
    CommandDenied body -> S (S (Z (I body)))
    CommandMissing body -> S (S (S (Z (I body))))
    CommandConflict body -> S (S (S (S (Z (I body)))))
    CommandTooLarge body -> S (S (S (S (S (Z (I body))))))
    CommandUnavailable body -> S (S (S (S (S (S (Z (I body)))))))
  fromUnion = \case
    Z (I body) -> CommandAccepted body
    S (Z (I body)) -> CommandInvalid body
    S (S (Z (I body))) -> CommandDenied body
    S (S (S (Z (I body)))) -> CommandMissing body
    S (S (S (S (Z (I body))))) -> CommandConflict body
    S (S (S (S (S (Z (I body)))))) -> CommandTooLarge body
    S (S (S (S (S (S (Z (I body))))))) -> CommandUnavailable body
    S (S (S (S (S (S (S (impossible))))))) -> case impossible of {}

data ObjectiveApi mode = ObjectiveApi
  { create :: mode :- ReqBody '[JSON] ObjectiveCreate :> MultiVerb 'POST '[JSON] CreateResponses CreateResult,
    list :: mode :- QueryParam "after" Text :> QueryParam "limit" Int :> MultiVerb 'GET '[JSON] ListResponses ListResult,
    inspect :: mode :- Capture "objectiveId" Text :> QueryParam "after" Int :> QueryParam "limit" Int :> MultiVerb 'GET '[JSON] ReadResponses ReadResult,
    history :: mode :- Capture "objectiveId" Text :> "history" :> QueryParam "after" Integer :> QueryParam "limit" Int :> MultiVerb 'GET '[JSON] HistoryResponses HistoryResult,
    command :: mode :- Capture "objectiveId" Text :> "commands" :> ReqBody '[JSON] ObjectiveCommand :> MultiVerb 'POST '[JSON] CommandResponses CommandResult
  }
  deriving stock (Generic)

instance ToSchema ObjectiveCreate where
  declareNamedSchema _ = pure (NamedSchema (Just "ObjectiveCreate") (schemaValue createSchema))

instance ToSchema ObjectiveCommand where
  declareNamedSchema _ = pure (NamedSchema (Just "ObjectiveCommand") (schemaValue commandSchema))

schemaValue :: Aeson.Value -> Schema
schemaValue value = case Aeson.fromJSON value of Aeson.Success schema -> schema; Aeson.Error message -> error message

objectSchema :: [(Key, Aeson.Value)] -> Aeson.Value
objectSchema fields = Aeson.object ["type" .= ("object" :: Text), "required" .= map fst fields, "additionalProperties" .= False, "properties" .= Aeson.object fields]

stringSchema, integerSchema, formatSchema, createSchema, criterionSchema, commandSchema :: Aeson.Value
stringSchema = Aeson.object ["type" .= ("string" :: Text)]
integerSchema = Aeson.object ["type" .= ("integer" :: Text), "minimum" .= (0 :: Int)]
formatSchema = Aeson.object ["type" .= ("integer" :: Text), "const" .= (1 :: Int)]

arraySchema :: Aeson.Value -> Aeson.Value
arraySchema item = Aeson.object ["type" .= ("array" :: Text), "items" .= item]

createSchema = objectSchema [("format", formatSchema), ("operationKey", stringSchema), ("request", objectSchema [("title", stringSchema), ("goal", stringSchema), ("instructions", stringSchema), ("criteria", arraySchema criterionSchema), ("external", arraySchema externalSchema)])]

criterionSchema = objectSchema [("key", stringSchema), ("description", stringSchema), ("kind", Aeson.object ["enum" .= (["Automatic", "HumanVerifiable"] :: [Text])]), ("journeyRequired", Aeson.object ["type" .= ("boolean" :: Text)])]

commandSchema = objectSchema [("format", formatSchema), ("operationKey", stringSchema), ("expectedRevision", integerSchema), ("command", Aeson.object ["oneOf" .= map commandVariant publicTags])]
  where
    publicTags = ["ReviseInstructions", "ReviseCriteria", "SetAssignments", "RecordProgress", "RecordEvidence", "SetNextAction", "SetBlocked", "ProposeCompletion", "AcceptCompletion", "CancelObjective", "GrantMember", "RevokeMember", "BindConversation", "LinkExternal"] :: [Text]
    commandVariant tag = objectSchema ([("tag", Aeson.object ["const" .= tag])] <> if tag `elem` ["AcceptCompletion", "CancelObjective"] then [] else [("contents", contents tag)])
    contents "ReviseInstructions" = stringSchema
    contents "ReviseCriteria" = arraySchema criterionSchema
    contents "SetNextAction" = arraySchema stringSchema
    contents "SetBlocked" = Aeson.object ["type" .= ("boolean" :: Text)]
    contents "BindConversation" = stringSchema
    contents "SetAssignments" = arraySchema assignmentSchema
    contents "RecordProgress" = tupleSchema [assignmentKeySchema, enumSchema ["Pending", "Working", "Done", "Withdrawn"], arraySchema stringSchema, arraySchema stringSchema]
    contents "RecordEvidence" = tupleSchema [assignmentKeySchema, evidenceSchema]
    contents "ProposeCompletion" = proposalSchema
    contents "GrantMember" = tupleSchema [principalSchema, arraySchema (enumSchema ["Owner", "Coordinator", "Worker", "Reader", "Completer"])]
    contents "RevokeMember" = principalSchema
    contents "LinkExternal" = externalSchema
    contents _ = Aeson.Bool False

boolSchema, assignmentKeySchema, identitySchema, principalSchema, externalSchema, assignmentSchema, evidenceSchema, resultSchema, resultReceiptSchema, proposalSchema :: Aeson.Value
boolSchema = Aeson.object ["type" .= ("boolean" :: Text)]
assignmentKeySchema = objectSchema [("value", stringSchema)]
identitySchema = oneOfSchema [objectSchema [("kind", constant "verified"), ("principalId", stringSchema)], objectSchema [("kind", constant "compatibility"), ("agentName", stringSchema)], objectSchema [("kind", constant "unresolved-legacy")]]
principalSchema = oneOfSchema [variant "VerifiedCaller" stringSchema, variant "LocalOperator" stringSchema, variant "RecordedAgent" identitySchema]
externalSchema = oneOfSchema [variant tag stringSchema | tag <- ["ReiIntention", "ExecPlan", "ProtocolTask"]]
assignmentSchema = objectSchema [("assignmentId", assignmentKeySchema), ("instructions", stringSchema), ("dependencies", arraySchema assignmentKeySchema), ("owner", identitySchema), ("state", enumSchema ["Pending", "Working", "Done", "Withdrawn"]), ("sessionId", nullable stringSchema), ("rootId", nullable stringSchema), ("cutoff", nullable (Aeson.object ["type" .= ("string" :: Text), "format" .= ("date-time" :: Text)]))]
evidenceSchema =
  oneOfSchema
    [ objectSchema [("tag", constant "ResultEvidence"), ("key", stringSchema), ("criterion", stringSchema), ("result", resultSchema), ("journey", boolSchema)],
      objectSchema [("tag", constant "Attestation"), ("key", stringSchema), ("criterion", stringSchema), ("artifact", stringSchema), ("statement", stringSchema), ("journey", boolSchema)]
    ]
resultSchema =
  oneOfSchema
    [ objectSchema [("tag", constant "WorkerResult"), ("receipt", resultReceiptSchema), ("artifact", stringSchema)],
      objectSchema [("tag", constant "RetainedResult"), ("runId", stringSchema), ("executionId", stringSchema), ("digest", stringSchema), ("artifact", stringSchema)]
    ]
resultReceiptSchema = objectSchema [("format", formatSchema), ("sessionId", stringSchema), ("assignmentId", stringSchema), ("operationId", stringSchema), ("fingerprint", stringSchema), ("disposition", enumSchema ["AssignmentSucceeded", "AssignmentFailed", "AssignmentCancelled"]), ("output", objectSchema [("payloadId", stringSchema), ("digest", stringSchema), ("bytes", integerSchema)]), ("cursor", integerSchema)]
proposalSchema = objectSchema [("objectiveRevision", integerSchema), ("instructionsRevision", integerSchema), ("criteriaRevision", integerSchema), ("artifacts", arraySchema stringSchema), ("checks", arraySchema stringSchema), ("limitations", arraySchema stringSchema)]

constant :: Text -> Aeson.Value
constant value = Aeson.object ["const" .= value]

enumSchema :: [Text] -> Aeson.Value
enumSchema values = Aeson.object ["type" .= ("string" :: Text), "enum" .= values]

oneOfSchema :: [Aeson.Value] -> Aeson.Value
oneOfSchema values = Aeson.object ["oneOf" .= values]

variant :: Text -> Aeson.Value -> Aeson.Value
variant tag contents = objectSchema [("tag", constant tag), ("contents", contents)]

nullable :: Aeson.Value -> Aeson.Value
nullable value = oneOfSchema [Aeson.object ["type" .= ("null" :: Text)], value]

tupleSchema :: [Aeson.Value] -> Aeson.Value
tupleSchema values = Aeson.object ["type" .= ("array" :: Text), "prefixItems" .= values, "minItems" .= length values, "maxItems" .= length values]
