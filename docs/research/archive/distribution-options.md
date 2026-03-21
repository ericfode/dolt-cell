# Distribution Options for the Retort

**Bead**: dc-sjc
**Date**: 2026-03-20
**Author**: Alchemist (dolt-cell)
**Context**: Consensus (dc-rv8) chose Dolt for production behind
RetortStore interface. This document evaluates distribution options
for the retort in detail.

## The Requirement

The retort is a shared distributed tuple space. Agents across Gas City
pour programs, evaluate cells, and observe crystallized yields. The
distribution requirement is:

1. **Pour anywhere** — any agent can pour a program into the retort
2. **Observe everywhere** — frozen yields are visible to all agents
3. **Claim exclusively** — exactly one piston evaluates each frame
4. **Append-only replication** — yields are immutable once frozen

Key constraint: **claims must be linearizable** (exactly-once mutex).
Everything else is append-only and can use eventual consistency.

## Options Evaluated

### 1. Dolt Remote-Based Replication (RECOMMENDED)

**How it works**: One Dolt server is primary (accepts writes). Read
replicas pull from a shared remote (DoltHub, filesystem, S3). Push
on write, pull on read.

**Configuration**:
```sql
-- Primary
SET @@GLOBAL.dolt_replicate_to_remote = 'origin';

-- Replica
SET @@GLOBAL.dolt_read_replica_remote = 'origin';
SET @@GLOBAL.dolt_replicate_all_heads = 1;
```

**Strengths**:
- Already built. Zero new code.
- Push/pull on Dolt commit (not every SQL transaction).
- Replication granularity matches cell evaluation: commit after pour,
  commit after freeze = replicas see complete programs and yields.
- DoltHub as remote means city-wide sharing via standard URL.
- All existing `ct` commands work unchanged.

**Weaknesses**:
- Single-writer. Only one Dolt server accepts writes.
- No automated failover in remote-based mode.
- Pull-on-read adds latency to replica reads.
- No merge conflict resolution for multi-writer.

**Fitness for cell model**:
- Claims must happen on the primary (single-writer is fine — claims
  need linearizability anyway).
- Pours happen on the primary.
- Observations can happen on replicas (read-only, eventually consistent).
- Yields are immutable — no conflict possible.

**Verdict**: The single-writer constraint is actually a *feature* for
claims. The claim mutex requires exactly one authority. Dolt's primary
IS that authority. Replicas provide read scaling for observe/gather.

### 2. Dolt Direct-to-Standby Replication

**How it works**: Primary pushes every SQL transaction commit to
standby servers. No intermediate remote.

**Strengths**:
- Lower read latency (no pull-on-read).
- Hot standby for failover.
- Synchronous — standbys are always current.

**Weaknesses**:
- Higher write latency (every commit synchronizes to standbys).
- More complex configuration (YAML cluster config, bootstrap roles).
- Designed for HA, not for cross-city distribution.
- DROP DATABASE and grants not replicated.

**Fitness for cell model**:
- Better for HA within a single location.
- Not designed for cross-city (different networks, high latency).

**Verdict**: Good for single-site HA. Not the right tool for Gas City
distribution where agents are in different rigs/locations.

### 3. NATS JetStream (Log Shipping)

**How it works**: Retort events (pour, claim, submit, fail, thaw) are
published to a NATS JetStream stream. Each node replays the stream to
build local state. Claims are coordinated via NATS request-reply.

**Strengths**:
- Append-only streams are natural for event log replication.
- Built-in Raft consensus for stream replication.
- Go-native client.
- Sub-millisecond message delivery.
- Replay from any sequence number (time travel!).
- Consumer groups for load balancing piston dispatch.

**Weaknesses**:
- New infrastructure dependency (NATS cluster).
- Must build event serialization, claim coordination, state rebuild.
- No SQL query interface (need separate tooling for `ct status` etc.).
- Claim coordination via request-reply is more complex than Dolt's
  single-writer INSERT IGNORE.

