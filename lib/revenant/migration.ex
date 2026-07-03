defmodule Revenant.Migration do
  @moduledoc """
  Creates and drops the `revenant_states` table.

  Use it in a migration in your application:

      defmodule MyApp.Repo.Migrations.AddRevenant do
        use Revenant.Migration
      end
  """

  use Ecto.Migration

  defmacro __using__(_opts) do
    quote do
      use Ecto.Migration

      def up, do: Revenant.Migration.up()
      def down, do: Revenant.Migration.down()
    end
  end

  def up do
    create table(:revenant_states, primary_key: false) do
      add(:module, :text, primary_key: true)
      add(:id, :text, primary_key: true)
      add(:state, :binary, null: false)
      add(:version, :bigint, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end
  end

  def down do
    drop(table(:revenant_states))
  end
end
