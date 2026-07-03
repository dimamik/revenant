defmodule Revenant.Supervisor do
  @moduledoc """
  The supervision tree for Revenant servers.

  Add it to your application after your repo:

      children = [MyApp.Repo, Revenant.Supervisor]

  It owns the registry that maps `{module, id}` to live pids and the
  dynamic supervisor under which servers start lazily on first message.
  Servers are `:temporary`: a crashed server is not restarted eagerly but
  revived from its committed state by the next call that addresses it.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Revenant.Registry},
      {DynamicSupervisor, name: Revenant.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
