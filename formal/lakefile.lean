import Lake
open Lake DSL

package stemcell where
  leanOptions := #[⟨`autoImplicit, false⟩]

@[default_target]
lean_lib StemCell

lean_lib Claims

lean_lib Core

lean_lib Retort where
  roots := #[`Retort]
  extraDepTargets := #[`Claims]

lean_lib Denotational where
  roots := #[`Denotational]

lean_lib Refinement where
  roots := #[`Refinement]

lean_lib TupleSpace where
  roots := #[`TupleSpace]

lean_lib EffectEval where
  roots := #[`EffectEval]

lean_lib Autopour where
  roots := #[`Autopour]
