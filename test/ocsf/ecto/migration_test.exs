defmodule OCSF.Ecto.MigrationTest do
  use ExUnit.Case, async: true

  alias OCSF.Ecto.Migration

  doctest OCSF.Ecto.Migration

  describe "current_version/0" do
    test "returns a positive integer" do
      assert Migration.current_version() >= 1
    end

    test "matches the length of versions/0" do
      assert Migration.current_version() == length(Migration.versions())
    end
  end

  describe "versions/0" do
    test "returns a dense list starting at 1" do
      versions = Migration.versions()

      assert List.first(versions) == 1
      assert versions == Enum.to_list(1..Migration.current_version())
    end
  end

  describe "up/1 argument validation" do
    test "raises on a non-integer version" do
      assert_raise ArgumentError, ~r/invalid :version/, fn ->
        Migration.up(version: :latest)
      end
    end

    test "raises on version 0" do
      assert_raise ArgumentError, ~r/invalid :version/, fn ->
        Migration.up(version: 0)
      end
    end

    test "raises on a version above current" do
      too_high = Migration.current_version() + 1

      assert_raise ArgumentError, ~r/invalid :version/, fn ->
        Migration.up(version: too_high)
      end
    end

    test "raises when :prefix is overridden" do
      assert_raise ArgumentError, ~r/not supported yet/, fn ->
        Migration.up(prefix: "custom__")
      end
    end

    test "raises when :table is overridden" do
      assert_raise ArgumentError, ~r/not supported yet/, fn ->
        Migration.up(table: "events")
      end
    end

    test "raises when :schema is provided" do
      assert_raise ArgumentError, ~r/not supported yet/, fn ->
        Migration.up(schema: "analytics")
      end
    end
  end

  describe "down/1 argument validation" do
    test "raises on an unknown version" do
      assert_raise ArgumentError, ~r/invalid :version/, fn ->
        Migration.down(version: 99)
      end
    end

    test "raises on override options" do
      assert_raise ArgumentError, ~r/not supported yet/, fn ->
        Migration.down(table: "events")
      end
    end
  end

  # resolve!/1 is the seam between opts validation and the final
  # apply/3 glue. Covering it directly exercises resolve_version/1,
  # version_module!/1, and resolve_opts!/1 without needing an
  # Ecto.Migrator context (the happy-path apply/3 lands as a no-op
  # glue line, validated end-to-end by `mix ecto.migrate`).
  describe "resolve!/1" do
    test "returns {V_current, resolved_opts} for defaults" do
      assert {OCSF.Ecto.Migration.V3, opts} = Migration.resolve!([])
      assert opts == %{prefix: "ocsf_event__", table: "logs", schema: nil}
    end

    test "returns the pinned version's module" do
      assert {OCSF.Ecto.Migration.V1, _} = Migration.resolve!(version: 1)
      assert {OCSF.Ecto.Migration.V2, _} = Migration.resolve!(version: 2)
      assert {OCSF.Ecto.Migration.V3, _} = Migration.resolve!(version: 3)
    end

    test "raises on invalid :version" do
      assert_raise ArgumentError, ~r/invalid :version/, fn ->
        Migration.resolve!(version: 0)
      end
    end

    test "raises on override options" do
      assert_raise ArgumentError, ~r/not supported yet/, fn ->
        Migration.resolve!(prefix: "custom__")
      end
    end
  end
end
