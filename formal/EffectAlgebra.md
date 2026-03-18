# Effect Algebra for the Cell Tuple Space

**Philip Wadler** -- 2026-03-18, revised after dialogue with Sussman

---

## 0. The Correction

My earlier analysis (`wadler-effect-algebra.md`) got the lattice wrong. I
classified effects by *what they are*: Pure, Semantic, Divergent. But the
operational question the runtime must answer is not "what kind of effect is
this?" but "what happens when it fails?" The Sussman dialogue crystallised the
right decomposition: effects are classified by *recoverability*.

Cell is a Linda tuple space. Dolt is the versioned tuple space. The three
Linda operations map as follows:

    out  =  ct pour      (add tuples)
    in   =  ct next/claim (destructive read -- but reversible via Dolt time travel)
    rd   =  reading frozen yields (non-destructive read)

The executor runs a cell until it reaches a *boundary* -- an operation that
cannot be completed inline. The question at the boundary is: can I retry this
automatically, or does retry require rolling back the tuple space?

## 1. The Effect Lattice

```
  data EffLevel where
    Pure          -- deterministic, no effects
    Replayable    -- has effects, but auto-retryable (produces a value, no mutations)
    NonReplayable -- has effects that mutate the tuple space or the outside world
```

The ordering forms a join semilattice:

```
  Pure  <  Replayable  <  NonReplayable
```

With join:

```
  join : EffLevel -> EffLevel -> EffLevel
  join Pure         e              = e
  join e            Pure           = e
  join Replayable   Replayable    = Replayable
  join Replayable   NonReplayable = NonReplayable
  join NonReplayable _            = NonReplayable
```

**Theorem (Semilattice).** `(EffLevel, join)` is a bounded join semilattice
with bottom `Pure`. Proof: `join` is associative, commutative, idempotent,
and `join Pure e = e` for all `e`.

## 2. PistonOp Graded by the Lattice

```
  data PistonOp : EffLevel -> Type -> Type where
    -- Pure: deterministic computation, no boundaries
    Lookup    : FieldName -> PistonOp Pure String
    Yield     : FieldName -> String -> PistonOp Pure ()
    SQLQuery  : String -> PistonOp Pure String          -- read-only, same gen = same result

    -- Replayable: crosses a boundary but produces a value without mutation
    LLMCall   : Prompt -> PistonOp Replayable String    -- non-deterministic, but safe to retry
    OracleChk : Assertion -> Env -> PistonOp Replayable Bool  -- semantic oracle evaluation

    -- NonReplayable: mutates the tuple space or has external side effects
    SQLExec   : String -> PistonOp NonReplayable ()     -- INSERT, UPDATE, DELETE on retort
    Spawn     : CellDef -> PistonOp NonReplayable ()    -- ct pour / dynamic cell creation
    CascadeThaw : CellName -> PistonOp NonReplayable () -- ct thaw: reset + transitive deps
    ExternalIO  : IO a -> PistonOp NonReplayable a      -- anything outside the tuple space
```

The classification principle: a `Replayable` operation may be called
multiple times and the runtime selects any one result. A `NonReplayable`
operation changes what is *in* the tuple space; calling it twice produces
a different world than calling it once.

## 3. The Free Monad

```
  data Cell (e : EffLevel) (a : Type) where
    Return : a -> Cell e a
    Bind   : PistonOp e' x -> (x -> Cell e a) -> Cell (join e' e) a
```

This is the free monad over the graded signature `PistonOp`. It satisfies:

    return x >>= f   =   f x                     -- left identity
    m >>= return      =   m                       -- right identity
    (m >>= f) >>= g   =   m >>= (fun x => f x >>= g)  -- associativity

And the grading satisfies:

    eff(return x)  =  Pure
    eff(m >>= f)   =  join(eff(m), eff(f(x)))    -- for all x in the range of m

**Theorem (Pure Isomorphism).** `Cell Pure a ~ a`. A cell that uses only
`Pure` operations is a value. The free monad over an empty effect set is
the identity.

## 4. The Algebraic Laws

**Law 1 (Effect Join).** For `c = c1 >> c2`, `eff(c) = join(eff(c1), eff(c2))`.
A cell's effect is the join of its constituent operations.

