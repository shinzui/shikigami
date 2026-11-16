-- | The HTTP API description against a frozen copy.
--
-- The breaking rules are a closed sum, so a report names the one that fired.
-- They are asymmetric on purpose: a client reads responses and writes
-- requests, so removing something from a response breaks a reader, and
-- demanding something new in a request breaks a writer.
module ApiBaseline.Check.OpenApi
  ( OpenApiChange (..),
    openApiChanges,
    openApiFindings,
    changeSeverity,
    renderChange,
  )
where

import ApiBaseline.Types (Finding (..), Severity (..))
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.List (sort)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

data OpenApiChange
  = PathRemoved !Text
  | OperationRemoved !Text !Text
  | ResponseStatusRemoved !Text !Text !Text
  | -- | A property a response carried is gone: (where, property).
    ResponsePropertyRemoved !Text !Text
  | -- | A property's type changed: (where, property, frozen, current).
    PropertyTypeChanged !Text !Text !Text !Text
  | -- | A request must now supply a property it did not have to: (where, property).
    RequestPropertyNowRequired !Text !Text
  | -- | A response may no longer carry an enumeration value: (where, value).
    ResponseEnumValueRemoved !Text !Text
  | -- | The documents differ in a way no breaking rule covers.
    OtherDifference
  deriving stock (Eq, Ord, Show)

changeSeverity :: OpenApiChange -> Severity
changeSeverity = \case
  OtherDifference -> Changed
  _ -> Breaking

renderChange :: OpenApiChange -> Text
renderChange = \case
  PathRemoved path -> "path removed: " <> path
  OperationRemoved path method -> "operation removed: " <> Text.toUpper method <> " " <> path
  ResponseStatusRemoved path method status -> "response status removed: " <> status <> " of " <> Text.toUpper method <> " " <> path
  ResponsePropertyRemoved place property -> "response property removed: " <> property <> " of " <> place
  PropertyTypeChanged place property frozen current -> "property type changed: " <> property <> " of " <> place <> " was " <> frozen <> ", is " <> current
  RequestPropertyNowRequired place property -> "request property now required: " <> property <> " of " <> place
  ResponseEnumValueRemoved place value -> "response enumeration value removed: " <> value <> " of " <> place
  OtherDifference -> "the description differs from the frozen copy in a compatible way"

openApiFindings :: Value -> Value -> [Finding]
openApiFindings frozen current = [Finding (changeSeverity change) (renderChange change) | change <- openApiChanges frozen current]

-- | Every change from the frozen description to the current one. When no
-- breaking rule fires and the documents still differ, the answer is
-- @['OtherDifference']@.
openApiChanges :: Value -> Value -> [OpenApiChange]
openApiChanges frozen current
  | frozen == current = []
  | null breaking = [OtherDifference]
  | otherwise = sort (Set.toList (Set.fromList breaking))
  where
    breaking = pathChanges <> componentChanges
    frozenPaths = member "paths" frozen
    currentPaths = member "paths" current
    pathChanges =
      concat
        [ case lookupMember path currentPaths of
            Nothing -> [PathRemoved path]
            Just currentItem -> operationChanges path frozenItem currentItem
        | (path, frozenItem) <- members frozenPaths
        ]
    operationChanges path frozenItem currentItem =
      concat
        [ case lookupMember method currentItem of
            Nothing -> [OperationRemoved path method]
            Just currentOperation ->
              responseChanges path method frozenOperation currentOperation
                <> requestChanges (Text.toUpper method <> " " <> path <> " request") frozenOperation currentOperation
        | (method, frozenOperation) <- members frozenItem,
          method `elem` httpMethods
        ]
    responseChanges path method frozenOperation currentOperation =
      concat
        [ case lookupMember status (member "responses" currentOperation) of
            Nothing -> [ResponseStatusRemoved path method status]
            Just currentResponse ->
              concat
                [ compareSchema Response (Text.toUpper method <> " " <> path <> " " <> status) frozenSchema currentSchema
                | (mediaType, frozenMedia) <- members (member "content" frozenResponse),
                  Just currentMedia <- [lookupMember mediaType (member "content" currentResponse)],
                  let frozenSchema = member "schema" frozenMedia,
                  let currentSchema = member "schema" currentMedia
                ]
        | (status, frozenResponse) <- members (member "responses" frozenOperation)
        ]
    requestChanges place frozenOperation currentOperation =
      concat
        [ compareSchema Request place (member "schema" frozenMedia) (member "schema" currentMedia)
        | (mediaType, frozenMedia) <- members (member "content" (member "requestBody" frozenOperation)),
          Just currentMedia <- [lookupMember mediaType (member "content" (member "requestBody" currentOperation))]
        ]
    -- A named schema is held to the rules of every direction it is used in.
    frozenSchemas = member "schemas" (member "components" frozen)
    currentSchemas = member "schemas" (member "components" current)
    responseNames = reachable frozenSchemas (referencesIn Response frozen)
    requestNames = reachable frozenSchemas (referencesIn Request frozen)
    componentChanges =
      concat
        [ concat
            [ compareSchema direction ("schema " <> name) frozenSchema currentSchema
            | (direction, used) <- [(Response, responseNames), (Request, requestNames)],
              name `Set.member` used
            ]
        | (name, frozenSchema) <- members frozenSchemas,
          Just currentSchema <- [lookupMember name currentSchemas]
        ]

