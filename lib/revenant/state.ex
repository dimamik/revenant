defmodule Revenant.State do
  @moduledoc """
  The Ecto schema for persisted server state.

  One row per entity, keyed by `(module, id)`. The `state` column is an
  External Term Format blob of `{vsn, user_state}`; the `version` column
  guards every write against stale processes.
  """

  use Ecto.Schema

  @primary_key false
  schema "revenant_states" do
    field(:module, :string, primary_key: true)
    field(:id, :string, primary_key: true)
    field(:state, :binary)
    field(:version, :integer)
    field(:updated_at, :utc_datetime_usec)
  end
end