**Fitness for cell model**:
- Pour: publish POUR event to stream. All nodes see it.
- Claim: publish CLAIM request, single responder wins (NATS queue group).
- Submit: publish SUBMIT event. All nodes freeze yields.
- Observe: local state, rebuilt from stream.
- Gather: local state.

**Verdict**: Powerful and natural for append-only event replication.
But requires building significant infrastructure. The claim
coordination is the tricky part — NATS doesn't give you INSERT IGNORE
semantics. You'd need a claim coordinator service.

**Estimate**: ~2000 lines of Go + NATS cluster ops.

### 4. CRDTs (Append-Only Sets)

**How it works**: Frozen yields form a grow-only set (G-Set). Claims
form an add-remove set. Replicate via gossip or merge.

**Strengths**:
- Mathematically guaranteed convergence for append-only data.
- No single point of failure.
- Works over unreliable networks.

**Weaknesses**:
- Claims (mutable, exclusive) are fundamentally not CRDT-friendly.
  A claim is an exclusive lock — the opposite of "merge without
  coordination."
- Need a separate coordination mechanism for claims.
- Complex implementation for a system that also has mutable state.

**Fitness for cell model**:
- Yields: perfect (G-Set, trivially convergent).
- Frames: good (append-only, G-Set).
- Claims: terrible (requires consensus, not CRDT).

**Verdict**: CRDTs solve the easy part (replicating immutable yields)
but don't help with the hard part (claim coordination). The claim
mutex is inherently a consensus problem.

### 5. LiteFS (Distributed SQLite)

**How it works**: FUSE filesystem intercepts SQLite writes, ships
transaction logs to replicas. Single primary writes.

**Strengths**:
- SQLite is simpler than Dolt.
- Transparent — app sees a local SQLite file.
- Proven at Fly.io for edge replication.

**Weaknesses**:
- Pre-1.0, API may change.
- FUSE dependency (Linux only, kernel module).
- Single primary (same as Dolt).
- No time travel, no branching, no merge.
- Loses Dolt's unique capabilities.

**Fitness for cell model**:
- Same single-writer model as Dolt but with less functionality.
- No benefit over Dolt for our use case.

**Verdict**: Worse than Dolt on every dimension except raw speed.
Not recommended.

### 6. Log Store + Custom Replication

**How it works**: The alchemist's log store writes to a local file.
A replication daemon tails the log and ships events to other nodes.
Claims are forwarded to a designated primary.

**Strengths**:
- Total control over replication semantics.
- Append-only log is trivially shippable.
- Can optimize for cell evaluation patterns.
- No external dependencies.

**Weaknesses**:
- Must build everything: discovery, membership, failure detection,
  leader election (for claims), event ordering, catch-up replay.
- This is "building a database from scratch."

**Fitness for cell model**:
- Perfect in theory. Impossible in practice (scope).

**Verdict**: This is the "build Dolt from scratch" option. The
consensus recommendation was right to reject it.

## Comparison Matrix

| Dimension | Dolt Remote | Dolt Standby | NATS JS | CRDTs | LiteFS | Custom |
|-----------|-----------|-------------|---------|-------|--------|--------|
| New code | 0 | 0 | ~2000 | ~3000 | ~500 | ~5000+ |
| New infra | 0 | 0 | NATS cluster | None | LiteFS | None |
| Claim safety | Yes | Yes | Complex | No | Yes | Must build |
| Multi-writer | No | No | Complex | Yes* | No | Must build |
| Time travel | Yes | Yes | Yes | No | No | Must build |
| Latency | Medium | Low | Very low | Low | Low | Lowest |
| Ops burden | Low | Medium | High | Low | Medium | Very high |
| Maturity | Production | Production | Production | Research | Pre-1.0 | N/A |

*CRDTs enable multi-writer for yields but NOT for claims.

## Recommendation: Dolt Remote-Based Replication

The consensus was right. Dolt remote-based replication is the answer.

**Why it wins**:

1. **Zero new code.** The `ct` tool already uses Dolt. Adding
   replication is configuration, not development.