**Law 2 (Subsumption).** If `eff(c) <= e`, then `c` can be interpreted by
any handler of capability `e`. A NonReplayable handler can run any cell.
A Replayable handler can run Pure and Replayable cells. A Pure handler can
run only Pure cells.

**Law 3 (Law of Replay).** If `eff(c) <= Replayable` and evaluation of `c`
fails at step `k`, the runtime may discard all intermediate results and
re-evaluate `c` from the beginning. The tuple space is unchanged because
no `NonReplayable` operation was executed. Formally: for `c : Cell Replayable a`,
if `eval(c, env)` fails, then `eval(c, env)` may be retried with identical
preconditions.

**Law 4 (Law of Thaw).** If `eff(c) = NonReplayable` and evaluation of `c`
fails at step `k`, the tuple space may have been mutated by prior operations
in the cell's body. Recovery requires *cascade-thaw*: Dolt time travel to
the pre-execution commit, followed by creation of generation N+1 frames
for the failed cell and all transitive dependents. Formally: for
`c : Cell NonReplayable a`, if `eval(c, env)` fails after executing some
`SQLExec` or `Spawn`, then retry requires `thaw(c)`, which:
  1. Reverts the cell to `declared` state
  2. Creates frame at generation `currentGen(c) + 1`
  3. Recursively thaws every cell `d` such that `d` transitively depends on `c`
  4. Records the epoch boundary in the Dolt commit log

**Law 5 (Pure Determinism).** For `c : Cell Pure a`, `eval(c, env) = eval(c, env)`.
Same inputs, same outputs, unconditionally. Pure cells are referentially transparent.

**Law 6 (Replayable Structural Determinism).** For `c : Cell Replayable a`,
the *trace structure* (which cells fire, in what topological order) is
deterministic. Only the values returned by `LLMCall` and `OracleChk` may
vary between runs.

**Law 7 (Handler Equivalence for Pure).** For `c : Cell Pure a` and any two
handlers `h1, h2`: `h1(c) = h2(c) = c`. Pure cells are parametric over
their handler.

**Law 8 (Thaw Monotonicity).** Thaw never decreases the generation counter.
After `thaw(c)`, `currentGen(c)` = old `currentGen(c)` + 1. Prior generations'
yields remain in the append-only store. This follows from `framesPreserved`
and `yieldsPreserved` in `Retort.lean`.

**Law 9 (Replayable Cacheability).** For `c : Cell Replayable a` with a frozen
frame at generation `g`, the yields of that frame are a valid cache. If the
runtime re-evaluates `c` and obtains a different value (because `LLMCall` is
non-deterministic), both values are acceptable. The runtime *may* cache and
reuse the old value. The formal guarantee: both the cached yields and fresh
yields satisfy the cell's oracles.

**Law 10 (NonReplayable Ordering).** `NonReplayable` operations within a cell
body have a well-defined sequential order. The runtime must not reorder them,
because each mutation may depend on the state produced by the previous one.
For `c : Cell NonReplayable a`, the evaluation of `c.body` is a totally
ordered sequence of `PistonOp` invocations.

**Law 11 (Composition Closure).** Programs composed entirely of `Pure` cells
are `Pure`. Programs with at most `Replayable` cells are `Replayable`. Any
program with a `NonReplayable` cell is `NonReplayable`. This follows from
`join` being a semilattice homomorphism over program composition.

## 5. Linda Operations and Effect Levels

| Linda op | Cell operation          | Effect level    | Rationale                                        |
|----------|------------------------|-----------------|--------------------------------------------------|
| `rd`     | Read frozen yield      | `Pure`          | Non-destructive; same gen, same value             |
| `rd`     | `SQLQuery` (read-only) | `Pure`          | Dolt commit is immutable within a generation      |
| `out`    | `Yield` (freeze value) | `Pure`          | Append-only; adds to tuple space monotonically    |
| `out`    | `ct pour` / `Spawn`    | `NonReplayable` | Creates new cells/tuples; cannot undo without thaw|
| `in`     | `ct next` / claim      | `Replayable`    | Destructive read of the ready queue, but the claim is released on failure; the tuple is not consumed |
| `in`     | `SQLExec` (DML)        | `NonReplayable` | Mutates tuples; requires thaw to undo             |

