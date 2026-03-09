defmodule SymphonyElixirWeb.HistoryLive do
  @moduledoc """
  Browse and replay persisted agent session event logs.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.EventStore
  alias SymphonyElixir.GitHub.Adapter

  @impl true
  def mount(params, _session, socket) do
    sessions = EventStore.list_persisted_sessions()
    selected_file = params["file"]

    {selected_events, selected_meta} =
      if selected_file do
        case EventStore.load_persisted_session(selected_file) do
          {:ok, events} ->
            meta = Enum.find(sessions, &(&1.filename == selected_file))
            {events, meta}

          {:error, _} ->
            {[], nil}
        end
      else
        {[], nil}
      end

    issue_map = fetch_issue_map(sessions)

    socket =
      socket
      |> assign(:sessions, sessions)
      |> assign(:issue_map, issue_map)
      |> assign(:selected_file, selected_file)
      |> assign(:selected_events, selected_events)
      |> assign(:selected_meta, selected_meta)
      |> assign(:replay_index, length(selected_events))
      |> assign(:replaying, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("replay_start", _params, socket) do
    send(self(), :replay_tick)
    {:noreply, assign(socket, replay_index: 0, replaying: true)}
  end

  @impl true
  def handle_event("replay_stop", _params, socket) do
    {:noreply, assign(socket, replaying: false, replay_index: length(socket.assigns.selected_events))}
  end

  @impl true
  def handle_info(:replay_tick, socket) do
    if socket.assigns.replaying do
      next = socket.assigns.replay_index + 1

      if next >= length(socket.assigns.selected_events) do
        {:noreply, assign(socket, replay_index: length(socket.assigns.selected_events), replaying: false)}
      else
        Process.send_after(self(), :replay_tick, replay_interval(socket.assigns.selected_events, next))
        {:noreply, assign(socket, :replay_index, next)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card" style="padding: 1.25rem 1.5rem;">
        <div style="display: flex; align-items: center; gap: 1rem; flex-wrap: wrap;">
          <a href="/" class="back-link">&larr; Dashboard</a>
          <div style="flex: 1;">
            <p class="eyebrow">Session History</p>
            <h1 class="hero-title" style="font-size: 1.8rem; margin-top: 0.2rem;">
              <%= if @selected_meta, do: @selected_meta.display_name, else: "Browse Sessions" %>
            </h1>
          </div>
        </div>
      </header>

      <%= if @selected_file do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Session Replay</h2>
              <p class="section-copy">
                <%= length(@selected_events) %> events
                <%= if @selected_meta do %>
                  · <%= format_session_time(@selected_meta.timestamp) %>
                <% end %>
              </p>
            </div>
            <div style="display: flex; gap: 0.5rem;">
              <%= if @replaying do %>
                <button phx-click="replay_stop" class="subtle-button">Stop</button>
              <% else %>
                <button phx-click="replay_start" class="subtle-button">Replay</button>
              <% end %>
              <a href="/history" class="subtle-button" style="display:inline-flex;align-items:center;">
                All sessions
              </a>
            </div>
          </div>

          <div class="event-log" id="replay-log">
            <%= if visible_events(@selected_events, @replay_index) == [] do %>
              <p class="empty-state" style="padding: 2rem;">
                Press "Replay" to start playback.
              </p>
            <% else %>
              <div
                :for={event <- visible_events(@selected_events, @replay_index)}
                class={"event-row event-row-#{event_css_type(event)}"}
              >
                <div class="event-time mono">
                  <%= format_event_time(event) %>
                </div>
                <div class={"event-type-badge event-type-#{event_css_type(event)}"}>
                  <%= event_type_label(event) %>
                </div>
                <div class="event-body">
                  <span class="event-summary"><%= event_summary(event) %></span>
                </div>
                <%= if event_tokens(event) do %>
                  <div class="event-tokens mono muted"><%= event_tokens(event) %></div>
                <% end %>
              </div>
            <% end %>
          </div>
        </section>
      <% else %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Saved Sessions</h2>
              <p class="section-copy">Completed agent sessions persisted to disk.</p>
            </div>
          </div>

          <%= if @sessions == [] do %>
            <p class="empty-state" style="padding: 2rem;">
              No saved sessions yet. Sessions are persisted when agents complete.
            </p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 580px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Session</th>
                    <th>Timestamp</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={session <- @sessions}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= issue_identifier(@issue_map, session.issue_id) %></span>
                        <span class="issue-link"><%= issue_title(@issue_map, session.issue_id) %></span>
                      </div>
                    </td>
                    <td class="mono muted"><%= short_session(session.session_id) %></td>
                    <td class="mono"><%= format_session_time(session.timestamp) %></td>
                    <td>
                      <a href={"/history?file=#{session.filename}"} class="subtle-button">
                        View
                      </a>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  # --- Helpers ---

  defp visible_events(events, index) do
    Enum.take(events, index)
  end

  defp replay_interval(events, next_index) do
    current = Enum.at(events, next_index - 1)
    next = Enum.at(events, next_index)

    cond do
      current && next ->
        t1 = parse_event_ts(current)
        t2 = parse_event_ts(next)

        if t1 && t2 do
          diff_ms = DateTime.diff(t2, t1, :millisecond)
          # Clamp between 50ms and 2000ms for reasonable replay speed
          max(50, min(diff_ms, 2000))
        else
          200
        end

      true ->
        200
    end
  end

  defp parse_event_ts(%{"timestamp" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_event_ts(%{timestamp: %DateTime{} = dt}), do: dt
  defp parse_event_ts(_), do: nil

  defp event_type(event) do
    event["event_type"] || event[:event_type]
  end

  defp event_css_type(event) do
    case event_type(event) do
      t when t in ["session_started", :session_started] -> "session"
      t when t in ["notification", :notification] ->
        if (event["tool_name"] || event[:tool_name]), do: "tool", else: "notification"
      t when t in ["turn_completed", :turn_completed] -> "turn"
      t when t in ["turn_ended_with_error", :turn_ended_with_error] -> "error"
      _ -> "default"
    end
  end

  defp event_type_label(event) do
    case event_type(event) do
      t when t in ["session_started", :session_started] -> "SESSION"
      t when t in ["notification", :notification] ->
        if (event["tool_name"] || event[:tool_name]), do: "TOOL", else: "MSG"
      t when t in ["turn_completed", :turn_completed] -> "TURN"
      t when t in ["turn_ended_with_error", :turn_ended_with_error] -> "ERROR"
      other -> to_string(other || "EVENT") |> String.upcase() |> String.slice(0, 8)
    end
  end

  defp event_summary(event) do
    tool = event["tool_name"] || event[:tool_name]
    msg = event["message"] || event[:message]
    reason = event["reason"] || event[:reason]

    cond do
      tool -> "Tool: #{tool}"
      is_map(msg) -> msg["message"] || msg[:message] || inspect(msg, limit: 5)
      msg -> to_string(msg)
      reason -> "Error: #{inspect(reason, limit: 5)}"
      true -> to_string(event_type(event))
    end
  end

  defp event_tokens(event) do
    usage = event["usage"] || event[:usage]

    if is_map(usage) do
      input = usage["input_tokens"] || usage[:input_tokens] || 0
      output = usage["output_tokens"] || usage[:output_tokens] || 0
      "in:#{input} out:#{output}"
    else
      nil
    end
  end

  defp format_event_time(event) do
    case parse_event_ts(event) do
      %DateTime{} = dt -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> "—"
    end
  end

  defp format_session_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_session_time(_), do: "—"

  defp fetch_issue_map(sessions) do
    issue_ids =
      sessions
      |> Enum.map(& &1.issue_id)
      |> Enum.uniq()

    case Adapter.fetch_issue_states_by_ids(issue_ids) do
      {:ok, issues} ->
        Map.new(issues, fn issue -> {issue.id, issue} end)

      {:error, _} ->
        %{}
    end
  end

  defp issue_identifier(issue_map, issue_id) do
    case Map.get(issue_map, issue_id) do
      %{identifier: id} when is_binary(id) -> id
      _ -> short_id(issue_id)
    end
  end

  defp issue_title(issue_map, issue_id) do
    case Map.get(issue_map, issue_id) do
      %{title: title} when is_binary(title) -> title
      _ -> ""
    end
  end

  defp short_id(id) when is_binary(id) do
    if String.length(id) > 8, do: String.slice(id, 0, 8) <> "…", else: id
  end

  defp short_id(_), do: "—"

  defp short_session("nosession"), do: "—"

  defp short_session(sid) when is_binary(sid) do
    if String.length(sid) > 12, do: String.slice(sid, 0, 12) <> "...", else: sid
  end

  defp short_session(_), do: "—"
end
