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

  # Accumulator for stream processing. Tracks tokens across multiple agentic turns
  # within a single send_message call. Each turn emits message_start/delta/stop events.
  # The Result message (if received) contains definitive totals.
  @type stream_acc :: %{
          session_id: String.t() | nil,
          accumulated_input: non_neg_integer(),
          accumulated_output: non_neg_integer(),
          turn_input: non_neg_integer(),
          turn_output: non_neg_integer(),
          result_usage: map() | nil
        }

  @spec initial_acc() :: stream_acc()
  defp initial_acc do
    %{
      session_id: nil,
      accumulated_input: 0,
      accumulated_output: 0,
      turn_input: 0,
      turn_output: 0,
      result_usage: nil
    }
  end

  defp consume_stream(session_pid, prompt, on_message, metadata) do
    stream = Streaming.send_message(session_pid, prompt)

    acc =
      Enum.reduce_while(stream, initial_acc(), fn event, acc ->
        handle_stream_event(event, acc, on_message, metadata)
      end)

    # The control_client stream halts after the final message_stop, but the
    # Result message (with definitive usage totals) arrives as {:claude_message, ...}
    # shortly after. Drain it from the process mailbox before finalizing usage.
    acc = maybe_drain_result(session_pid, acc, on_message, metadata)

    {:ok, Map.put(acc, :usage, finalize_usage(acc))}
  rescue
    error ->
      {:error, {:stream_error, Exception.message(error)}}
  end

  # For control_client path: drain the pending Result message from the process
  # mailbox. The SDK's stream halts on message_stop before the Result message
  # (which carries definitive usage totals) can be delivered through the stream.
  defp maybe_drain_result({:control_client, _}, acc, on_message, metadata) do
    receive do
      {:claude_message, message} ->
        usage = extract_result_usage(message)

        if usage do
          new_acc = %{acc | result_usage: usage}

          Logger.info(
            "Claude Code result (post-stream drain): " <>
              "input=#{sum_input_tokens(usage)} " <>
              "(uncached=#{extract_token(usage, "input_tokens")} " <>
              "cache_read=#{extract_token(usage, "cache_read_input_tokens")} " <>
              "cache_create=#{extract_token(usage, "cache_creation_input_tokens")}) " <>
              "output=#{extract_token(usage, "output_tokens")}"
          )

          emit_event(
            on_message,
            :turn_completed,
            %{method: :turn_completed, raw: inspect(message)},
            Map.merge(metadata, %{usage: finalize_usage(new_acc)})
          )

          new_acc
        else
          acc
        end
    after
      # Brief wait for the Result message to arrive after stream termination.
      # In practice it arrives within milliseconds; 500ms is a safe upper bound.
      500 -> acc
    end
  end

  defp maybe_drain_result(_session_pid, acc, _on_message, _metadata), do: acc

  # Build final usage map: prefer Result message totals, fallback to accumulated values.
  # Includes cache breakdown fields when available from Result message.
  defp finalize_usage(%{result_usage: result} = acc) when is_map(result) do
    input = sum_input_tokens(result)
    output = extract_token(result, "output_tokens")

    # Use result totals if they're non-trivial, otherwise use accumulated
    final_input = if input > 0, do: input, else: acc.accumulated_input
    final_output = if output > 0, do: output, else: acc.accumulated_output

    uncached = extract_token(result, "input_tokens")
    cache_read = extract_token(result, "cache_read_input_tokens")
    cache_create = extract_token(result, "cache_creation_input_tokens")

    %{
      "input_tokens" => final_input,
      "output_tokens" => final_output,
      "total_tokens" => final_input + final_output,
      "input_tokens_uncached" => uncached,
      "cache_read_input_tokens" => cache_read,
      "cache_creation_input_tokens" => cache_create
    }
  end

  defp finalize_usage(acc) do
    %{
      "input_tokens" => acc.accumulated_input,
      "output_tokens" => acc.accumulated_output,
      "total_tokens" => acc.accumulated_input + acc.accumulated_output
    }
  end

  defp handle_stream_event(%{type: :message_start} = event, acc, on_message, metadata) do
    session_id = event[:session_id] || acc.session_id
    usage = extract_event_usage(event)
    input = sum_input_tokens(usage)

    # Start a new turn: capture this turn's input tokens
    new_acc = %{acc | session_id: session_id, turn_input: input, turn_output: 0}

    emit_event(on_message, :notification, %{payload: event, raw: inspect(event)}, metadata)
    {:cont, new_acc}
  end

  defp handle_stream_event(%{type: :text_delta}, acc, _on_message, _metadata) do
    {:cont, acc}
  end

  defp handle_stream_event(%{type: :message_stop} = event, acc, on_message, metadata) do
    # Turn complete: accumulate this turn's tokens into running totals
    new_acc = %{
      acc
      | accumulated_input: acc.accumulated_input + acc.turn_input,
        accumulated_output: acc.accumulated_output + acc.turn_output
    }

    emit_event(
      on_message,
      :turn_completed,
      %{
        method: :turn_completed,
        payload: event,
        raw: inspect(event),
        details: event
      },
      Map.merge(metadata, %{usage: current_usage(new_acc)})
    )

    # Don't halt here - continue consuming to capture the result message
    # with definitive usage data. The stream terminates naturally.
    {:cont, new_acc}
  end

  defp handle_stream_event(%{type: :message_delta} = event, acc, on_message, metadata) do
    usage = extract_event_usage(event)
    output = extract_token(usage, "output_tokens")
    input = sum_input_tokens(usage)

    # Update this turn's tokens (message_delta carries cumulative values for the turn)
    new_acc = acc
    new_acc = if output > new_acc.turn_output, do: %{new_acc | turn_output: output}, else: new_acc
    new_acc = if input > new_acc.turn_input, do: %{new_acc | turn_input: input}, else: new_acc

    emit_event(
      on_message,
      :notification,
      %{payload: event, raw: inspect(event)},
      Map.merge(metadata, %{usage: current_usage(new_acc)})
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

    {:halt, acc}
  end

  # Control client path delivers result Messages as %{type: :message, message: msg}
  defp handle_stream_event(%{type: :message, message: message}, acc, on_message, metadata) do
    usage = extract_result_usage(message)

    new_acc = if usage, do: %{acc | result_usage: usage}, else: acc

    if usage do
      Logger.info(
        "Claude Code result message received: input=#{extract_token(usage, "input_tokens")} output=#{extract_token(usage, "output_tokens")}"
      )

      emit_event(
        on_message,
        :turn_completed,
        %{method: :turn_completed, raw: inspect(message)},
        Map.merge(metadata, %{usage: finalize_usage(new_acc)})
      )
    end

    {:cont, new_acc}
  end

  defp handle_stream_event(_event, acc, _on_message, _metadata) do
    {:cont, acc}
  end

  # Extract usage from any event, checking both parsed fields and raw_event
  defp extract_event_usage(event) do
    event[:usage] ||
      get_in(event, [:raw_event, "usage"]) ||
      get_in(event, [:raw_event, "message", "usage"]) ||
      %{}
  end

  # Extract a specific token count from a usage map (handles both string and atom keys)
  defp extract_token(usage, key) when is_map(usage) do
    usage[key] || usage[String.to_atom(key)] || 0
  end

  defp extract_token(_, _), do: 0

  # Sum all input-related token fields from usage map.
  # With prompt caching, input_tokens only counts uncached tokens.
  # cache_read_input_tokens and cache_creation_input_tokens are separate.
  defp sum_input_tokens(usage) when is_map(usage) do
    extract_token(usage, "input_tokens") +
      extract_token(usage, "cache_read_input_tokens") +
      extract_token(usage, "cache_creation_input_tokens")
  end

  defp sum_input_tokens(_), do: 0

  # Build current usage snapshot for event emission (accumulated + current turn)
  defp current_usage(acc) do
    input = acc.accumulated_input + acc.turn_input
    output = acc.accumulated_output + acc.turn_output

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
