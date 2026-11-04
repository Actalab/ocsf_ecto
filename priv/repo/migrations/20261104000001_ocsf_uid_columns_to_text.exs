defmodule OCSF.Ecto.Repo.Migrations.OcsfUidColumnsToText do
  # Library self-test migration for schema v3 (`user__uid` and
  # `metadata__correlation_uid` as text). Consumer apps write their own
  # one-liner that delegates to OCSF.Ecto.Migration.up(version: 3).
  use Ecto.Migration

  def up, do: OCSF.Ecto.Migration.up(version: 3)
  def down, do: OCSF.Ecto.Migration.down(version: 3)
end
