defmodule OCSF.Ecto.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/elixir-ocsf/ocsf_ecto"

  def project do
    [
      app: :ocsf_ecto,
      version: @version,
      elixir: "~> 1.18",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "OCSF.Ecto",
      description: "Postgres Ecto adapter for the OCSF Elixir library",
      package: package(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      test_coverage: [
        # V_n modules are DDL-only; they're exercised end-to-end by
        # `mix ecto.migrate` during the test alias, not by unit tests.
        ignore_modules: [OCSF.Ecto.Migration.V1, OCSF.Ecto.Migration.V2, OCSF.Ecto.Migration.V3]
      ]
    ]
  end

  def application do
    [
      mod: {OCSF.Ecto.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ocsf, "~> 0.2"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:cloak_ecto, "~> 1.3"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},

      # test-only
      # ocsf_ingest is used only to prove the end-to-end pipeline writes through
      # this sink (integration test). The dependency direction is one-way:
      # ocsf_ingest never depends on a sink.
      {:ocsf_ingest, "~> 0.1", only: :test},
      {:stream_data, "~> 1.0", only: [:test, :dev], runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},

      # Audit
      {:credo, "~> 1.7", only: [:test, :dev], runtime: false},
      {:blitz_credo_checks, "~> 0.1", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1", only: [:dev, :test], runtime: false},
      {:oeditus_credo, "~> 0.4", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: :dev},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      audit: [
        "credo --strict",
        "deps.audit --ignore-file .mix_audit.ignore",
        "deps.unlock --check-unused",
        "dialyzer --format github",
        "doctor --raise",
        "format --check-formatted",
        "sobelow --config --skip",
        &run_hex_audit/1
      ]
    ]
  end

  defp run_hex_audit(_), do: Mix.shell().cmd("mix hex.audit")
end
