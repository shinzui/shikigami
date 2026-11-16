-- | Reading @api-baseline/surfaces.dhall@.
module ApiBaseline.Inventory
  ( loadInventory,
    InventoryError (..),
    renderInventoryError,
  )
where

import ApiBaseline.Types (Surface (..))
import Control.Exception (SomeException, try)
import Data.List (group, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall qualified

data InventoryError
  = -- | The file does not evaluate to a list of surfaces.
    InventoryUnreadable !FilePath !Text
  | -- | Two entries share a name, so a pin or a report line would be ambiguous.
    DuplicateSurface !Text
  deriving stock (Eq, Show)

renderInventoryError :: InventoryError -> Text
renderInventoryError = \case
  InventoryUnreadable path problem -> "cannot read the inventory " <> Text.pack path <> ":\n" <> problem
  DuplicateSurface name -> "the inventory names the surface " <> name <> " more than once"

loadInventory :: FilePath -> IO (Either InventoryError [Surface])
loadInventory path = do
  loaded <- try (Dhall.inputFile Dhall.auto path) :: IO (Either SomeException [Surface])
  pure case loaded of
    Left problem -> Left (InventoryUnreadable path (Text.pack (show problem)))
    Right surfaces -> case [name | name : _ : _ <- group (sort (map (.name) surfaces))] of
      duplicate : _ -> Left (DuplicateSurface duplicate)
      [] -> Right surfaces