data Direction = Request | Response
  deriving stock (Eq)

httpMethods :: [Text]
httpMethods = ["get", "put", "post", "delete", "patch", "head", "options", "trace"]

-- | Compare two schemas in place. A reference is compared by its target name
-- and not followed; the named schema is compared once, under its own name.
compareSchema :: Direction -> Text -> Value -> Value -> [OpenApiChange]
compareSchema direction place frozen current =
  propertyChanges <> requiredChanges <> enumChanges <> itemChanges
  where
    frozenProperties = member "properties" frozen
    currentProperties = member "properties" current
    propertyChanges =
      concat
        [ case lookupMember property currentProperties of
            Nothing -> [ResponsePropertyRemoved place property | direction == Response]
            Just currentProperty ->
              [PropertyTypeChanged place property (typeOf frozenProperty) (typeOf currentProperty) | typeOf frozenProperty /= typeOf currentProperty]
                <> compareSchema direction (place <> "." <> property) frozenProperty currentProperty
        | (property, frozenProperty) <- members frozenProperties
        ]
    requiredChanges =
      [ RequestPropertyNowRequired place property
      | direction == Request,
        property <- strings (member "required" current),
        property `notElem` strings (member "required" frozen)
      ]
    enumChanges =
      [ ResponseEnumValueRemoved place value
      | direction == Response,
        value <- strings (member "enum" frozen),
        value `notElem` strings (member "enum" current)
      ]
    itemChanges = case (lookupMember "items" frozen, lookupMember "items" current) of
      (Just frozenItems, Just currentItems) ->
        [PropertyTypeChanged place "items" (typeOf frozenItems) (typeOf currentItems) | typeOf frozenItems /= typeOf currentItems]
          <> compareSchema direction (place <> "[]") frozenItems currentItems
      _ -> []

-- | What a schema says its values are: a reference target, or its type and format.
typeOf :: Value -> Text
typeOf schema = case lookupMember "$ref" schema of
  Just (String target) -> target
  _ -> Text.intercalate ":" [text | Just (String text) <- [lookupMember "type" schema, lookupMember "format" schema]]

-- | The named schemas referenced, directly, by requests or by responses.
referencesIn :: Direction -> Value -> Set Text
referencesIn direction document =
  Set.fromList
    [ name
    | (_, item) <- members (member "paths" document),
      (method, operation) <- members item,
      method `elem` httpMethods,
      body <- case direction of
        Request -> [member "requestBody" operation]
        Response -> map snd (members (member "responses" operation)),
      name <- schemaReferences body
    ]

-- | Close a set of schema names over the references between named schemas.
reachable :: Value -> Set Text -> Set Text
reachable schemas = go Set.empty . Set.toList
  where
    go seen [] = seen
    go seen (name : rest)
      | name `Set.member` seen = go seen rest
      | otherwise = go (Set.insert name seen) (maybe [] schemaReferences (lookupMember name schemas) <> rest)

schemaReferences :: Value -> [Text]
schemaReferences = \case
  Object fields ->
    [name | Just (String target) <- [KeyMap.lookup "$ref" fields], Just name <- [Text.stripPrefix "#/components/schemas/" target]]
      <> concatMap schemaReferences (KeyMap.elems fields)
  Array values -> concatMap schemaReferences (toList values)
  _ -> []

member :: Text -> Value -> Value
member key value = maybe Null id (lookupMember key value)

lookupMember :: Text -> Value -> Maybe Value
lookupMember key = \case
  Object fields -> KeyMap.lookup (Key.fromText key) fields
  _ -> Nothing

members :: Value -> [(Text, Value)]
members = \case
  Object fields -> [(Key.toText key, value) | (key, value) <- KeyMap.toList fields]
  _ -> []

strings :: Value -> [Text]
strings = \case
  Array values -> [text | String text <- toList values]
  _ -> []
