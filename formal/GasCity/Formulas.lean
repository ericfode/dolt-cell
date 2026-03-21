/-
  Formulas: Formal model of Gas City formula resolution and molecule instantiation

  Formulas are layered recipe definitions (TOML files) that compile into
  Recipes and instantiate as molecule bead trees. This file formalizes:

  1. resolve_idempotent — resolving already-resolved sources is stable
  2. higher_priority_wins — highest-priority layer determines the winner
  3. molecule_root_type — root bead of a molecule has type `.molecule`
  4. molecule_steps_parent — non-root steps' parentId tracks to their parent

  Go source references:
    cmd/gc/formula_resolve.go     — ResolveFormulas (layered resolution)
    internal/formula/recipe.go    — Recipe / RecipeStep / RecipeDep
    internal/molecule/molecule.go — Instantiate (bead tree creation)
-/

namespace GasCity.Formulas

/-! ====================================================================
    IDENTITY TYPES
    ==================================================================== -/

/-- Formula filename (e.g., "mol-polecat-work.formula.toml"). -/
structure FormulaName where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

instance : LawfulBEq FormulaName where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

/-- Step identifier within a recipe. -/
structure StepId where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

instance : LawfulBEq StepId where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

/-- Bead ID (store-assigned natural number). -/
abbrev BeadId := Nat

/-! ====================================================================
    PART 1: FORMULA RESOLUTION
    ==================================================================== -/

/-- A formula source: a named formula at a priority layer.
    Higher priority values win (later layers override earlier). -/
structure FormulaSource where
  name     : FormulaName
  path     : String
  priority : Nat
  deriving Repr, DecidableEq, BEq

/-- A resolved formula map: at most one entry per name, keyed by name.
    Using an association list (name → source) for proof friendliness. -/
abbrev ResolvedMap := List (FormulaName × FormulaSource)

/-- Look up a name in a resolved map. -/
def ResolvedMap.lookup (m : ResolvedMap) (name : FormulaName) : Option FormulaSource :=
  (m.find? (fun p => p.1 == name)).map (·.2)

/-- Insert or update: if the name exists and the new source has higher-or-equal
    priority, replace. Otherwise insert at the end. -/
def ResolvedMap.upsert (m : ResolvedMap) (s : FormulaSource) : ResolvedMap :=
  if m.any (fun p => p.1 == s.name) then
    m.map (fun p =>
      if p.1 == s.name && s.priority ≥ p.2.priority then (s.name, s) else p)
  else
    m ++ [(s.name, s)]

/-- Resolve: fold upsert over all sources, starting from empty map. -/
def resolve (sources : List FormulaSource) : ResolvedMap :=
  sources.foldl (fun m s => m.upsert s) []

/-- Extract the winner list from a resolved map. -/
def ResolvedMap.values (m : ResolvedMap) : List FormulaSource :=
  m.map (·.2)

/-! ====================================================================
    RESOLVE HELPER LEMMAS
    ==================================================================== -/

