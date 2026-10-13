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
  `%{sink, reason, field}`) counts each event dropped because its row can
  never be stored: `reason` is `:invalid_field` (`field` names the column
  whose type refused the value) or `:invalid_event` (`field` is `nil`: the
  row could not be built at all).

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
  can't take are coerced (see `row_for/1`). A row that still can't be
  stored is checked through the adapter's dumpers before the insert,
  dropped, and counted on `[:ocsf_ecto, :sink, :rejected]`; the rest is
  written. Typical cases are a `metadata.uid` that isn't a UUID, a value
  the column type refuses, or an encryption failure. `{:error, _}` is
  left for failures of the write itself, such as the database being
  down, which are worth retrying.

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
    events
    |> Enum.flat_map(&storable_row/1)
    |> insert()
  end

  defp insert([]), do: :ok

  defp insert(rows) do
    case repo().insert_all(EctoEvent, rows, on_conflict: :nothing, conflict_target: :id) do
      {_count, _} -> :ok
    end
  rescue
    error -> {:error, error}
  end

  # One row the table can never take fails the whole `insert_all/3`, so the
  # batch with it, on every retry. Each row is first dumped through the
  # schema's column types: one that does not dump is dropped and counted on
  # `[:ocsf_ecto, :sink, :rejected]`, and the rest of the batch is written.
  defp storable_row(event) do
    row = row_for(event)

    case undumpable_field(repo().__adapter__(), row) do
      nil -> [row]
      field -> rejected(:invalid_field, field)
    end
  rescue
    _error -> rejected(:invalid_event, nil)
  end

  # Through the adapter's dumpers, as `insert_all/3` does: `:binary_id` is
  # only checked to be a UUID there.
  defp undumpable_field(adapter, row) do
    Enum.find_value(row, fn {field, value} ->
      if dumps?(adapter, EctoEvent.__schema__(:type, field), value), do: nil, else: field
    end)
  end

  defp dumps?(_adapter, _type, nil), do: true

  defp dumps?(adapter, type, value) do
    match?({:ok, _}, Ecto.Type.adapter_dump(adapter, type, value))
  rescue
    _error -> false
  end

  defp rejected(reason, field) do
    :telemetry.execute([:ocsf_ecto, :sink, :rejected], %{count: 1}, %{
      sink: __MODULE__,
      reason: reason,
      field: field
    })

    []
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
  is parsed, and dropped when it doesn't parse (the event is kept); a
  `user.uid` or `metadata.correlation_uid` that is not a UUID moves to
  `unmapped`, under its OCSF path (`"user.uid"`), instead of the
  `binary_id` column.

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
  def row_for(%OCSF.Event{} = event) do
    redacted = OCSF.Policy.apply(policy(), event)
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
  #     does not parse is dropped (the event is kept);
  #   * `user.uid` / `metadata.correlation_uid` — any string in OCSF, a
  #     `binary_id` column here: a value that is not a UUID moves to
  #     `unmapped` under its OCSF path rather than being lost.
  @uuid_columns [user__uid: "user.uid", metadata__correlation_uid: "metadata.correlation_uid"]

  defp normalize(row) do
    row
    |> Map.update!(:time, &usec/1)
    |> Map.update!(:src_endpoint__ip, &ip/1)
    |> Map.update!(:dst_endpoint__ip, &ip/1)
    |> unmap_non_uuids()
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

  defp unmap_non_uuids(row) do
    Enum.reduce(@uuid_columns, row, fn {column, path}, row ->
      case uuid(row[column]) do
        {:ok, uuid} -> %{row | column => uuid}
        :error -> %{row | column => nil, unmapped: Map.put(row.unmapped, path, row[column])}
      end
    end)
  end

  defp uuid(nil), do: {:ok, nil}
  defp uuid(value), do: Ecto.UUID.cast(value)

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
