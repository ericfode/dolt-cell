import Lake
open Lake DSL

package stemcell where
  leanOptions := #[⟨`autoImplicit, false⟩]

@[default_target]
lean_lib StemCell

lean_lib Claims

lean_lib Retort
