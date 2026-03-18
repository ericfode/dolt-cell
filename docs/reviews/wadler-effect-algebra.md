# The Algebra of Piston Effects

**Philip Wadler** -- 2026-03-18

---

I have been asked to address the effect algebra of this system, and I must begin
with a confession of the sin that pervades it: the comment `M = Id` in
`Denotational.lean` line 230 is not simplification. It is erasure. The formal
model parameterises `CellBody` over a monad `M`, then instantiates `M = Id`
at every call site. Meanwhile the runtime (`eval.go`) executes arbitrary SQL
against a mutable database, spawns successor cells via INSERT, and delegates to
LLM pistons with non-deterministic output. The types say "pure." The
implementation says "IO." That gap is the entire problem.

## 1. The Algebra of Piston Capabilities

A piston is an interpreter of cell bodies. What capabilities should it have?
Define the *piston effect signature* as a graded monad indexed by `EffectLevel`:

```
  data PistonOp : EffectLevel -> Type -> Type where
    Lookup   : FieldName -> PistonOp Pure String
    Yield    : FieldName -> String -> PistonOp Pure ()
    LLMCall  : String -> PistonOp Semantic String
    SQLExec  : String -> PistonOp Divergent String
    SQLQuery : String -> PistonOp Divergent String
    Spawn    : CellDef -> PistonOp Divergent ()
```

The operations form a *ranked alphabet*. The key algebraic structure is that
effect levels are closed under join in the lattice `Pure < Semantic < Divergent`:

```
  join : EffectLevel -> EffectLevel -> EffectLevel
  join Pure      e         = e
  join e         Pure      = e
  join Semantic  Semantic  = Semantic
  join Semantic  Divergent = Divergent
  join Divergent _         = Divergent
```

A cell's effect level is the join of all operations it uses. This is well-defined
because join is associative, commutative, and idempotent -- a semilattice. A
cell that only uses `Lookup` and `Yield` is Pure. A cell that calls `LLMCall` is
at least Semantic. A cell that calls `SQLExec` or `Spawn` is Divergent.

**Law 1 (Effect Join).** For any composite cell `c = c1 ; c2`, the effect level
satisfies `eff(c) = join(eff(c1), eff(c2))`.

**Law 2 (Monotonicity).** If `eff(c) <= e`, then `c` can be interpreted by any
piston with capability level `e`.

**Law 3 (Subsumption).** A Divergent piston can evaluate any cell. A Semantic
piston can evaluate Pure and Semantic cells. A Pure piston evaluates only Pure cells.

## 2. The Monad Stack

The honest monad for the Retort runtime is not `Id`. It is:

```
  M_Pure     a = a                                   -- Identity
  M_Semantic a = ReaderT Env (ExceptT Error (WriterT Cost IO)) a
  M_Divergent a = ReaderT Env (StateT RetortDB (ExceptT Error (WriterT Cost IO))) a
```

But this tower commits two sins: it fixes the interpretation, and it does not
compose. The correct approach is the *free monad* over the effect signature,
with interpretation deferred to the handler.

```
  data Cell (e : EffectLevel) (a : Type) where
    Pure   : a -> Cell e a
    Bind   : PistonOp e x -> (x -> Cell e a) -> Cell e a
```

This is the free monad on `PistonOp e`. It satisfies the monad laws by
construction. The critical property: `Cell Pure a` is isomorphic to `a` -- a
pure cell has no effects, and the free monad over an empty signature is the
identity. So `M = Id` is *correct for Pure cells*. The lie is using it for
Semantic and Divergent cells.

**Law 4 (Pure Embedding).** `Cell Pure a ~ a`. Pure cells admit equational
reasoning as if they were plain functions.

**Law 5 (Composition).** `Cell e1 a -> (a -> Cell e2 b) -> Cell (join e1 e2) b`.
Monadic bind raises the effect level to the join.

## 3. Algebraic Laws for Cell Composition

Given a program `P` with cells `c_1, ..., c_n`, define:

```
  programEffect(P) = join(eff(c_1), ..., eff(c_n))
```

**Law 6 (Pure Program Determinism).** If `programEffect(P) = Pure`, then
for all well-formed inputs `env`, `eval(P, env)` is deterministic: same
inputs yield the same trace. This justifies caching.

**Law 7 (Semantic Program Bounded Non-Determinism).** If
`programEffect(P) = Semantic`, then `eval(P, env)` may vary between runs,
but the *structure* of the trace (which cells fire, in what order) is
deterministic. Only the yield *values* vary (because LLM calls are opaque).

**Law 8 (Pure Cell Cacheability).** If `eff(c) = Pure` and `c` has been
evaluated with inputs `env` producing outputs `out`, then any subsequent
evaluation of `c` with identical inputs `env` must produce `out`. The runtime
may substitute the cached value without observable difference. This is the
*referential transparency* of pure cells.

