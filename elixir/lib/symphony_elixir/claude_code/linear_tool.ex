defmodule SymphonyElixir.ClaudeCode.LinearTool do
  @moduledoc """
  SDK-based MCP tool for Linear GraphQL access.

  Uses `ClaudeAgentSDK.Tool` macro to define an in-process `linear_graphql` tool
  that delegates to `SymphonyElixir.Linear.Client.graphql/3`. This eliminates the
  need for an external MCP server binary at `priv/mcp/linear_mcp_server`.
  """

  use ClaudeAgentSDK.Tool

  alias SymphonyElixir.Linear.Client

  deftool :linear_graphql,
          "Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.",
          %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["query"],
            "properties" => %{
              "query" => %{
                "type" => "string",
                "description" => "GraphQL query or mutation document to execute against Linear."
              },
              "variables" => %{
                "type" => "object",
                "description" => "Optional GraphQL variables object.",
                "additionalProperties" => true
              }
            }
          } do
    def execute(%{"query" => query} = input) do
      variables = Map.get(input, "variables") || %{}

      case Client.graphql(query, variables, []) do
        {:ok, response} ->
          {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(response)}]}}

        {:error, reason} ->
          {:error, "Linear GraphQL request failed: #{inspect(reason)}"}
      end
    end

    def execute(_input) do
      {:error, "`linear_graphql` requires a non-empty `query` string."}
    end
  end
end
