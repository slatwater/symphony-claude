defmodule SymphonyElixir.EventStore do
  @moduledoc """
  ETS-backed event store for agent session events.

  Accumulates granular events (tool calls, messages, token updates) per issue_id
  during a session. On session completion, persists the event log to disk as JSON
  for later replay. Also provides an in-memory query API for the live dashboard.
  """

  use GenServer
  require Logger

  @table :symphony_event_store
  @max_events_per_issue 500
  @sessions_dir "log/sessions"

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec append(String.t(), map()) :: :ok
  def append(issue_id, event) when is_binary(issue_id) and is_map(event) do
    timestamped =
      event
      |> Map.put_new(:id, System.unique_integer([:positive, :monotonic]))
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> Map.put(:issue_id, issue_id)

    GenServer.cast(__MODULE__, {:append, issue_id, timestamped})
  end

  @spec get_events(String.t()) :: [map()]
  def get_events(issue_id) when is_binary(issue_id) do
    case :ets.lookup(@table, issue_id) do
      [{^issue_id, events}] -> events
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  @spec persist_session(String.t(), String.t() | nil) :: :ok
  def persist_session(issue_id, session_id \\ nil) do
    GenServer.cast(__MODULE__, {:persist_session, issue_id, session_id})
  end

  @spec clear(String.t()) :: :ok
  def clear(issue_id) when is_binary(issue_id) do
    GenServer.cast(__MODULE__, {:clear, issue_id})
  end

  @spec list_persisted_sessions() :: [map()]
  def list_persisted_sessions do
    dir = sessions_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&parse_session_filename/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

      {:error, _} ->
        []
    end
  end

  @spec load_persisted_session(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def load_persisted_session(filename) when is_binary(filename) do
    path = Path.join(sessions_dir(), sanitize_filename(filename))

    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, events} -> {:ok, events}
          {:error, _} -> {:error, :not_found}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @spec active_issue_ids() :: [String.t()]
  def active_issue_ids do
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    File.mkdir_p!(sessions_dir())
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:append, issue_id, event}, state) do
    events =
      case :ets.lookup(@table, issue_id) do
        [{^issue_id, existing}] -> existing
        [] -> []
      end

    trimmed =
      if length(events) >= @max_events_per_issue do
        Enum.drop(events, 1)
      else
        events
      end

    :ets.insert(@table, {issue_id, trimmed ++ [event]})
    {:noreply, state}
  end

  def handle_cast({:persist_session, issue_id, session_id}, state) do
    events = get_events(issue_id)

    if events != [] do
      do_persist(issue_id, session_id, events)
      :ets.delete(@table, issue_id)
    end

    {:noreply, state}
  end

  def handle_cast({:clear, issue_id}, state) do
    :ets.delete(@table, issue_id)
    {:noreply, state}
  end

  # --- Private ---

  defp do_persist(issue_id, session_id, events) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[^0-9T]/, "-")
    sid = session_id || "nosession"
    filename = "#{issue_id}_#{sid}_#{ts}.json"
    path = Path.join(sessions_dir(), sanitize_filename(filename))

    serializable =
      Enum.map(events, fn event ->
        event
        |> Map.update(:timestamp, nil, &safe_to_string/1)
        |> stringify_keys()
      end)

    case Jason.encode(serializable, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)
        Logger.info("Persisted #{length(events)} events for #{issue_id} to #{path}")

      {:error, reason} ->
        Logger.warning("Failed to serialize events for #{issue_id}: #{inspect(reason)}")
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp safe_to_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp safe_to_string(other), do: to_string(other)

  defp sessions_dir do
    Application.get_env(:symphony_elixir, :sessions_dir, @sessions_dir)
  end

  defp parse_session_filename(filename) do
    base = String.replace_suffix(filename, ".json", "")
    parts = String.split(base, "_", parts: 3)

    case parts do
      [issue_id, session_id, ts_str] ->
        %{
          filename: filename,
          issue_id: issue_id,
          session_id: session_id,
          timestamp: parse_ts(ts_str),
          display_name: "#{issue_id} / #{session_id}"
        }

      _ ->
        nil
    end
  end

  defp parse_ts(ts_str) do
    # Stored as ISO8601 with - replacing special chars
    case DateTime.from_iso8601(String.replace(ts_str, "-", ":") |> fix_iso_ts()) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp fix_iso_ts(s) do
    # best effort: 2026:03:08T12:30:00:000Z → 2026-03-08T12:30:00.000Z
    s
  end

  defp sanitize_filename(filename) do
    filename
    |> String.replace(~r/[^A-Za-z0-9._\-]/, "_")
    |> String.slice(0, 255)
  end
end
