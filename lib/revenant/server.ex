defmodule Revenant.Server do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias Revenant.State

  defstruct ~w(module id repo vsn durability idle_timeout user_state version dirty)a

  def start_link(module, id) do
    id = to_string(id)
    GenServer.start_link(__MODULE__, {module, id}, name: via(module, id))
  end

  defp via(module, id), do: {:via, Registry, {Revenant.Registry, {module, id}}}

  @impl GenServer
  def init({module, id}) do
    Process.flag(:trap_exit, true)
    config = module.__revenant__()

    server = %__MODULE__{
      module: module,
      id: id,
      repo: config.repo,
      vsn: config.vsn,
      durability: config.durability,
      idle_timeout: config.idle_timeout,
      dirty: false
    }

    {user_state, version} = load(server)
    {:ok, %{server | user_state: user_state, version: version}, server.idle_timeout}
  end

  @impl GenServer
  def handle_call({:"$revenant", message, opts}, from, server) do
    case server.module.handle_call(message, from, server.user_state) do
      {:reply, reply, new_user_state} ->
        server = commit(server, new_user_state, opts)
        {:reply, reply, server, server.idle_timeout}

      {:stop, reason, reply, new_user_state} ->
        {:stop, reason, reply, commit(server, new_user_state, durability: :strict)}

      other ->
        raise ArgumentError,
              "expected #{inspect(server.module)}.handle_call/3 to return " <>
                "{:reply, reply, state} or {:stop, reason, reply, state}, " <>
                "got: #{inspect(other)}"
    end
  end

  @impl GenServer
  def handle_cast({:"$revenant", message}, server) do
    server.module
    |> apply(:handle_cast, [message, server.user_state])
    |> handle_noreply_result(server)
  end

  @impl GenServer
  def handle_info(:"$revenant_flush", server) do
    {:noreply, if(server.dirty, do: flush(server), else: server), server.idle_timeout}
  end

  def handle_info(:timeout, %{idle_timeout: idle_timeout} = server)
      when idle_timeout != :infinity do
    {:stop, :normal, server}
  end

  def handle_info(message, server) do
    server.module
    |> apply(:handle_info, [message, server.user_state])
    |> handle_noreply_result(server)
  end

  @impl GenServer
  def terminate(reason, server) do
    server = if server.dirty, do: flush(server), else: server
    server.module.terminate(reason, server.user_state)
  end

  defp handle_noreply_result(result, server) do
    case result do
      {:noreply, new_user_state} ->
        server = commit(server, new_user_state, [])
        {:noreply, server, server.idle_timeout}

      {:stop, reason, new_user_state} ->
        {:stop, reason, commit(server, new_user_state, [])}

      other ->
        raise ArgumentError,
              "expected #{inspect(server.module)} callback to return " <>
                "{:noreply, state} or {:stop, reason, state}, got: #{inspect(other)}"
    end
  end

  defp commit(%{user_state: unchanged} = server, unchanged, _opts), do: server

  defp commit(server, new_user_state, opts) do
    if Application.get_env(:revenant, :validate_state, false) do
      assert_persistable!(new_user_state)
    end

    server = %{server | user_state: new_user_state}

    case escalate(server.durability, opts) do
      :strict -> flush(server)
      {:interval, milliseconds} -> mark_dirty(server, milliseconds)
      :on_stop -> %{server | dirty: true}
    end
  end

  defp escalate(durability, opts) do
    if Keyword.get(opts, :durability) == :strict, do: :strict, else: durability
  end

  defp mark_dirty(%{dirty: true} = server, _milliseconds), do: server

  defp mark_dirty(server, milliseconds) do
    Process.send_after(self(), :"$revenant_flush", milliseconds)
    %{server | dirty: true}
  end

  defp flush(server) do
    blob = :erlang.term_to_binary({server.vsn, server.user_state})

    row_count =
      if server.version == 0, do: insert_row(server, blob), else: update_row(server, blob)

    case row_count do
      1 ->
        :telemetry.execute([:revenant, :flush], %{bytes: byte_size(blob)}, %{
          module: server.module,
          id: server.id,
          version: server.version + 1
        })

        %{server | version: server.version + 1, dirty: false}

      0 ->
        :telemetry.execute([:revenant, :conflict], %{system_time: System.system_time()}, %{
          module: server.module,
          id: server.id,
          version: server.version
        })

        exit({:revenant_conflict, {server.module, server.id}})
    end
  end

  defp insert_row(server, blob) do
    {row_count, _} =
      server.repo.insert_all(
        State,
        [
          %{
            module: inspect(server.module),
            id: server.id,
            state: blob,
            version: 1,
            updated_at: DateTime.utc_now()
          }
        ],
        on_conflict: :nothing
      )

    row_count
  end

  defp update_row(server, blob) do
    {row_count, _} =
      State
      |> where(module: ^inspect(server.module), id: ^server.id, version: ^server.version)
      |> server.repo.update_all(
        set: [state: blob, version: server.version + 1, updated_at: DateTime.utc_now()]
      )

    row_count
  end

  defp load(server) do
    case server.repo.get_by(State, module: inspect(server.module), id: server.id) do
      nil ->
        {server.module.initial_state(server.id), 0}

      row ->
        # No :safe - the blob is our own trusted write, and :safe would make
        # snapshots referencing since-deleted atoms undecodable before
        # upgrade/2 ever gets a chance to migrate them.
        {stored_vsn, user_state} = :erlang.binary_to_term(row.state)

        user_state =
          if stored_vsn == server.vsn do
            user_state
          else
            server.module.upgrade(stored_vsn, user_state)
          end

        :telemetry.execute([:revenant, :load], %{system_time: System.system_time()}, %{
          module: server.module,
          id: server.id,
          version: row.version
        })

        {user_state, row.version}
    end
  end

  defp assert_persistable!(term) when is_pid(term) or is_reference(term) or is_port(term) do
    raise ArgumentError, "runtime handle in durable state: #{inspect(term)}"
  end

  defp assert_persistable!(term) when is_function(term) do
    case Function.info(term, :type) do
      {:type, :external} -> :ok
      _ -> raise ArgumentError, "anonymous function in durable state: #{inspect(term)}"
    end
  end

  defp assert_persistable!(term) when is_list(term) do
    for element <- term, do: assert_persistable!(element)
    :ok
  end

  defp assert_persistable!(term) when is_tuple(term) do
    for element <- Tuple.to_list(term), do: assert_persistable!(element)
    :ok
  end

  defp assert_persistable!(term) when is_map(term) do
    for {key, value} <- Map.to_list(term) do
      assert_persistable!(key)
      assert_persistable!(value)
    end

    :ok
  end

  defp assert_persistable!(_term), do: :ok
end
