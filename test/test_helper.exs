alias Revenant.TestRepo

{:ok, _} = TestRepo.start_link()

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

{:ok, _} = Revenant.Supervisor.start_link()

ExUnit.start()
