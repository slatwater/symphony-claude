defmodule SymphonyElixirWeb.AgentLogLive do
  @moduledoc """
  Pipeline flow view for agent tasks. Aggregates raw events into high-level
  phases and renders a horizontal flow diagram with click-to-expand detail.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.EventStore
  alias SymphonyElixirWeb.ObservabilityPubSub

  @phase_order [
    :receive_task,
    :query_issue,
    :start_processing,
    :explore_code,
    :analyze_plan,
    :modify_code,
    :validate,
    :commit_push,
    :create_pr,
    :review_check,
    :complete_task
  ]

  @phase_labels %{
    receive_task: "接收任务",
    query_issue: "查询Issue",
    start_processing: "开始处理",
    explore_code: "探索代码",
    analyze_plan: "分析规划",
    modify_code: "修改代码",
    validate: "验证测试",
    commit_push: "提交推送",
    create_pr: "创建PR",
    review_check: "审查检查",
    complete_task: "完成任务"
  }

  @impl true
  def mount(%{"issue_identifier" => identifier}, _session, socket) do
    issue_id = resolve_issue_id(identifier)

    events =
      cond do
        issue_id && EventStore.get_events(issue_id) != [] ->
          EventStore.get_events(issue_id)

        true ->
          load_persisted_events_for_identifier(identifier)
      end

    status = if issue_id, do: :live, else: :historical
    phases = build_phases(events, status)

    socket =
      socket
      |> assign(:issue_identifier, identifier)
      |> assign(:issue_id, issue_id)
      |> assign(:events, events)
      |> assign(:phases, phases)
      |> assign(:selected_phase, nil)
      |> assign(:status, status)

    if connected?(socket) && issue_id do
      :ok = ObservabilityPubSub.subscribe_agent_events(issue_id)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info({:agent_event, _issue_id, event}, socket) do
    events = socket.assigns.events ++ [event]
    phases = build_phases(events, socket.assigns.status)

    selected = socket.assigns.selected_phase

    selected =
      if selected && Enum.any?(phases, &(&1.phase == selected)),
        do: selected,
        else: nil

    {:noreply,
     socket
     |> assign(:events, events)
     |> assign(:phases, phases)
     |> assign(:selected_phase, selected)}
  end

  @impl true
  def handle_event("select_phase", %{"phase" => phase_str}, socket) do
    phase = String.to_existing_atom(phase_str)
    selected = if socket.assigns.selected_phase == phase, do: nil, else: phase
    {:noreply, assign(socket, :selected_phase, selected)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card" style="padding: 1.25rem 1.5rem;">
        <div style="display: flex; align-items: center; gap: 1rem; flex-wrap: wrap;">
          <a href="/" class="back-link">&larr; Dashboard</a>
          <div style="flex: 1;">
            <p class="eyebrow">Agent Pipeline</p>
            <h1 class="hero-title" style="font-size: 1.8rem; margin-top: 0.2rem;">
              <%= @issue_identifier %>
            </h1>
          </div>
          <div style="display: flex; gap: 0.5rem; align-items: center;">
            <span class="event-count-badge"><%= length(@events) %> events</span>
            <span class={"status-badge #{if @status == :live, do: "status-live", else: "status-historical"}"}>
              <%= if @status == :live, do: "LIVE", else: "HISTORICAL" %>
            </span>
          </div>
        </div>
      </header>

      <section class="section-card">
        <%= if @phases == [] do %>
          <p class="empty-state" style="padding: 2rem;">
            <%= if @status == :live do %>
              Waiting for agent events...
            <% else %>
              No events found for this issue.
            <% end %>
          </p>
        <% else %>
          <div class="flow-pipeline">
            <%= for {phase, idx} <- Enum.with_index(@phases) do %>
              <%= if idx > 0 do %>
                <div class="flow-arrow">
                  <div class="flow-arrow-line"></div>
                  <div class="flow-arrow-head"></div>
                </div>
              <% end %>
              <div
                class={"flow-step flow-step-#{phase.status} #{if @selected_phase == phase.phase, do: "flow-step-selected"}"}
                phx-click="select_phase"
                phx-value-phase={phase.phase}
              >
                <div class="flow-step-label"><%= phase.label %></div>
                <div class="flow-step-meta"><%= phase.summary %></div>
                <div class="flow-step-duration mono"><%= phase.duration || "—" %></div>
              </div>
            <% end %>
          </div>
        <% end %>
      </section>

      <%= if @selected_phase do %>
        <% phase_data = Enum.find(@phases, &(&1.phase == @selected_phase)) %>
        <%= if phase_data do %>
          <section class="section-card" style="margin-top: 0;">
            <div class="phase-detail-header">
              <h3 class="phase-detail-title"><%= phase_data.label %></h3>
              <span class="event-count-badge"><%= length(phase_data.events) %> events</span>
            </div>
            <div class="phase-detail-log">
              <%= for {event, idx} <- Enum.with_index(phase_data.events) do %>
                <div id={"detail-#{idx}"} class={"event-row event-row-#{event_css_type(event)}"}>
                  <div class="event-time mono"><%= format_event_time(event) %></div>
                  <div class={"event-type-badge event-type-#{event_css_type(event)}"}>
                    <%= event_type_label(event) %>
                  </div>
                  <div class="event-body">
                    <%= if event_css_type(event) == "text" do %>
                      <pre class="event-text-block"><%= field(event, :text) || field(event, :message) || "" %></pre>
                    <% else %>
                      <span class="event-summary"><%= event_summary(event) %></span>
                    <% end %>
                  </div>
                  <%= if event_tokens(event) do %>
                    <div class="event-tokens mono muted"><%= event_tokens(event) %></div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </section>
        <% end %>
      <% end %>
    </section>
    """
  end

  # --- Phase Building ---

  defp build_phases(events, session_status) do
    {raw_phases, _seen} =
      Enum.reduce(events, {[], MapSet.new()}, fn event, {phases, seen} ->
        classification = classify_event(event, seen)

        case classification do
          nil ->
            {phases, seen}

          phase when phase in [:_meta, :_text, :_setup] ->
            {append_to_last_phase(phases, event), seen}

          phase_key ->
            if phases != [] && List.last(phases).phase == phase_key do
              {append_to_last_phase(phases, event), seen}
            else
              new_phase = %{
                phase: phase_key,
                label: @phase_labels[phase_key] || to_string(phase_key),
                events: [event],
                start_time: field(event, :timestamp),
                end_time: field(event, :timestamp)
              }

              {phases ++ [new_phase], MapSet.put(seen, phase_key)}
            end
        end
      end)

    sorted = sort_phases(raw_phases)
    total = length(sorted)

    sorted
    |> Enum.with_index()
    |> Enum.map(fn {phase, idx} ->
      is_last = idx == total - 1

      phase
      |> compute_duration()
      |> compute_summary()
      |> compute_status(is_last, session_status)
    end)
  end

  defp append_to_last_phase([], _event), do: []

  defp append_to_last_phase(phases, event) do
    List.update_at(phases, -1, fn phase ->
      %{phase | events: phase.events ++ [event], end_time: field(event, :timestamp)}
    end)
  end

  defp sort_phases(phases) do
    order_map = @phase_order |> Enum.with_index() |> Map.new()

    phases
    |> Enum.sort_by(fn p -> Map.get(order_map, p.phase, 999) end)
    |> merge_same_phases()
  end

  defp merge_same_phases([]), do: []

  defp merge_same_phases([first | rest]) do
    {merged, last} =
      Enum.reduce(rest, {[], first}, fn phase, {acc, prev} ->
        if phase.phase == prev.phase do
          combined = %{
            prev
            | events: prev.events ++ phase.events,
              end_time: phase.end_time || prev.end_time
          }

          {acc, combined}
        else
          {acc ++ [prev], phase}
        end
      end)

    merged ++ [last]
  end

  defp compute_duration(phase) do
    duration =
      with s when not is_nil(s) <- parse_time(phase.start_time),
           e when not is_nil(e) <- parse_time(phase.end_time) do
        diff = DateTime.diff(e, s, :second)

        cond do
          diff < 1 -> "<1s"
          diff < 60 -> "#{diff}s"
          true -> "#{div(diff, 60)}m#{rem(diff, 60)}s"
        end
      else
        _ -> nil
      end

    Map.put(phase, :duration, duration)
  end

  defp compute_summary(phase) do
    tool_events =
      Enum.filter(phase.events, fn e -> event_type(e) == :tool_use end)

    tool_count = length(tool_events)

    summary =
      case phase.phase do
        :receive_task ->
          Enum.find_value(phase.events, "", fn e ->
            field(e, :issue_identifier)
          end)

        :query_issue ->
          "#{tool_count} 次查询"

        :start_processing ->
          "状态 → 进行中"

        :explore_code ->
          "#{tool_count} 次工具调用"

        :analyze_plan ->
          "Agent 思考"

        :modify_code ->
          files =
            tool_events
            |> Enum.filter(fn e ->
              to_string(field(e, :tool_name)) in ["Write", "Edit"]
            end)
            |> Enum.map(fn e ->
              path = to_string(field(e, :tool_input_summary) || "")
              path |> String.split("/") |> List.last() || ""
            end)
            |> Enum.filter(&(&1 != ""))
            |> Enum.uniq()

          if files != [], do: Enum.join(files, ", "), else: "#{tool_count} 次操作"

        :validate ->
          "#{tool_count} 次验证"

        :commit_push ->
          "add → commit → push"

        :create_pr ->
          find_pr_number(phase.events) || "创建中"

        :review_check ->
          "#{tool_count} 次检查"

        :complete_task ->
          "状态 → 待审查"

        _ ->
          "#{tool_count} 次操作"
      end

    Map.put(phase, :summary, summary)
  end

  defp compute_status(phase, is_last, session_status) do
    has_error =
      Enum.any?(phase.events, fn e ->
        event_type(e) in [:turn_ended_with_error, :error]
      end)

    status =
      cond do
        has_error -> :failed
        is_last && session_status == :live -> :in_progress
        true -> :completed
      end

    Map.put(phase, :status, status)
  end

  defp find_pr_number(events) do
    Enum.find_value(events, fn e ->
      msg = to_string(field(e, :message) || field(e, :text) || "")

      case Regex.run(~r/pull\/(\d+)/, msg) do
        [_, num] -> "PR ##{num}"
        _ -> nil
      end
    end)
  end

  # --- Event Classification ---

  defp classify_event(event, seen) do
    type = event_type(event)
    tool = to_string(field(event, :tool_name) || "")
    raw = to_string(field(event, :tool_input_summary) || field(event, :message) || "")
    summary = String.downcase(raw)

    cond do
      type == :session_started ->
        :receive_task

      type in [:turn_completed, :turn_ended_with_error] ->
        :_meta

      type == :text_output ->
        :_text

      tool == "ToolSearch" ->
        :_setup

      tool == "mcp__linear__linear_graphql" ->
        classify_linear_event(summary, seen)

      type == :tool_use ->
        classify_tool_event(tool, summary)

      true ->
        nil
    end
  end

  defp classify_linear_event(summary, seen) do
    cond do
      String.contains?(summary, "query") && !String.contains?(summary, "mutation") ->
        :query_issue

      String.contains?(summary, "issueupdate") ->
        if MapSet.member?(seen, :start_processing), do: :complete_task, else: :start_processing

      String.contains?(summary, "commentcreate") ||
          String.contains?(summary, "commentupdate") ->
        :review_check

      String.contains?(summary, "attach") ->
        :review_check

      true ->
        :query_issue
    end
  end

  defp classify_tool_event(tool, summary) do
    cond do
      String.contains?(summary, "gh pr create") ->
        :create_pr

      String.contains?(summary, "gh pr view") ||
          (String.contains?(summary, "pulls") && String.contains?(summary, "comments")) ->
        :review_check

      String.contains?(summary, "git add") || String.contains?(summary, "git commit") ->
        :commit_push

      String.contains?(summary, "git push") ->
        :commit_push

      String.contains?(summary, "git checkout -b") ->
        :modify_code

      Regex.match?(~r/\btest\b/, summary) || String.contains?(summary, "echo exis") ||
          String.contains?(summary, "verify") ->
        :validate

      tool in ["Write", "Edit"] ->
        :modify_code

      tool in ["Read", "Glob", "Grep"] ->
        :explore_code

      true ->
        :explore_code
    end
  end

  # --- Helpers ---

  defp field(event, key) when is_atom(key) do
    event[key] || event[Atom.to_string(key)]
  end

  defp event_type(event) do
    raw = event[:event_type] || event["event_type"]
    if is_binary(raw), do: String.to_existing_atom(raw), else: raw
  end

  defp event_css_type(event) do
    case event_type(event) do
      :session_started -> "session"
      :tool_use -> "tool"
      :text_output -> "text"
      :turn_completed -> "turn"
      :turn_ended_with_error -> "error"
      :notification -> if field(event, :tool_name), do: "tool", else: "notification"
      _ -> "default"
    end
  end

  defp event_type_label(event) do
    case event_type(event) do
      :session_started -> "SESSION"
      :tool_use -> safe_string(field(event, :tool_name)) || "TOOL"
      :text_output -> "AGENT"
      :turn_completed -> "TURN"
      :turn_ended_with_error -> "ERROR"
      :notification -> if field(event, :tool_name), do: safe_string(field(event, :tool_name)), else: "MSG"
      other -> to_string(other || "EVENT") |> String.upcase() |> String.slice(0, 8)
    end
  end

  defp event_summary(event) do
    cond do
      event_type(event) == :tool_use ->
        s = safe_string(field(event, :tool_input_summary) || field(event, :message) || "")
        if s != "", do: s, else: safe_string(field(event, :tool_name))

      event[:message] && is_binary(event[:message]) ->
        safe_string(event[:message])

      event["message"] && is_binary(event["message"]) ->
        safe_string(event["message"])

      field(event, :reason) ->
        "Error: #{inspect_short(field(event, :reason))}"

      true ->
        safe_string(event_type(event))
    end
  end

  defp event_tokens(event) do
    usage = field(event, :usage)

    if is_map(usage) do
      input = usage["input_tokens"] || usage[:input_tokens] || 0
      output = usage["output_tokens"] || usage[:output_tokens] || 0
      "in:#{format_num(input)} out:#{format_num(output)}"
    else
      nil
    end
  end

  defp safe_string(nil), do: nil
  defp safe_string(s) when is_binary(s), do: s
  defp safe_string(a) when is_atom(a), do: Atom.to_string(a)
  defp safe_string(n) when is_number(n), do: to_string(n)
  defp safe_string(term), do: inspect(term, limit: 5, printable_limit: 120)

  defp format_event_time(event) do
    case field(event, :timestamp) do
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

  defp parse_time(%DateTime{} = dt), do: dt

  defp parse_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp format_num(n) when is_integer(n) and n >= 1000, do: "#{div(n, 1000)}k"
  defp format_num(n) when is_integer(n), do: to_string(n)
  defp format_num(_), do: "0"

  defp inspect_short(term) do
    s = inspect(term, limit: 5, printable_limit: 100)
    if String.length(s) > 120, do: String.slice(s, 0, 120) <> "...", else: s
  end

  defp resolve_issue_id(identifier) do
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
      EventStore.active_issue_ids()
      |> Enum.find(fn id ->
        events = EventStore.get_events(id)
        Enum.any?(events, fn e -> field(e, :issue_identifier) == identifier end)
      end)
    end
  end

  defp load_persisted_events_for_identifier(identifier) do
    sessions = EventStore.list_persisted_sessions()

    # Strategy 1: match by filename
    session = Enum.find(sessions, fn s -> String.contains?(s.filename, identifier) end)

    # Strategy 2: scan event contents for matching identifier
    session =
      session ||
        Enum.find(sessions, fn s ->
          case EventStore.load_persisted_session(s.filename) do
            {:ok, events} ->
              Enum.any?(events, fn e ->
                (e[:issue_identifier] || e["issue_identifier"]) == identifier
              end)

            _ ->
              false
          end
        end)

    case session do
      nil ->
        []

      s ->
        case EventStore.load_persisted_session(s.filename) do
          {:ok, events} -> events
          _ -> []
        end
    end
  end
end
