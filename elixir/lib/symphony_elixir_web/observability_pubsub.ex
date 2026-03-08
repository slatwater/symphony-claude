defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates and agent event streams.
  """

  @pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated
  @agent_events_topic_prefix "agent:events:"
  @all_agent_events_topic "agent:events:all"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec broadcast_update() :: :ok
  def broadcast_update do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, @update_message)

      _ ->
        :ok
    end
  end

  @spec subscribe_agent_events(String.t()) :: :ok | {:error, term()}
  def subscribe_agent_events(issue_id) when is_binary(issue_id) do
    Phoenix.PubSub.subscribe(@pubsub, @agent_events_topic_prefix <> issue_id)
  end

  @spec subscribe_all_agent_events() :: :ok | {:error, term()}
  def subscribe_all_agent_events do
    Phoenix.PubSub.subscribe(@pubsub, @all_agent_events_topic)
  end

  @spec broadcast_agent_event(String.t(), map()) :: :ok
  def broadcast_agent_event(issue_id, event) when is_binary(issue_id) and is_map(event) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        msg = {:agent_event, issue_id, event}
        Phoenix.PubSub.broadcast(@pubsub, @agent_events_topic_prefix <> issue_id, msg)
        Phoenix.PubSub.broadcast(@pubsub, @all_agent_events_topic, msg)

      _ ->
        :ok
    end
  end
end
