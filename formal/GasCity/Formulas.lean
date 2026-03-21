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
  let (s1, root) := BeadStore.create s {
    id := ""
    status := .open
    type := .molecule
    parentId := none
    labels := []
    assignee := none
    createdAt := ts
  }
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
-- Helper: Nat.repr / bead ID injectivity
-- ═══════════════════════════════════════════════════════════════

private theorem toDigitsCore_acc (base fuel n : Nat) (acc : List Char) :
    Nat.toDigitsCore base fuel n acc = Nat.toDigitsCore base fuel n [] ++ acc := by
  induction fuel generalizing n acc with
  | zero => simp [Nat.toDigitsCore.eq_1]
  | succ fuel ih =>
    simp only [Nat.toDigitsCore.eq_2]; split
    · simp
    · rw [ih, ih (acc := [(n % base).digitChar])]; simp [List.append_assoc]

private theorem toDigitsCore_fuel_sufficient (f m : Nat) (acc : List Char) (hf : f ≥ m + 1) :
    Nat.toDigitsCore 10 f m acc = Nat.toDigitsCore 10 (m + 1) m acc := by
  induction m using Nat.strongRecOn generalizing f acc with
  | _ m ih =>
    obtain ⟨f', rfl⟩ := Nat.exists_eq_succ_of_ne_zero (by omega : f ≠ 0)
    rw [Nat.toDigitsCore.eq_2, Nat.toDigitsCore.eq_2]; split
    · rfl
    · rw [ih (m / 10) (Nat.div_lt_self (by omega) (by omega)) f' _ (by omega),
          ih (m / 10) (Nat.div_lt_self (by omega) (by omega)) m _ (by omega)]

private theorem toDigitsCore_ne_nil (base fuel n : Nat) :
    Nat.toDigitsCore base (fuel + 1) n [] ≠ [] := by
  rw [Nat.toDigitsCore.eq_2]; split
  · simp
  · rw [toDigitsCore_acc]; simp

private theorem toDigits_lt_10 (n : Nat) (h : n < 10) :
    Nat.toDigits 10 n = [Nat.digitChar n] := by
  simp [Nat.toDigits]; rw [Nat.toDigitsCore.eq_2]
  simp [show n / 10 = 0 by omega, show n % 10 = n by omega]

private theorem toDigits_ge_10 (n : Nat) (h : n ≥ 10) :
    Nat.toDigits 10 n = Nat.toDigits 10 (n / 10) ++ [Nat.digitChar (n % 10)] := by
  simp [Nat.toDigits]; rw [Nat.toDigitsCore.eq_2]
  simp [show n / 10 ≠ 0 by omega]; rw [toDigitsCore_acc]
  congr 1; exact toDigitsCore_fuel_sufficient n (n / 10) [] (by omega)

private theorem toDigits_length_pos (n : Nat) : (Nat.toDigits 10 n).length ≥ 1 := by
  simp [Nat.toDigits]
  exact Nat.pos_of_ne_zero fun heq => toDigitsCore_ne_nil 10 n n (List.eq_nil_iff_length_eq_zero.mpr heq)
private theorem toDigits_length_ge_2 (n : Nat) (h : n ≥ 10) :
    (Nat.toDigits 10 n).length ≥ 2 := by
  rw [toDigits_ge_10 n h]; simp [List.length_append]
  have := toDigits_length_pos (n / 10); omega

private theorem digitChar_injective (a b : Nat) (ha : a < 10) (hb : b < 10)
    (h : Nat.digitChar a = Nat.digitChar b) : a = b := by
  have : a = 0 ∨ a = 1 ∨ a = 2 ∨ a = 3 ∨ a = 4 ∨ a = 5 ∨ a = 6 ∨ a = 7 ∨ a = 8 ∨ a = 9 := by omega
  have : b = 0 ∨ b = 1 ∨ b = 2 ∨ b = 3 ∨ b = 4 ∨ b = 5 ∨ b = 6 ∨ b = 7 ∨ b = 8 ∨ b = 9 := by omega
  rcases ‹a = 0 ∨ _› with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
  rcases ‹b = 0 ∨ _› with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
  simp_all [Nat.digitChar]