The key subtlety: Linda's `in` (destructive read) maps to *two* different
effect levels depending on what is consumed. Claiming a cell from the ready
queue is `Replayable` because the claim can be released (the tuple returns
to the space). Executing DML is `NonReplayable` because the mutation persists
in the Dolt commit.

## 6. Handler Interpretation

```
  type Handler (e : EffLevel) = forall a. Cell e a -> IO a
```

### Production Handler (`Handler NonReplayable`)

Interprets all operations against the live Dolt server and real LLM endpoints.

```
  prodHandler (Return a)                 = pure a
  prodHandler (Bind (Lookup f) k)        = do v <- queryYield f; prodHandler (k v)
  prodHandler (Bind (LLMCall p) k)       = do v <- callLLM p; prodHandler (k v)
  prodHandler (Bind (SQLExec q) k)       = do execSQL q; prodHandler (k ())
  prodHandler (Bind (Spawn cd) k)        = do pourCell cd; prodHandler (k ())
  prodHandler (Bind (CascadeThaw cn) k)  = do thawCascade cn; prodHandler (k ())
```

### Test Handler (`Handler NonReplayable`)

Replays deterministic results; mocks non-determinism. Identical structure to
production but substitutes `mockSQL`, `cachedLLM`, `mockThaw`.

```
  testHandler (Bind (LLMCall p) k)   = do v <- lookupCache p; testHandler (k v)
  testHandler (Bind (SQLExec q) k)   = do mockExec q; testHandler (k ())
```

### Sandbox Handler (`Handler Replayable`)

**Type-level guarantee: cannot execute `NonReplayable` operations.**

```
  sandboxHandler : forall a. Cell Replayable a -> IO a
  sandboxHandler (Return a)                = pure a
  sandboxHandler (Bind (Lookup f) k)       = do v <- queryYield f; sandboxHandler (k v)
  sandboxHandler (Bind (LLMCall p) k)      = do v <- callLLM p; sandboxHandler (k v)
  sandboxHandler (Bind (OracleChk a e) k)  = do v <- evalOracle a e; sandboxHandler (k v)
  -- SQLExec, Spawn, CascadeThaw, ExternalIO: ABSENT from the signature.
  -- A Cell Replayable a cannot contain these operations.
  -- The type system enforces the sandbox. No allow-list required.
```

This replaces the string-prefix matching in `sandbox.go`. The current
`sandboxSQL` checks `strings.HasPrefix(upper, "INSERT INTO CELLS")` --
an allow-list that must be maintained by hand and can be evaded. With the
graded free monad, the *type* of a `Replayable` cell guarantees it cannot
issue mutations. There is no list to maintain, no pattern to match, no
injection to defend against.

## 7. Implementation Path

The bridge from this algebra to the existing Go codebase:

1. **Tag cells at pour time.** The parser already distinguishes `hard`/`soft`/`stem`.
   Extend `body_type` (or add a column `effect_level`) with the three-valued
   classification. `hard` cells with `sql:SELECT` are `Pure`. `soft`/`stem`
   cells are `Replayable` (LLM call, no mutations). Cells with `sql:INSERT`
   or `sql:UPDATE` are `NonReplayable`.

2. **Enforce at claim time.** In `cell_eval_step`, before dispatching a cell
   to a piston, check the cell's effect level against the piston's capability.
   A sandbox piston refuses `NonReplayable` cells.

3. **Auto-retry `Replayable` failures.** In `cmdRun` (eval.go), when a
   `Replayable` cell fails (LLM timeout, oracle rejection), retry automatically
   up to N times. The current `hardSQLFails` map is a degenerate case of this.

4. **Require cascade-thaw for `NonReplayable` failures.** When a `NonReplayable`
   cell fails after executing mutations, call `cmdThaw` automatically. The
   current manual `ct thaw` becomes the formal recovery path.

---

The previous effect algebra was decorative: `EffectLevel` existed in `Core.lean`
but `M = Id` erased it at every call site. The new algebra is operational:
the distinction between `Replayable` and `NonReplayable` determines what the
runtime *does* when a cell fails. This is not a change in the mathematics.
It is a change in what the mathematics is *about*.
