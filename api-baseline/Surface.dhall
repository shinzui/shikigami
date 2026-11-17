{- The type of the public-surface inventory. See docs/architecture/api-baseline.md.

   A surface is something a consumer outside this repository's control may
   depend on. Each entry names its owner, how much a consumer may rely on it,
   the rule a change must obey, and the check that compares it with its pin.
   Every path is relative to the repository root.
-}
let Stability = < Stable | Provisional | Internal >

let Enforcement = < Report | Enforce >

let Freeze = < Declaration | Kernel >

let Check =
      < DhallSchema : { schema : Text, hash : Text, corpus : Text }
      | ExportList : { component : Text, modules : List Text, pinned : Text }
      | OpenApi : { current : Text, frozen : Text }
      | CliHelp :
          { executable : Text, verbs : List (List Text), goldens : Text }
      | JournalCodec : { corpus : Text, goldens : Text }
      | KeiroGate : { since : Text }
      | ExposedSet : { cabal : Text, pinned : Text }
      >

let Surface =
      { name : Text
      , owner : Text
      , stability : Stability
      , rule : Text
      , check : Check
      , freeze : Freeze
      , enforcement : Enforcement
      }

in  { Stability, Enforcement, Freeze, Check, Surface }