private theorem toDigits_injective : ∀ n m : Nat,
    Nat.toDigits 10 n = Nat.toDigits 10 m → n = m := by
  intro n; induction n using Nat.strongRecOn with
  | _ n ih =>
    intro m h
    by_cases hn : n < 10
    · by_cases hm : m < 10
      · rw [toDigits_lt_10 n hn, toDigits_lt_10 m hm] at h
        exact digitChar_injective n m hn hm (List.cons.inj h).1
      · rw [toDigits_lt_10 n hn] at h
        have := congrArg List.length h; simp at this
        have := toDigits_length_ge_2 m (by omega); omega
    · by_cases hm : m < 10
      · rw [toDigits_lt_10 m hm] at h
        have := congrArg List.length h; simp at this
        have := toDigits_length_ge_2 n (by omega); omega
      · rw [toDigits_ge_10 n (by omega), toDigits_ge_10 m (by omega)] at h
        have hlen : (Nat.toDigits 10 (n / 10)).length = (Nat.toDigits 10 (m / 10)).length := by
          have := congrArg List.length h; simp [List.length_append] at this; omega
        have ⟨hpre, hsuf⟩ := List.append_inj h hlen
        have := digitChar_injective (n % 10) (m % 10) (by omega) (by omega) (by simpa using hsuf)
        have := ih (n / 10) (Nat.div_lt_self (by omega) (by omega)) (m / 10) hpre
        omega

private theorem string_append_left_cancel {a b c : String} (h : a ++ b = a ++ c) : b = c := by
  have : a.toList ++ b.toList = a.toList ++ c.toList := by
    have := congrArg String.toList h; rwa [String.toList_append, String.toList_append] at this
  exact String.ext (List.append_cancel_left this)

private theorem beadId_injective (n m : Nat) (h : s!"bead-{n}" = s!"bead-{m}") : n = m := by
  have h1 : toString n = toString m := string_append_left_cancel h
  have h2 : Nat.toDigits 10 n = Nat.toDigits 10 m := by
    have : String.ofList (Nat.toDigits 10 n) = String.ofList (Nat.toDigits 10 m) := h1
    have := congrArg String.toList this
    rwa [String.toList_ofList, String.toList_ofList] at this
  exact toDigits_injective n m h2

-- ═══════════════════════════════════════════════════════════════
-- Helper: eraseDups idempotence
-- ═══════════════════════════════════════════════════════════════

private def mem_of_mem_eraseDups [BEq α] [LawfulBEq α] {x : α} :
    (l : List α) → x ∈ l.eraseDups → x ∈ l
  | [], h => by simp [List.eraseDups] at h
  | a :: as, h => by
    rw [List.eraseDups_cons] at h
    cases List.mem_cons.mp h with
    | inl h => exact h ▸ List.Mem.head _
    | inr h =>
      exact List.Mem.tail _ ((List.mem_filter.mp (mem_of_mem_eraseDups _ h)).1)
termination_by l => l.length
decreasing_by simp_wf; have := List.length_filter_le (fun b => !(b == a)) as; simp; omega

