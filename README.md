# Revenant

> **Status: experiment.** This library is an exploration and is not yet
> production ready. APIs, guarantees, and the storage format may change
> without notice.

Durable GenServers backed by Postgres. A reply is a commit receipt.

Revenant gives you process-per-entity GenServers whose state survives
crashes, restarts, and deploys, using only the Postgres you already run.
No object storage, no new infrastructure. **Single node** - or you route
each entity's messages to one node yourself; see [Topology](#topology).

```elixir
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
#=> :ok  - the new state is committed to Postgres before you see this
```

Processes are addressed by `{module, entity_id}`, not by pid. They start
lazily on the first message and revive from committed state after any kind
of death - a crash, a deploy, a scale-down. Callers never notice.

Idle processes passivate: after `:idle_timeout` milliseconds without a
message (default 5 minutes) a process flushes pending state and stops, and
the next message revives it. Memory tracks your working set, not every
entity ever touched. Set `idle_timeout: :infinity` to keep processes
resident; note that `:timeout` is a reserved info message on any server
with a finite idle timeout.

## Topology

The registry is node-local. Revenant is built for a single node - the
deployment most apps actually run - or for clusters where you already
route each entity's messages to one node (consistent hashing, a fronting
queue, sticky sessions).

If two nodes do load the same entity, your data stays safe: every write is
version-fenced, so the stale process exits with `{:revenant_conflict, key}`
instead of overwriting. But under relaxed durability the losing node has
already acked writes it can no longer commit. If you cannot guarantee
routing, use `:strict`, where every ack is already durable.

## The guarantee

With the default `:strict` durability, the state change is committed to
Postgres **before** the caller receives its reply. There is no window
between "acknowledged" and "durable":

* Anything a caller ever observed survives a crash.
* A handler crash before commit rolls back to the last committed state -
  a poison message cannot persist a state nobody was acked on.
* Every write is guarded by a version column: a stale process exits with
  `{:revenant_conflict, key}` rather than overwriting a newer commit.

## Durability levels

Strictness has a price: one Postgres commit per mutation, so per-entity
write throughput is capped by commit latency (roughly 1ms locally). When
an entity takes many low-value writes, relax it - and escalate the calls
that matter:

```elixir
use Revenant, repo: MyApp.Repo, durability: {:interval, 5_000}

Revenant.call({Session, id}, {:track, event})                      # coalesced, flushed within 5s
Revenant.call({Session, id}, {:checkout, cart}, durability: :strict) # committed before this reply
```

| Level | Flushes | Loss window on hard crash |
|---|---|---|
| `:strict` (default) | before every reply | none |
| `{:interval, ms}` | at most once per interval + on shutdown | up to one interval |
| `:on_stop` | only on graceful shutdown | the whole session |

All levels flush on graceful shutdown - and passivation is a graceful
shutdown - so deploys, scale-downs, and idle stops lose nothing in any
mode. The loss window exists only for `kill -9` and power loss.

## Setup

```elixir
# mix.exs
{:revenant, "~> 0.1"}

# a migration
defmodule MyApp.Repo.Migrations.AddRevenant do
  use Revenant.Migration
end

# application.ex, after your repo
children = [MyApp.Repo, Revenant.Supervisor]
```

## State rules

State is stored as an External Term Format blob, so any Elixir term
round-trips exactly - except runtime handles. No pids, references, ports,
or anonymous functions (captures of named functions are fine). Enable the
deep check in dev and test:

```elixir
config :revenant, validate_state: true
```

When the shape of your state changes between releases, bump `:vsn` and
migrate old snapshots as they load:

```elixir
use Revenant, repo: MyApp.Repo, vsn: 2

def upgrade(1, state), do: Map.put(state, :currency, :usd)
```

Snapshots are decoded without `:safe`, so state referencing modules or
atoms deleted since the snapshot was written still loads and reaches your
`upgrade/2` - a renamed struct arrives as a plain map with its old
`__struct__` for you to migrate.

To remove an entity entirely - stop its process and drop its row - use
`Revenant.delete({Account, id})`. The next call starts it fresh from
`initial_state/1`.

## Telemetry

* `[:revenant, :flush]` - a snapshot was committed; measurements
  `%{bytes: n}`, metadata `%{module, id, version}`
* `[:revenant, :conflict]` - a stale process lost a version race and is
  exiting; metadata `%{module, id, version}`
* `[:revenant, :load]` - a process revived from a committed snapshot (not
  first-ever starts); metadata `%{module, id, version}`

## Planned

* **Group commit.** Under `:strict`, per-entity throughput is capped by
  commit latency because every call is its own `UPDATE`. When calls queue
  up on one entity, the server will drain its mailbox, apply the handlers,
  commit **once** - one snapshot covers all of them - and only then reply
  to every caller. The guarantee is unchanged (no caller is acked before
  its state is durable), but throughput under contention scales with batch
  size instead of write latency.

* **Postgres-arbitrated ownership.** Today the registry is node-local and
  multi-node routing is your job. Since Postgres is already the source of
  truth, it can also arbitrate ownership: a lease claimed on activation,
  renewed by heartbeat, stolen when expired. A node that loses its lease
  passivates the entity instead of racing it. Multi-node clusters would
  then work without consistent hashing or a fronting queue, with the
  version column demoted to a backstop instead of the primary defense.

## When not to use this

If `init/1` could rebuild your state from tables you already have, you do
not need Revenant - you need a plain GenServer with a good `init`.
Revenant is for state whose only source of truth is the process itself:
live sessions, in-progress matches, actor-as-aggregate write models.

Side effects are not journaled. A handler that sends an email and then
crashes before commit will send the email again on the retry. For durable
effects, enqueue an Oban job - it is also just Postgres.
