defmodule Revenant do
  @moduledoc """
  Durable GenServers backed by Postgres. A reply is a commit receipt.

  Revenant gives you process-per-entity GenServers whose state survives
  crashes, restarts, and deploys, using only the Postgres you already run.
  The callback module looks exactly like a GenServer:

      defmodule Account do
        use Revenant, repo: MyApp.Repo

        def initial_state(_id), do: %{balance: 0}

        def handle_call({:deposit, amount}, _from, state) do
          {:reply, :ok, %{state | balance: state.balance + amount}}
        end

        def handle_call(:balance, _from, state) do
          {:reply, state.balance, state}
        end
      end

      Revenant.call({Account, "acct_42"}, {:deposit, 100})
      #=> :ok  (the new state is committed to Postgres before you see this)

  Processes start lazily on the first message and are addressed by
  `{module, entity_id}` - a stable identity, not a pid. When a process is
  down, the next call revives it from its committed state. After
  `:idle_timeout` milliseconds without a message (default 5 minutes) a
  process passivates: it flushes any pending state and stops, and the next
  message revives it. Set `idle_timeout: :infinity` to keep processes
  resident. The `:timeout` info message is reserved for passivation on any
  server with a finite idle timeout.

  ## Topology

  The registry is node-local. Run Revenant on a single node, or route each
  entity's messages to one node yourself (consistent hashing, a fronting
  queue). If two nodes load the same entity, the version column keeps the
  data safe - the stale process exits with `{:revenant_conflict, key}`
  instead of overwriting - but under relaxed durability the losing node has
  already acked writes it can no longer commit. If you cannot guarantee
  routing, use `:strict`.

  ## Durability levels

  Set per server via the `:durability` option, escalate per call:

    * `:strict` (default) - every state change is committed before the
      caller gets its reply. Anything a caller ever observed is durable.

    * `{:interval, milliseconds}` - state changes mark the server dirty and
      the latest snapshot is flushed at most once per interval, plus always
      on graceful shutdown. Replies precede the commit, so a hard crash can
      lose up to one interval of acknowledged writes.

    * `:on_stop` - state is flushed only on graceful shutdown. The loss
      window on a hard crash is the whole session.

  Any single call on a relaxed server can demand strictness:

      Revenant.call({Account, id}, {:charge, amount}, durability: :strict)

  This flushes all pending state (it is one snapshot - flushing everything
  is the same write as flushing anything) and only then replies.

  ## Guarantees and non-guarantees

  Writes are guarded by a version column, so a stale process can never
  overwrite a newer commit - it exits with `{:revenant_conflict, key}`
  instead. A handler crash before commit rolls state back to the last
  commit; a poison message cannot persist a state no caller was acked on.

  State must be serializable: no pids, references, ports, or anonymous
  functions (captures of named functions are fine). Set
  `config :revenant, validate_state: true` in dev and test to deep-check
  every mutation. Side effects are not journaled - a handler that sends an
  email and then crashes before commit will send it again on retry.

  ## Setup

  Add the states table in a migration:

      defmodule MyApp.Repo.Migrations.AddRevenant do
        use Revenant.Migration
      end

  Start the supervisor after your repo:

      children = [MyApp.Repo, Revenant.Supervisor]

  ## State evolution

  Snapshots carry a schema version, set with the `:vsn` option (default 1).
  Bump it when the shape of your state changes and implement `upgrade/2`
  to migrate old snapshots as they load:

      use Revenant, repo: MyApp.Repo, vsn: 2

      def upgrade(1, state), do: Map.put(state, :currency, :usd)

  ## Telemetry

  Revenant emits:

    * `[:revenant, :flush]` - a snapshot was committed; measurements
      `%{bytes: n}`, metadata `%{module, id, version}`
    * `[:revenant, :conflict]` - a stale process lost a version race and is
      exiting; metadata `%{module, id, version}`
    * `[:revenant, :load]` - a process revived from a committed snapshot
      (not first-ever starts); metadata `%{module, id, version}`
  """

  import Ecto.Query

  alias Revenant.State

  @callback initial_state(id :: String.t()) :: term()
  @callback handle_call(message :: term(), from :: GenServer.from(), state :: term()) ::
              {:reply, term(), term()} | {:stop, term(), term(), term()}
  @callback handle_cast(message :: term(), state :: term()) ::
              {:noreply, term()} | {:stop, term(), term()}
  @callback handle_info(message :: term(), state :: term()) ::
              {:noreply, term()} | {:stop, term(), term()}
  @callback upgrade(old_vsn :: pos_integer(), state :: term()) :: term()
  @callback terminate(reason :: term(), state :: term()) :: term()

  @optional_callbacks handle_cast: 2, handle_info: 2, upgrade: 2, terminate: 2

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Revenant

      @revenant_config Revenant.compile_config!(__MODULE__, opts)

      def __revenant__, do: @revenant_config

      def child_spec(id) do
        %{
          id: {__MODULE__, id},
          start: {Revenant.Server, :start_link, [__MODULE__, id]},
          restart: :temporary
        }
      end

      def handle_cast(message, _state) do
        exit({:bad_cast, message})
      end

      def handle_info(_message, state), do: {:noreply, state}

      def upgrade(old_vsn, _state) do
        raise "#{inspect(__MODULE__)} loaded a vsn #{old_vsn} snapshot but is at " <>
                "vsn #{@revenant_config.vsn} and does not implement upgrade/2"
      end

      def terminate(_reason, _state), do: :ok

      defoverridable child_spec: 1, handle_cast: 2, handle_info: 2, upgrade: 2, terminate: 2
    end
  end

  @doc false
  def compile_config!(module, opts) do
    repo =
      Keyword.get(opts, :repo) ||
        raise ArgumentError, "use Revenant requires a :repo option in #{inspect(module)}"

    vsn = Keyword.get(opts, :vsn, 1)

    unless is_integer(vsn) and vsn > 0 do
      raise ArgumentError, ":vsn must be a positive integer, got: #{inspect(vsn)}"
    end

    durability = Keyword.get(opts, :durability, :strict)

    case durability do
      :strict ->
        :ok

      :on_stop ->
        :ok

      {:interval, milliseconds} when is_integer(milliseconds) and milliseconds > 0 ->
        :ok

      other ->
        raise ArgumentError,
              ":durability must be :strict, {:interval, milliseconds}, or :on_stop, " <>
                "got: #{inspect(other)}"
    end

    idle_timeout = Keyword.get(opts, :idle_timeout, :timer.minutes(5))

    unless idle_timeout == :infinity or (is_integer(idle_timeout) and idle_timeout > 0) do
      raise ArgumentError,
            ":idle_timeout must be a positive integer in milliseconds or :infinity, " <>
              "got: #{inspect(idle_timeout)}"
    end

    %{repo: repo, vsn: vsn, durability: durability, idle_timeout: idle_timeout}
  end

  @doc """
  Calls the server identified by `{module, id}`, starting it if necessary.

  Options:

    * `:timeout` - the call timeout (default 5000)
    * `:durability` - pass `:strict` to commit before this reply even on a
      server running a relaxed durability level

  """
  def call(server, message, opts \\ []) do
    server = normalize(server)
    timeout = Keyword.get(opts, :timeout, 5000)
    do_call(server, message, opts, timeout, 3)
  end

  defp do_call(server, message, opts, timeout, attempts_left) do
    pid = whereis(server) || start(server)

    try do
      GenServer.call(pid, {:"$revenant", message, opts}, timeout)
    catch
      # :noproc - the pid died between lookup and call; :normal - the server
      # passivated after the call was sent but before processing it. Both
      # mean the message was never handled, so a retry cannot double-apply.
      :exit, {reason, _} when reason in [:noproc, :normal] and attempts_left > 1 ->
        do_call(server, message, opts, timeout, attempts_left - 1)
    end
  end

  @doc """
  Casts to the server identified by `{module, id}`, starting it if necessary.

  Fire-and-forget, exactly like `GenServer.cast/2`: a crash before the next
  commit loses the message. Use `call/3` when you need the durability
  receipt.
  """
  def cast(server, message) do
    server = normalize(server)
    pid = whereis(server) || start(server)
    GenServer.cast(pid, {:"$revenant", message})
  end

  @doc """
  Returns the pid of a live server, or `nil`.

  A `nil` does not mean the entity has no state - only that no process is
  currently loaded for it.
  """
  def whereis(server) do
    case Registry.lookup(Revenant.Registry, normalize(server)) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
      [] -> nil
    end
  end

  @doc """
  Gracefully stops a live server, flushing any pending state first.

  A no-op if the server is not running.
  """
  def stop(server, reason \\ :normal) do
    case whereis(server) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, reason)
        catch
          # the server passivated between the lookup and the stop
          :exit, :noproc -> :ok
        end
    end
  end

  @doc """
  Stops a live server and deletes its committed state.

  The next call addressing the entity starts fresh from `initial_state/1`.
  A concurrent call racing this function can revive the entity, so stop
  sending messages to it before deleting.
  """
  def delete(server) do
    {module, id} = normalize(server)
    :ok = stop({module, id})

    State
    |> where(module: ^inspect(module), id: ^id)
    |> module.__revenant__().repo.delete_all()

    :ok
  end

  defp normalize({module, id}) when is_atom(module), do: {module, to_string(id)}

  defp start({module, id} = server) do
    case DynamicSupervisor.start_child(Revenant.DynamicSupervisor, {module, id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> exit({:revenant_start_failed, server, reason})
    end
  end
end
