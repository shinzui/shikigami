module Shikigami.Program.Decision.Registry (decisionPrograms, decisionCodecs) where

import Shikigami.Program.Decision
import Shikigami.Program.Decision.Adaptive
import Shikigami.Program.Decision.Examples
import Shikigami.Program.Decision.Initiative (assessmentProgram)
import Shikigami.Program.Decision.JudgmentExample (judgmentProgram)

decisionPrograms :: ProgramRegistry
decisionPrograms = either (error . show) id (programRegistry [SomeProgram triageProgram, SomeProgram investigationProgram, SomeProgram judgmentProgram, SomeProgram adaptiveProgram, SomeProgram assessmentProgram])

decisionCodecs :: ResultCodecRegistry
decisionCodecs = either (error . show) id (resultCodecRegistry [retainedCodec triageProgram, retainedCodec investigationProgram, retainedCodec judgmentProgram, retainedCodec adaptiveProgram, retainedCodec assessmentProgram])
