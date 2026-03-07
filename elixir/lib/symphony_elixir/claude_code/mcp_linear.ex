defmodule SymphonyElixir.ClaudeCode.McpLinear do
  @moduledoc """
  MCP server configuration for exposing Linear GraphQL to Claude Code.

  Generates the MCP server config map to pass into `ClaudeAgentSDK.Options.mcp_servers`.
  Prefers an external stdio binary at `priv/mcp/linear_mcp_server` when available,
  otherwise falls back to an in-process SDK MCP server via `LinearTool`.
  """

  require Logger
  alias SymphonyElixir.Config

  @doc """
  Returns MCP server configuration for the Linear GraphQL tool.

  This can be passed to `ClaudeAgentSDK.Options` as `mcp_servers`.
  Returns `nil` if no Linear API token is configured.

  When the external binary is missing, creates an SDK-based in-process MCP server
  using `ClaudeAgentSDK.create_sdk_mcp_server/1` backed by `LinearTool`.
  """
  @spec mcp_server_config() :: %{String.t() => map()} | nil
  def mcp_server_config do
    case Config.linear_api_token() do
      nil ->
        nil

      token when is_binary(token) ->
        cmd = linear_mcp_command()

        if File.exists?(cmd) do
          %{
            "linear" => %{
              type: :stdio,
              command: cmd,
              args: linear_mcp_args(),
              env: %{
                "LINEAR_API_KEY" => token,
                "LINEAR_ENDPOINT" => Config.linear_endpoint()
              }
            }
          }
        else
          Logger.info("Linear MCP binary not found at #{cmd}, using in-process SDK MCP server")
          build_sdk_mcp_server()
        end
    end
  end

  defp build_sdk_mcp_server do
    server =
      ClaudeAgentSDK.create_sdk_mcp_server(
        name: "linear",
        version: "1.0.0",
        tools: [SymphonyElixir.ClaudeCode.LinearTool.LinearGraphql]
      )

    %{"linear" => server}
  end

  defp linear_mcp_command do
    priv_dir = :code.priv_dir(:symphony_elixir)
    Path.join([to_string(priv_dir), "mcp", "linear_mcp_server"])
  end

  defp linear_mcp_args, do: []
end
