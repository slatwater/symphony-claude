defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub REST API client for polling and managing issues.

  Issues use labels for workflow state management. The `active_states` and
  `terminal_states` configured in WORKFLOW.md map to GitHub label names.
  """

  require Logger
  alias SymphonyElixir.{Config, GitHub.Issue}

  @issues_per_page 100
  @max_error_body_log_bytes 1_000

  # --- Public API ---

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    repo = Config.github_repo()

    cond do
      is_nil(Config.github_api_token()) -> {:error, :missing_github_api_token}
      is_nil(repo) -> {:error, :missing_github_repo}
      true ->
        with {:ok, assignee_filter} <- resolve_assignee_filter() do
          do_fetch_by_labels(repo, Config.github_active_states(), assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_labels) when is_list(state_labels) do
    normalized = state_labels |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      repo = Config.github_repo()

      cond do
        is_nil(Config.github_api_token()) -> {:error, :missing_github_api_token}
        is_nil(repo) -> {:error, :missing_github_repo}
        true -> do_fetch_by_labels(repo, normalized, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_numbers) when is_list(issue_numbers) do
    numbers = Enum.uniq(issue_numbers)

    if numbers == [] do
      {:ok, []}
    else
      repo = Config.github_repo()

      cond do
        is_nil(Config.github_api_token()) -> {:error, :missing_github_api_token}
        is_nil(repo) -> {:error, :missing_github_repo}
        true ->
          with {:ok, assignee_filter} <- resolve_assignee_filter(),
               {:ok, headers} <- auth_headers() do
            fetch_issues_by_number_list(repo, numbers, headers, assignee_filter)
          end
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_number, body) when is_binary(issue_number) and is_binary(body) do
    repo = Config.github_repo()

    with {:ok, headers} <- auth_headers(),
         url = "#{api_base()}/repos/#{repo}/issues/#{issue_number}/comments",
         {:ok, %{status: status}} when status in 200..299 <-
           Req.post(url, headers: headers, json: %{"body" => body}, connect_options: [timeout: 30_000]) do
      :ok
    else
      {:ok, response} ->
        Logger.error("GitHub create comment failed status=#{response.status}")
        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_number, target_state)
      when is_binary(issue_number) and is_binary(target_state) do
    repo = Config.github_repo()

    all_state_labels =
      (Config.github_active_states() ++ Config.github_terminal_states())
      |> Enum.map(&normalize_label/1)
      |> MapSet.new()

    with {:ok, headers} <- auth_headers(),
         {:ok, current_issue} <- fetch_single_issue(repo, issue_number, headers) do
      new_labels =
        current_issue.labels
        |> Enum.reject(fn l -> MapSet.member?(all_state_labels, normalize_label(l)) end)
        |> then(fn labels -> [target_state | labels] end)

      terminal_set =
        Config.github_terminal_states()
        |> Enum.map(&normalize_label/1)
        |> MapSet.new()

      gh_state =
        if MapSet.member?(terminal_set, normalize_label(target_state)),
          do: "closed",
          else: "open"

      url = "#{api_base()}/repos/#{repo}/issues/#{issue_number}"

      case Req.patch(url,
             headers: headers,
             json: %{"labels" => new_labels, "state" => gh_state},
             connect_options: [timeout: 30_000]
           ) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, response} -> {:error, {:github_api_status, response.status}}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  # --- Private: Fetching ---

  defp do_fetch_by_labels(repo, labels, assignee_filter) do
    results =
      Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, acc} ->
        case fetch_label_issues(repo, label, assignee_filter) do
          {:ok, issues} -> {:cont, {:ok, acc ++ issues}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, issues} -> {:ok, Enum.uniq_by(issues, & &1.id)}
      error -> error
    end
  end

  defp fetch_label_issues(repo, label, assignee_filter, page \\ 1, acc \\ []) do
    with {:ok, headers} <- auth_headers() do
      url = "#{api_base()}/repos/#{repo}/issues"

      params = [
        state: "open",
        labels: label,
        per_page: @issues_per_page,
        page: page,
        sort: "updated",
        direction: "desc"
      ]

      case Req.get(url, headers: headers, params: params, connect_options: [timeout: 30_000]) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          issues =
            body
            |> Enum.map(&normalize_issue(&1, assignee_filter))
            |> Enum.reject(&is_nil/1)

          all_issues = acc ++ issues

          if length(body) == @issues_per_page do
            fetch_label_issues(repo, label, assignee_filter, page + 1, all_issues)
          else
            {:ok, all_issues}
          end

        {:ok, %{status: status} = response} ->
          Logger.error(
            "GitHub API request failed status=#{status}#{error_context(response)}"
          )

          {:error, {:github_api_status, status}}

        {:error, reason} ->
          Logger.error("GitHub API request failed: #{inspect(reason)}")
          {:error, {:github_api_request, reason}}
      end
    end
  end

  defp fetch_issues_by_number_list(repo, numbers, headers, assignee_filter) do
    results =
      Enum.reduce_while(numbers, {:ok, []}, fn number, {:ok, acc} ->
        case fetch_single_issue(repo, number, headers) do
          {:ok, issue} ->
            updated = %{issue | assigned_to_worker: assigned_to_worker?(issue.assignee_id, assignee_filter)}
            {:cont, {:ok, [updated | acc]}}

          {:error, :issue_not_found} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp fetch_single_issue(repo, number, headers) do
    url = "#{api_base()}/repos/#{repo}/issues/#{number}"

    case Req.get(url, headers: headers, connect_options: [timeout: 30_000]) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        case normalize_issue(body, nil) do
          nil -> {:error, :issue_not_found}
          issue -> {:ok, issue}
        end

      {:ok, %{status: 404}} ->
        {:error, :issue_not_found}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  # --- Private: Normalization ---

  defp normalize_issue(%{"pull_request" => _}, _assignee_filter), do: nil

  defp normalize_issue(%{"number" => number} = issue, assignee_filter) when is_integer(number) do
    labels = extract_labels(issue)
    state = derive_state(issue, labels)
    assignee_login = get_in(issue, ["assignee", "login"])

    %Issue{
      id: to_string(number),
      identifier: "##{number}",
      title: issue["title"],
      description: issue["body"],
      priority: nil,
      state: state,
      branch_name: "issue-#{number}",
      url: issue["html_url"],
      assignee_id: assignee_login,
      blocked_by: [],
      labels: labels,
      assigned_to_worker: assigned_to_worker?(assignee_login, assignee_filter),
      created_at: parse_datetime(issue["created_at"]),
      updated_at: parse_datetime(issue["updated_at"])
    }
  end

  defp normalize_issue(_, _assignee_filter), do: nil

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> String.downcase(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_), do: []

  defp derive_state(%{"state" => "closed"}, _labels), do: "Done"

  defp derive_state(_issue, labels) do
    all_states = Config.github_active_states() ++ Config.github_terminal_states()

    Enum.find(all_states, "open", fn state ->
      normalize_label(state) in labels
    end)
  end

  # --- Private: Assignee ---

  defp resolve_assignee_filter do
    case Config.github_assignee() do
      nil -> {:ok, nil}
      assignee -> build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    trimmed = String.trim(assignee)

    cond do
      trimmed == "" ->
        {:ok, nil}

      String.downcase(trimmed) == "me" ->
        resolve_current_user_filter()

      true ->
        {:ok, %{login: String.downcase(trimmed)}}
    end
  end

  defp resolve_current_user_filter do
    with {:ok, headers} <- auth_headers(),
         {:ok, %{status: 200, body: %{"login" => login}}} <-
           Req.get("#{api_base()}/user", headers: headers, connect_options: [timeout: 30_000]) do
      {:ok, %{login: String.downcase(login)}}
    else
      {:ok, _} -> {:error, :missing_github_user_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assigned_to_worker?(_login, nil), do: true
  defp assigned_to_worker?(nil, %{login: _}), do: false

  defp assigned_to_worker?(login, %{login: filter_login}) when is_binary(login) do
    String.downcase(login) == filter_login
  end

  defp assigned_to_worker?(_, _), do: true

  # --- Private: Helpers ---

  defp api_base, do: Config.github_endpoint()

  defp auth_headers do
    case Config.github_api_token() do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", "2022-11-28"}
         ]}
    end
  end

  defp normalize_label(label) when is_binary(label) do
    label |> String.trim() |> String.downcase()
  end

  defp error_context(%{body: body}) when is_binary(body) do
    truncated =
      if byte_size(body) > @max_error_body_log_bytes do
        binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
      else
        body
      end

    " body=#{inspect(truncated)}"
  end

  defp error_context(_), do: ""

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
