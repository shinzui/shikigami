-- | The closed public JSON vocabulary, shared by HTTP and native adapters.
-- Model adapters select only the schema fragments their own inputs expose.
module Shikigami.Objective.Schema where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Shikigami.Prelude hiding ((.=))

objectSchema :: [(Key, Aeson.Value)] -> Aeson.Value
objectSchema fields = Aeson.object ["type" .= ("object" :: Text), "required" .= map fst fields, "additionalProperties" .= False, "properties" .= Aeson.object fields]

stringSchema, integerSchema, formatSchema, createSchema, criterionSchema, commandSchema, createRequestSchema, commandBodySchema :: Aeson.Value
stringSchema = Aeson.object ["type" .= ("string" :: Text)]
integerSchema = Aeson.object ["type" .= ("integer" :: Text), "minimum" .= (0 :: Int)]
formatSchema = Aeson.object ["type" .= ("integer" :: Text), "const" .= (1 :: Int)]

arraySchema :: Aeson.Value -> Aeson.Value
arraySchema item = Aeson.object ["type" .= ("array" :: Text), "items" .= item]

createRequestSchema = objectSchema [("title", stringSchema), ("goal", stringSchema), ("instructions", stringSchema), ("criteria", arraySchema criterionSchema), ("external", arraySchema externalSchema)]

createSchema = objectSchema [("format", formatSchema), ("operationKey", stringSchema), ("request", createRequestSchema)]

criterionSchema = objectSchema [("key", stringSchema), ("description", stringSchema), ("kind", Aeson.object ["enum" .= (["Automatic", "HumanVerifiable"] :: [Text])]), ("journeyRequired", Aeson.object ["type" .= ("boolean" :: Text)])]

commandSchema = objectSchema [("format", formatSchema), ("operationKey", stringSchema), ("expectedRevision", integerSchema), ("command", commandBodySchema)]

commandBodySchema = Aeson.object ["oneOf" .= map commandVariant publicTags]
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
