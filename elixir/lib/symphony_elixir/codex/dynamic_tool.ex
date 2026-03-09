defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Config

  @github_api_tool "github_api"
  @github_api_description """
  Execute a GitHub REST API request using Symphony's configured auth.
  """
  @github_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "description" => "HTTP method: GET, POST, PATCH, PUT, or DELETE."
      },
      "path" => %{
        "type" => "string",
        "description" => "API path relative to the GitHub API base (e.g., /repos/owner/repo/issues/1)."
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON request body.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @github_api_tool ->
        execute_github_api(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @github_api_tool,
        "description" => @github_api_description,
        "inputSchema" => @github_api_input_schema
      }
    ]
  end

  defp execute_github_api(arguments, _opts) do
    with {:ok, method, path, body} <- normalize_github_api_arguments(arguments),
         {:ok, response} <- do_github_request(method, path, body) do
      api_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_github_api_arguments(arguments) when is_map(arguments) do
    method = (Map.get(arguments, "method") || Map.get(arguments, :method) || "") |> to_string() |> String.upcase()
    path = Map.get(arguments, "path") || Map.get(arguments, :path)
    body = Map.get(arguments, "body") || Map.get(arguments, :body)

    cond do
      method not in ["GET", "POST", "PATCH", "PUT", "DELETE"] ->
        {:error, :invalid_method}

      !is_binary(path) or String.trim(path) == "" ->
        {:error, :missing_path}

      true ->
        {:ok, method, String.trim(path), body}
    end
  end

  defp normalize_github_api_arguments(_arguments), do: {:error, :invalid_arguments}

  defp do_github_request(method, path, body) do
    token = Config.github_api_token()

    if is_nil(token) do
      {:error, :missing_github_api_token}
    else
      url = "#{Config.github_endpoint()}#{path}"

      headers = [
        {"Authorization", "Bearer #{token}"},
        {"Accept", "application/vnd.github+json"},
        {"X-GitHub-Api-Version", "2022-11-28"}
      ]

      opts = [headers: headers, connect_options: [timeout: 30_000]]
      opts = if body && method in ["POST", "PATCH", "PUT"], do: Keyword.put(opts, :json, body), else: opts

      case method do
        "GET" -> Req.get(url, opts)
        "POST" -> Req.post(url, opts)
        "PATCH" -> Req.patch(url, opts)
        "PUT" -> Req.put(url, opts)
        "DELETE" -> Req.delete(url, opts)
      end
    end
  end

  defp api_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    %{
      "success" => true,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(body)
        }
      ]
    }
  end

  defp api_response({:ok, %{status: status, body: body}}) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(%{"status" => status, "body" => body})
        }
      ]
    }
  end

  defp api_response({:error, reason}) do
    failure_response(tool_error_payload({:github_api_request, reason}))
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_path) do
    %{"error" => %{"message" => "`github_api` requires a non-empty `path` string."}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "`github_api.method` must be GET, POST, PATCH, PUT, or DELETE."}}
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`github_api` expects an object with `method`, `path`, and optional `body`."}}
  end

  defp tool_error_payload(:missing_github_api_token) do
    %{"error" => %{"message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."}}
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{"error" => %{"message" => "GitHub API request failed.", "reason" => inspect(reason)}}
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "GitHub API tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