**Law 9 (Composing Pure Sub-Programs).** If programs `P` and `Q` both have
`programEffect = Pure`, then `merge(P, Q)` has `programEffect = Pure`, and the
merged program's denotation is the product of the individual denotations. This
follows from `merge_assoc` in the formal model and the idempotence of
`join(Pure, Pure) = Pure`.

## 4. SQL Cells in the Effect Algebra

SQL cells are currently the most dangerous gap. In `eval.go` line 55, a hard
cell with body `sql:QUERY` executes `db.QueryRow(sqlQuery).Scan(&result)` --
that is `IO` in its rawest form. The `sandboxSQL` function in `sandbox.go`
performs string-prefix matching against an allow list. This is not an effect
system; it is a firewall.

The algebraic classification:

- `sql: SELECT ...` with no side effects: should be `Pure`. The query is a
  function from database state to a value. If the database state is fixed
  (which it is within a generation, because Dolt commits are immutable), then
  the SELECT is deterministic. **But the system does not verify this.** The
  cell author writes `sql:` and the runtime trusts it.

- `sql: INSERT/UPDATE/DELETE ...`: `Divergent`. These mutate the retort state.
  The `cell-zero-eval` program's pistons issue INSERT INTO cells, UPDATE cells,
  DELETE FROM cell_claims -- full read-write IO.

The fix is to split `sql:` into two annotations:

```
  sql-query: SELECT ...     -- Pure (read-only, deterministic given generation)
  sql-exec:  INSERT ...     -- Divergent (mutates retort state)
```

And enforce this at the type level: `sql-query` cells get `eff = Pure`;
`sql-exec` cells get `eff = Divergent`. The sandbox allow-list becomes a
consequence of the type, not a substitute for it.

**Law 10 (SQL Query Purity).** If a cell's body is `sql-query: Q` and `Q`
contains no non-deterministic functions (RAND, NOW, UUID), then the cell is
Pure: same database generation, same result.

## 5. Free Monad Handlers and Piston Sandboxing

The free monad encoding gives us something the current system lacks entirely:
the ability to *interpret the same cell in different contexts*. Define handlers:

```
  type Handler (e : EffectLevel) = forall a. Cell e a -> IO a

  productionHandler : Handler Divergent
  productionHandler (Pure a)          = pure a
  productionHandler (Bind (SQLExec q) k) = do
    result <- realSQL q
    productionHandler (k result)
  productionHandler (Bind (LLMCall p) k) = do
    result <- realLLM p
    productionHandler (k result)

  testHandler : Handler Divergent
  testHandler (Pure a)              = pure a
  testHandler (Bind (SQLExec q) k)  = do
    result <- mockSQL q   -- deterministic mock
    testHandler (k result)
  testHandler (Bind (LLMCall p) k)  = do
    result <- cachedLLM p -- replay from cache
    testHandler (k result)

  sandboxHandler : Handler Semantic  -- REJECTS Divergent operations at the type level
  sandboxHandler (Pure a)              = pure a
  sandboxHandler (Bind (LLMCall p) k)  = do
    result <- sandboxedLLM p
    sandboxHandler (k result)
  -- SQLExec and Spawn are NOT in the Semantic signature. They cannot appear.
  -- The type system enforces the sandbox. No string matching required.
```

The `sandboxHandler` is the key insight. Today's `sandboxSQL` in `sandbox.go`
does string-prefix matching: `if strings.HasPrefix(upper, "INSERT INTO CELLS")`
-- an allow-list that must be maintained by hand, that can be evaded by SQL
injection, and that provides no compositional guarantees. With the free monad
approach, the *type* of a Semantic cell guarantees it cannot issue SQL mutations.
The handler for `Cell Semantic a` simply does not have a case for `SQLExec`.
There is nothing to match, nothing to evade, nothing to maintain.

**Law 11 (Handler Equivalence for Pure Cells).** For any pure cell `c : Cell Pure a`
and any two handlers `h1, h2 : Handler e` (where `e >= Pure`):
`h1(embed c) = h2(embed c) = c`. Pure cells produce the same result under any
handler. This is the *parametricity* of purity.

---

The path forward is clear. The formal model already has `EffectLevel` in
`Core.lean` and uses it as a classification tag in `Denotational.lean`. The
runtime already has `body_type` in the SQL schema and `sandboxSQL` as an
ad-hoc effect boundary. What is missing is the bridge: the free monad that
makes `EffectLevel` *computational* rather than *decorative*. Today, writing
`eff = Pure` on a cell that issues SQL mutations is a lie the type system
cannot detect. Tomorrow, with graded monadic bodies, it should be a type error.
The algebra is already latent in the system. It needs only to be made honest.
