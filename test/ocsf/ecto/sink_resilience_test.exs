defmodule OCSF.Ecto.SinkResilienceTest do
  # async: false — opens the :network class through the global sink policy.
  use OCSF.Ecto.DataCase, async: false

  alias OCSF.Ecto.Event, as: EctoEvent
  alias OCSF.Ecto.{Sink, TelemetryRelay}
  alias OCSF.Events.Authentication

  @rejected [:ocsf_ecto, :sink, :rejected]

  setup do
    original = Application.get_env(:ocsf_ecto, Sink)

    Application.put_env(:ocsf_ecto, Sink,
      policy: %OCSF.Policy{
        allow: [:identifier, :tenant, :taxonomic, :temporal, :contact, :identity, :network],
        deny: [],
        transform: []
      }
    )

    TelemetryRelay.attach(@rejected, self())

    on_exit(fn ->
      TelemetryRelay.detach(@rejected, self())
      restore(original)
    end)
  end

  defp restore(nil), do: Application.delete_env(:ocsf_ecto, Sink)
  defp restore(config), do: Application.put_env(:ocsf_ecto, Sink, config)

  defp build_event do
    {:ok, event} =
      Authentication.logon(
        user: %{uid: Ecto.UUID.generate(), email_addr: "jane@example.com", org: %{uid: "acme"}},
        src_endpoint: %{ip: {10, 0, 0, 1}},
        service: %{name: "Auth"},
        status: :Success,
        severity: :Informational
      )

    event
  end

  defp stored(event), do: Repo.get(EctoEvent, event.metadata.uid)

  describe "values the sink normalises instead of failing the batch" do
    test "a time without microsecond precision" do
      event = %{build_event() | time: DateTime.truncate(DateTime.utc_now(), :second)}

      assert :ok = Sink.write([event])
      assert %EctoEvent{time: %DateTime{microsecond: {_, 6}}} = stored(event)
    end

    test "a source IP given as a string" do
      event = put_in(build_event().src_endpoint.ip, "192.0.2.7")

      assert :ok = Sink.write([event])
      assert stored(event).src_endpoint__ip == {192, 0, 2, 7}
    end

    test "a source IP that does not parse is dropped, the event kept" do
      event = put_in(build_event().src_endpoint.ip, "not-an-ip")

      assert :ok = Sink.write([event])
      assert %EctoEvent{src_endpoint__ip: nil} = stored(event)
    end

    test "a user uid that is not a UUID is stored as is" do
      event = put_in(build_event().user.uid, "cryptr|42")

      assert :ok = Sink.write([event])
      assert %EctoEvent{user__uid: "cryptr|42"} = stored(event)
    end

    test "a correlation uid that is not a UUID is stored as is" do
      event = put_in(build_event().metadata.correlation_uid, "corr-123")

      assert :ok = Sink.write([event])
      assert %EctoEvent{metadata__correlation_uid: "corr-123"} = stored(event)
    end
  end

  defp with_repo(repo) do
    original = Application.fetch_env(:ocsf_ecto, :repo)
    Application.put_env(:ocsf_ecto, :repo, repo)

    on_exit(fn ->
      case original do
        {:ok, repo} -> Application.put_env(:ocsf_ecto, :repo, repo)
        :error -> Application.delete_env(:ocsf_ecto, :repo)
      end
    end)
  end

  describe "an event that can never be stored" do
    test "is dropped with telemetry, the rest of the batch written" do
      good = [build_event(), build_event()]
      bad = put_in(build_event().metadata.uid, "not-a-uuid")

      assert :ok = Sink.write([hd(good), bad | tl(good)])

      assert Enum.all?(good, &stored/1)
      assert Repo.aggregate(EctoEvent, :count) == 2

      assert_receive {:telemetry, @rejected, %{count: 1},
                      %{sink: Sink, reason: :invalid_row, error: Ecto.ChangeError}}

      refute_received {:telemetry, @rejected, _, _}
    end

    test "a term that is not an event" do
      assert :ok = Sink.write([%{not_an_event: true}, build_event()])
      assert Repo.aggregate(EctoEvent, :count) == 1
      assert_receive {:telemetry, @rejected, %{count: 1}, %{reason: :invalid_event, error: nil}}
    end

    test "an event its row cannot be built from" do
      assert :ok = Sink.write([%{build_event() | metadata: nil}, build_event()])
      assert Repo.aggregate(EctoEvent, :count) == 1
      assert_receive {:telemetry, @rejected, %{count: 1}, %{reason: :invalid_event}}
    end

    test "a field its column type cannot take" do
      bad = %{build_event() | raw_data: %{"not" => "a string"}}

      assert :ok = Sink.write([bad])
      assert stored(bad) == nil
      assert_receive {:telemetry, @rejected, %{count: 1}, %{error: Ecto.ChangeError}}
    end

    test "a NOT NULL column Postgres refuses" do
      good = build_event()
      bad = %{build_event() | time: nil}

      assert :ok = Sink.write([bad, good])
      assert stored(good)
      assert Repo.aggregate(EctoEvent, :count) == 1
      assert_receive {:telemetry, @rejected, %{count: 1}, %{error: Postgrex.Error}}
    end

    test "an unmapped term JSON cannot encode" do
      good = build_event()
      bad = %{build_event() | unmapped: %{"pid" => self()}}

      assert :ok = Sink.write([good, bad])
      assert stored(good)
      assert stored(bad) == nil
      assert_receive {:telemetry, @rejected, %{count: 1}, %{error: Protocol.UndefinedError}}
    end

    test "an unmapped string that is not valid UTF-8" do
      bad = %{build_event() | unmapped: %{"bytes" => <<0xFF>>}}

      assert :ok = Sink.write([bad])
      assert stored(bad) == nil
      assert_receive {:telemetry, @rejected, %{count: 1}, %{error: Jason.EncodeError}}
    end

    test "a NUL character jsonb cannot hold" do
      # Valid JSON, refused by Postgres itself (data exception, class 22).
      bad = %{build_event() | unmapped: %{"nul" => "a\u0000b"}}

      assert :ok = Sink.write([bad])
      assert stored(bad) == nil
      assert_receive {:telemetry, @rejected, %{count: 1}, %{error: Postgrex.Error}}
    end

    test "a batch with no event at all writes nothing" do
      assert :ok = Sink.write([:not_an_event])
      assert Repo.aggregate(EctoEvent, :count) == 0
      assert_receive {:telemetry, @rejected, %{count: 1}, %{reason: :invalid_event}}
    end

    test "inside the caller's transaction, which stays usable" do
      good = build_event()
      bad = %{build_event() | time: nil}

      assert {:ok, 1} =
               Repo.transaction(fn ->
                 :ok = Sink.write([bad, good])
                 Repo.aggregate(EctoEvent, :count)
               end)
    end

    test "a whole batch of them writes nothing and still answers :ok" do
      bad = put_in(build_event().metadata.uid, "nope")

      assert :ok = Sink.write([bad])
      assert Repo.aggregate(EctoEvent, :count) == 0
    end
  end

  describe "a failure of the write itself fails the batch, to be retried" do
    # Not a row problem: nothing is rejected, the caller sees the error.
    test "the database is down" do
      with_repo(OCSF.Ecto.DownRepo)

      assert {:error, %DBConnection.ConnectionError{}} = Sink.write([build_event()])
      refute_received {:telemetry, @rejected, _, _}
    end

    test "the database goes down while rows are retried one at a time" do
      with_repo(OCSF.Ecto.DropsMidBatchRepo)

      assert {:error, %DBConnection.ConnectionError{}} =
               Sink.write([build_event(), build_event()])

      refute_received {:telemetry, @rejected, _, _}
    end

    test "the configured repo is not loaded" do
      with_repo(OCSF.Ecto.NotLoadedRepo)

      assert {:error, %UndefinedFunctionError{}} = Sink.write([build_event()])
      refute_received {:telemetry, @rejected, _, _}
    end
  end
end
