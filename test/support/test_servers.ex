defmodule Revenant.StrictCounter do
  use Revenant, repo: Revenant.TestRepo

  def initial_state(_id), do: %{count: 0}

  def handle_call(:increment, _from, state) do
    {:reply, state.count + 1, %{state | count: state.count + 1}}
  end

  def handle_call(:get, _from, state), do: {:reply, state.count, state}

  def handle_call(:embed_pid, _from, state) do
    {:reply, :ok, Map.put(state, :pid, self())}
  end

  def handle_cast(:increment, state), do: {:noreply, %{state | count: state.count + 1}}

  def handle_info(:increment, state), do: {:noreply, %{state | count: state.count + 1}}
end

defmodule Revenant.IntervalCounter do
  use Revenant, repo: Revenant.TestRepo, durability: {:interval, 50}

  def initial_state(_id), do: %{count: 0}

  def handle_call(:increment, _from, state) do
    {:reply, state.count + 1, %{state | count: state.count + 1}}
  end

  def handle_call(:get, _from, state), do: {:reply, state.count, state}
end

defmodule Revenant.OnStopCounter do
  use Revenant, repo: Revenant.TestRepo, durability: :on_stop

  def initial_state(_id), do: %{count: 0}

  def handle_call(:increment, _from, state) do
    {:reply, state.count + 1, %{state | count: state.count + 1}}
  end

  def handle_call(:get, _from, state), do: {:reply, state.count, state}
end

defmodule Revenant.SleepyCounter do
  use Revenant, repo: Revenant.TestRepo, idle_timeout: 50

  def initial_state(_id), do: %{count: 0}

  def handle_call(:increment, _from, state) do
    {:reply, state.count + 1, %{state | count: state.count + 1}}
  end

  def handle_call(:get, _from, state), do: {:reply, state.count, state}
end

defmodule Revenant.UpgradedCounter do
  use Revenant, repo: Revenant.TestRepo, vsn: 2

  def initial_state(_id), do: %{count: 0, upgraded: false}

  def upgrade(1, state), do: Map.put(state, :upgraded, true)

  def handle_call(:get, _from, state), do: {:reply, state, state}

  def handle_call(:increment, _from, state) do
    {:reply, state.count + 1, %{state | count: state.count + 1}}
  end
end
