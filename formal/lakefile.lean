import Lake
open Lake DSL

package stemcell where
  leanOptions := #[⟨`autoImplicit, false⟩]

-- Cell language formal model (root-level)
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

-- Gas City formal model (GasCity/ module)
lean_lib GasCity where
  roots := #[`GasCity.AgentProtocol, `GasCity.BeadStore, `GasCity.Config,
             `GasCity.Dispatch, `GasCity.EventBus, `GasCity.Formulas,
             `GasCity.HealthPatrol, `GasCity.Layering, `GasCity.PromptTemplates,
             `GasCity.PrimitiveTest]
  extraDepTargets := #[`Core]
