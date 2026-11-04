defmodule OCSF.Ecto.Sink do
  @moduledoc """
  Postgres sink implementation of the `OCSF.Sink` behaviour.

  Writes `%OCSF.Event{}` structs to the `ocsf_event__logs` table via
  `Ecto.Repo.insert_all/3`. Applies the configured `OCSF.Policy` for
  field-level redaction before insert. PII fields (`user__name`,
  `user__email_addr`) are transparently encrypted via Cloak.

  ## Configuration

      # Optional — swap the Repo if you want the sink to write
      # through your host app's Repo instead of the bundled
      # OCSF.Ecto.Repo. Defaults to OCSF.Ecto.Repo.
      config :ocsf_ecto, repo: MyApp.Repo

      # Policy applied to every write. Optional — defaults to
      # allow PII / deny :network.
      config :ocsf_ecto, OCSF.Ecto.Sink,
        policy: %OCSF.Policy{
          allow: [:identifier, :tenant, :taxonomic, :temporal,
                  :contact, :identity],
          deny:  [:network],
          transform: []
        }

  ## Example

      {:ok, event} =
        OCSF.Events.Authentication.logon(user: %{uid: "u1"}, service: %{name: "auth"})
      OCSF.Ecto.Sink.write([event])
      #=> :ok

  ## Telemetry

  `write/1` wraps its work in `:telemetry.span/3`, emitting three
  events under the `[:ocsf_ecto, :sink, :write]` prefix:

  | Event                                      | Measurements          | Metadata                                        |
  |--------------------------------------------|-----------------------|-------------------------------------------------|
  | `[:ocsf_ecto, :sink, :write, :start]`      | `:monotonic_time`, `:system_time`     | `:count`, `:sink`                               |
  | `[:ocsf_ecto, :sink, :write, :stop]`       | `:duration`, `:monotonic_time`        | `:count`, `:sink`, `:result` (`:ok \| :error`)  |
  | `[:ocsf_ecto, :sink, :write, :exception]`  | `:duration`, `:monotonic_time`        | `:count`, `:sink`, `:kind`, `:reason`, `:stacktrace` |

  Metadata intentionally excludes event payloads — batch `:count`
  is a coarse observability signal; emitters should correlate with
  the core `[:ocsf, :event, :new]` stream for per-event detail.

  `[:ocsf_ecto, :sink, :rejected]` (`%{count: 1}` /
  `%{sink, reason, error}`) counts each event dropped because its row can
  never be stored: `reason` is `:invalid_row` (`error` names the exception
  module the insert raised, e.g. `Ecto.ChangeError`, `Postgrex.Error`) or
  `:invalid_event` (`error` is `nil`: the row could not be built at all).

  See `OCSF.Ecto.Event`, `OCSF.Ecto.Repo`.
  """

  alias OCSF.Ecto.Event, as: EctoEvent

  @behaviour OCSF.Sink

  @default_repo OCSF.Ecto.Repo

  @default_policy %OCSF.Policy{
    allow: [:identifier, :tenant, :taxonomic, :temporal, :contact, :identity],
    deny: [:network],
    transform: []
  }

  @doc """
  Writes a batch of OCSF events to Postgres.

  Each event is run through the configured `OCSF.Policy` (denied
  classes become `nil`), projected to the flat `ocsf_event__logs`
  row shape, and inserted via `Ecto.Repo.insert_all/3` with
  `on_conflict: :nothing` on the `:id` column. Replaying the same
  event UID is therefore a no-op.

  Returns `:ok` when the insert succeeds (even if no new rows were
  written due to conflict), or `{:error, exception}` on failure.

  One bad row never fails the batch. Values OCSF allows but a column
  can't take are coerced (see `row_for/1`). When the batch insert still
  fails on a row — a `metadata.uid` that isn't a UUID, a value the column
  type refuses, a `NOT NULL` column left empty, an `unmapped` term JSON
  can't encode — the batch is retried one row at a time: the faulty rows
  are dropped and counted on `[:ocsf_ecto, :sink, :rejected]`, the rest is
  written. `{:error, _}` is left for failures of the write itself, such
  as the database being down or the vault failing, which are worth
  retrying.

  Emits `:telemetry` events under `[:ocsf_ecto, :sink, :write]` —
  see the module docs for the full event table.

  ## Examples

      {:ok, event} =
        OCSF.Events.Authentication.logon(user: %{uid: "u1"}, service: %{name: "auth"})
      :ok = OCSF.Ecto.Sink.write([event])

      # Replay is idempotent on metadata.uid
      :ok = OCSF.Ecto.Sink.write([event])
  """
  @impl true
  @spec write([OCSF.Event.t()]) :: :ok | {:error, term}
  def write(events) when is_list(events) do
    start_metadata = %{count: length(events), sink: __MODULE__}

    :telemetry.span(
      [:ocsf_ecto, :sink, :write],
      start_metadata,
      fn ->
        result = do_write(events)
        {result, Map.put(start_metadata, :result, result_tag(result))}
      end
    )
  end

  defp do_write(events) do
    policy = policy()

    events
    |> Enum.flat_map(&build_row(&1, policy))
    |> insert()
  end

  # Building a row only reads the event: whatever it raises comes from the
  # event, never from the environment (repo, policy, vault are outside).
  defp build_row(%OCSF.Event{} = event, policy) do
    [project(event, policy)]
  rescue
    _error -> rejected(:invalid_event)
  end

  defp build_row(_not_an_event, _policy), do: rejected(:invalid_event)

  # One row the table refuses fails the whole `insert_all/3`, so the batch
  # with it, on every retry. When the batch fails on a row error, it is
  # retried one row at a time: the faulty row is dropped and counted on
  # `[:ocsf_ecto, :sink, :rejected]`, the rest is written. Rows written
  # before the failure are no-ops the second time (`on_conflict: :nothing`).
  defp insert([]), do: :ok

  defp insert(rows) do
    insert_all(rows)
  rescue
    error -> if row_error?(error), do: isolate(rows), else: {:error, error}
  end

  defp isolate(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case insert_one(row) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp insert_one(row) do
    insert_all([row])
  rescue
    error ->
      if row_error?(error), do: rejected(:invalid_row, error), else: {:error, error}
  end

  # Inside a transaction, a statement Postgres refuses aborts it: the
  # savepoint keeps the caller's transaction, and the isolation retries,
  # usable.
  defp insert_all(rows) do
    repo = repo()
    opts = [on_conflict: :nothing, conflict_target: :id]
    opts = if repo.in_transaction?(), do: [mode: :savepoint] ++ opts, else: opts

    {_count, _} = repo.insert_all(EctoEvent, rows, opts)
    :ok
  end

  # Errors a row causes, and a retry of the same row never fixes. Anything
  # else — the database down, a timeout, the vault failing — is the write's
  # problem: `{:error, _}`, the batch is retried.
  defp row_error?(%Ecto.ChangeError{}), do: true
  defp row_error?(%Protocol.UndefinedError{protocol: Jason.Encoder}), do: true
  defp row_error?(%Jason.EncodeError{}), do: true
  # Postgres classes 22 (data exception) and 23 (integrity constraint).
  defp row_error?(%Postgrex.Error{postgres: %{pg_code: "22" <> _}}), do: true
  defp row_error?(%Postgrex.Error{postgres: %{pg_code: "23" <> _}}), do: true
  defp row_error?(_error), do: false

  defp rejected(:invalid_event) do
    emit_rejected(:invalid_event, nil)
    []
  end

  defp rejected(:invalid_row, error) do
    emit_rejected(:invalid_row, error.__struct__)
    :ok
  end

  defp emit_rejected(reason, error) do
    :telemetry.execute([:ocsf_ecto, :sink, :rejected], %{count: 1}, %{
      sink: __MODULE__,
      reason: reason,
      error: error
    })
  end

  defp result_tag(:ok), do: :ok
  defp result_tag({:error, _}), do: :error

  @doc """
  Projects an `%OCSF.Event{}` to the raw row map inserted by `write/1`.

  Applies the sink's policy, encrypts PII via Cloak, and returns
  the keyword-indexed map passed to `Ecto.Repo.insert_all/3`.
  Exposed for diagnostic and test use — prefer `write/1` in
  application code.

  Values OCSF allows but the columns can't take as is are coerced:
  `time` is padded to microsecond precision; an IP given as a string
  is parsed, and dropped when it doesn't parse (the event is kept).

  ## Examples

      {:ok, event} =
        OCSF.Events.Authentication.logon(user: %{uid: "u1"}, service: %{name: "auth"})
      row = OCSF.Ecto.Sink.row_for(event)
      row.class_uid
      #=> 3002
      row.metadata__uid == event.metadata.uid
      #=> true
  """
  @impl true
  @spec row_for(OCSF.Event.t()) :: map
  def row_for(%OCSF.Event{} = event), do: project(event, policy())

  defp project(event, policy) do
    redacted = OCSF.Policy.apply(policy, event)
    now = DateTime.utc_now()

    # Serialized (label-rich, OCSF-shaped) view of the redacted event —
    # source for the completeness `jsonb` columns so the row round-trips.
    serialized = OCSF.to_map(redacted)

    %{
      id: redacted.metadata.uid,
      time: redacted.time,
      metadata__uid: redacted.metadata.uid,
      metadata__version: redacted.metadata.version,
      metadata__product__name: get_in_safe(redacted, [:metadata, :product, :name]),
      metadata__correlation_uid: redacted.metadata.correlation_uid,
      metadata__trace_uid: redacted.metadata.trace_uid,
      metadata__span_uid: redacted.metadata.span_uid,
      metadata__event_code: redacted.metadata.event_code,
      category_uid: redacted.category_uid,
      class_uid: redacted.class_uid,
      type_uid: redacted.type_uid,
      activity_id: redacted.activity_id,
      severity_id: redacted.severity_id,
      status_id: redacted.status_id,
      status_detail: redacted.status_detail,
      auth_protocol_id: redacted.auth_protocol_id,
      user__uid: get_in_safe(redacted, [:user, :uid]),
      user__name: get_in_safe(redacted, [:user, :name]),
      user__email_addr: get_in_safe(redacted, [:user, :email_addr]),
      user__org__uid: get_in_safe(redacted, [:user, :org, :uid]),
      http_request__url: get_in_safe(redacted, [:http_request, :url]),
      http_request__user_agent: get_in_safe(redacted, [:http_request, :user_agent]),
      http_request__http_method: get_in_safe(redacted, [:http_request, :http_method]),
      src_endpoint__ip: get_in_safe(redacted, [:src_endpoint, :ip]),
      dst_endpoint__ip: get_in_safe(redacted, [:dst_endpoint, :ip]),
      dst_endpoint__hostname: get_in_safe(redacted, [:dst_endpoint, :hostname]),
      service__name: get_in_safe(redacted, [:service, :name]),
      # completeness columns (v2) — non-PII sub-objects and lists, taken
      # from the serialized view so they store OCSF-shaped jsonb.
      iam_role: serialized[:iam_role],
      updated_role: serialized[:updated_role],
      group: serialized[:group],
      api: serialized[:api],
      groups: serialized[:groups],
      iam_roles: serialized[:iam_roles],
      privileges: serialized[:privileges],
      resources: serialized[:resources],
      metadata__profiles: get_in(serialized, [:metadata, :profiles]),
      # PII sub-objects — encrypted at rest via EncryptedMap.
      actor: serialized[:actor],
      updated_user: serialized[:updated_user],
      entity: serialized[:entity],
      raw_data: redacted.raw_data,
      unmapped: redacted.unmapped || %{},
      inserted_at: now
    }
    |> normalize()
  end

  # Values OCSF allows but the columns can't take as is: coerced here, so
  # they don't fail the row.
  #
  #   * `time` — `:utc_datetime_usec` requires a microsecond precision;
  #   * IPs — `inet` columns take a tuple: a string is parsed, and one that
  #     does not parse is dropped (the event is kept).
  defp normalize(row) do
    row
    |> Map.update!(:time, &usec/1)
    |> Map.update!(:src_endpoint__ip, &ip/1)
    |> Map.update!(:dst_endpoint__ip, &ip/1)
  end

  defp usec(%DateTime{microsecond: {us, _precision}} = time), do: %{time | microsecond: {us, 6}}
  defp usec(time), do: time

  defp ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, address} -> address
      {:error, _reason} -> nil
    end
  end

  defp ip(ip), do: ip

  @doc """
  Returns the `OCSF.Policy` applied to every write.

  Resolved from `Application.get_env(:ocsf_ecto, OCSF.Ecto.Sink)`
  at call time. Falls back to a deny-`:network`, allow-PII default
  when no config is provided.

  ## Examples

      %OCSF.Policy{} = OCSF.Ecto.Sink.policy()
  """
  @impl true
  @spec policy() :: OCSF.Policy.t()
  def policy do
    config = Application.get_env(:ocsf_ecto, __MODULE__, [])
    Keyword.get(config, :policy, @default_policy)
  end

  @doc """
  Probes the underlying Repo and returns a sink health signal.

  Issues a `SELECT 1` against Postgres. Returns `:ok` when the
  query succeeds, or `{:down, reason}` when the Repo is unavailable
  or raises.

  ## Examples

      :ok = OCSF.Ecto.Sink.health()
  """
  @impl true
  @spec health() :: OCSF.Sink.health()
  def health do
    case repo().query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, reason} -> {:down, reason}
    end
  rescue
    error -> {:down, error}
  end

  @doc """
  Returns the `Ecto.Repo` module the sink writes through.

  Resolved from `config :ocsf_ecto, :repo` at call time, so host
  apps can point the sink at their own Repo without touching the
  library. Defaults to `OCSF.Ecto.Repo`.

  ## Examples

      OCSF.Ecto.Sink.repo()
      #=> OCSF.Ecto.Repo
  """
  @spec repo() :: module
  def repo, do: Application.get_env(:ocsf_ecto, :repo, @default_repo)

  defp get_in_safe(nil, _path), do: nil

  defp get_in_safe(data, [key]) do
    case data do
      %{} -> Map.get(data, key)
      _ -> nil
    end
  end

  defp get_in_safe(data, [key | rest]) do
    case data do
      %{} ->
        data
        |> Map.get(key)
        |> get_in_safe(rest)

      _ ->
        nil
    end
  end
end
