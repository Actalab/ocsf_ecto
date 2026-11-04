defmodule OCSF.Ecto.Event do
  @moduledoc """
  Ecto schema for the `ocsf_event__logs` Postgres table.

  Flat projection of a canonical `%OCSF.Event{}` using the `__`
  segment separator (SPEC §6): nested paths like `metadata.product.name`
  become single columns (`metadata__product__name`). Corresponds to
  the OCSF
  [Base Event](https://schema.ocsf.io/1.9.0/classes/base_event) and
  the objects it embeds (`metadata`, `user`, `http_request`,
  `src_endpoint`, `dst_endpoint`, `service`).

  Writes are performed by `OCSF.Ecto.Sink.write/1` via
  `Ecto.Repo.insert_all/3`. Reads back to canonical OCSF JSON via
  `to_ocsf_map/1` (and the `Jason.Encoder` implementation built on it),
  which reconstructs the nested event from the flat columns.

  ## Primary key

  `:id` is a `:binary_id` seeded from the event's `metadata.uid` so
  the OCSF event UID IS the row UID. This enables
  `on_conflict: :nothing, conflict_target: :id` idempotent replays
  in the sink.

  ## Encrypted columns

  The following columns are encrypted at rest via Cloak:

  - `user__name`, `user__email_addr` — `OCSF.Ecto.Types.EncryptedString`
  - `actor`, `updated_user`, `entity` — `OCSF.Ecto.Types.EncryptedMap`
    (PII-bearing sub-objects, stored as encrypted JSON)

  ## Custom types

  - `OCSF.Ecto.Types.Inet` on `src_endpoint__ip`, `dst_endpoint__ip`
  - `OCSF.Ecto.Types.EncryptedString` on encrypted PII columns

  See `OCSF.Ecto.Sink` for the write path and `OCSF.Event` for the
  canonical nested struct shape.
  """

  use Ecto.Schema

  alias OCSF.Ecto.Types.{EncryptedMap, EncryptedString, Json}

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "ocsf_event__logs" do
    field :time, :utc_datetime_usec

    # metadata
    field :metadata__uid, :binary_id
    field :metadata__version, :string
    field :metadata__product__name, :string
    field :metadata__correlation_uid, :string
    field :metadata__trace_uid, :string
    field :metadata__span_uid, :string
    field :metadata__event_code, :string

    # classification
    field :category_uid, :integer
    field :class_uid, :integer
    field :type_uid, :integer
    field :activity_id, :integer
    field :severity_id, :integer
    field :status_id, :integer
    field :status_detail, :string
    field :auth_protocol_id, :integer

    # user (PII encrypted)
    field :user__uid, :string
    field :user__name, EncryptedString
    field :user__email_addr, EncryptedString
    field :user__org__uid, :string

    # http
    field :http_request__url, :string
    field :http_request__user_agent, :string
    field :http_request__http_method, :string

    # network (only when policy allows)
    field :src_endpoint__ip, OCSF.Ecto.Types.Inet
    field :dst_endpoint__ip, OCSF.Ecto.Types.Inet
    field :dst_endpoint__hostname, :string

    # service
    field :service__name, :string

    # completeness — non-PII sub-objects (v2, jsonb)
    field :iam_role, Json
    field :updated_role, Json
    field :group, Json
    field :api, Json

    # completeness — list-valued fields (v2, jsonb)
    field :groups, Json
    field :iam_roles, Json
    field :privileges, Json
    field :resources, Json
    field :metadata__profiles, Json

    # completeness — PII sub-objects (v2, Cloak-encrypted jsonb)
    field :actor, EncryptedMap
    field :updated_user, EncryptedMap
    field :entity, EncryptedMap

    # raw payload (v2)
    field :raw_data, :string

    # extension
    field :unmapped, :map, default: %{}

    timestamps(updated_at: false, inserted_at: :inserted_at, type: :utc_datetime_usec)
  end

  # Columns that are storage-only, not part of the OCSF event body.
  @non_ocsf_columns [:id, :inserted_at]

  # Inet columns are loaded as Erlang IP tuples; format them to their
  # string form so the reconstructed map matches OCSF serializer output.
  @ip_columns [:src_endpoint__ip, :dst_endpoint__ip]

  @doc """
  Reconstruct the canonical nested OCSF event map from a stored row.

  Un-flattens the `__`-joined columns (and splices the `jsonb`
  sub-object / list columns at their nested path), then re-derives the
  OCSF label fields (`class_name`, `severity`, …) by round-tripping
  through `OCSF.Deserializer.from_map/1` and `OCSF.to_map/1`. The result
  is schema-conformant OCSF 1.9 JSON.

  If the stored row cannot be deserialized into a valid `%OCSF.Event{}`
  (e.g. a class whose required field was not persisted), it falls back
  to the structurally-reconstructed map — still valid JSON, without the
  re-derived labels.

  PII sub-objects (`actor`, `updated_user`, `entity`) are decrypted from
  their `EncryptedMap` columns and spliced back in transparently.
  """
  @spec to_ocsf_map(t()) :: map
  def to_ocsf_map(%__MODULE__{} = row) do
    nested =
      row
      |> Map.from_struct()
      |> Map.drop([:__meta__ | @non_ocsf_columns])
      |> Enum.reduce(%{}, fn {field, value}, acc ->
        case normalize(field, value) do
          nil -> acc
          normalized -> Map.put(acc, Atom.to_string(field), normalized)
        end
      end)
      |> OCSF.Flatten.unflatten()

    case OCSF.Deserializer.from_map(nested) do
      {:ok, event} -> OCSF.to_map(event)
      {:error, _reason} -> nested
    end
  end

  defp normalize(field, ip) when field in @ip_columns and is_tuple(ip), do: format_ip(ip)

  defp normalize(_field, value) when value == %{}, do: nil
  defp normalize(_field, value), do: value

  defp format_ip(tuple) do
    case :inet.ntoa(tuple) do
      {:error, _} -> nil
      chars -> to_string(chars)
    end
  end
end
