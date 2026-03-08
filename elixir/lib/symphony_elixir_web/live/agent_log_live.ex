defmodule SymphonyElixirWeb.AgentLogLive do
  @moduledoc """
  Live event stream for a specific agent/issue. Subscribes to per-agent PubSub
  topic and renders a scrolling log of tool calls, messages, and token updates.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.EventStore
  alias SymphonyElixirWeb.ObservabilityPubSub

  @max_display_events 200

  @impl true
  def mount(%{"issue_identifier" => identifier}, _session, socket) do
    issue_id = resolve_issue_id(identifier)

    # Load events from ETS (live) or persisted files (history fallback)
    events =
      cond do
        issue_id && EventStore.get_events(issue_id) != [] ->
          EventStore.get_events(issue_id)

        true ->
          # Try loading from persisted session files matching this identifier
          load_persisted_events_for_identifier(identifier)
      end

    socket =
      socket
      |> assign(:issue_identifier, identifier)
      |> assign(:issue_id, issue_id)
      |> assign(:events, Enum.take(events, -@max_display_events))
      |> assign(:auto_scroll, true)
      |> assign(:filter, "all")
      |> assign(:status, if(issue_id, do: :live, else: :historical))

    if connected?(socket) && issue_id do
      :ok = ObservabilityPubSub.subscribe_agent_events(issue_id)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info({:agent_event, _issue_id, event}, socket) do
    events = socket.assigns.events ++ [event]
    trimmed = Enum.take(events, -@max_display_events)

    {:noreply, assign(socket, :events, trimmed)}
  end

  @impl true
  def handle_event("toggle_auto_scroll", _params, socket) do
    {:noreply, assign(socket, :auto_scroll, !socket.assigns.auto_scroll)}
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card" style="padding: 1.25rem 1.5rem;">
        <div style="display: flex; align-items: center; gap: 1rem; flex-wrap: wrap;">
          <a href="/" class="back-link">&larr; Dashboard</a>
          <div style="flex: 1;">
            <p class="eyebrow">Agent Event Stream</p>
            <h1 class="hero-title" style="font-size: 1.8rem; margin-top: 0.2rem;">
              <%= @issue_identifier %>
            </h1>
          </div>
          <div style="display: flex; gap: 0.5rem; align-items: center;">
            <span class="event-count-badge"><%= length(filtered_events(@events, @filter)) %> events</span>
            <button
              phx-click="toggle_auto_scroll"
              class={"subtle-button #{if @auto_scroll, do: "auto-scroll-on"}"}
            >
              Auto-scroll: <%= if @auto_scroll, do: "ON", else: "OFF" %>
            </button>
          </div>
        </div>
      </header>

      <section class="section-card">
        <div class="filter-bar">
          <button
            :for={f <- ["all", "tool_use", "text", "turn_completed", "error"]}
            phx-click="set_filter"
            phx-value-filter={f}
            class={"filter-btn #{if @filter == f, do: "filter-active"}"}
          >
            <%= filter_label(f) %>
          </button>
        </div>

        <div class="event-log" id="event-log">
          <%= if filtered_events(@events, @filter) == [] do %>
            <p class="empty-state" style="padding: 2rem;">
              <%= if @events == [] do %>
                <%= if @status == :live do %>
                  Waiting for agent events... (subscribed to live stream)
                <% else %>
                  No events found for this issue. The agent may not have started yet, or events were cleared on restart.
                <% end %>
              <% else %>
                No events match this filter.
              <% end %>
            </p>
          <% else %>
            <div
              :for={{event, idx} <- Enum.with_index(filtered_events(@events, @filter))}
              id={"ev-#{idx}"}
              class={"event-row event-row-#{event_css_type(event)}"}
            >
              <div class="event-time mono">
                <%= format_event_time(event) %>
              </div>
              <div class={"event-type-badge event-type-#{event_css_type(event)}"}>
                <%= event_type_label(event) %>
              </div>
              <div class="event-body">
                <%= if event_css_type(event) == "text" do %>
                  <pre class="event-text-block"><%= event[:text] || event[:message] || "" %></pre>
                <% else %>
                  <span class="event-summary"><%= event_summary(event) %></span>
                  <%= if event_detail(event) do %>
                    <span class="event-detail muted"><%= event_detail(event) %></span>
                  <% end %>
                <% end %>
              </div>
              <%= if event_tokens(event) do %>
                <div class="event-tokens mono muted">
                  <%= event_tokens(event) %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </section>
    </section>
    """
  end

  # --- Helpers ---

  defp resolve_issue_id(identifier) do
    # Strategy 1: Check orchestrator snapshot (most reliable — maps identifier to issue_id)
    issue_id_from_orchestrator =
      case SymphonyElixir.Orchestrator.snapshot() do
        %{running: running} ->
          entry = Enum.find(running, &(&1.identifier == identifier))
          if entry, do: entry.issue_id, else: nil

        _ ->
          nil
      end

    if issue_id_from_orchestrator do
      issue_id_from_orchestrator
    else
      # Strategy 2: Scan EventStore keys for one whose events contain this identifier
      EventStore.active_issue_ids()
      |> Enum.find(fn id ->
        events = EventStore.get_events(id)
        Enum.any?(events, fn e -> e[:issue_identifier] == identifier end)
      end)
    end
  end

  defp load_persisted_events_for_identifier(identifier) do
    EventStore.list_persisted_sessions()
    |> Enum.find(fn s -> String.contains?(s.filename, identifier) end)
    |> case do
      nil ->
        []

      session ->
        case EventStore.load_persisted_session(session.filename) do
          {:ok, events} -> events
          _ -> []
        end
    end
  end

  # Merge consecutive text_output events into single blocks for readability
  defp filtered_events(events, filter) do
    events
    |> do_filter(filter)
    |> aggregate_text_blocks()
  end

  defp do_filter(events, "all"), do: events

  defp do_filter(events, "tool_use") do
    Enum.filter(events, fn e -> event_type(e) in [:tool_use, :notification] && e[:tool_name] != nil end)
  end

  defp do_filter(events, "text") do
    Enum.filter(events, fn e -> event_type(e) == :text_output end)
  end

  defp do_filter(events, "turn_completed") do
    Enum.filter(events, fn e -> event_type(e) in [:turn_completed, :session_started] end)
  end

  defp do_filter(events, "error") do
    Enum.filter(events, fn e -> event_type(e) in [:turn_ended_with_error, :error] end)
  end

  defp do_filter(events, _), do: events

  # Merge runs of consecutive :text_output events into single aggregated events
  defp aggregate_text_blocks(events) do
    {result, pending} =
      Enum.reduce(events, {[], nil}, fn event, {acc, pending_text} ->
        type = event[:event_type] || event["event_type"]

        case {type, pending_text} do
          {:text_output, nil} ->
            {acc, event}

          {:text_output, prev} ->
            merged = Map.put(prev, :text, (prev[:text] || "") <> (event[:text] || ""))
            {acc, merged}

          {_, nil} ->
            {acc ++ [event], nil}

          {_, prev} ->
            {acc ++ [prev, event], nil}
        end
      end)

    if pending, do: result ++ [pending], else: result
  end

  defp event_type(event) do
    event[:event_type] || event["event_type"]
  end

  defp event_css_type(event) do
    case event_type(event) do
      :session_started -> "session"
      :tool_use -> "tool"
      :text_output -> "text"
      :turn_completed -> "turn"
      :turn_ended_with_error -> "error"
      :notification -> if event[:tool_name], do: "tool", else: "notification"
      _ -> "default"
    end
  end

  defp event_type_label(event) do
    case event_type(event) do
      :session_started -> "SESSION"
      :tool_use -> safe_string(event[:tool_name]) || "TOOL"
      :text_output -> "AGENT"
      :turn_completed -> "TURN"
      :turn_ended_with_error -> "ERROR"
      :notification -> if event[:tool_name], do: safe_string(event[:tool_name]), else: "MSG"
      other -> to_string(other || "EVENT") |> String.upcase() |> String.slice(0, 8)
    end
  end

  defp event_summary(event) do
    cond do
      event_type(event) == :text_output ->
        safe_string(event[:text] || event[:message] || "")

      event_type(event) == :tool_use ->
        summary = safe_string(event[:tool_input_summary] || event[:message] || "")
        if summary != "", do: summary, else: safe_string(event[:tool_name])

      event[:message] && is_binary(event[:message]) ->
        safe_string(event[:message])

      event[:message] && is_map(event[:message]) ->
        safe_string(event[:message][:message] || event[:message]["message"]) ||
          inspect_short(event[:message])

      event[:reason] ->
        "Error: #{inspect_short(event[:reason])}"

      true ->
        safe_string(event_type(event))
    end
  end

  defp event_detail(_event), do: nil

  defp safe_string(nil), do: nil
  defp safe_string(s) when is_binary(s), do: s
  defp safe_string(a) when is_atom(a), do: Atom.to_string(a)
  defp safe_string(n) when is_number(n), do: to_string(n)
  defp safe_string(term), do: inspect(term, limit: 5, printable_limit: 120)

  defp event_tokens(event) do
    usage = event[:usage]

    if is_map(usage) do
      input = usage["input_tokens"] || usage[:input_tokens] || 0
      output = usage["output_tokens"] || usage[:output_tokens] || 0
      "in:#{format_num(input)} out:#{format_num(output)}"
    else
      nil
    end
  end

  defp format_event_time(event) do
    case event[:timestamp] do
      %DateTime{} = dt ->
        Calendar.strftime(dt, "%H:%M:%S")

      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
          _ -> "—"
        end

      _ ->
        "—"
    end
  end

  defp format_num(n) when is_integer(n) and n >= 1000 do
    "#{div(n, 1000)}k"
  end

  defp format_num(n) when is_integer(n), do: to_string(n)
  defp format_num(_), do: "0"

  defp inspect_short(term) do
    s = inspect(term, limit: 5, printable_limit: 100)
    if String.length(s) > 120, do: String.slice(s, 0, 120) <> "...", else: s
  end

  defp filter_label("all"), do: "All"
  defp filter_label("tool_use"), do: "Tools"
  defp filter_label("text"), do: "Agent Output"
  defp filter_label("turn_completed"), do: "Turns"
  defp filter_label("error"), do: "Errors"
  defp filter_label(f), do: f
end