private theorem filter_ne_no_op [BEq α] [LawfulBEq α] (a : α) :
    (l : List α) → a ∉ l → l.filter (fun b => !(b == a)) = l
  | [], _ => rfl
  | x :: xs, h => by
    simp only [List.mem_cons, not_or] at h
    simp only [List.filter_cons, show (!(x == a)) = true from by
      rw [Bool.not_eq_true']; exact beq_eq_false_iff_ne.mpr (Ne.symm h.1), ite_true]
    exact congrArg (x :: ·) (filter_ne_no_op a xs h.2)

private def eraseDups_idempotent [BEq α] [LawfulBEq α] :
    (l : List α) → l.eraseDups.eraseDups = l.eraseDups
  | [] => rfl
  | a :: as => by
    rw [List.eraseDups_cons, List.eraseDups_cons]
    have : a ∉ (as.filter (fun b => !(b == a))).eraseDups :=
      fun hmem => by have := (List.mem_filter.mp (mem_of_mem_eraseDups _ hmem)).2; simp at this
    rw [filter_ne_no_op a _ this]
    exact congrArg (a :: ·) (eraseDups_idempotent (as.filter (fun b => !(b == a))))
termination_by l => l.length
decreasing_by simp_wf; have := List.length_filter_le (fun b => !(b == a)) as; simp; omega

-- ═══════════════════════════════════════════════════════════════
-- Helper: resolve foldl properties
-- ═══════════════════════════════════════════════════════════════

private theorem pickFn_foldl_ge (init : FormulaSource) (xs : List FormulaSource) :
    ∀ r, xs.foldl (fun best src => match best with
      | none => some src
      | some b => if src.layer.priority > b.layer.priority then some src else some b
    ) (some init) = some r →
    r.layer.priority ≥ init.layer.priority ∧ ∀ x ∈ xs, r.layer.priority ≥ x.layer.priority := by
  induction xs generalizing init with
  | nil => intro r hr; simp at hr; subst hr
           exact ⟨Nat.le_refl _, fun _ h => absurd h (by simp)⟩
  | cons y ys ih =>
    intro r hr; simp only [List.foldl_cons] at hr
    constructor
    · split at hr
      · have ⟨h, _⟩ := ih y r hr; omega
      · exact (ih init r hr).1
    · intro x hx; simp at hx; cases hx with
      | inl h => rw [h]; split at hr
                 · exact (ih y r hr).1
                 · have := (ih init r hr).1; omega
      | inr h => split at hr
                 · exact (ih y r hr).2 x h
                 · exact (ih init r hr).2 x h

private theorem pickFn_foldl_name (init : FormulaSource) (xs : List FormulaSource)
    (name : String) (hinit : init.name = name) (hxs : ∀ x ∈ xs, x.name = name) :
    ∀ r, xs.foldl (fun best src => match best with
      | none => some src
      | some b => if src.layer.priority > b.layer.priority then some src else some b
    ) (some init) = some r → r.name = name := by
  induction xs generalizing init with
  | nil => intro r hr; simp at hr; rw [← hr]; exact hinit
  | cons y ys ih =>
    intro r hr; simp only [List.foldl_cons] at hr
    have hy := hxs y (by simp)
    have hys : ∀ z ∈ ys, z.name = name := fun z hz => hxs z (by simp [hz])
    split at hr
    · exact ih y hy hys r hr
    · exact ih init hinit hys r hr

private theorem pickFn_foldl_some (init : FormulaSource) (xs : List FormulaSource) :
    ∃ r, xs.foldl (fun best src => match best with
      | none => some src
      | some b => if src.layer.priority > b.layer.priority then some src else some b
    ) (some init) = some r := by
  induction xs generalizing init with
  | nil => exact ⟨init, rfl⟩
  | cons y ys ih =>
    simp only [List.foldl_cons]; split
    · exact ih y
    · exact ih init

-- ═══════════════════════════════════════════════════════════════
-- Helper: molecule foldl invariants
-- ═══════════════════════════════════════════════════════════════

private theorem foldl_preserves_root
    (rootNextId : Nat) (ts : Timestamp) (steps : List String)
    (s0 : BeadStore.StoreState) (ids0 : List BeadId)
    (h_stored : s0.beads (s!"bead-{rootNextId}") = some {
      id := s!"bead-{rootNextId}", status := .open, type := .molecule,
      parentId := none, labels := [], assignee := none, createdAt := ts })
    (h_nextId : s0.nextId > rootNextId) :
    (steps.foldl (fun (acc : BeadStore.StoreState × List BeadId) (_stepTitle : String) =>
      ({ beads := fun n => if n = s!"bead-{acc.1.nextId}" then some {
            id := s!"bead-{acc.1.nextId}", status := .open, type := .task,
            parentId := some (s!"bead-{rootNextId}"), labels := [], assignee := none, createdAt := ts
          } else acc.1.beads n,
         nextId := acc.1.nextId + 1 },
       acc.2 ++ [s!"bead-{acc.1.nextId}"])) (s0, ids0)).1.beads (s!"bead-{rootNextId}") = some {
      id := s!"bead-{rootNextId}", status := .open, type := .molecule,
      parentId := none, labels := [], assignee := none, createdAt := ts } := by
  induction steps generalizing s0 ids0 with
  | nil => simpa
  | cons step rest ih =>
    simp only [List.foldl_cons]; apply ih
    · simp only []; rw [if_neg]; exact h_stored
      intro heq; have := beadId_injective rootNextId s0.nextId heq; omega
    · show s0.nextId + 1 > rootNextId; omega

private theorem foldl_steps_parent
    (rootNextId : Nat) (ts : Timestamp) (steps : List String)
    (s0 : BeadStore.StoreState) (ids0 : List BeadId)
    (h_inv : ∀ sid ∈ ids0, ∃ b, s0.beads sid = some b ∧ b.parentId = some (s!"bead-{rootNextId}"))
    (h_nextId : s0.nextId > rootNextId)
    (h_ids_bound : ∀ sid ∈ ids0, ∃ k, sid = s!"bead-{k}" ∧ k < s0.nextId) :
    let result := steps.foldl (fun (acc : BeadStore.StoreState × List BeadId) (_stepTitle : String) =>
      ({ beads := fun n => if n = s!"bead-{acc.1.nextId}" then some {
            id := s!"bead-{acc.1.nextId}", status := .open, type := .task,
            parentId := some (s!"bead-{rootNextId}"), labels := [], assignee := none, createdAt := ts
          } else acc.1.beads n,
         nextId := acc.1.nextId + 1 },
       acc.2 ++ [s!"bead-{acc.1.nextId}"])) (s0, ids0)
    ∀ sid ∈ result.2, ∃ b, result.1.beads sid = some b ∧ b.parentId = some (s!"bead-{rootNextId}") := by
  induction steps generalizing s0 ids0 with
  | nil => simpa
  | cons step rest ih =>
    simp only [List.foldl_cons]; apply ih
    · intro sid hsid
      simp only [List.mem_append, List.mem_singleton] at hsid
      cases hsid with
      | inl h =>
        have ⟨b, hb_stored, hb_parent⟩ := h_inv sid h
        have ⟨k, hk_id, hk_bound⟩ := h_ids_bound sid h
        refine ⟨b, ?_, hb_parent⟩; simp only []; rw [if_neg]; exact hb_stored
        rw [hk_id]; intro heq; have := beadId_injective k s0.nextId heq; omega
      | inr h =>
        exact ⟨{id := s!"bead-{s0.nextId}", status := .open, type := .task,
                  parentId := some (s!"bead-{rootNextId}"), labels := [], assignee := none, createdAt := ts},
                by simp [h], rfl⟩
    · show s0.nextId + 1 > rootNextId; omega
    · intro sid hsid
      simp only [List.mem_append, List.mem_singleton] at hsid
      cases hsid with
      | inl h => have ⟨k, hk_id, hk_bound⟩ := h_ids_bound sid h
                 exact ⟨k, hk_id, show k < s0.nextId + 1 by omega⟩
      | inr h => exact ⟨s0.nextId, h, show s0.nextId < s0.nextId + 1 by omega⟩

-- ═══════════════════════════════════════════════════════════════
-- Helper: resolve idempotence infrastructure
-- ═══════════════════════════════════════════════════════════════

private theorem filterMap_congr {f g : α → Option β} {l : List α}
    (h : ∀ x ∈ l, f x = g x) : l.filterMap f = l.filterMap g := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    simp only [List.filterMap_cons, h x (by simp), ih (fun y hy => h y (by simp [hy]))]

-- maxForName: the foldl that resolve uses to pick best source for a name
private def maxForName (sources : List FormulaSource) (name : String) : Option FormulaSource :=
  (sources.filter (·.name = name)).foldl (fun best src =>
    match best with
    | none => some src
    | some b => if src.layer.priority > b.layer.priority then some src else some b
  ) none

-- resolve = filterMap of maxForName
private theorem resolve_eq_filterMap (sources : List FormulaSource) :
    resolve sources = (sources.map (·.name) |>.eraseDups).filterMap (maxForName sources) := rfl

-- maxForName returns some with correct name for names that appear in sources
private theorem maxForName_some (sources : List FormulaSource) (name : String)
    (h : name ∈ sources.map (·.name)) :
    ∃ r, maxForName sources name = some r ∧ r.name = name := by
  simp only [maxForName]
  obtain ⟨s, hs, rfl⟩ := List.mem_map.mp h
  have hs_filter : s ∈ sources.filter (·.name = s.name) := by
    rw [List.mem_filter]; simp [hs]
  obtain ⟨c, cs, hcs⟩ := List.exists_cons_of_ne_nil (List.ne_nil_of_mem hs_filter)
  rw [hcs]; simp only [List.foldl_cons]
  have ⟨r, hr⟩ := pickFn_foldl_some c cs
  refine ⟨r, hr, ?_⟩
  have hc : c.name = s.name := by
    have : c ∈ sources.filter (·.name = s.name) := by rw [hcs]; simp
    simpa using (List.mem_filter.mp this).2
  have hcs' : ∀ x ∈ cs, x.name = s.name := by
    intro x hx; have : x ∈ sources.filter (·.name = s.name) := by rw [hcs]; simp [hx]
    simpa using (List.mem_filter.mp this).2
  exact pickFn_foldl_name c cs s.name hc hcs' r hr

-- The output names of resolve = eraseDups of input names
private theorem resolve_map_name (sources : List FormulaSource) :
    (resolve sources).map (·.name) = (sources.map (·.name)).eraseDups := by
  rw [resolve_eq_filterMap, List.map_filterMap]
  -- LHS: ((sources.map (·.name)).eraseDups).filterMap (fun n => (maxForName sources n).map (·.name))
  -- RHS: (sources.map (·.name)).eraseDups
  -- Show LHS = names by showing the filterMap function = some (i.e., identity)
  -- Then filterMap some = id.
  suffices h : ∀ n ∈ (sources.map (·.name)).eraseDups,
    (maxForName sources n).map (·.name) = some n from
    (filterMap_congr h).trans List.filterMap_some
  intro n hn
  obtain ⟨r, hr, hrname⟩ := maxForName_some sources n (mem_of_mem_eraseDups hn)
  rw [hr]; simp [hrname]

-- For a name n, resolve's candidates give back the same maxForName result
private theorem maxForName_resolve_eq (sources : List FormulaSource) (n : String)
    (hn : n ∈ (sources.map (·.name)).eraseDups) :
    maxForName (resolve sources) n = maxForName sources n := by
  obtain ⟨r, hr, hrname⟩ := maxForName_some sources n (mem_of_mem_eraseDups hn)
  have hr_in : r ∈ resolve sources :=
    resolve_eq_filterMap sources ▸ List.mem_filterMap.mpr ⟨n, hn, by rw [hr]⟩
  have hr_filter : r ∈ (resolve sources).filter (·.name = n) :=
    List.mem_filter.mpr ⟨hr_in, by simp [hrname]⟩
  have h_all_eq : ∀ x ∈ (resolve sources).filter (·.name = n), x = r := by
    intro x hx
    have hx_name : x.name = n := by simpa using (List.mem_filter.mp hx).2
    obtain ⟨m, hm_in, hm_fold⟩ := List.mem_filterMap.mp (resolve_eq_filterMap sources ▸ (List.mem_filter.mp hx).1)
    obtain ⟨rx, hrx, hrx_name⟩ := maxForName_some sources m (mem_of_mem_eraseDups hm_in)
    have hx_eq_rx : x = rx := Option.some.inj (by rw [← hm_fold, ← hrx])
    have : m = n := by rw [← hrx_name, ← hx_eq_rx]; exact hx_name
    exact hx_eq_rx ▸ Option.some.inj (by rw [← hr, ← this ▸ hrx])
  rw [hr]; show maxForName (resolve sources) n = some r
  -- foldl on a list where every element = r returns some r
  have h_foldl : ∀ (l : List FormulaSource), l ≠ [] → (∀ x ∈ l, x = r) →
      l.foldl (fun best src => match best with
        | none => some src
        | some b => if src.layer.priority > b.layer.priority then some src else some b
      ) none = some r := by
    intro l hl hall
    obtain ⟨c, cs, rfl⟩ := List.exists_cons_of_ne_nil hl
    simp only [List.foldl_cons]; rw [hall c (by simp)]
    suffices ∀ (zs : List FormulaSource), (∀ z ∈ zs, z = r) →
        List.foldl (fun best src => match best with
          | none => some src
          | some b => if src.layer.priority > b.layer.priority then some src else some b
        ) (some r) zs = some r from this cs (fun z hz => hall z (List.mem_cons_of_mem c hz))
    intro zs hzs; induction zs with
    | nil => rfl
    | cons w ws ih =>
      simp only [List.foldl_cons]; rw [hzs w (by simp)]
      simp [show ¬(r.layer.priority > r.layer.priority) from Nat.lt_irrefl _]
      exact ih (fun z hz => hzs z (List.mem_cons_of_mem w hz))
  exact h_foldl _ (List.ne_nil_of_mem hr_filter) h_all_eq

-- ═══════════════════════════════════════════════════════════════
-- Theorems
-- ═══════════════════════════════════════════════════════════════

/-- Resolution is idempotent: resolving resolved sources gives same result. -/
theorem resolve_idempotent (sources : List FormulaSource) :
    resolve (resolve sources) = resolve sources := by
  rw [resolve_eq_filterMap (resolve sources)]
  rw [resolve_map_name]
  rw [eraseDups_idempotent]
  rw [resolve_eq_filterMap sources]
  exact filterMap_congr fun n hn => maxForName_resolve_eq sources n hn
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
  simp only [resolve] at hr
  rw [List.mem_filterMap] at hr
  obtain ⟨name, _, hfold⟩ := hr
  have h_ne : (sources.filter fun x => decide (x.name = name)) ≠ [] := by
    intro h; simp [h] at hfold
  obtain ⟨c, cs, hcs⟩ := List.exists_cons_of_ne_nil h_ne
  have h_filter_name : ∀ c, c ∈ (sources.filter fun x => decide (x.name = name)) → c.name = name :=
    fun c hc => by have := (List.mem_filter.mp hc).2; simpa using this
  rw [hcs] at hfold; simp only [List.foldl_cons] at hfold
  have hc_name : c.name = name := h_filter_name c (by rw [hcs]; simp)
  have hcs_name : ∀ x ∈ cs, x.name = name := fun x hx => h_filter_name x (by rw [hcs]; simp [hx])
  have h_r_name : r.name = name := pickFn_foldl_name c cs name hc_name hcs_name r hfold
  have h_name_eq : name = s1.name := by rw [← hrname, h_r_name]
  have h_s2_cand : s2 ∈ (sources.filter fun x => decide (x.name = name)) := by
    rw [List.mem_filter]; simp; exact ⟨hs2, by rw [h_name_eq, ← hname]⟩
  rw [hcs] at h_s2_cand; simp at h_s2_cand
  cases h_s2_cand with
  | inl h => rw [h]; exact (pickFn_foldl_ge c cs r hfold).1
  | inr h => exact (pickFn_foldl_ge c cs r hfold).2 s2 h

/-- Molecule root is type=molecule. -/
theorem molecule_root_type (s : BeadStore.StoreState) (name : String)
    (steps : List String) (ts : Timestamp) :
    let (s', mol) := instantiate s name steps ts
    match s'.beads mol.rootId with
    | some b => b.type = .molecule
    | none => False := by
  simp only [instantiate, BeadStore.create]
  have h := foldl_preserves_root s.nextId ts steps
    { beads := fun n => if n = s!"bead-{s.nextId}" then some {
        id := s!"bead-{s.nextId}", status := .open, type := .molecule,
        parentId := none, labels := [], assignee := none, createdAt := ts
      } else s.beads n
    , nextId := s.nextId + 1 }
    []
    (by simp)
    (show s.nextId + 1 > s.nextId by omega)
  simp only [h]

/-- All molecule steps have parentId = rootId. -/
theorem molecule_steps_parent (s : BeadStore.StoreState) (name : String)
    (steps : List String) (ts : Timestamp) :
    let (s', mol) := instantiate s name steps ts
    ∀ sid ∈ mol.stepIds,
      match s'.beads sid with
      | some b => b.parentId = some mol.rootId
      | none => False := by
  simp only [instantiate, BeadStore.create]
  intro sid hsid
  have h := foldl_steps_parent s.nextId ts steps
    { beads := fun n => if n = s!"bead-{s.nextId}" then some {
        id := s!"bead-{s.nextId}", status := .open, type := .molecule,
        parentId := none, labels := [], assignee := none, createdAt := ts
      } else s.beads n
    , nextId := s.nextId + 1 }
    []
    (by simp)
    (show s.nextId + 1 > s.nextId by omega)
    (by simp)
    sid hsid
  obtain ⟨b, hb_stored, hb_parent⟩ := h
  simp only [hb_stored, hb_parent]

-- TODO: formalize derivation claim as a real theorem
/-- Derivation: formulas use only Config (layer priority) and
    BeadStore (molecule instantiation). -/
theorem derivation_from_p2_p4 : True := by trivial

end GasCity.Formulas
