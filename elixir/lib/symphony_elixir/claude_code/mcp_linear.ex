defmodule SymphonyElixir.ClaudeCode.McpLinear do
  @moduledoc """
  MCP server configuration for exposing Linear GraphQL to Claude Code.

  Generates the MCP server config map to pass into `ClaudeAgentSDK.Options.mcp_servers`.
  """

  alias SymphonyElixir.Config

  @doc """
  Returns MCP server configuration for the Linear GraphQL tool.

  This can be passed to `ClaudeAgentSDK.Options` as `mcp_servers`.
  Returns `nil` if no Linear API token is configured.
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
          require Logger
          Logger.warning("Linear MCP server not found at #{cmd}, skipping MCP config")
          nil
        end
    end
  end

  defp linear_mcp_command do
    priv_dir = :code.priv_dir(:symphony_elixir)
    Path.join([to_string(priv_dir), "mcp", "linear_mcp_server"])
  end

  defp linear_mcp_args, do: []
end
