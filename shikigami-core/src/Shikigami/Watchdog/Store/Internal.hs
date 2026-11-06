-- | Transaction adapters private to the watchdog persistence owner.
module Shikigami.Watchdog.Store.Internal where

import Control.Monad (void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, except, runExceptT)
import Data.Aeson (FromJSON, Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Watchdog.Ledger (WatchdogError (LedgerCorrupt))
import Shikigami.Watchdog.Types (Subject, subjectKey, subjectKeyText)

type Checked = ExceptT WatchdogError Transaction

atomic :: Checked a -> Transaction (Either WatchdogError a)
atomic action = do
  result <- runExceptT action
  case result of Left _ -> Tx.condemn; Right _ -> pure ()
  pure result

decoded :: (FromJSON a) => Value -> Checked a
decoded value = except case Aeson.fromJSON value of Aeson.Success result -> Right result; _ -> Left LedgerCorrupt

row :: Text -> Value -> Checked (Maybe Value)
row sql value = lift (Tx.statement value (preparable sql (E.param (E.nonNullable E.jsonb)) (D.rowMaybe (D.column (D.nonNullable D.jsonb)))))

rows :: Text -> Value -> Checked [Value]
rows sql value = lift (Tx.statement value (preparable sql (E.param (E.nonNullable E.jsonb)) (D.rowList (D.column (D.nonNullable D.jsonb)))))

execute :: Text -> Value -> Checked ()
execute sql value = lift (Tx.statement value (preparable sql (E.param (E.nonNullable E.jsonb)) D.noResult))

-- Serializes a subject across distinct scope claims, including an absent mark.
-- Sweep locks serialize receipts; this lock serializes subject/family coalescing.
lockSubject :: Subject -> Checked ()
lockSubject subject = void (lift (Tx.statement (object ["key" .= ("watchdog/" <> subjectKeyText (subjectKey subject))]) (preparable "SELECT true FROM pg_advisory_xact_lock(hashtextextended($1->>'key',0))" (E.param (E.nonNullable E.jsonb)) (D.singleRow (D.column (D.nonNullable D.bool))))))
