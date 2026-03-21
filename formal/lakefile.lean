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

lean_lib EventBus where
  roots := #[`EventBus]
  extraDepTargets := #[`Core]

lean_lib AgentProtocol where
  roots := #[`AgentProtocol]

lean_lib PromptTemplates where
  roots := #[`PromptTemplates]

lean_lib BeadStore where
  roots := #[`BeadStore]

lean_lib HealthPatrol where
  roots := #[`HealthPatrol]

lean_lib Dispatch where
  roots := #[`Dispatch]
  extraDepTargets := #[`Core]

lean_lib Config where
  roots := #[`Config]
