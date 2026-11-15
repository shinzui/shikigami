-- The operator's tools file, $XDG_CONFIG_HOME/shikigami/tools.dhall (EP-3 of
-- MasterPlan 22). Optional: a declared CLI tool runs on the operator's grant
-- of the declaration. A ceiling of the same name bounds the declaration.
let A = ./Agent.dhall

let CliToolCeiling =
      { name : Text
      , executable : A.ExecutableRef
      , allow : List A.ArgumentPattern
      , maximumOperationClass : A.OperationClass
      }

-- An MCP server binding (ADR-65): the stdio transport and the approved tools.
-- inputSchema is the approved JSON schema as text, exactly as the server
-- reports it (shikigami-local mcp prints it).
let McpArgument = < LiteralArgument : Text | WorkspaceRootArgument >

let ApprovedMcpTool =
      { remoteName : Text
      , description : Text
      , inputSchema : Text
      , operationClass : A.OperationClass
      }

let McpBinding =
      { server : Text
      , command : Text
      , arguments : List McpArgument
      , environment : List Text
      , tools : List ApprovedMcpTool
      }

let Catalog =
      { Type = { cli : List CliToolCeiling, mcp : List McpBinding }
      , default = { cli = [] : List CliToolCeiling, mcp = [] : List McpBinding }
      }

in  { CliToolCeiling, McpArgument, ApprovedMcpTool, McpBinding, Catalog }
