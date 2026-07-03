defmodule Revenant.TestRepo do
  use Ecto.Repo, otp_app: :revenant, adapter: Ecto.Adapters.Postgres
end