/-- upsert preserves name-uniqueness of keys. -/
private theorem upsert_preserves_unique_keys (m : ResolvedMap) (s : FormulaSource)
    (huniq : ∀ (a b : FormulaName × FormulaSource), a ∈ m → b ∈ m → a.1 = b.1 → a = b) :
    ∀ (a b : FormulaName × FormulaSource),
      a ∈ m.upsert s → b ∈ m.upsert s → a.1 = b.1 → a = b := by
  intro a b ha hb heq
  unfold ResolvedMap.upsert at ha hb
  split at ha <;> split at hb
  · -- Both in update (map) branch
    rename_i hany _ -- same condition
    obtain ⟨a', ha', rfl⟩ := List.mem_map.mp ha
    obtain ⟨b', hb', rfl⟩ := List.mem_map.mp hb
    -- Each of a', b' either satisfied the condition or not
    -- If condition true, result is (s.name, s). If false, result is a'/b'.
    have key : ∀ (x : FormulaName × FormulaSource),
        (if (x.1 == s.name && decide (s.priority ≥ x.2.priority)) = true
         then (s.name, s) else x).1 =
        (if (x.1 == s.name && decide (s.priority ≥ x.2.priority)) = true
         then s.name else x.1) := by
      intro x; split <;> rfl
    -- The mapped function applied to a' and b'
    let fa := if (a'.1 == s.name && decide (s.priority ≥ a'.2.priority)) = true then (s.name, s) else a'
    let fb := if (b'.1 == s.name && decide (s.priority ≥ b'.2.priority)) = true then (s.name, s) else b'
    -- heq : fa.1 = fb.1
    -- Case analysis on whether each matched
    by_cases hca : (a'.1 == s.name && decide (s.priority ≥ a'.2.priority)) = true <;>
    by_cases hcb : (b'.1 == s.name && decide (s.priority ≥ b'.2.priority)) = true
    · -- Both matched: both are (s.name, s)
      simp only [hca, ite_true, hcb]
    · -- a' matched (result = (s.name, s)), b' didn't (result = b')
      simp only [hca, ite_true, hcb] at heq ⊢
      -- heq : s.name = b'.1
      -- b' didn't match, so b'.1 ≠ s.name OR priority failed
      have hbn : (b'.1 == s.name) = true := beq_iff_eq.mpr heq.symm
      -- First part of && is true, so the decide part must be false
      simp only [hbn, Bool.true_and] at hcb
      -- Now hca says a'.1 == s.name && ... = true, hcb says ¬decide(s.priority ≥ b'.2.priority) = true
      have han : (a'.1 == s.name) = true := by
        rcases Bool.and_eq_true_iff.mp hca with ⟨h1, _⟩; exact h1
      have hab : a'.1 = b'.1 := by
        rw [beq_iff_eq] at han; rw [han, beq_iff_eq.mp hbn]
      have := huniq a' b' ha' hb' hab
      subst this
      -- Now a' = b', but hca true and hcb says the decide part is false
      rcases Bool.and_eq_true_iff.mp hca with ⟨_, h2⟩
      exact absurd h2 hcb
    · -- Symmetric: b' matched, a' didn't
      simp only [hca, hcb, ite_true] at heq ⊢
      have han : (a'.1 == s.name) = true := beq_iff_eq.mpr heq
      simp only [han, Bool.true_and] at hca
      have hbn : (b'.1 == s.name) = true := by
        rcases Bool.and_eq_true_iff.mp hcb with ⟨h1, _⟩; exact h1
      have hab : a'.1 = b'.1 := by
        rw [beq_iff_eq] at han hbn; rw [han, hbn]
      have := huniq a' b' ha' hb' hab
      subst this
      rcases Bool.and_eq_true_iff.mp hcb with ⟨_, h2⟩
      exact absurd h2 hca
    · -- Neither matched: both are originals
      simp only [hca, hcb] at heq ⊢
      exact huniq a' b' ha' hb' heq
  · -- a in update, b in insert -- impossible (condition can't be both true and false)
    rename_i hany hany'
    exact absurd hany hany'
  · -- a in insert, b in update -- impossible
    rename_i hany hany'
    exact absurd hany' hany
  · -- Both in insert branch
    rename_i hany _
    rcases List.mem_append.mp ha with ha | ha <;> rcases List.mem_append.mp hb with hb | hb
    · exact huniq a b ha hb heq
    · have hb' := List.mem_singleton.mp hb; subst hb'
      exfalso; apply hany
      rw [List.any_eq_true]
      exact ⟨a, ha, beq_iff_eq.mpr heq⟩
    · have ha' := List.mem_singleton.mp ha; subst ha'
      exfalso; apply hany
      rw [List.any_eq_true]
      exact ⟨b, hb, beq_iff_eq.mpr heq.symm⟩
    · rw [List.mem_singleton.mp ha, List.mem_singleton.mp hb]

/-- The resolve fold maintains unique keys. -/
private theorem resolve_foldl_unique_keys (sources : List FormulaSource)
    (acc : ResolvedMap)
    (hacc : ∀ (a b : FormulaName × FormulaSource), a ∈ acc → b ∈ acc → a.1 = b.1 → a = b) :
    ∀ (a b : FormulaName × FormulaSource),
      a ∈ sources.foldl (fun m s => m.upsert s) acc →
      b ∈ sources.foldl (fun m s => m.upsert s) acc →
      a.1 = b.1 → a = b := by
  induction sources generalizing acc with
  | nil => exact hacc
  | cons hd tl ih =>
    simp only [List.foldl]
    exact ih (acc.upsert hd) (upsert_preserves_unique_keys acc hd hacc)

/-- resolve produces unique keys. -/
theorem resolve_unique_keys (sources : List FormulaSource) :
    ∀ (a b : FormulaName × FormulaSource),
      a ∈ resolve sources → b ∈ resolve sources → a.1 = b.1 → a = b :=
  resolve_foldl_unique_keys sources [] (fun _ _ h => absurd h (List.not_mem_nil))

/-- Every entry in upsert result either came from acc or is (s.name, s). -/
private theorem upsert_mem_or_new (m : ResolvedMap) (s : FormulaSource)
    (p : FormulaName × FormulaSource) (hp : p ∈ m.upsert s) :
    p ∈ m ∨ p = (s.name, s) := by
  unfold ResolvedMap.upsert at hp
  by_cases hany : m.any (fun q => q.1 == s.name) = true
  · simp only [hany] at hp
    obtain ⟨p', hp', rfl⟩ := List.mem_map.mp hp
    by_cases heq : p'.1 == s.name && s.priority ≥ p'.2.priority
    · simp only [heq] at *
      exact Or.inr rfl
    · simp only [heq] at *
      exact Or.inl hp'
  · simp only [hany] at hp
    rcases List.mem_append.mp hp with hp | hp
    · exact Or.inl hp
    · exact Or.inr (List.mem_singleton.mp hp)

/-- Every entry in resolve came from some source. Key stays equal to source name. -/
private theorem resolve_entry_from_source (sources : List FormulaSource) :
    ∀ (p : FormulaName × FormulaSource), p ∈ resolve sources →
      p.2 ∈ sources ∧ p.1 = p.2.name := by
  unfold resolve
  suffices h : ∀ (acc : ResolvedMap) (srcs : List FormulaSource),
    (∀ (q : FormulaName × FormulaSource), q ∈ acc → q.2 ∈ sources ∧ q.1 = q.2.name) →
    (∀ (s : FormulaSource), s ∈ srcs → s ∈ sources) →
    (∀ (q : FormulaName × FormulaSource),
      q ∈ srcs.foldl (fun m s => m.upsert s) acc →
      q.2 ∈ sources ∧ q.1 = q.2.name) by
    exact h [] sources (fun _ h => absurd h (List.not_mem_nil)) (fun s hs => hs)
  intro acc srcs hacc hsrcs
  induction srcs generalizing acc with
  | nil => exact hacc
  | cons hd tl ih =>
    simp only [List.foldl]
    apply ih (acc.upsert hd)
    · intro q hq
      rcases upsert_mem_or_new acc hd q hq with hq | hq
      · exact hacc q hq
      · subst hq; exact ⟨hsrcs hd (List.mem_cons_self), rfl⟩
    · intro s hs; exact hsrcs s (List.mem_cons_of_mem _ hs)

/-- If a name has an entry in the accumulator, upsert preserves some entry for it. -/
private theorem upsert_preserves_name (m : ResolvedMap) (s : FormulaSource)
    (name : FormulaName) (h : m.any (fun p => p.1 == name) = true) :
    (m.upsert s).any (fun p => p.1 == name) = true := by
  unfold ResolvedMap.upsert
  split
  · -- Update branch: m.map preserves entries for `name`
    rw [List.any_eq_true] at h ⊢
    obtain ⟨x, hx, hxeq⟩ := h
    -- The mapped version of x still has key == name
    refine ⟨_, List.mem_map.mpr ⟨x, hx, rfl⟩, ?_⟩
    -- Whether or not x matches s.name, the key is preserved or becomes s.name
    split
    · -- x was replaced: key becomes s.name = name (since x.1 = name = s.name from match)
      rename_i hcond
      have : x.1 = s.name := by
        rcases Bool.and_eq_true_iff.mp hcond with ⟨h1, _⟩; exact beq_iff_eq.mp h1
      rw [beq_iff_eq] at hxeq ⊢
      rw [this] at hxeq; exact hxeq
    · -- x was kept: key stays x.1
      exact hxeq
  · -- Insert branch: m ++ [(s.name, s)]. m already had `name`, so it's still there.
    rw [List.any_append]
    simp only [h, Bool.true_or]

/-- After processing a source s, the resolved map has an entry for s.name. -/
private theorem upsert_has_name (m : ResolvedMap) (s : FormulaSource) :
    (m.upsert s).any (fun p => p.1 == s.name) = true := by
  unfold ResolvedMap.upsert
  split
  · -- Update branch: some entry had key == s.name; map preserves or replaces it
    rename_i hany
    rw [List.any_eq_true] at hany ⊢
    obtain ⟨x, hx, hxeq⟩ := hany
    refine ⟨_, List.mem_map.mpr ⟨x, hx, rfl⟩, ?_⟩
    split
    · simp only [beq_self_eq_true]
    · exact hxeq
  · -- Insert branch: we append (s.name, s)
    rw [List.any_append]
    simp only [List.any_cons, beq_self_eq_true, List.any_nil, Bool.or_false, Bool.or_true]

/-- Folding upsert preserves an existing name entry. -/
private theorem foldl_upsert_preserves_name (acc : ResolvedMap) (srcs : List FormulaSource)
    (name : FormulaName) (h : acc.any (fun p => p.1 == name) = true) :
    (srcs.foldl (fun m t => m.upsert t) acc).any (fun p => p.1 == name) = true := by
  induction srcs generalizing acc with
  | nil => exact h
  | cons shd stl sih =>
    simp only [List.foldl]
    exact sih (acc.upsert shd) (upsert_preserves_name acc shd name h)

/-- Folding upsert over a list containing s produces an entry for s.name. -/
private theorem foldl_upsert_has_name (acc : ResolvedMap) (srcs : List FormulaSource)
    (s : FormulaSource) (hs : s ∈ srcs) :
    (srcs.foldl (fun m t => m.upsert t) acc).any (fun p => p.1 == s.name) = true := by
  induction srcs generalizing acc with
  | nil => contradiction
  | cons hd tl ih =>
    simp only [List.foldl]
    rcases List.mem_cons.mp hs with rfl | hs
    · exact foldl_upsert_preserves_name _ tl s.name (upsert_has_name acc s)
    · exact ih (acc.upsert hd) hs

/-- After resolve, every source name has an entry. -/
private theorem resolve_has_all_names (sources : List FormulaSource)
    (s : FormulaSource) (hs : s ∈ sources) :
    (resolve sources).any (fun p => p.1 == s.name) = true := by
  exact foldl_upsert_has_name [] sources s hs

/-- After upsert of s, every entry with key s.name has priority ≥ s.priority. -/
private theorem upsert_entry_priority (m : ResolvedMap) (s : FormulaSource)
    (p : FormulaName × FormulaSource)
    (hp : p ∈ m.upsert s) (hname : p.1 = s.name) :
    p.2.priority ≥ s.priority := by
  rcases upsert_mem_or_new m s p hp with hp' | hp'
  · -- p ∈ m with p.1 = s.name. In the update branch, p was kept, meaning
    -- the condition was false: ¬(p.1 == s.name ∧ s.priority ≥ p.2.priority).
    -- Since p.1 == s.name is true, s.priority < p.2.priority.
    -- But wait: if we're in the update branch and p ∈ m, the map result contains
    -- f(p) not p. upsert_mem_or_new says p ∈ m when f(p) = p (condition false).
    -- So p.1 = s.name with condition false means s.priority < p.2.priority.
    -- Actually, upsert_mem_or_new proves p ∈ m by taking the `else` branch.
    -- In the update case with condition false for entry p': f(p') = p' ∈ m.
    -- But p'.1 = s.name, so the beq check is true, hence the decide check must be false.
    -- So ¬(s.priority ≥ p'.2.priority), meaning s.priority < p'.2.priority.
    -- In the insert case: p ∈ m, p.1 = s.name, but m has no entry for s.name — contradiction.
    unfold ResolvedMap.upsert at hp
    split at hp
    · -- Update branch: p ∈ m.map ...
      -- p ∈ m means p = f(p) for some entry, but also f(p) ∈ mapped list.
      -- Since p ∈ m, f(p) is either (s.name, s) (if condition true) or p (if false).
      -- But p is also the result of f applied to SOME entry, which gave p.
      -- The path through upsert_mem_or_new that gave us hp' : p ∈ m means the
      -- condition was false for the preimage. So hname says p.1 = s.name but
      -- condition was false, meaning s.priority < p.2.priority.
      -- Let me use hp' : p ∈ m and hname directly.
      -- Since p ∈ m and p.1 = s.name, we're in the update branch.
      -- p appears as f(p) in the map. f(p) = p means the condition was false for p.
      -- The condition is p.1 == s.name && s.priority ≥ p.2.priority.
      -- p.1 == s.name is true (from hname). So decide(s.priority ≥ p.2.priority) is false.
      -- Hence s.priority < p.2.priority, so p.2.priority > s.priority ≥ s.priority.
      -- But wait: how do we know f(p) = p? We know p ∈ m from upsert_mem_or_new,
      -- but that doesn't mean f(p) = p. It means there exists some p' with f(p') = p and p ∈ m.
      -- Hmm, upsert_mem_or_new says: if condition false then f(p') = p', so p' ∈ m. It returns p' ∈ m.
      -- But p' could be different from p. Actually no: f(p') = p and f(p') = p' (condition false),
      -- so p = p'. OK so we do have f(p) = p.
      -- Now: p.1 == s.name is true. The condition being false means:
      -- ¬(p.1 == s.name && decide(s.priority ≥ p.2.priority) = true)
      -- Since p.1 == s.name = true, this means ¬(decide(s.priority ≥ p.2.priority) = true)
      -- i.e., s.priority < p.2.priority, so p.2.priority ≥ s.priority + 1 ≥ s.priority.
      -- But how to extract this? Let me just work with the map structure directly.
      obtain ⟨p', hp'mem, hfp'⟩ := List.mem_map.mp hp
      by_cases hcond : (p'.1 == s.name && decide (s.priority ≥ p'.2.priority)) = true
      · -- f(p') = (s.name, s), hfp' says this = p
        simp only [hcond, ite_true] at hfp'
        rw [← hfp']; exact Nat.le_refl _
      · -- f(p') = p', so p' = p
        simp only [hcond] at hfp'
        rw [← hfp'] at hname
        have hbeq : (p'.1 == s.name) = true := beq_iff_eq.mpr hname
        simp only [hbeq, Bool.true_and, decide_eq_true_eq] at hcond
        rw [← hfp']
        exact Nat.le_of_lt (Nat.lt_of_not_le hcond)
    · -- Insert branch: p ∈ m ++ [(s.name, s)]
      rename_i hany
      -- p ∈ m (from hp'), p.1 = s.name, but m has no entry for s.name
      exfalso; apply hany
      rw [List.any_eq_true]
      exact ⟨p, hp', beq_iff_eq.mpr hname⟩
  · -- p = (s.name, s): priority = s.priority
    subst hp'; exact Nat.le_refl _

/-- Upsert never decreases entry priority: if all entries for `name` had priority ≥ minp
    and the name exists in the map, then after upsert, entries for `name` still have
    priority ≥ minp. (Because upsert replaces only when new priority ≥ old priority.) -/
private theorem upsert_entry_priority_stable (m : ResolvedMap) (t : FormulaSource)
    (name : FormulaName) (minp : Nat)
    (hexists : m.any (fun p => p.1 == name) = true)
    (hprio : ∀ p : FormulaName × FormulaSource, p ∈ m → p.1 = name → p.2.priority ≥ minp)
    (p : FormulaName × FormulaSource)
    (hp : p ∈ m.upsert t) (hpname : p.1 = name) :
    p.2.priority ≥ minp := by
  rcases upsert_mem_or_new m t p hp with hp' | hp'
  · exact hprio p hp' hpname
  · -- p = (t.name, t), hpname : t.name = name
    subst hp'
    simp only at hpname
    -- Need: t.priority ≥ minp
    -- t replaced some existing entry. In the update branch, condition was true for some x:
    -- t.priority ≥ x.2.priority and x.1 = t.name = name, so x.2.priority ≥ minp, hence t.priority ≥ minp.
    -- In the insert branch: m has no entry for t.name = name, contradicting hexists.
    unfold ResolvedMap.upsert at hp
    split at hp
    · -- Update branch
      obtain ⟨x, hx, hfx⟩ := List.mem_map.mp hp
      by_cases hcond : (x.1 == t.name && decide (t.priority ≥ x.2.priority)) = true
      · simp only [hcond, ite_true] at hfx
        -- hfx : (t.name, t) = (t.name, t). x had condition true.
        have hxname : x.1 = name := by
          rcases Bool.and_eq_true_iff.mp hcond with ⟨h1, _⟩
          rw [beq_iff_eq] at h1; rw [h1, hpname]
        have hxp := hprio x hx hxname
        rcases Bool.and_eq_true_iff.mp hcond with ⟨_, h2⟩
        simp only [decide_eq_true_eq] at h2
        exact Nat.le_trans hxp h2
      · -- Condition false: f(x) = x, and hfx says x = (t.name, t)
        simp only [hcond] at hfx
        subst hfx
        exact hprio (t.name, t) hx hpname
    · -- Insert branch: contradicts hexists
      rename_i hany
      exfalso; apply hany
      rw [List.any_eq_true] at hexists ⊢
      obtain ⟨x, hx, hxeq⟩ := hexists
      rw [beq_iff_eq] at hxeq
      exact ⟨x, hx, by rw [beq_iff_eq]; rw [hxeq, ← hpname]⟩

/-- Folding upsert preserves priority ≥ minp for a name. Once an entry for `name`
    has priority ≥ minp, it stays ≥ minp through any number of upserts. -/
private theorem foldl_upsert_priority_stable (acc : ResolvedMap) (srcs : List FormulaSource)
    (name : FormulaName) (minp : Nat)
    (hexists : acc.any (fun p => p.1 == name) = true)
    (hprio : ∀ p : FormulaName × FormulaSource, p ∈ acc → p.1 = name → p.2.priority ≥ minp) :
    ∀ p : FormulaName × FormulaSource,
      p ∈ srcs.foldl (fun m t => m.upsert t) acc → p.1 = name → p.2.priority ≥ minp := by
  induction srcs generalizing acc with
  | nil => exact hprio
  | cons hd tl ih =>
    simp only [List.foldl]
    apply ih (acc.upsert hd)
    · exact upsert_preserves_name acc hd name hexists
    · exact upsert_entry_priority_stable acc hd name minp hexists hprio

/-! ====================================================================
    RESOLVE PROPERTIES (the 4 required theorems)
    ==================================================================== -/

/-- When the accumulator has no entry for s.name, upsert appends. -/
private theorem upsert_of_not_any (acc : ResolvedMap) (s : FormulaSource)
    (h : ¬(acc.any (fun p => p.1 == s.name) = true)) :
    acc.upsert s = acc ++ [(s.name, s)] := by
  unfold ResolvedMap.upsert
  split
  · rename_i hany; exact absurd hany h
  · rfl

/-- Folding upsert over sources with distinct names (disjoint from acc) just appends.
    Uses Pairwise for key uniqueness in entries (stronger than same-key-implies-same-element). -/
private theorem foldl_upsert_append (acc : ResolvedMap) (entries : List (FormulaName × FormulaSource))
    (hkey : ∀ p : FormulaName × FormulaSource, p ∈ entries → p.1 = p.2.name)
    (hdisjoint : ∀ a : FormulaName × FormulaSource, a ∈ acc →
      ∀ b : FormulaName × FormulaSource, b ∈ entries → a.1 ≠ b.1)
    (hpairwise : entries.Pairwise (fun a b => a.1 ≠ b.1)) :
    (entries.map (·.2)).foldl (fun m s => m.upsert s) acc = acc ++ entries := by
  induction entries generalizing acc with
  | nil => simp only [List.map_nil, List.foldl, List.append_nil]
  | cons hd tl ih =>
    simp only [List.map_cons, List.foldl]
    have hhd_key := hkey hd (List.mem_cons_self)
    rw [List.pairwise_cons] at hpairwise
    obtain ⟨hpw_hd, hpw_tl⟩ := hpairwise
    -- acc has no entry for hd.2.name = hd.1
    have hno_any : ¬(acc.any (fun p => p.1 == hd.2.name) = true) := by
      intro hany
      rw [List.any_eq_true] at hany
      obtain ⟨x, hx, hxeq⟩ := hany
      rw [beq_iff_eq] at hxeq
      exact hdisjoint x hx hd (List.mem_cons_self) (hxeq.trans hhd_key.symm)
    rw [upsert_of_not_any acc hd.2 hno_any]
    have hhd_eq : (hd.2.name, hd.2) = hd := by rw [← hhd_key]
    rw [hhd_eq]
    -- Goal: foldl upsert (acc ++ [hd]) (tl.map (·.2)) = acc ++ hd :: tl
    -- Apply ih with acc' = acc ++ [hd]
    have hdisjoint' : ∀ a : FormulaName × FormulaSource, a ∈ (acc ++ [hd]) →
        ∀ b : FormulaName × FormulaSource, b ∈ tl → a.1 ≠ b.1 := by
      intro a ha b hb
      rcases List.mem_append.mp ha with ha | ha
      · exact hdisjoint a ha b (List.mem_cons_of_mem _ hb)
      · have := List.mem_singleton.mp ha; subst this
        exact fun heq => hpw_hd b hb heq
    rw [ih (acc ++ [hd]) (fun p hp => hkey p (List.mem_cons_of_mem _ hp)) hdisjoint' hpw_tl]
    simp only [List.append_assoc, List.singleton_append]

/-- The upsert map function preserves the key of each entry. -/
private theorem upsert_map_key (s : FormulaSource) (p : FormulaName × FormulaSource) :
    (if (p.1 == s.name && decide (s.priority ≥ p.2.priority)) = true
     then (s.name, s) else p).1 = p.1 := by
  split
  · rename_i hcond
    rcases Bool.and_eq_true_iff.mp hcond with ⟨h1, _⟩
    rw [beq_iff_eq] at h1; exact h1.symm
  · rfl

/-- upsert preserves Pairwise key disjointness. -/
private theorem upsert_preserves_pairwise (m : ResolvedMap) (s : FormulaSource)
    (hpw : m.Pairwise (fun a b => a.1 ≠ b.1)) :
    (m.upsert s).Pairwise (fun a b => a.1 ≠ b.1) := by
  unfold ResolvedMap.upsert
  split
  · -- Update branch: m.map preserves keys (upsert_map_key), so pairwise is preserved
    rw [List.pairwise_map]
    exact hpw.imp (fun {a b} (hab : a.1 ≠ b.1) =>
      show (if _ then _ else a).1 ≠ (if _ then _ else b).1 by
        rw [upsert_map_key s a, upsert_map_key s b]; exact hab)
  · -- Insert branch: append preserves pairwise if new key is fresh
    rename_i hany
    rw [List.pairwise_append]
    refine ⟨hpw, List.pairwise_singleton _ _, ?_⟩
    intro a ha b hb
    have := List.mem_singleton.mp hb; subst this
    intro heq
    apply hany
    rw [List.any_eq_true]
    exact ⟨a, ha, beq_iff_eq.mpr heq⟩

/-- resolve produces a Pairwise-distinct-keys list. -/
private theorem resolve_pairwise_keys (sources : List FormulaSource) :
    (resolve sources).Pairwise (fun a b => a.1 ≠ b.1) := by
  unfold resolve
  suffices h : ∀ (acc : ResolvedMap) (srcs : List FormulaSource),
    acc.Pairwise (fun a b => a.1 ≠ b.1) →
    (srcs.foldl (fun m s => m.upsert s) acc).Pairwise (fun a b => a.1 ≠ b.1) by
    exact h [] sources List.Pairwise.nil
  intro acc srcs hpw
  induction srcs generalizing acc with
  | nil => exact hpw
  | cons hd tl ih =>
    simp only [List.foldl]
    exact ih (acc.upsert hd) (upsert_preserves_pairwise acc hd hpw)

/-- **Property 1**: Resolving already-resolved sources is stable (idempotent).
    Models the idempotent property of ResolveFormulas: correct symlinks
    are left alone, stale ones are updated. -/
theorem resolve_idempotent (sources : List FormulaSource) :
    resolve (resolve sources).values = resolve sources := by
  have huniq := resolve_unique_keys sources
  have hkey := resolve_entry_from_source sources
  have hpw := resolve_pairwise_keys sources
  unfold resolve ResolvedMap.values
  exact foldl_upsert_append [] (resolve sources)
    (fun p hp => (hkey p hp).2)
    (fun a ha => absurd ha (List.not_mem_nil))
    hpw

/-- **Property 2**: The highest-priority source for each name wins. -/
theorem higher_priority_wins (sources : List FormulaSource)
    (s : FormulaSource) (hs : s ∈ sources)
    (_hmax : ∀ (t : FormulaSource), t ∈ sources → t.name = s.name →
      t.priority ≤ s.priority) :
    ∃ p ∈ resolve sources, p.2.name = s.name ∧ p.2.priority ≥ s.priority := by
  -- From resolve_has_all_names, we know there's an entry for s.name
  have hhas := resolve_has_all_names sources s hs
  rw [List.any_eq_true] at hhas
  obtain ⟨p, hp, hpname⟩ := hhas
  rw [beq_iff_eq] at hpname
  -- From resolve_entry_from_source, the entry has key = source.name
  have ⟨_, hkey⟩ := resolve_entry_from_source sources p hp
  refine ⟨p, hp, hkey ▸ hpname, ?_⟩
  -- Main challenge: show p.2.priority ≥ s.priority
  -- After processing s in the fold, entry for s.name has priority ≥ s.priority.
  -- Subsequent upserts never decrease it (upsert_entry_priority_stable).
  -- We prove this by splitting the source list at s.
  obtain ⟨before, after, hsplit⟩ := List.append_of_mem hs
  unfold resolve at hp
  -- sources = before ++ s :: after
  -- foldl over (before ++ s :: after):
  -- = foldl f (foldl f [] before) (s :: after)
  -- = foldl f ((foldl f [] before).upsert s) after
  rw [hsplit, List.foldl_append, List.foldl] at hp
  -- hp : p ∈ after.foldl ... ((before.foldl ... []).upsert s)
  let accBefore : ResolvedMap := before.foldl (fun m t => m.upsert t) []
  have hprio : ∀ q : FormulaName × FormulaSource,
      q ∈ accBefore.upsert s → q.1 = s.name → q.2.priority ≥ s.priority :=
    fun q hq hqn => upsert_entry_priority accBefore s q hq hqn
  have hexists := upsert_has_name accBefore s
  exact foldl_upsert_priority_stable (accBefore.upsert s) after s.name s.priority
    hexists hprio p hp hpname

/-! ====================================================================
    PART 2: RECIPE AND MOLECULE TYPES
    ==================================================================== -/

/-- Bead type for molecule instantiation. -/
inductive BeadType where
  | task | bug | molecule | wisp | convoy | mail
  deriving Repr, DecidableEq, BEq

/-- A compiled recipe step. -/
structure RecipeStep where
  id           : StepId
  title        : String
  isRoot       : Bool
  parentStepId : Option StepId
  deriving Repr, DecidableEq, BEq

/-- A bead created during molecule instantiation. -/
structure MolBead where
  id       : BeadId
  title    : String
  beadType : BeadType
  parentId : Option BeadId
  stepRef  : StepId
  deriving Repr, DecidableEq, BEq

/-- A recipe: named list of steps where Steps[0] is the root. -/
structure Recipe where
  name  : FormulaName
  steps : List RecipeStep
  deriving Repr

/-- ID mapping built during instantiation. -/
abbrev IdMapping := List (StepId × BeadId)

/-- Look up a step ID in the mapping. -/
def IdMapping.lookup (m : IdMapping) (sid : StepId) : Option BeadId :=
  (m.find? (fun p => p.1 == sid)).map (·.2)

/-- Instantiation state threaded through the fold. -/
structure InstState where
  beads   : List MolBead
  nextId  : BeadId
  mapping : IdMapping
  deriving Repr

/-- Process one recipe step into a bead. -/
def processStep (st : InstState) (step : RecipeStep) : InstState :=
  let beadType := if step.isRoot then BeadType.molecule else BeadType.task
  let parentBeadId := match step.parentStepId with
    | some pid => st.mapping.lookup pid
    | none     => none
  let bead : MolBead := {
    id       := st.nextId
    title    := step.title
    beadType := beadType
    parentId := parentBeadId
    stepRef  := step.id
  }
  { beads   := st.beads ++ [bead]
    nextId  := st.nextId + 1
    mapping := st.mapping ++ [(step.id, st.nextId)] }

/-- Instantiate a recipe into molecule beads. -/
def instantiate (recipe : Recipe) (startId : BeadId) : List MolBead :=
  (recipe.steps.foldl processStep
    { beads := [], nextId := startId, mapping := [] }).beads

/-! ====================================================================
    MOLECULE HELPER LEMMAS
    ==================================================================== -/

/-- processStep appends exactly one bead. -/
theorem processStep_beads (st : InstState) (step : RecipeStep) :
    (processStep st step).beads = st.beads ++ [{
      id       := st.nextId
      title    := step.title
      beadType := if step.isRoot then BeadType.molecule else BeadType.task
      parentId := match step.parentStepId with
                  | some pid => st.mapping.lookup pid
                  | none     => none
      stepRef  := step.id
    }] := rfl

/-- processStep increments nextId. -/
theorem processStep_nextId (st : InstState) (step : RecipeStep) :
    (processStep st step).nextId = st.nextId + 1 := rfl

/-- processStep extends the mapping. -/
theorem processStep_mapping (st : InstState) (step : RecipeStep) :
    (processStep st step).mapping = st.mapping ++ [(step.id, st.nextId)] := rfl

/-- Folding processStep preserves all existing beads. -/
theorem foldl_processStep_preserves (acc : InstState) (steps : List RecipeStep)
    (b : MolBead) (hb : b ∈ acc.beads) :
    b ∈ (steps.foldl processStep acc).beads := by
  induction steps generalizing acc with
  | nil => exact hb
  | cons hd tl ih =>
    simp only [List.foldl]
    exact ih (processStep acc hd) (by rw [processStep_beads]; exact List.mem_append_left _ hb)

/-! ====================================================================
    MOLECULE PROPERTIES
    ==================================================================== -/

/-- **Property 3**: The root bead of an instantiated molecule has type `.molecule`.
    Models line 128 of molecule.go: `b.Type = "molecule"`. -/
theorem molecule_root_type (recipe : Recipe) (startId : BeadId)
    (hd : RecipeStep) (tl : List RecipeStep)
    (hsteps : recipe.steps = hd :: tl)
    (hroot : hd.isRoot = true) :
    ∃ b ∈ instantiate recipe startId,
      b.stepRef = hd.id ∧ b.beadType = .molecule := by
  unfold instantiate
  rw [hsteps]
  simp only [List.foldl]
  -- First show the bead exists in processStep result, then lift via fold preservation
  suffices h : ∃ b ∈ (processStep { beads := [], nextId := startId, mapping := [] } hd).beads,
      b.stepRef = hd.id ∧ b.beadType = .molecule by
    obtain ⟨b, hb, href, htyp⟩ := h
    exact ⟨b, foldl_processStep_preserves _ tl b hb, href, htyp⟩
  rw [processStep_beads]
  simp only [List.nil_append]
  exact ⟨_, List.mem_singleton.mpr rfl, rfl, by simp [hroot]⟩

/-- Folding processStep extends the mapping with each step's ID. -/
private theorem foldl_processStep_mapping_has (acc : InstState) (steps : List RecipeStep)
    (step : RecipeStep) (hstep : step ∈ steps) :
    ∃ bid, (step.id, bid) ∈ (steps.foldl processStep acc).mapping := by
  induction steps generalizing acc with
  | nil => contradiction
  | cons hd tl ih =>
    simp only [List.foldl]
    rcases List.mem_cons.mp hstep with rfl | hs
    · -- step = hd: processStep adds (hd.id, acc.nextId) to mapping
      refine ⟨acc.nextId, ?_⟩
      -- After processStep, the mapping contains (hd.id, acc.nextId)
      -- The fold over tl only appends more entries
      suffices hpres : ∀ (st : InstState) (rest : List RecipeStep)
          (p : StepId × BeadId) (hp : p ∈ st.mapping),
          p ∈ (rest.foldl processStep st).mapping by
        apply hpres
        rw [processStep_mapping]
        exact List.mem_append.mpr (Or.inr (List.mem_singleton.mpr rfl))
      intro st rest p hp
      induction rest generalizing st with
      | nil => exact hp
      | cons rhd rtl rih =>
        simp only [List.foldl]
        apply rih
        rw [processStep_mapping]
        exact List.mem_append.mpr (Or.inl hp)
    · exact ih (processStep acc hd) hs

/-- **Property 4**: Every non-root step whose parentStepId refers to an earlier
    step gets a parentId pointing to the corresponding bead.

    Simplified statement: if a step has parentStepId = some pid and pid
    appears earlier in the step list, then the instantiated bead for that
    step has a non-none parentId.

    Models lines 144-152 of molecule.go: non-root beads resolve ParentID
    from the parent-child deps using the ID mapping built during the fold. -/
theorem molecule_steps_parent (recipe : Recipe) (startId : BeadId)
    (before : List RecipeStep) (step : RecipeStep) (after : List RecipeStep)
    (hsteps : recipe.steps = before ++ [step] ++ after)
    (_hnotroot : step.isRoot = false)
    (parentStep : RecipeStep) (hparent : parentStep ∈ before)
    (hpid : step.parentStepId = some parentStep.id) :
    ∃ b ∈ instantiate recipe startId,
      b.stepRef = step.id ∧ b.parentId ≠ none := by
  unfold instantiate
  rw [hsteps]
  simp only [List.foldl_append, List.foldl]
  -- After folding `before`, the mapping contains parentStep.id → some beadId.
  let accBefore := before.foldl processStep { beads := [], nextId := startId, mapping := [] }
  -- parentStep was processed during the fold over `before`, so its id is in mapping.
  have ⟨parentBeadId, hparentInMap⟩ := foldl_processStep_mapping_has
    { beads := [], nextId := startId, mapping := [] } before parentStep hparent
  -- The lookup succeeds: find? finds some matching entry
  have hlookup : (accBefore.mapping.find? (fun p => p.1 == parentStep.id)).isSome = true := by
    rw [List.find?_isSome]
    exact ⟨(parentStep.id, parentBeadId), hparentInMap, by simp only [beq_iff_eq]⟩
  -- The lookup for parentStep.id succeeds, so processStep creates a bead with parentId ≠ none
  have hlookup_some : (accBefore.mapping.lookup parentStep.id).isSome = true := by
    unfold IdMapping.lookup
    rw [Option.isSome_map]; exact hlookup
  -- Get the actual value
  obtain ⟨parentBid, hparentBid⟩ := Option.isSome_iff_exists.mp hlookup_some
  -- The bead created by processStep for `step`
  have hbead_parentId : (processStep accBefore step).beads =
      accBefore.beads ++ [{
        id := accBefore.nextId
        title := step.title
        beadType := if step.isRoot then BeadType.molecule else BeadType.task
        parentId := match step.parentStepId with
                    | some pid => accBefore.mapping.lookup pid
                    | none => none
        stepRef := step.id
      }] := processStep_beads accBefore step
  -- The bead for `step` has parentId = accBefore.mapping.lookup parentStep.id = some parentBid ≠ none
  have hparentId : (match step.parentStepId with
      | some pid => accBefore.mapping.lookup pid
      | none => none) = some parentBid := by
    rw [hpid]; exact hparentBid
  -- The bead is in processStep result
  let theBead : MolBead := {
    id := accBefore.nextId
    title := step.title
    beadType := if step.isRoot then BeadType.molecule else BeadType.task
    parentId := some parentBid
    stepRef := step.id
  }
  have hbead_mem : theBead ∈ (processStep accBefore step).beads := by
    rw [hbead_parentId]
    apply List.mem_append.mpr
    right
    apply List.mem_singleton.mpr
    simp only [hparentId]; rfl
  -- The bead is preserved through folding `after`
  have hfinal_mem : theBead ∈ (after.foldl processStep (processStep accBefore step)).beads :=
    foldl_processStep_preserves _ after theBead hbead_mem
  exact ⟨theBead, hfinal_mem, rfl, by simp⟩

end GasCity.Formulas
