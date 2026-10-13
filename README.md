# ocsf_ecto

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Postgres companion for the [`ocsf`](https://hex.pm/packages/ocsf)
Elixir library. Provides an `OCSF.Sink` implementation backed by
`Ecto` + `postgrex`, with [Cloak](https://hex.pm/packages/cloak_ecto)
field-level encryption for PII attributes (`:contact`, `:identity`
data classes) and policy-driven redaction applied before insert.

- **Single flat table** — `ocsf_event__logs`, with nested OCSF
  paths projected via the `__` segment separator
  (e.g. `user.email_addr` → `user__email_addr`).
- **Encryption at rest** — PII columns encrypted via AES-GCM
  through `OCSF.Ecto.Types.EncryptedString`.
- **Idempotent writes** — primary key is the event's
  `metadata.uid`, so replaying the same event is a no-op.
- **Policy-driven redaction** — denied data classes become `nil`
  columns before insert.

> **Buffered emission:** `OCSF.Ecto.Sink.write/1` is a synchronous bulk
> insert. For non-blocking, batched, back-pressured emission on a hot
> path (and per-tenant isolation), put
> [`ocsf_ingest`](https://hex.pm/packages/ocsf_ingest) in front of this
> sink — its README is the end-to-end adoption guide. Call `write/1`
> directly only for low-volume or one-off writes.

## Installation

```elixir
# mix.exs
def deps do
  [
    {:ocsf, "~> 0.2"},
    {:ocsf_ecto, "~> 0.1"}
  ]
end
```

## Configuration

The library ships with its own `OCSF.Ecto.Repo` and
`OCSF.Ecto.Vault`, which are started automatically by
`OCSF.Ecto.Application`. Two setup paths are supported:

### A. Quickstart — use the bundled Repo

Point `OCSF.Ecto.Repo` at a Postgres instance and configure the
Cloak vault. Fine for prototyping or small apps where the OCSF
table lives in its own database.

```elixir
# config/config.exs
config :ocsf_ecto, OCSF.Ecto.Repo,
  database: "my_app_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost"

config :ocsf_ecto, ecto_repos: [OCSF.Ecto.Repo]

# Cloak vault — generate a key with:
#   :crypto.strong_rand_bytes(32) |> Base.encode64()
# The production key MUST come from the environment.
config :ocsf_ecto, OCSF.Ecto.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!(System.get_env("CLOAK_KEY") || raise "CLOAK_KEY not set"),
       iv_length: 12}
  ]
```

### B. Host app — use your own Repo

Recommended for production apps that already own an `Ecto.Repo`.
The sink resolves its Repo at call time from
`config :ocsf_ecto, :repo`, so you point it at your app's Repo
without any code in the library.

**1. Stop the bundled Repo from booting.** Ecto honours this via
the Repo's init callback — no supervision-tree surgery needed:

```elixir
# config/config.exs
config :ocsf_ecto, OCSF.Ecto.Repo, start: false
```

**2. Tell the sink which Repo to use.**

```elixir
config :ocsf_ecto, repo: MyApp.Repo
```

**3. Configure the Cloak vault the same way as the Quickstart.**
The vault is independent of the Repo and must be running for
encrypted PII columns to round-trip. It's small (single GenServer)
and can stay supervised by `OCSF.Ecto.Application` — no action
needed beyond providing the cipher config.

**4. Use `OCSF.Ecto.Event` with your Repo.** The Ecto schema is
Repo-agnostic:

```elixir
import Ecto.Query

OCSF.Ecto.Event
|> where([e], e.class_uid == 3002)
|> MyApp.Repo.all()
```

That's it — `OCSF.Ecto.Sink.write/1`, `.health/0`,
`OCSF.Ecto.Migration.up/1`, and queries via `OCSF.Ecto.Event` all
flow through `MyApp.Repo` once the two config lines are set.

> **Limitation:** `:ocsf_ecto, :repo` is a single global module per
> VM — one sink, one Repo. Per-instance sinks (multiple Repos in
> the same app) are not supported in v0. Track the discussion in
> SPEC §11 if you hit that requirement.

## Schema setup

The library ships its DDL as code via `OCSF.Ecto.Migration`
(Oban-style). In your host app, generate a migration and delegate
to it — this keeps the schema versioned across OCSF upgrades
without forcing you to regenerate migration files.

```bash
mix ecto.gen.migration add_ocsf_events
```

```elixir
# priv/repo/migrations/<ts>_add_ocsf_events.exs
defmodule MyApp.Repo.Migrations.AddOcsfEvents do
  use Ecto.Migration

  def up,   do: OCSF.Ecto.Migration.up()
  def down, do: OCSF.Ecto.Migration.down()
end
```

```bash
mix ecto.migrate
```

When a new OCSF schema version lands, create a new migration file
pinning the version:

```elixir
def up,   do: OCSF.Ecto.Migration.up(version: 2)
def down, do: OCSF.Ecto.Migration.down(version: 2)
```

Full DDL contract: see SPEC §11. The module is idempotent
(`create_if_not_exists`) so re-running `up/0` is safe.

## Writing events

```elixir
# Build an event via the core lib
{:ok, event} =
  OCSF.Events.Authentication.logon(
    user: %{uid: "u1", org: %{uid: "acme"}},
    service: %{name: "My Auth"},
    status: :Success,
    severity: :Informational,
    auth_protocol: :"OAUTH 2.0"
  )

# Write via the Postgres sink (applies policy + encrypts PII)
:ok = OCSF.Ecto.Sink.write([event])

# Replays are idempotent on metadata.uid
:ok = OCSF.Ecto.Sink.write([event])
```

Batch writes use a single `insert_all/3`:

```elixir
:ok = OCSF.Ecto.Sink.write(many_events)
```

## Policy

The sink runs `OCSF.Policy.apply/2` on every event before insert.
Denied data classes become `nil` in the row; allowed classes pass
through (and PII classes are Cloak-encrypted at the column level).

Default policy:

```elixir
%OCSF.Policy{
  allow: [:identifier, :tenant, :taxonomic, :temporal, :contact, :identity],
  deny:  [:network],
  transform: []
}
```

Override per-sink via application config:

```elixir
config :ocsf_ecto, OCSF.Ecto.Sink,
  policy: %OCSF.Policy{
    allow: [:identifier, :tenant, :taxonomic, :temporal],
    deny:  [:contact, :identity, :network],
    transform: []
  }
```

## Reading events

The library focuses on the **write path**. For reads, query
`OCSF.Ecto.Event` directly via your own Repo code — Cloak columns
decrypt transparently when loaded through the schema:

```elixir
import Ecto.Query

OCSF.Ecto.Event
|> where([e], e.class_uid == 3002)
|> order_by([e], desc: e.time)
|> limit(100)
|> OCSF.Ecto.Repo.all()
```

## Health check

```elixir
case OCSF.Ecto.Sink.health() do
  :ok -> :healthy
  {:down, reason} -> {:unhealthy, reason}
end
```

## Telemetry

`OCSF.Ecto.Sink.write/1` emits `:telemetry` span events under the
`[:ocsf_ecto, :sink, :write]` prefix:

| Event                                      | Measurements                      | Metadata                                             |
|--------------------------------------------|-----------------------------------|------------------------------------------------------|
| `[:ocsf_ecto, :sink, :write, :start]`      | `:monotonic_time`, `:system_time` | `:count`, `:sink`                                    |
| `[:ocsf_ecto, :sink, :write, :stop]`       | `:duration`, `:monotonic_time`    | `:count`, `:sink`, `:result` (`:ok` \| `:error`)     |
| `[:ocsf_ecto, :sink, :write, :exception]`  | `:duration`, `:monotonic_time`    | `:count`, `:sink`, `:kind`, `:reason`, `:stacktrace` |

Metadata is intentionally event-payload-free — batch `:count` is a
coarse signal; correlate with the core `[:ocsf, :event, :new]`
stream for per-event detail.

### One bad row never fails the batch

A single row Postgres refuses would fail the whole `insert_all/3`, and
a pipeline retrying that batch would never get past it. So
`write/1`:

- **coerces** values OCSF allows but the columns can't take: `time`
  padded to microsecond precision, a string IP parsed (dropped if it
  doesn't parse), a non-UUID `user.uid` / `metadata.correlation_uid`
  moved to `unmapped` under its OCSF path;
- **drops** a row that still can't be stored (checked through the
  adapter's dumpers: a non-UUID `metadata.uid`, a value the column type
  refuses, an encryption failure), writes the rest, and counts it:

| Event                              | Measurements | Metadata                                                        |
|------------------------------------|--------------|-----------------------------------------------------------------|
| `[:ocsf_ecto, :sink, :rejected]`   | `%{count}`   | `:sink`, `:reason` (`:invalid_field` \| `:invalid_event`), `:field` |

`{:error, _}` is left for failures of the write itself (the database
is down, a timeout), which a retry can fix.

Attach a module-based handler (never an anonymous function — the
`:telemetry` library warns about performance):

```elixir
defmodule MyApp.OcsfSinkMetrics do
  def handle_event([:ocsf_ecto, :sink, :write, :stop], %{duration: d}, meta, _config) do
    :telemetry_metrics_prometheus.observe(
      {:ocsf_sink_write_duration_ms, [result: meta.result]},
      System.convert_time_unit(d, :native, :millisecond)
    )
  end
end

:telemetry.attach_many(
  "ocsf-sink-metrics",
  [[:ocsf_ecto, :sink, :write, :stop]],
  &MyApp.OcsfSinkMetrics.handle_event/4,
  nil
)
```

## Security notes

- **Key management:** `CLOAK_KEY` must be provisioned out-of-band
  in production (env var, secret manager). Never commit keys.
- **Key rotation:** follow the Cloak
  [migration guide](https://hexdocs.pm/cloak_ecto/generate_migrate_encrypted_data.html).
  Multiple ciphers can be configured with `default:` pointing at the
  current key; old ciphertext stays readable while new writes use
  the new key.
- **Raw-bytes assertion:** every encrypted column is tested with a
  raw-SQL probe that proves the plaintext is not present in the
  column (see `test/ocsf/ecto/event_test.exs`).

## Links

- [`ocsf`](https://hex.pm/packages/ocsf) — core library
- [OCSF 1.9 Schema](https://schema.ocsf.io/1.9.0/)
- [Cloak](https://hex.pm/packages/cloak_ecto) — field-level encryption
- [Ecto](https://hex.pm/packages/ecto_sql) — persistence layer

## License

Apache-2.0
