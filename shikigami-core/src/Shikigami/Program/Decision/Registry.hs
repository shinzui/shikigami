module Shikigami.Program.Decision.Registry (builtinDecisionPrograms, builtinRetainedCodecs, decisionPrograms, decisionCodecs) where

import Shikigami.Program.Decision
import Shikigami.Program.Decision.Adaptive
import Shikigami.Program.Decision.Drift (driftProgram)

-- | The decision programs the builtin pack contributes. This is the one list:
-- 'decisionPrograms' and 'Shikigami.Flow.Builtin.builtinPack' both read it.
builtinDecisionPrograms :: [SomeProgram]
builtinDecisionPrograms = [SomeProgram adaptiveProgram, SomeProgram driftProgram]

-- | Codecs outlive retired programs (ADR-45), so they are a list of their own.
builtinRetainedCodecs :: [SomeResultCodec]
builtinRetainedCodecs = [retainedCodec adaptiveProgram, retainedCodec driftProgram]

decisionPrograms :: ProgramRegistry
decisionPrograms = either (error . show) id (programRegistry builtinDecisionPrograms)

decisionCodecs :: ResultCodecRegistry
decisionCodecs = either (error . show) id (resultCodecRegistry builtinRetainedCodecs)
