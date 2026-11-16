-- | What a pack imports to contribute decision programs and
-- @ShikumiProgram@ tasks. Part of @shikigami-core:flow-sdk@; the export list
-- is pinned by a golden file.
module Shikigami.Flow.Sdk.Program
  ( ProgramTask (..),
    BehaviorInput (..),
    SomeProgram (..),
    SomeResultCodec,
    registerProgram,
    retainedCodec,
    programRef,
  )
where

import Shikigami.Behavior.Input (BehaviorInput (..))
import Shikigami.Program.Decision (SomeProgram (..), SomeResultCodec, programRef, registerProgram, retainedCodec)
import Shikigami.Program.Task (ProgramTask (..))
