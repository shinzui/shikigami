let S = ../../../schema/Agent.dhall

in S.Agent::{
     name = "harness-fixture",
     trigger = S.Trigger.Event { eventType = "test" },
     behavior = S.Behavior.Skill { path = "test/fixtures/durable-skill" },
     harness = Some (S.Harness::{ maxModelTurns = Some 2, output = Some S.OutputRequirement.NonemptyReply, deniedTools = [ "write" ] })
   }
