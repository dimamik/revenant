defmodule RevenantTest do
  use ExUnit.Case, async: false

  alias Revenant.IntervalCounter
  alias Revenant.OnStopCounter
  alias Revenant.SleepyCounter
  alias Revenant.State
  alias Revenant.StrictCounter
  alias Revenant.TestRepo
  alias Revenant.UpgradedCounter

  setup do
    TestRepo.query!("truncate revenant_states")
    :ok
  end

  defp unique_id, do: "entity_#{System.unique_integer([:positive])}"

  defp row(module, id), do: TestRepo.get_by(State, module: inspect(module), id: id)

  defp decode(row), do: :erlang.binary_to_term(row.state)

  describe "lifecycle" do
    test "starts lazily on first call with initial_state/1" do
      id = unique_id()

      assert Revenant.whereis({StrictCounter, id}) == nil
      assert Revenant.call({StrictCounter, id}, :get) == 0
      assert is_pid(Revenant.whereis({StrictCounter, id}))
    end

    test "a read-only call writes nothing" do
      id = unique_id()

      assert Revenant.call({StrictCounter, id}, :get) == 0
      assert row(StrictCounter, id) == nil
    end

    test "state survives a graceful stop" do
      id = unique_id()

      assert Revenant.call({StrictCounter, id}, :increment) == 1
      :ok = Revenant.stop({StrictCounter, id})
      assert Revenant.whereis({StrictCounter, id}) == nil

      assert Revenant.call({StrictCounter, id}, :get) == 1
    end

    test "state survives a brutal kill" do
      id = unique_id()

      assert Revenant.call({StrictCounter, id}, :increment) == 1
      assert Revenant.call({StrictCounter, id}, :increment) == 2

      pid = Revenant.whereis({StrictCounter, id})
      reference = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^reference, :process, ^pid, :killed}

      assert Revenant.call({StrictCounter, id}, :get) == 2
    end

    test "entities with the same id but different modules do not collide" do
      id = unique_id()

      assert Revenant.call({StrictCounter, id}, :increment) == 1
      assert Revenant.call({OnStopCounter, id}, :get) == 0
    end
  end

  describe "passivation" do
    test "an idle process flushes, stops, and revives on the next call" do
      id = unique_id()

      assert Revenant.call({SleepyCounter, id}, :increment) == 1
      pid = Revenant.whereis({SleepyCounter, id})
      reference = Process.monitor(pid)

      assert_receive {:DOWN, ^reference, :process, ^pid, :normal}, 500
      assert Revenant.whereis({SleepyCounter, id}) == nil

      assert Revenant.call({SleepyCounter, id}, :get) == 1
      assert Revenant.whereis({SleepyCounter, id}) != pid
    end
  end

  describe "delete" do
    test "removes committed state so the entity starts fresh" do
      id = unique_id()

      assert Revenant.call({StrictCounter, id}, :increment) == 1
      assert :ok = Revenant.delete({StrictCounter, id})

      assert Revenant.whereis({StrictCounter, id}) == nil
      assert row(StrictCounter, id) == nil
      assert Revenant.call({StrictCounter, id}, :get) == 0
    end

    test "is a no-op for an entity that never existed" do
      assert :ok = Revenant.delete({StrictCounter, unique_id()})
    end
  end

  describe "telemetry" do
    test "a flush emits [:revenant, :flush]" do
      id = unique_id()
      test_pid = self()

      :telemetry.attach(
        "flush-#{id}",
        [:revenant, :flush],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:flush, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("flush-#{id}") end)

      assert Revenant.call({StrictCounter, id}, :increment) == 1

      assert_receive {:flush, %{bytes: bytes}, %{module: StrictCounter, id: ^id, version: 1}}

      assert bytes > 0
    end

    test "a revival emits [:revenant, :load]" do
      id = unique_id()
      test_pid = self()

      :telemetry.attach(
        "load-#{id}",
        [:revenant, :load],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:load, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("load-#{id}") end)

      assert Revenant.call({StrictCounter, id}, :increment) == 1
      :ok = Revenant.stop({StrictCounter, id})
      refute_received {:load, _}

      assert Revenant.call({StrictCounter, id}, :get) == 1
      assert_receive {:load, %{module: StrictCounter, id: ^id, version: 1}}
    end
  end

  describe "strict durability" do
    test "the row is committed before the reply" do
      id = unique_id()

      assert Revenant.call({StrictCounter, id}, :increment) == 1

      persisted = row(StrictCounter, id)
      assert persisted.version == 1
      assert decode(persisted) == {1, %{count: 1}}
    end

    test "every mutation bumps the version" do
      id = unique_id()

      for _ <- 1..3, do: Revenant.call({StrictCounter, id}, :increment)

      assert row(StrictCounter, id).version == 3
    end

    test "casts ride the same commit path" do
      id = unique_id()

      Revenant.cast({StrictCounter, id}, :increment)
      assert Revenant.call({StrictCounter, id}, :get) == 1
      assert row(StrictCounter, id).version == 1
    end

    test "handle_info mutations commit too" do
      id = unique_id()

      assert Revenant.call({StrictCounter, id}, :get) == 0
      send(Revenant.whereis({StrictCounter, id}), :increment)

      assert Revenant.call({StrictCounter, id}, :get) == 1
      assert row(StrictCounter, id).version == 1
    end
  end

  describe "interval durability" do
    test "flushes at most once per interval, coalescing mutations" do
      id = unique_id()

      for _ <- 1..3, do: Revenant.call({IntervalCounter, id}, :increment)

      assert row(IntervalCounter, id) == nil

      Process.sleep(120)

      persisted = row(IntervalCounter, id)
      assert persisted.version == 1
      assert decode(persisted) == {1, %{count: 3}}
    end

    test "a per-call :strict escalation flushes everything pending" do
      id = unique_id()

      assert Revenant.call({IntervalCounter, id}, :increment) == 1
      assert Revenant.call({IntervalCounter, id}, :increment, durability: :strict) == 2

      persisted = row(IntervalCounter, id)
      assert decode(persisted) == {1, %{count: 2}}
    end

    test "pending state flushes on graceful stop" do
      id = unique_id()

      assert Revenant.call({IntervalCounter, id}, :increment) == 1
      :ok = Revenant.stop({IntervalCounter, id})

      assert decode(row(IntervalCounter, id)) == {1, %{count: 1}}
    end
  end

  describe "on_stop durability" do
    test "writes nothing until graceful shutdown" do
      id = unique_id()

      for _ <- 1..5, do: Revenant.call({OnStopCounter, id}, :increment)
      assert row(OnStopCounter, id) == nil

      :ok = Revenant.stop({OnStopCounter, id})
      assert decode(row(OnStopCounter, id)) == {1, %{count: 5}}
    end

    test "a brutal kill loses the session, by contract" do
      id = unique_id()

      assert Revenant.call({OnStopCounter, id}, :increment) == 1

      pid = Revenant.whereis({OnStopCounter, id})
      reference = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^reference, :process, ^pid, :killed}

      assert Revenant.call({OnStopCounter, id}, :get) == 0
    end
  end

  describe "write safety" do
    @tag capture_log: true
    test "a stale process exits with a conflict instead of clobbering" do
      id = unique_id()

      assert Revenant.call({StrictCounter, id}, :increment) == 1

      TestRepo.query!("update revenant_states set version = 42 where id = $1", [id])

      assert {{:revenant_conflict, {StrictCounter, ^id}}, _} =
               catch_exit(Revenant.call({StrictCounter, id}, :increment))
    end

    @tag capture_log: true
    test "runtime handles in state are rejected when validate_state is on" do
      id = unique_id()

      assert {{%ArgumentError{message: message}, _}, _} =
               catch_exit(Revenant.call({StrictCounter, id}, :embed_pid))

      assert message =~ "runtime handle"
    end
  end

  describe "migration" do
    defmodule AddRevenant do
      use Revenant.Migration
    end

    @migration_version 20_260_703_000_000

    defp table_exists? do
      %{rows: [[exists]]} =
        TestRepo.query!(
          "select exists (select from pg_tables where tablename = 'revenant_states')"
        )

      exists
    end

    test "use Revenant.Migration creates and drops the table" do
      on_exit(fn ->
        TestRepo.query!("delete from schema_migrations where version = $1", [@migration_version])

        TestRepo.query!("""
        create table if not exists revenant_states (
          module text not null,
          id text not null,
          state bytea not null,
          version bigint not null,
          updated_at timestamptz not null,
          primary key (module, id)
        )
        """)
      end)

      TestRepo.query!("drop table revenant_states")

      assert :ok = Ecto.Migrator.up(TestRepo, @migration_version, AddRevenant, log: false)
      assert table_exists?()

      assert :ok = Ecto.Migrator.down(TestRepo, @migration_version, AddRevenant, log: false)
      refute table_exists?()
    end
  end

  describe "state evolution" do
    test "old snapshots pass through upgrade/2 on load" do
      id = unique_id()
      old_blob = :erlang.term_to_binary({1, %{count: 5}})

      TestRepo.insert_all(State, [
        %{
          module: inspect(UpgradedCounter),
          id: id,
          state: old_blob,
          version: 7,
          updated_at: DateTime.utc_now()
        }
      ])

      assert Revenant.call({UpgradedCounter, id}, :get) == %{count: 5, upgraded: true}

      assert Revenant.call({UpgradedCounter, id}, :increment) == 6
      persisted = row(UpgradedCounter, id)
      assert persisted.version == 8
      assert decode(persisted) == {2, %{count: 6, upgraded: true}}
    end
  end
end
