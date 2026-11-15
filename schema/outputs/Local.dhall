-- Local outputs (EP-8 M2 of MasterPlan 22). An output is a registered kind and
-- its configuration as JSON text; a declaration with no outputs takes the
-- composition's default (under local-operator, a Markdown report).
let A = ../Agent.dhall

let Format = < Markdown | Json >

let report =
      \(format : Format) ->
          { kind = "local.report"
          , config =
              merge
                { Markdown = "{\"format\":\"markdown\"}"
                , Json = "{\"format\":\"json\"}"
                }
                format
          }
        : A.Output

in  { Format, report }
