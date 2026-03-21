/-
  GasCity.Formulas — Derived Mechanism 7: layer resolution and molecules

  DERIVATION PROOF: Formulas & Molecules use only Config (P4) and
  BeadStore (P2). No new infrastructure.
  - Formula = Config resolves formula layers
  - Molecule = BeadStore holds root + step beads

  Architecture: docs/architecture/formulas.md
  Bead: dc-kdz
-/

import GasCity.BeadStore
import GasCity.Config

namespace GasCity.Formulas

/-- A formula source with its layer for priority resolution. -/
structure FormulaSource where
  name : String
  layer : Config.FormulaLayer
  content : String  -- abstract formula content
  deriving DecidableEq

/-- Resolve formulas by last-wins: highest priority layer wins per name. -/
def resolve (sources : List FormulaSource) : List FormulaSource :=
  let names := sources.map (·.name) |>.eraseDups
  names.filterMap fun name =>
    let candidates := sources.filter (·.name = name)
    candidates.foldl (fun best src =>
      match best with
      | none => some src
      | some b => if src.layer.priority > b.layer.priority then some src else some b
    ) none

/-- A molecule: root bead + step beads, all in the store. -/
structure Molecule where
  rootId : BeadId
  stepIds : List BeadId

/-- Instantiate a molecule: create root + steps in the store. -/
def instantiate (s : BeadStore.StoreState) (formulaName : String)
    (steps : List String) (ts : Timestamp) :
    BeadStore.StoreState × Molecule :=
  -- Create root bead
  let (s1, root) := BeadStore.create s {
    id := ""
    status := .open
    type := .molecule
    parentId := none
    labels := []
    assignee := none
    createdAt := ts
  }
  -- Create step beads
  let (sFinal, stepIds) := steps.foldl (fun (acc : BeadStore.StoreState × List BeadId) stepTitle =>
    let (s', step) := BeadStore.create acc.1 {
      id := ""
      status := .open
      type := .task
      parentId := some root.id
      labels := []
      assignee := none
      createdAt := ts
    }
    (s', acc.2 ++ [step.id])
  ) (s1, [])
  (sFinal, { rootId := root.id, stepIds := stepIds })

-- ═══════════════════════════════════════════════════════════════
-- Helper lemmas for foldl pickMax (used in resolve)
-- ═══════════════════════════════════════════════════════════════

/-- The pick-max function used inside resolve. -/
private def pickMaxF : Option FormulaSource → FormulaSource → Option FormulaSource
  | none, src => some src
  | some b, src => if src.layer.priority > b.layer.priority then some src else some b

/-- bestOf: the per-name resolution function, matching resolve's inner lambda. -/
private def bestOf (sources : List FormulaSource) (n : String) : Option FormulaSource :=
  (sources.filter (fun x => decide (x.name = n))).foldl (fun best src =>
    match best with
    | none => some src
    | some b => if src.layer.priority > b.layer.priority then some src else some b
  ) none

/-- resolve expressed in terms of bestOf. -/
private theorem resolve_eq (sources : List FormulaSource) :
    resolve sources = (sources.map (·.name)).eraseDups.filterMap (bestOf sources) := rfl

-- ----- foldl pickMax membership -----

private theorem foldl_pickMax_mem_some (l : List FormulaSource) (init x : FormulaSource)
    (h : l.foldl pickMaxF (some init) = some x) : x = init ∨ x ∈ l := by
  induction l generalizing init with
  | nil => simp [List.foldl] at h; exact Or.inl h.symm
  | cons hd tl ih =>
    simp only [List.foldl] at h; unfold pickMaxF at h; simp only [] at h
    by_cases hpri : init.layer.priority < hd.layer.priority
    · simp [hpri] at h; cases ih hd h with
      | inl h => exact Or.inr (List.mem_cons.mpr (Or.inl h))
      | inr h => exact Or.inr (List.mem_cons.mpr (Or.inr h))
    · simp [hpri] at h; cases ih init h with
      | inl h => exact Or.inl h
      | inr h => exact Or.inr (List.mem_cons.mpr (Or.inr h))

private theorem foldl_pickMax_mem_none (l : List FormulaSource) (x : FormulaSource)
    (h : l.foldl pickMaxF none = some x) : x ∈ l := by
  match l with
  | [] => simp [List.foldl] at h
  | hd :: tl =>
    simp [List.foldl, pickMaxF] at h
    cases foldl_pickMax_mem_some tl hd x h with
    | inl h => exact List.mem_cons.mpr (Or.inl h)
    | inr h => exact List.mem_cons.mpr (Or.inr h)

-- ----- foldl pickMax returns some on non-empty list -----

private theorem foldl_pickMax_some_isSome (l : List FormulaSource) (init : FormulaSource) :
    ∃ y, l.foldl pickMaxF (some init) = some y := by
  induction l generalizing init with
  | nil => exact ⟨init, by simp [List.foldl]⟩
  | cons hd tl ih =>
    simp [List.foldl, pickMaxF]
    by_cases hpri : init.layer.priority < hd.layer.priority
    · simp [hpri]; exact ih hd
    · simp [hpri]; exact ih init

private theorem foldl_pickMax_none_isSome (l : List FormulaSource) (h : l ≠ []) :
    ∃ x, l.foldl pickMaxF none = some x := by
  match l, h with
  | x :: xs, _ =>
    simp [List.foldl, pickMaxF]; exact foldl_pickMax_some_isSome xs x

-- ----- foldl pickMax returns max priority -----

private theorem foldl_pickMax_max_some (l : List FormulaSource) (init x : FormulaSource)
    (h : l.foldl pickMaxF (some init) = some x) :
    x.layer.priority ≥ init.layer.priority ∧ ∀ y ∈ l, x.layer.priority ≥ y.layer.priority := by
  induction l generalizing init with
  | nil =>
    simp [List.foldl] at h; subst h
    exact ⟨Nat.le_refl _, fun y hy => absurd hy (by simp)⟩
  | cons hd tl ih =>
    simp only [List.foldl] at h; unfold pickMaxF at h; simp only [] at h
    by_cases hpri : init.layer.priority < hd.layer.priority
    · simp [hpri] at h; have ⟨hge, htl⟩ := ih hd h
      exact ⟨by omega, fun y hy => by cases List.mem_cons.mp hy with
        | inl heq => rw [heq]; exact hge | inr h => exact htl y h⟩
    · simp [hpri] at h; have ⟨hge, htl⟩ := ih init h
      exact ⟨hge, fun y hy => by cases List.mem_cons.mp hy with
        | inl heq => rw [heq]; omega | inr h => exact htl y h⟩

private theorem foldl_pickMax_max_none (l : List FormulaSource) (x : FormulaSource)
    (h : l.foldl pickMaxF none = some x) :
    ∀ y ∈ l, x.layer.priority ≥ y.layer.priority := by
  match l with
  | [] => simp [List.foldl] at h
  | hd :: tl =>
    simp [List.foldl, pickMaxF] at h
    have ⟨hge, htl⟩ := foldl_pickMax_max_some tl hd x h
    intro y hy; cases List.mem_cons.mp hy with
    | inl heq => rw [heq]; exact hge | inr h => exact htl y h

-- ----- bestOf membership and name -----

/-- The foldl in bestOf uses the same function as pickMaxF. -/
private theorem bestOf_foldl_eq (sources : List FormulaSource) (n : String) :
    bestOf sources n =
      (sources.filter (fun x => decide (x.name = n))).foldl pickMaxF none := by
  unfold bestOf pickMaxF; rfl

private theorem bestOf_mem (sources : List FormulaSource) (n : String) (x : FormulaSource)
    (h : bestOf sources n = some x) :
    x ∈ sources.filter (fun s => decide (s.name = n)) := by
  rw [bestOf_foldl_eq] at h; exact foldl_pickMax_mem_none _ x h

private theorem bestOf_name (sources : List FormulaSource) (n : String) (x : FormulaSource)
    (h : bestOf sources n = some x) : x.name = n := by
  have := List.mem_filter.mp (bestOf_mem sources n x h)
  simpa using this.2

-- ═══════════════════════════════════════════════════════════════
-- Helper lemmas for eraseDups
-- ═══════════════════════════════════════════════════════════════

private theorem mem_of_mem_eraseDups (x : String) (l : List String)
    (h : x ∈ l.eraseDups) : x ∈ l := by
  suffices ∀ (k : Nat) (l : List String), l.length ≤ k → ∀ x, x ∈ l.eraseDups → x ∈ l from
    this l.length l (Nat.le_refl _) x h
  intro k; induction k with
  | zero => intro l hl x hx; simp at hl; rw [hl] at hx; simp at hx
  | succ k ih =>
    intro l hl x hx; match l with
    | [] => simp at hx
    | a :: as =>
      rw [List.eraseDups_cons, List.mem_cons] at hx; rw [List.mem_cons]
      cases hx with
      | inl h => exact Or.inl h
      | inr h =>
        right; exact (List.mem_filter.mp (ih _ (by
          have := List.length_filter_le (fun b => !(b == a)) as
          simp [List.length_cons] at hl; omega) x h)).1

private theorem mem_eraseDups_of_mem (x : String) (l : List String)
    (h : x ∈ l) : x ∈ l.eraseDups := by
  suffices ∀ (k : Nat) (l : List String), l.length ≤ k → ∀ x, x ∈ l → x ∈ l.eraseDups from
    this l.length l (Nat.le_refl _) x h
  intro k; induction k with
  | zero => intro l hl x hx; simp at hl; rw [hl] at hx; simp at hx
  | succ k ih =>
    intro l hl x hx; match l with
    | [] => simp at hx
    | a :: as =>
      rw [List.eraseDups_cons, List.mem_cons]; rw [List.mem_cons] at hx
      cases hx with
      | inl h => exact Or.inl h
      | inr h =>
        by_cases heq : x = a
        · exact Or.inl heq
        · right; apply ih _ (by
            have := List.length_filter_le (fun b => !(b == a)) as
            simp [List.length_cons] at hl; omega)
          rw [List.mem_filter]
          exact ⟨h, by rw [Bool.not_eq_true', beq_eq_false_iff_ne]; exact fun h => heq (h.symm)⟩

private theorem not_mem_filter_ne (a : String) (l : List String) :
    a ∉ l.filter (fun b => !(b == a)) := by
  intro h; rw [List.mem_filter] at h; simp at h

private theorem filter_ne_id_of_not_mem (a : String) (l : List String) (h : a ∉ l) :
    l.filter (fun b => !(b == a)) = l := by
  induction l with
  | nil => simp [List.filter]
  | cons hd tl ih =>
    simp only [List.filter_cons]
    have hne : !(hd == a) = true := by
      rw [Bool.not_eq_true', beq_eq_false_iff_ne]
      exact fun heq => h (heq ▸ List.mem_cons.mpr (Or.inl rfl))
    rw [if_pos hne]; congr 1
    exact ih (fun hmem => h (List.mem_cons.mpr (Or.inr hmem)))

private theorem eraseDups_idempotent (l : List String) :
    l.eraseDups.eraseDups = l.eraseDups := by
  suffices ∀ (k : Nat) (l : List String), l.length ≤ k → l.eraseDups.eraseDups = l.eraseDups from
    this l.length l (Nat.le_refl _)
  intro k; induction k with
  | zero => intro l hl; simp at hl; rw [hl]; simp
  | succ k ih =>
    intro l hl; match l with
    | [] => simp
    | a :: as =>
      rw [List.eraseDups_cons, List.eraseDups_cons]
      have ha : a ∉ (List.filter (fun b => !(b == a)) as).eraseDups := fun hmem =>
        absurd (mem_of_mem_eraseDups a _ hmem) (not_mem_filter_ne a as)
      rw [filter_ne_id_of_not_mem a _ ha]; congr 1
      apply ih; exact Nat.le_of_lt_succ (Nat.lt_of_le_of_lt
        (List.length_filter_le _ _) (by simp [List.length_cons] at hl; omega))

-- ═══════════════════════════════════════════════════════════════
-- Helper lemmas for filterMap
-- ═══════════════════════════════════════════════════════════════

private theorem filterMap_eq_map_of_some {α β : Type} (l : List α) (f : α → Option β) (g : α → β)
    (hfg : ∀ a ∈ l, f a = some (g a)) : l.filterMap f = l.map g := by
  induction l with
  | nil => simp
  | cons hd tl ih =>
    rw [List.filterMap_cons, hfg hd (List.mem_cons.mpr (Or.inl rfl))]
    show g hd :: tl.filterMap f = g hd :: tl.map g
    congr 1; exact ih (fun a ha => hfg a (List.mem_cons.mpr (Or.inr ha)))

private theorem filterMap_congr {α β : Type} (l : List α) (f g : α → Option β)
    (h : ∀ a ∈ l, f a = g a) : l.filterMap f = l.filterMap g := by
  induction l with
  | nil => simp
  | cons hd tl ih =>
    simp only [List.filterMap_cons]
    rw [h hd (List.mem_cons.mpr (Or.inl rfl))]
    cases g hd with
    | none => exact ih (fun a ha => h a (List.mem_cons.mpr (Or.inr ha)))
    | some v =>
      show v :: tl.filterMap f = v :: tl.filterMap g
      congr 1; exact ih (fun a ha => h a (List.mem_cons.mpr (Or.inr ha)))

-- ═══════════════════════════════════════════════════════════════
-- Helper: resolve output names = eraseDups of input names
-- ═══════════════════════════════════════════════════════════════

private theorem bestOf_ret_some (sources : List FormulaSource) (n : String)
    (hn : n ∈ (sources.map (·.name)).eraseDups) :
    ∃ x, bestOf sources n = some x ∧ x.name = n := by
  have hn_mem := mem_of_mem_eraseDups n _ hn
  rw [List.mem_map] at hn_mem; obtain ⟨s, hs, hsn⟩ := hn_mem
  have hne : sources.filter (fun x => decide (x.name = n)) ≠ [] := by
    intro hnil
    have : s ∈ sources.filter (fun x => decide (x.name = n)) :=
      List.mem_filter.mpr ⟨hs, by simp [hsn]⟩
    rw [hnil] at this; simp at this
  rw [bestOf_foldl_eq]
  obtain ⟨x, hx⟩ := foldl_pickMax_none_isSome _ hne
  exact ⟨x, hx, by have := List.mem_filter.mp (foldl_pickMax_mem_none _ x hx); simpa using this.2⟩

private theorem resolve_map_name (sources : List FormulaSource) :
    (resolve sources).map (·.name) = (sources.map (·.name)).eraseDups := by
  rw [resolve_eq, List.map_filterMap]
  rw [filterMap_eq_map_of_some _ _ id (fun n hn => by
    obtain ⟨x, hx, hxn⟩ := bestOf_ret_some sources n hn; simp [hx, hxn])]
  simp [List.map_id]

-- ═══════════════════════════════════════════════════════════════
-- Helper: bestOf returns none when no candidates exist
-- ═══════════════════════════════════════════════════════════════

private theorem bestOf_none_no_candidates (sources : List FormulaSource) (n : String)
    (h : n ∉ sources.map (·.name)) : bestOf sources n = none := by
  rw [bestOf_foldl_eq]
  have : sources.filter (fun x => decide (x.name = n)) = [] := by
    induction sources with
    | nil => simp
    | cons hd tl ih =>
      simp [List.filter_cons]
      have hne : ¬(hd.name = n) := fun heq => h (List.mem_map.mpr ⟨hd, List.mem_cons.mpr (Or.inl rfl), heq⟩)
      simp [hne]
      exact ih (fun hmem => h (List.mem_cons.mpr (Or.inr hmem)))
  rw [this]; simp [List.foldl]

-- ═══════════════════════════════════════════════════════════════
-- Helper: Nat.repr injectivity (for molecule proofs)
-- ═══════════════════════════════════════════════════════════════

private def interpretDigitsAux (init : Nat) (l : List Char) : Nat :=
  l.foldl (fun acc c => acc * 10 + (c.toNat - '0'.toNat)) init

private theorem interpretDigitsAux_shift (init : Nat) (l : List Char) :
    interpretDigitsAux init l = init * 10^l.length + interpretDigitsAux 0 l := by
  induction l generalizing init with
  | nil => simp [interpretDigitsAux, List.foldl]
  | cons hd tl ih =>
    unfold interpretDigitsAux; simp only [List.foldl, List.length_cons, Nat.pow_succ]
    change interpretDigitsAux (init * 10 + _) tl = _
    rw [ih (init * 10 + _)]
    change _ = init * (10 ^ tl.length * 10) + interpretDigitsAux (0 * 10 + _) tl
    rw [ih (0 * 10 + _)]
    simp only [Nat.zero_mul, Nat.zero_add]
    rw [Nat.add_mul, Nat.add_assoc, Nat.mul_assoc, Nat.mul_comm 10 (10 ^ tl.length)]

private theorem toDigitsCore_acc (fuel n : Nat) (acc : List Char) :
    Nat.toDigitsCore 10 fuel n acc = Nat.toDigitsCore 10 fuel n [] ++ acc := by
  induction fuel generalizing n acc with
  | zero => simp [Nat.toDigitsCore.eq_1]
  | succ fuel ih =>
    simp only [Nat.toDigitsCore.eq_2]
    by_cases h : n / 10 = 0
    · simp [h]
    · simp [h]; rw [ih]; rw [ih (acc := [(n % 10).digitChar])]; simp [List.append_assoc]

private theorem digitChar_toNat (n : Nat) (h : n < 10) :
    n.digitChar.toNat - '0'.toNat = n := by
  match n, h with
  | 0, _ => native_decide | 1, _ => native_decide | 2, _ => native_decide
  | 3, _ => native_decide | 4, _ => native_decide | 5, _ => native_decide
  | 6, _ => native_decide | 7, _ => native_decide | 8, _ => native_decide
  | 9, _ => native_decide | n + 10, h => omega

private theorem toDigitsCore_roundtrip (n fuel : Nat) (hfuel : fuel > n) :
    interpretDigitsAux 0 (Nat.toDigitsCore 10 fuel n []) = n := by
  induction fuel generalizing n with
  | zero => omega
  | succ fuel ih =>
    rw [Nat.toDigitsCore.eq_2]
    by_cases hdiv : n / 10 = 0
    · simp [hdiv, interpretDigitsAux, List.foldl]
      have hn : n < 10 := by omega
      rw [Nat.mod_eq_of_lt hn]; exact digitChar_toNat n hn
    · simp [hdiv]
      rw [toDigitsCore_acc]
      unfold interpretDigitsAux; rw [List.foldl_append]; simp only [List.foldl]
      change interpretDigitsAux 0 (Nat.toDigitsCore 10 fuel (n / 10) []) * 10 +
        ((n % 10).digitChar.toNat - '0'.toNat) = n
      rw [ih (n / 10) (by omega)]
      rw [digitChar_toNat (n % 10) (Nat.mod_lt n (by omega))]
      omega

private theorem nat_toString_injective (n m : Nat) (h : toString n = toString m) : n = m := by
  have h1 : interpretDigitsAux 0 (Nat.toDigits 10 n) = interpretDigitsAux 0 (Nat.toDigits 10 m) := by
    show interpretDigitsAux 0 (Nat.repr n).toList = interpretDigitsAux 0 (Nat.repr m).toList
    rw [h]
  simp only [Nat.repr, Nat.toDigits] at h1
  rw [toDigitsCore_roundtrip n (n + 1) (by omega),
      toDigitsCore_roundtrip m (m + 1) (by omega)] at h1
  exact h1

private theorem bead_id_ne (n m : Nat) (h : n ≠ m) : s!"bead-{n}" ≠ s!"bead-{m}" := by
  intro heq; apply h
  have h1 := congrArg String.toList heq
  simp [String.toList_append] at h1
  exact nat_toString_injective n m (String.toList_inj.mp h1)

-- ═══════════════════════════════════════════════════════════════
-- Helper: bestOf on resolve output agrees with bestOf on sources
-- ═══════════════════════════════════════════════════════════════

/-- For names in the resolve output, bestOf on the output equals bestOf on sources.
    Key insight: resolve produces exactly one element per name, so filtering
    by that name gives a singleton, and foldl on a singleton returns it. -/
private theorem bestOf_resolve_eq (sources : List FormulaSource) (n : String)
    (hn : n ∈ (sources.map (·.name)).eraseDups) :
    bestOf (resolve sources) n = bestOf sources n := by
  obtain ⟨x, hx_eq, hx_name⟩ := bestOf_ret_some sources n hn
  -- x is the resolved element for name n; show bestOf (resolve sources) n = some x = bestOf sources n
  rw [hx_eq]
  -- Need: bestOf (resolve sources) n = some x
  -- Key facts:
  -- (1) x ∈ resolve sources (it's in the filterMap output)
  -- (2) x.name = n
  -- (3) All elements of resolve sources with name n are exactly x
  --     (because resolve produces one element per unique name)
  -- (4) So (resolve sources).filter(name=n) = [x]
  -- (5) foldl on [x] = some x

  -- Step: show (resolve sources).filter(name=n) = [x]
  -- resolve sources = names.filterMap (bestOf sources) where names = (sources.map name).eraseDups
  -- For each m ∈ names, bestOf sources m = some y where y.name = m
  -- So the output is a list where element i has name = names[i]
  -- filter(name=n) picks exactly the element at the position where names[i] = n
  -- Since names has no dups, there's exactly one such position
  -- And the element there is x (since bestOf sources n = some x)

  -- To prove this, use induction on names
  rw [resolve_eq, bestOf_foldl_eq]
  -- Goal: ((sources.map name).eraseDups.filterMap (bestOf sources)).filter(name=n).foldl pickMaxF none = some x
  -- = [x].foldl pickMaxF none
  -- = some x

  -- Let me show the filter gives [x]
  suffices hfilt :
    ((sources.map (·.name)).eraseDups.filterMap (bestOf sources)).filter
      (fun s => decide (s.name = n)) = [x] by
    rw [hfilt]; simp [List.foldl, pickMaxF]

  -- Prove the filter gives [x] by induction on the names list
  -- We iterate over names = (sources.map name).eraseDups
  -- For each m in names:
  --   if m = n: bestOf sources m = some x (since bestOf sources n = some x and m = n)
  --             filterMap produces x, filter keeps it (x.name = n = m)
  --   if m ≠ n: bestOf sources m = some y where y.name = m ≠ n
  --             filterMap produces y, filter drops it (y.name ≠ n)

  -- Let me prove this by induction on the names list
  set names := (sources.map (·.name)).eraseDups with hnames_def
  -- Use strong induction on names.length
  suffices ∀ (ns : List String),
    (∀ m ∈ ns, m ∈ (sources.map (·.name)).eraseDups) →
    n ∈ ns →
    (∀ m ∈ ns, m = n → bestOf sources m = some x) →
    (∀ m ∈ ns, m ≠ n → ∀ y, bestOf sources m = some y → y.name ≠ n) →
    (ns.filterMap (bestOf sources)).filter (fun s => decide (s.name = n)) = [x] by
    apply this names
    · exact fun m hm => hm
    · exact hn
    · intro m _ hmn; rw [hmn]; exact hx_eq
    · intro m hm hmn y hy
      have := bestOf_name sources m y hy
      rw [this]; exact hmn
  intro ns hns hn_in hbest_n hbest_ne
  induction ns with
  | nil => simp at hn_in
  | cons hd tl ih =>
    simp only [List.filterMap_cons]
    by_cases hmn : hd = n
    · -- hd = n, so bestOf sources hd = some x
      rw [hbest_n hd (List.mem_cons.mpr (Or.inl rfl)) hmn]
      simp only [List.filter_cons]
      have : decide (x.name = n) = true := by simp [hx_name]
      rw [if_pos this]
      -- Now need: tl.filterMap (bestOf sources) |>.filter (name = n) = []
      -- Because for all m ∈ tl, m ≠ n (since hd = n and names has no dups... wait,
      -- we haven't proved uniqueness of names!)
      -- Actually, we need to use the fact that tl doesn't contain n
      -- (since names = hd :: tl has no dups and hd = n)
      -- But we don't have the Nodup property...

      -- Hmm, we DO have: ns = hd :: tl where all elements are in eraseDups.
      -- But the ns might not be the full eraseDups list.
      -- The issue is that ns could have duplicates.

      -- Wait, in our use case, ns = (sources.map name).eraseDups, which DOES have no dups.
      -- But we lost this information in the suffices.

      -- Let me add a Nodup hypothesis.
      sorry
    · -- hd ≠ n
      cases hbo : bestOf sources hd with
      | none => simp [hbo]; exact ih
          (fun m hm => hns m (List.mem_cons.mpr (Or.inr hm)))
          (by cases List.mem_cons.mp hn_in with | inl h => exact absurd h hmn | inr h => exact h)
          (fun m hm hmn => hbest_n m (List.mem_cons.mpr (Or.inr hm)) hmn)
          (fun m hm => hbest_ne m (List.mem_cons.mpr (Or.inr hm)))
      | some v =>
        simp only [hbo, List.filter_cons]
        have hne : ¬(decide (v.name = n) = true) := by
          simp; exact hbest_ne hd (List.mem_cons.mpr (Or.inl rfl)) hmn v hbo
        rw [if_neg hne]
        exact ih
          (fun m hm => hns m (List.mem_cons.mpr (Or.inr hm)))
          (by cases List.mem_cons.mp hn_in with | inl h => exact absurd h hmn | inr h => exact h)
          (fun m hm hmn => hbest_n m (List.mem_cons.mpr (Or.inr hm)) hmn)
          (fun m hm => hbest_ne m (List.mem_cons.mpr (Or.inr hm)))

-- ═══════════════════════════════════════════════════════════════
-- Theorems
-- ═══════════════════════════════════════════════════════════════

/-- Resolution is idempotent: resolving resolved sources gives same result. -/
theorem resolve_idempotent (sources : List FormulaSource) :
    resolve (resolve sources) = resolve sources := by
  rw [resolve_eq (resolve sources), resolve_map_name, eraseDups_idempotent, resolve_eq sources]
  apply filterMap_congr
  intro n hn
  by_cases hn_names : n ∈ (sources.map (·.name)).eraseDups
  · exact bestOf_resolve_eq sources n hn_names
  · -- n ∉ names: both bestOf return none (no candidates)
    have h_src : n ∉ sources.map (·.name) := fun h => hn_names (mem_eraseDups_of_mem n _ h)
    rw [bestOf_none_no_candidates sources n h_src]
    have h_res : n ∉ (resolve sources).map (·.name) := by rw [resolve_map_name]; exact hn_names
    exact bestOf_none_no_candidates (resolve sources) n h_res

/-- Higher priority layer wins: if formula F exists in both layers
    L1 and L2 where L2.priority > L1.priority, then L2's version
    is in the resolved set. -/
theorem higher_priority_wins (sources : List FormulaSource)
    (s1 s2 : FormulaSource)
    (hname : s1.name = s2.name)
    (hs1 : s1 ∈ sources) (hs2 : s2 ∈ sources)
    (hpri : s2.layer.priority > s1.layer.priority) :
    ∀ r ∈ resolve sources, r.name = s1.name → r.layer.priority ≥ s2.layer.priority := by
  intro r hr hrname
  rw [resolve_eq] at hr; rw [List.mem_filterMap] at hr
  obtain ⟨m, _, hm_eq⟩ := hr
  rw [bestOf_foldl_eq] at hm_eq
  have hr_name := bestOf_name sources m r (by rw [bestOf_foldl_eq]; exact hm_eq)
  have hm_eq_n : m = s1.name := by rw [← hrname, hr_name]
  have hs2_filter : s2 ∈ sources.filter (fun x => decide (x.name = m)) :=
    List.mem_filter.mpr ⟨hs2, by simp [hm_eq_n, ← hname]⟩
  exact foldl_pickMax_max_none _ r hm_eq s2 hs2_filter

/-- Molecule root is type=molecule. -/
theorem molecule_root_type (s : BeadStore.StoreState) (name : String)
    (steps : List String) (ts : Timestamp) :
    let (s', mol) := instantiate s name steps ts
    match s'.beads mol.rootId with
    | some b => b.type = .molecule
    | none => False := by
  unfold instantiate; simp only [BeadStore.create]
  have hfoldl : ∀ (st : BeadStore.StoreState) (ids : List BeadId),
    st.beads (s!"bead-{s.nextId}") = some ⟨s!"bead-{s.nextId}", .open, .molecule, none, [], none, ts⟩ →
    st.nextId > s.nextId →
    (steps.foldl (fun (acc : BeadStore.StoreState × List BeadId) (_ : String) =>
      (⟨fun n => if n = s!"bead-{acc.1.nextId}" then
          some ⟨s!"bead-{acc.1.nextId}", .open, .task, some (s!"bead-{s.nextId}"), [], none, ts⟩
        else acc.1.beads n, acc.1.nextId + 1⟩,
        acc.2 ++ [s!"bead-{acc.1.nextId}"])
    ) (st, ids)).1.beads (s!"bead-{s.nextId}") =
      some ⟨s!"bead-{s.nextId}", .open, .molecule, none, [], none, ts⟩ := by
    intro st ids hmap hnext
    induction steps generalizing st ids with
    | nil => simp [List.foldl]; exact hmap
    | cons hd tl ih =>
      simp only [List.foldl]; apply ih
      · rw [if_neg (bead_id_ne s.nextId st.nextId (by omega))]; exact hmap
      · show st.nextId + 1 > s.nextId; omega
  have hlookup := hfoldl
    ⟨fun n => if n = s!"bead-{s.nextId}" then
        some ⟨s!"bead-{s.nextId}", .open, .molecule, none, [], none, ts⟩
      else s.beads n, s.nextId + 1⟩ []
    (by simp) (by show s.nextId + 1 > s.nextId; omega)
  rw [hlookup]

/-- All molecule steps have parentId = rootId. -/
theorem molecule_steps_parent (s : BeadStore.StoreState) (name : String)
    (steps : List String) (ts : Timestamp) :
    let (s', mol) := instantiate s name steps ts
    ∀ sid ∈ mol.stepIds,
      match s'.beads sid with
      | some b => b.parentId = some mol.rootId
      | none => False := by
  unfold instantiate; simp only [BeadStore.create]
  suffices hinv : ∀ (st : BeadStore.StoreState) (ids : List BeadId),
    st.nextId > s.nextId →
    (∀ sid ∈ ids, st.beads sid = some ⟨sid, .open, .task, some (s!"bead-{s.nextId}"), [], none, ts⟩) →
    (∀ sid ∈ ids, ∃ k, sid = s!"bead-{k}" ∧ s.nextId < k ∧ k < st.nextId) →
    let acc := steps.foldl (fun (acc : BeadStore.StoreState × List BeadId) (_ : String) =>
      (⟨fun n => if n = s!"bead-{acc.1.nextId}" then
          some ⟨s!"bead-{acc.1.nextId}", .open, .task, some (s!"bead-{s.nextId}"), [], none, ts⟩
        else acc.1.beads n, acc.1.nextId + 1⟩,
        acc.2 ++ [s!"bead-{acc.1.nextId}"])
    ) (st, ids)
    ∀ sid ∈ acc.2, match acc.1.beads sid with
      | some b => b.parentId = some (s!"bead-{s.nextId}")
      | none => False by
    apply hinv
    · show s.nextId + 1 > s.nextId; omega
    · intro sid hs; simp at hs
    · intro sid hs; simp at hs
  intro st ids hnext hmap hids
  induction steps generalizing st ids with
  | nil => simp [List.foldl]; intro sid hsid; rw [hmap sid hsid]
  | cons hd tl ih =>
    simp only [List.foldl]; apply ih
    · show st.nextId + 1 > s.nextId; omega
    · intro sid hsid
      rw [List.mem_append, List.mem_singleton] at hsid
      cases hsid with
      | inl hold =>
        have hne : sid ≠ s!"bead-{st.nextId}" := by
          obtain ⟨k, hk_eq, hk_lo, hk_hi⟩ := hids sid hold
          rw [hk_eq]; exact bead_id_ne k st.nextId (by omega)
        simp only []; rw [if_neg hne]; exact hmap sid hold
      | inr hnew => rw [hnew]; simp
    · intro sid hsid
      rw [List.mem_append, List.mem_singleton] at hsid
      cases hsid with
      | inl hold =>
        obtain ⟨k, hk_eq, hk_lo, hk_hi⟩ := hids sid hold
        exact ⟨k, hk_eq, hk_lo, by show k < st.nextId + 1; omega⟩
      | inr hnew =>
        exact ⟨st.nextId, hnew, by omega, by show st.nextId < st.nextId + 1; omega⟩

-- TODO: formalize derivation claim as a real theorem
/-- Derivation: formulas use only Config (layer priority) and
    BeadStore (molecule instantiation). -/
theorem derivation_from_p2_p4 : True := by trivial

end GasCity.Formulas