2. **Claims need a single authority.** Linearizable mutex requires
   consensus. Dolt's single-primary model IS consensus — the primary
   is the authority. Trying to distribute claims (NATS, CRDTs) adds
   massive complexity for no benefit.

3. **Yields are immutable.** The append-only guarantee means
   replication conflicts are impossible for yields. The only thing
   that can conflict is claims, and those stay on the primary.

4. **The topology matches the cell model.** Primary = where pistons
   claim and evaluate. Replicas = where observers read frozen yields.
   This is exactly how the retort should work:
   - Pistons connect to primary, claim frames, submit yields.
   - Observers (other agents, dashboards) connect to replicas.
   - Replication happens on Dolt commit (natural boundary).

5. **DoltHub as the remote.** Gas City agents across rigs can share
   a retort via DoltHub URLs. No custom networking. No service mesh.
   Just `dolt push` and `dolt pull`.

### Deployment Architecture

```
                    ┌──────────────┐
                    │   DoltHub    │
                    │  (remote)    │
                    └──────┬───────┘
                           │
              push ────────┼──────── pull
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────┴─────┐ ┌───┴────┐ ┌────┴─────┐
        │  Primary   │ │Replica │ │ Replica  │
        │  Dolt      │ │  Dolt  │ │  Dolt    │
        │            │ │        │ │          │
        │ ct pour    │ │ ct     │ │ ct       │
        │ ct next    │ │ yields │ │ watch    │
        │ ct submit  │ │ ct     │ │ ct       │
        │ pistons    │ │ status │ │ observe  │
        └────────────┘ └────────┘ └──────────┘
```

**Primary**: All write operations (pour, claim, submit, thaw).
Pistons connect here. Single instance.

**Replicas**: Read-only operations (observe, gather, status, watch).
Agents that only need to see frozen yields connect here. Scale
horizontally.

**DoltHub**: The shared remote. Push on commit from primary. Pull
on read from replicas. Standard DoltHub API — no custom infrastructure.

### Configuration for Gas City

```yaml
# Primary Dolt server (in the dolt-cell rig)
dolt_replicate_to_remote: "origin"
# origin = dolthub://org/retort

# Replica Dolt server (in other rigs)
dolt_read_replica_remote: "origin"
dolt_replicate_all_heads: true
dolt_async_replication: false  # sync for consistency
```

### What About Multi-Rig Pour?

If agents in different rigs need to pour programs (not just observe),
they pour via the primary. Two options:

**A. Direct connection**: Agent connects to primary Dolt over network.
Simplest but requires network access to primary.

**B. Pour via bead**: Agent creates a bead with the .cell file. A
piston on the primary picks it up and pours it. Works over the existing
bead infrastructure (which already replicates via Dolt).

Option B is cleaner — it uses the existing coordination system (beads)
and doesn't require direct database access from remote agents.

### Future: Multi-Primary

If Gas City grows to need multiple writers:

1. **Partition by program**: Each program lives on one primary. Claims
   for that program go to its primary. This is natural — programs are
   independent units of evaluation.

2. **Dolt merge for cross-primary sync**: Programs are independent DAGs.
   Merging yields from different programs has no conflicts (different
   cell namespaces). Dolt merge handles this.

3. **NATS for coordination**: If we need sub-second replication between
   primaries, NATS JetStream can ship events between primaries with
   Dolt merge as the reconciliation point.

This is future work. Single-primary covers the current Gas City scale.

## Open Questions

1. **Replication latency**: What's the actual latency of Dolt
   remote-based replication? Need to benchmark push-to-DoltHub and
   pull-from-DoltHub in a realistic network.

2. **Commit granularity**: How often should the primary commit? Per
   yield freeze? Per program completion? The consensus recommended
   reducing from ~20-40 to ~5-10 commits per program.

3. **Replica staleness**: How stale is acceptable for observers? If a
   replica is 5 seconds behind, is that OK for `ct watch`?

4. **DoltHub cost**: Is DoltHub the right remote for always-on
   replication, or should we use a self-hosted remote (filesystem, S3)?
