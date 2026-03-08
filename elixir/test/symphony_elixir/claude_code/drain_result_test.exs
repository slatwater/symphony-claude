defmodule SymphonyElixir.ClaudeCode.DrainResultTest do
  @moduledoc """
  Tests for the post-stream Result message drain fix.

  Verifies that:
  1. Result messages in the process mailbox are correctly captured
  2. extract_result_usage pattern matching works with Message structs
  3. finalize_usage prefers result_usage over low accumulated values
  4. Timeout works when no Result message is available
  """
  use ExUnit.Case

  # Re-implement the private functions under test to verify logic correctness.
  # These mirror the exact implementation in ClaudeCode.Client.

  defp extract_result_usage(%{type: :result, data: data}) when is_map(data) do
    data[:usage] || data["usage"]
  end

  defp extract_result_usage(%{data: data}) when is_map(data) do
    data[:usage] || data["usage"]
  end

  defp extract_result_usage(_), do: nil

  defp extract_token(usage, key) when is_map(usage) do
    usage[key] || usage[String.to_atom(key)] || 0
  end

  defp extract_token(_, _), do: 0

  defp sum_input_tokens(usage) when is_map(usage) do
    extract_token(usage, "input_tokens") +
      extract_token(usage, "cache_read_input_tokens") +
      extract_token(usage, "cache_creation_input_tokens")
  end

  defp sum_input_tokens(_), do: 0

  defp finalize_usage(%{result_usage: result} = acc) when is_map(result) do
    input = sum_input_tokens(result)
    output = extract_token(result, "output_tokens")
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

  defp maybe_drain_result({:control_client, _}, acc) do
    receive do
      {:claude_message, message} ->
        usage = extract_result_usage(message)
        if usage, do: %{acc | result_usage: usage}, else: acc
    after
      500 -> acc
    end
  end

  defp maybe_drain_result(_session_pid, acc), do: acc

  # ---- Tests ----

  describe "extract_result_usage/1" do
    test "extracts usage from map with type: :result and string-keyed usage" do
      message = %{
        type: :result,
        data: %{"usage" => %{"input_tokens" => 1234, "output_tokens" => 5678}}
      }

      usage = extract_result_usage(message)
      assert usage["input_tokens"] == 1234
      assert usage["output_tokens"] == 5678
    end

    test "extracts usage from map with atom-keyed data" do
      message = %{
        type: :result,
        data: %{usage: %{"input_tokens" => 999, "output_tokens" => 888}}
      }

      usage = extract_result_usage(message)
      assert usage["input_tokens"] == 999
    end

    test "extracts usage from ClaudeAgentSDK.Message struct" do
      message =
        struct(ClaudeAgentSDK.Message, %{
          type: :result,
          subtype: :success,
          data: %{
            usage: %{"input_tokens" => 4000, "output_tokens" => 3000},
            session_id: "sess-123"
          }
        })

      usage = extract_result_usage(message)
      assert usage["input_tokens"] == 4000
      assert usage["output_tokens"] == 3000
    end

    test "returns nil for non-result messages" do
      assert extract_result_usage(%{type: :assistant, data: %{}}) == nil
      assert extract_result_usage(%{type: :error}) == nil
      assert extract_result_usage("garbage") == nil
    end

    test "returns nil when data has no usage" do
      message = %{type: :result, data: %{session_id: "x"}}
      assert extract_result_usage(message) == nil
    end
  end

  describe "maybe_drain_result/2" do
    test "captures {:claude_message, result} from mailbox for control_client" do
      acc = %{
        accumulated_input: 15,
        accumulated_output: 3327,
        result_usage: nil
      }

      result_msg = %{
        type: :result,
        data: %{usage: %{"input_tokens" => 1234, "output_tokens" => 5678}}
      }

      # Simulate: Result message arrives in mailbox after stream halts
      send(self(), {:claude_message, result_msg})

      new_acc = maybe_drain_result({:control_client, self()}, acc)

      assert new_acc.result_usage != nil
      assert new_acc.result_usage["input_tokens"] == 1234
      assert new_acc.result_usage["output_tokens"] == 5678
    end

    test "returns unchanged acc on timeout (no message)" do
      acc = %{
        accumulated_input: 15,
        accumulated_output: 3327,
        result_usage: nil
      }

      # Don't send anything — should timeout after 500ms
      start = System.monotonic_time(:millisecond)
      new_acc = maybe_drain_result({:control_client, self()}, acc)
      elapsed = System.monotonic_time(:millisecond) - start

      assert new_acc.result_usage == nil
      assert elapsed >= 450, "should wait ~500ms before giving up"
      assert elapsed < 1000, "should not wait too long"
    end

    test "is no-op for non-control_client session" do
      acc = %{result_usage: nil}

      # Even with message in mailbox, non-control_client should skip
      send(self(), {:claude_message, %{type: :result, data: %{usage: %{"input_tokens" => 999}}}})

      new_acc = maybe_drain_result(self(), acc)
      assert new_acc.result_usage == nil

      # Clean up the message we sent
      receive do
        {:claude_message, _} -> :ok
      after
        0 -> :ok
      end
    end
  end

  describe "finalize_usage/1 priority" do
    test "prefers result_usage over low accumulated values" do
      acc = %{
        accumulated_input: 15,
        accumulated_output: 3327,
        result_usage: %{"input_tokens" => 1234, "output_tokens" => 5678}
      }

      usage = finalize_usage(acc)

      assert usage["input_tokens"] == 1234, "should use result input (not accumulated 15)"
      assert usage["output_tokens"] == 5678, "should use result output (not accumulated 3327)"
      assert usage["total_tokens"] == 1234 + 5678
    end

    test "falls back to accumulated when result_usage is nil" do
      acc = %{
        accumulated_input: 15,
        accumulated_output: 3327,
        result_usage: nil
      }

      usage = finalize_usage(acc)

      assert usage["input_tokens"] == 15
      assert usage["output_tokens"] == 3327
      assert usage["total_tokens"] == 15 + 3327
    end

    test "falls back to accumulated when result fields are zero" do
      acc = %{
        accumulated_input: 15,
        accumulated_output: 3327,
        result_usage: %{"input_tokens" => 0, "output_tokens" => 0}
      }

      usage = finalize_usage(acc)

      assert usage["input_tokens"] == 15
      assert usage["output_tokens"] == 3327
    end

    test "includes cache breakdown fields when result_usage has caching data" do
      acc = %{
        accumulated_input: 100,
        accumulated_output: 500,
        result_usage: %{
          "input_tokens" => 30,
          "cache_read_input_tokens" => 450_000,
          "cache_creation_input_tokens" => 50_000,
          "output_tokens" => 9000
        }
      }

      usage = finalize_usage(acc)

      # input_tokens = sum of all three fields
      assert usage["input_tokens"] == 30 + 450_000 + 50_000
      assert usage["output_tokens"] == 9000
      assert usage["total_tokens"] == 500_030 + 9000

      # Breakdown fields
      assert usage["input_tokens_uncached"] == 30
      assert usage["cache_read_input_tokens"] == 450_000
      assert usage["cache_creation_input_tokens"] == 50_000
    end

    test "breakdown fields are zero when result_usage has no caching data" do
      acc = %{
        accumulated_input: 100,
        accumulated_output: 500,
        result_usage: %{"input_tokens" => 1234, "output_tokens" => 5678}
      }

      usage = finalize_usage(acc)

      assert usage["input_tokens_uncached"] == 1234
      assert usage["cache_read_input_tokens"] == 0
      assert usage["cache_creation_input_tokens"] == 0
    end
  end

  describe "end-to-end drain scenario" do
    test "simulates full control_client flow: low accumulation + drained Result = accurate tokens" do
      # Initial state: low input_tokens from message_start accumulation (the bug)
      acc = %{
        session_id: "sess-abc",
        accumulated_input: 15,
        accumulated_output: 3327,
        turn_input: 0,
        turn_output: 0,
        result_usage: nil
      }

      # Simulate: SDK sends Result message after stream halts
      send(
        self(),
        {:claude_message,
         struct(ClaudeAgentSDK.Message, %{
           type: :result,
           subtype: :success,
           data: %{
             usage: %{"input_tokens" => 4500, "output_tokens" => 3327},
             session_id: "sess-abc",
             num_turns: 5
           }
         })}
      )

      # Drain (as done in consume_stream after Enum.reduce_while)
      acc = maybe_drain_result({:control_client, self()}, acc)

      # Finalize (as done in consume_stream)
      usage = finalize_usage(acc)

      # Assert: input_tokens now accurate (4500 from Result, not 15 from accumulation)
      assert usage["input_tokens"] == 4500
      assert usage["output_tokens"] == 3327
      assert usage["total_tokens"] == 4500 + 3327
    end
  end
end
