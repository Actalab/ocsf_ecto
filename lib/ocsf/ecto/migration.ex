defmodule OCSF.Ecto.Migration do
  @moduledoc """
  DDL packaging for `ocsf_event__logs`, Oban-style.

  Consumers delegate to this module from a one-line migration in
  their own `priv/repo/migrations/` so the library can evolve its
  schema across OCSF versions without forcing migration file
  regeneration.

  ## Usage

      # priv/repo/migrations/20260501000001_add_ocsf_events.exs
      defmodule MyApp.Repo.Migrations.AddOcsfEvents do
        use Ecto.Migration

        def up,   do: OCSF.Ecto.Migration.up()
        def down, do: OCSF.Ecto.Migration.down()
      end

  Subsequent OCSF schema bumps land as new migration files that
  pin the version:

      def up,   do: OCSF.Ecto.Migration.up(version: 2)
      def down, do: OCSF.Ecto.Migration.down(version: 2)

  See SPEC §11.3 for the full contract and PLAN
  "Migration packaging (ocsf_ecto)" for rationale.

  ## Options

  - **`:version`** — `:current` (default) or a positive integer.
    `:current` resolves to the highest shipped version.
  - **`:prefix`** — table prefix. Defaults to `"ocsf_event__"`.
  - **`:table`**  — table base name. Defaults to `"logs"`.
  - **`:schema`** — Postgres schema prefix. Defaults to `nil`.

  > **Prefix / table / schema overrides are not wired yet.**
  > `OCSF.Ecto.Event` hardcodes `"ocsf_event__logs"`; passing
  > non-default values to `up/1` raises until the schema side
  > catches up. The option is accepted so the public API stays
  > stable across that change.

  ## Downgrade semantics

  `down(version: 1)` drops the `ocsf_event__logs` table outright —
  there is no "v0" to downgrade to. This mirrors how Ecto
  migrations are individually reversible: each version's `down/1`
  undoes its own `up/1` and nothing more.
  """

  alias OCSF.Ecto.Migration.{V1, V2, V3}

  @type opts :: [
          version: :current | pos_integer,
          prefix: String.t(),
          table: String.t(),
          schema: String.t() | nil
        ]

  @versions [V1, V2, V3]
  @current_version length(@versions)

  @default_prefix "ocsf_event__"
  @default_table "logs"

  @doc """
  Runs the `V_n` migration's `up/1`.

  ## Examples

      :ok = OCSF.Ecto.Migration.up()
      :ok = OCSF.Ecto.Migration.up(version: 1)
  """
  @spec up(opts) :: :ok
  def up(opts \\ []), do: dispatch(opts, :up)

  @doc """
  Runs the `V_n` migration's `down/1`.

  ## Examples

      :ok = OCSF.Ecto.Migration.down()
      :ok = OCSF.Ecto.Migration.down(version: 1)
  """
  @spec down(opts) :: :ok
  def down(opts \\ []), do: dispatch(opts, :down)

  @doc """
  Returns the highest shipped version.

  ## Examples

      iex> OCSF.Ecto.Migration.current_version()
      3
  """
  @spec current_version() :: pos_integer
  def current_version, do: @current_version

  @doc """
  Returns every version number the library currently ships.

  ## Examples

      iex> OCSF.Ecto.Migration.versions()
      [1, 2, 3]
  """
  @spec versions() :: [pos_integer]
  def versions, do: Enum.to_list(1..@current_version)

  @doc false
  @spec resolve!(opts) :: {module, OCSF.Ecto.Migration.Version.opts()}
  def resolve!(opts) do
    version = resolve_version(Keyword.get(opts, :version, :current))
    module = version_module!(version)
    resolved = resolve_opts!(opts)

    {module, resolved}
  end

  # -- internals --

  defp dispatch(opts, direction) do
    {module, resolved} = resolve!(opts)
    apply(module, direction, [resolved])
  end

  defp resolve_version(:current), do: @current_version

  defp resolve_version(n) when is_integer(n) and n >= 1 and n <= @current_version,
    do: n

  defp resolve_version(other) do
    raise ArgumentError,
          "invalid :version #{inspect(other)} — expected :current or an " <>
            "integer in 1..#{@current_version}"
  end

  defp version_module!(version), do: Enum.at(@versions, version - 1)

  defp resolve_opts!(opts) do
    prefix = Keyword.get(opts, :prefix, @default_prefix)
    table = Keyword.get(opts, :table, @default_table)
    schema = Keyword.get(opts, :schema, nil)

    if prefix != @default_prefix or table != @default_table or schema != nil do
      raise ArgumentError,
            "custom :prefix / :table / :schema are not supported yet — " <>
              "`OCSF.Ecto.Event` still hardcodes \"#{@default_prefix}#{@default_table}\". " <>
              "See SPEC §11.3."
    end

    %{prefix: prefix, table: table, schema: schema}
  end
end
