defmodule OCSF.Ecto.Migration.V3 do
  @moduledoc """
  v3 migration — `user__uid` and `metadata__correlation_uid` become
  `text`.

  OCSF types [`user.uid`](https://schema.ocsf.io/1.9.0/objects/user) and
  [`metadata.correlation_uid`](https://schema.ocsf.io/1.9.0/objects/metadata)
  as strings: host identifiers are rarely UUIDs (`"auth0|42"`, `"u1"`).
  v1 stored them as `uuid`, so any other value could not be written to
  its column. Their indexes are rebuilt by Postgres as part of the type
  change.

  `down/1` casts back to `uuid`: values that are not UUIDs become `NULL`.

  See `OCSF.Ecto.Migration` for the public entry point.
  """

  use Ecto.Migration
  @behaviour OCSF.Ecto.Migration.Version

  @table :ocsf_event__logs

  @columns [:user__uid, :metadata__correlation_uid]

  @uuid_pattern "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

  @impl true
  def up(_opts) do
    alter table(@table) do
      for column <- @columns do
        modify column, :text, from: :binary_id
      end
    end

    :ok
  end

  @impl true
  def down(_opts) do
    for column <- @columns do
      execute """
      ALTER TABLE #{@table} ALTER COLUMN #{column} TYPE uuid
        USING CASE WHEN #{column} ~ '#{@uuid_pattern}' THEN #{column}::uuid END
      """
    end

    :ok
  end
end
