defmodule SymphonyElixir.ClaudeCode.Client do
  @moduledoc """
  Claude Code subprocess client using `claude_agent_sdk`.

  Exposes the same public API as `SymphonyElixir.Codex.AppServer`:
  `start_session/1`, `run_turn/4`, `stop_session/1`, `run/4`.
  """

  require Logger
  alias ClaudeAgentSDK.{Options, Streaming}
  alias SymphonyElixir.{ClaudeCode.McpLinear, Config}

  @type session :: %{
          session_pid: pid() | {:control_client, pid()},
          session_id: String.t() | nil,
          workspace: Path.t(),
          os_pid: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    with :ok <- validate_workspace_cwd(workspace) do
      expanded = Path.expand(workspace)

      sdk_options = %Options{
        model: Config.claude_model(),
        permission_mode: sdk_permission_mode(),
        allowed_tools: Config.claude_allowed_tools(),
        max_turns: Config.claude_max_turns(),
        cwd: expanded,
        append_system_prompt: Config.claude_append_system_prompt(),
        mcp_servers: McpLinear.mcp_server_config()
      }

      case Streaming.start_session(sdk_options) do
        {:ok, session_pid} ->
          os_pid = extract_os_pid(session_pid)

          {:ok,
           %{
             session_pid: session_pid,
             session_id: nil,
             workspace: expanded,
             os_pid: os_pid
           }}

        {:error, reason} ->
          {:error, {:claude_session_start_failed, reason}}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{session_pid: session_pid, workspace: workspace} = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    metadata = build_metadata(session)
    timeout_ms = Config.claude_turn_timeout_ms()

    emit_event(on_message, :session_started, %{session_id: session.session_id}, metadata)

    Logger.info(
      "Claude Code session started for #{issue_context(issue)} workspace=#{workspace}"
    )

    task =
      Task.async(fn ->
        consume_stream(session_pid, prompt, on_message, metadata)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        session_id = result[:session_id] || session.session_id

        Logger.info(
          "Claude Code session completed for #{issue_context(issue)} session_id=#{session_id}"
        )

        {:ok,
         %{
           result: :turn_completed,
           session_id: session_id,
           usage: result[:usage]
         }}

      {:ok, {:error, reason}} ->
        Logger.warning(
          "Claude Code session ended with error for #{issue_context(issue)}: #{inspect(reason)}"
        )

        emit_event(on_message, :turn_ended_with_error, %{reason: reason}, metadata)
        {:error, reason}

      nil ->
        Logger.error("Claude Code turn timeout for #{issue_context(issue)}")
        emit_event(on_message, :turn_ended_with_error, %{reason: :turn_timeout}, metadata)
        {:error, :turn_timeout}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{session_pid: session_pid}) do
    Streaming.close_session(session_pid)
  end

  # --- Private ---

  defp consume_stream(session_pid, prompt, on_message, metadata) do
    stream = Streaming.send_message(session_pid, prompt)

    result =
      Enum.reduce_while(stream, %{session_id: nil, usage: nil}, fn event, acc ->
        handle_stream_event(event, acc, on_message, metadata)
      end)

    {:ok, result}
  rescue
    error ->
      {:error, {:stream_error, Exception.message(error)}}
  end

  defp handle_stream_event(%{type: :message_start} = event, acc, on_message, metadata) do
    session_id = event[:session_id] || acc.session_id
    usage = event[:usage]
    new_acc = %{acc | session_id: session_id} |> maybe_update_usage(usage)

    emit_event(on_message, :notification, %{payload: event, raw: inspect(event)}, metadata)
    {:cont, new_acc}
  end

  defp handle_stream_event(%{type: :text_delta}, acc, _on_message, _metadata) do
    {:cont, acc}
  end

  defp handle_stream_event(%{type: :message_stop} = event, acc, on_message, metadata) do
    usage = event[:usage] || get_in(event, [:raw_event, "usage"])
    new_acc = maybe_update_usage(acc, usage)

    emit_event(
      on_message,
      :turn_completed,
      %{
        method: :turn_completed,
        payload: event,
        raw: inspect(event),
        details: event
      },
      Map.merge(metadata, usage_metadata(new_acc))
    )

    # Don't halt here - continue consuming to capture the result message
    # with definitive usage data. The stream terminates naturally.
    {:cont, new_acc}
  end

  defp handle_stream_event(%{type: :message_delta} = event, acc, on_message, metadata) do
    # SDK EventParser doesn't extract usage from message_delta; fall back to raw_event
    usage = event[:usage] || get_in(event, [:raw_event, "usage"])
    new_acc = maybe_update_usage(acc, usage)

    emit_event(
      on_message,
      :notification,
      %{payload: event, raw: inspect(event)},
      Map.merge(metadata, usage_metadata(new_acc))
    )

    {:cont, new_acc}
  end

  defp handle_stream_event(%{type: :tool_use_start} = event, acc, on_message, metadata) do
    emit_event(
      on_message,
      :notification,
      %{payload: event, raw: inspect(event), tool_name: event[:name]},
      metadata
    )

    {:cont, acc}
  end

  defp handle_stream_event(%{type: :error} = event, acc, on_message, metadata) do
    emit_event(
      on_message,
      :turn_ended_with_error,
      %{reason: event[:error], payload: event, raw: inspect(event)},
      metadata
    )

    {:halt, %{acc | usage: acc.usage || %{}}}
  end

  # Control client path delivers result Messages as %{type: :message, message: msg}
  defp handle_stream_event(%{type: :message, message: message}, acc, on_message, metadata) do
    usage = extract_result_usage(message)
    new_acc = maybe_update_usage(acc, usage)

    if usage do
      emit_event(
        on_message,
        :turn_completed,
        %{method: :turn_completed, raw: inspect(message)},
        Map.merge(metadata, usage_metadata(new_acc))
      )
    end

    {:cont, new_acc}
  end

  defp handle_stream_event(_event, acc, _on_message, _metadata) do
    {:cont, acc}
  end

  defp maybe_update_usage(acc, nil), do: acc

  defp maybe_update_usage(acc, usage) when is_map(usage) do
    merged = Map.merge(acc.usage || %{}, usage)
    %{acc | usage: merged}
  end

  defp usage_metadata(%{usage: usage}) when is_map(usage) do
    %{usage: normalize_usage(usage)}
  end

  defp usage_metadata(_), do: %{}

  defp normalize_usage(usage) when is_map(usage) do
    input = usage["input_tokens"] || usage[:input_tokens] || 0
    output = usage["output_tokens"] || usage[:output_tokens] || 0

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => input + output
    }
  end

  defp extract_result_usage(%{type: :result, data: data}) when is_map(data) do
    data[:usage] || data["usage"]
  end

  defp extract_result_usage(%{data: data}) when is_map(data) do
    data[:usage] || data["usage"]
  end

  defp extract_result_usage(_), do: nil

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())
    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error,
         {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp sdk_permission_mode do
    case Config.claude_permission_mode() do
      "bypassPermissions" -> :bypass_permissions
      "acceptEdits" -> :accept_edits
      "dontAsk" -> :dont_ask
      "plan" -> :plan
      "default" -> :default
      other -> String.to_atom(other)
    end
  end

  defp extract_os_pid({:control_client, client}) when is_pid(client) do
    to_string(:erlang.phash2(client))
  end

  defp extract_os_pid(pid) when is_pid(pid) do
    to_string(:erlang.phash2(pid))
  end

  defp build_metadata(session) do
    %{
      codex_app_server_pid: session.os_pid
    }
  end

  defp emit_event(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_), do: "unknown_issue"
end
