# Multi-Agent Debate for LLMs: Do Debate Teams Produce Better Results?

**Research survey (do-sqoz) — March 2026**

## Executive Summary

Multi-agent debate (MAD) — where multiple LLM instances argue, critique, and
refine responses over rounds — is a popular idea but the empirical picture is
**more nuanced than the hype suggests**. The strongest recent evidence (NeurIPS
2025 Spotlight, ICLR 2025 blog post, systematic evaluations) converges on several
uncomfortable findings:

1. **MAD often fails to outperform simple baselines** like Self-Consistency
   (majority voting over independent samples), especially when controlling for
   compute budget.
2. **Model diversity is the real driver** — heterogeneous teams (different model
   families) consistently outperform homogeneous ones. Debate mechanics alone
   contribute little beyond what majority voting provides.
3. **Persona assignment is a double-edged sword** — specialized critic personas
   can improve quality, but demographic or rigid "devil's advocate" personas
   can degrade performance by up to 26%.
4. **Sparse topologies beat fully-connected** — limiting who talks to whom
   actually improves results and cuts costs by 40-50%.
5. **Diminishing returns hit at ~5 agents** — gains from 1→5 agents are large,
   5→10 diminishing, beyond 10 negligible.

---

## Q1: Does Multi-Agent Debate Produce Measurably Better Outputs?

### The Optimistic Case

The foundational paper (Du et al., ICML 2024, [2305.14325]) showed multi-agent
debate improved factuality and reasoning across math, strategy, and QA tasks.
Multiple LLM instances propose answers, see each other's reasoning, and revise
over rounds. The "society of minds" framing generated significant excitement.

ReConcile (ACL 2024, [2309.13007]) demonstrated up to **11.4% improvement** over
prior baselines and **8% improvement on MATH** by combining API-based,
open-source, and domain-specific models with confidence-weighted voting. It even
outperformed GPT-4 on three datasets.

### The Skeptical Reality

**"Stop Overvaluing Multi-Agent Debate" (NeurIPS 2025 position, [2502.08788])**
systematically evaluated 5 MAD methods across 9 benchmarks using 4 models.
Finding: MAD **often fails to outperform Chain-of-Thought and Self-Consistency**
despite consuming significantly more compute.

**"Debate or Vote" (NeurIPS 2025 Spotlight, [2508.17536])** disentangled MAD
into its components and showed **majority voting alone accounts for most of the
performance gains** typically attributed to debate. Pure debate functions as a
stochastic martingale over agent beliefs — it doesn't improve expected
correctness without deliberate bias toward correction.

**ICLR 2025 Blog Post** found SC outperformed MAD on 9 benchmarks including
MMLU, MATH, and HumanEval. On GSM8k with GPT-4o-mini: SC 95.67% vs MAD 94.93%.
The conclusion: MAD functions as "an inefficient resampling method" rather than
leveraging genuine collaborative reasoning.

**"Can LLM Agents Really Debate?" ([2511.07784])** ran controlled experiments
with Knight-Knave-Spy logic puzzles. Finding: **intrinsic reasoning strength and
group diversity are the dominant drivers**, not debate mechanics. Structural
parameters (order, confidence visibility, depth) offer limited gains.

### When Debate Helps

Debate genuinely helps when:
- **Models are heterogeneous** (different architectures/training) — this is the
  "universal antidote" identified by [2502.08788]
- **Tasks benefit from adversarial critique** (factuality checking, evaluation)
- **The correct answer is held by at least some agents** and the debate process
  surfaces it
- **Targeted interventions** bias belief updates toward correction

### When Debate Hurts

**"Talk Isn't Always Cheap" ([2509.05396])** identified critical failure modes:
- **Correct→incorrect answer flips** happen more often than the reverse
- **Social conformity** causes agents to abandon correct answers when outnumbered
- Performance **degrades over rounds** on some tasks (especially commonsense QA)
- **Heterogeneous capability teams** see weaker models drag down stronger ones
- Prompting agents to "prioritize correctness" did NOT reduce harmful flips

### Verdict on Q1

**Modest, conditional improvement.** MAD can help, but the gains largely come
from (a) sampling diverse responses and (b) having different models in the mix.
The debate process itself (argumentation, persuasion, refinement) adds little
beyond what Self-Consistency already provides. For practitioners: **try
Self-Consistency first** — it's cheaper and often matches MAD performance.

---

## Q2: Does Persona/Role Assignment Affect Quality?

### Persona Can Help (When Done Right)

**Research ideation study (SIGDIAL 2025, [2507.08350])** tested 10 dialogue
configurations across 7 research topics with 6 domain personas (Physics-AI,
Chemistry-AI, etc.). Key findings:
- **Specialized critic personas** achieved win rate of 0.55 vs baseline — the
  strongest quality gain
- **Persona on proposer/reviser** yielded highest diversity (0.81) with
  competitive precision
- **Assignment location matters more than the persona itself** — a specialized
  critic helps more than a specialized proposer
- Optimal configuration: 3 parallel critics with domain specialization

### Persona Can Hurt (Significantly)

**"From Biased Chatbots to Biased Agents" ([2602.12285])** found that
demographic-based persona assignments degraded performance by **up to 26.2%**
across strategic reasoning, planning, and technical operations. Task-irrelevant
persona cues distort decision-making.

**ICLR 2025 Blog Post** found Multi-Persona performed **worst across nearly all
datasets** — rigid "devil's advocate" roles prevented meaningful counterargument
after initial disagreement.

### Sycophancy: The Hidden Variable

**"Peacemaker or Troublemaker" ([2509.23055])** discovered sycophancy
(excessive agreement) is a critical factor:
- Strong correlation (r=0.902) between agents abandoning correct answers and
  sycophantic behavior
- **Zero sycophancy is not optimal** — best configurations combine both
  "peacemaker" and "troublemaker" roles
- Centralized topologies show ~40% disagreement collapse rate vs 60%+ for
  decentralized
- Performance gap between best/worst sycophancy configs: **5.9pp on MMLU Pro**

### Cognitive Profile Stability

Assigned personas induce stable, distinct cognitive profiles that persist
regardless of debate length. An "Evidence-Driven Analyst" consistently shows
higher cognitive effort than a "Values-Focused Ethicist" — personas do shape
reasoning pathways, for better or worse.

### Verdict on Q2

**Persona choice matters enormously, but not in the way people expect.** Domain-
expert critic personas help. Demographic or rigid adversarial personas hurt.
The key insight: **assign personas to the critic role, not the proposer role**,
and ensure a mix of agreeable and adversarial dispositions. Avoid task-irrelevant
persona attributes (gender, age, background) that introduce bias without benefit.

---

## Q3: What Topologies Work?

### Topology Matters More Than Agent Count

**"Improving MAD with Sparse Communication Topology" ([2406.11776])** tested
regular graphs with 6 agents at varying density:

| Topology | MATH Accuracy | GSM8K Accuracy | Cost Reduction |
|----------|--------------|----------------|----------------|
| Fully-connected (D=1) | Baseline | Baseline | 0% |
| Sparse (D=3/5) | +3.0 to +7.5% | +3.5 to +6.5% | 41-44% |
| Neighbor-only (D=2/5) | Moderate gains | Moderate gains | ~50% |

Key finding: **sparse topologies sustained longer effective debates** before
premature consensus, allowing more extensive deliberation.

**Stronger LLMs at high-centrality positions** improves results: placing GPT-3.5
at degree-5 centrality among Mistral-7B agents yielded +3.0% vs +1.8% at low
centrality.

### Topology Taxonomy

**"Topological Structure Learning" ([2505.22467])** argues topology is an
under-explored priority and proposes a framework:

| Topology | Best For | Weakness |
|----------|----------|----------|
| **Chain** | Step-by-step refinement | Sequential bottleneck |
| **Tree** | Hierarchical planning/decomposition | Single point of failure at root |
| **Star** | Centralized control, judging | Hub overload |
| **Fully-connected** | Maximum info sharing | Conformity pressure, high cost |
| **Sparse graph** | Balanced deliberation | Design complexity |

Task performance varies by **up to 10%** between topologies. Naive scaling
without adaptive structure leads to redundant communication.

### Centralized vs Decentralized

The sycophancy study found centralized topologies (with a judge) show ~40%
disagreement collapse rate vs 60%+ for fully decentralized. A structured judge
role helps maintain productive tension.

### Practical Topology Recommendations

1. **Panel with judge** (D3 framework, [2410.04663]): Advocates + judge + optional
   jury. Two protocols — MORE (multi-advocate, one round) and SAMRE (single
   advocate, multi-round with budgeted stopping).
2. **Sparse graph with heterogeneous models**: Place strongest model at highest
   centrality. Limit connections to prevent conformity cascade.
3. **Round-table with confidence weighting** (ReConcile): All agents see all
   responses but vote with confidence weights. Best when using diverse model
   families.

### Verdict on Q3

**Sparse topologies with a judge/hub outperform fully-connected.** The key
principles: (1) limit connections to prevent conformity, (2) place strongest
models at high-centrality positions, (3) use a judge/arbiter role to maintain
productive disagreement, (4) prefer heterogeneous model families over copies of
the same model.

---

## Q4: Diminishing Returns — How Many Agents?

### The 1-5-10 Rule

**"More Agents Helps but Adversarial Robustness Gap Persists" ([2511.07112])**
tested 1-25 agents across 6 open-source models on 4 math benchmarks:

| Agent Count | Accuracy Gain | Marginal Improvement |
|-------------|---------------|---------------------|
| 1→5 | **Substantial** | High |
| 5→10 | Continued, slower | Diminishing |
| 10→25 | **Minimal** | Near zero |

**Critical caveat:** adversarial robustness gap persists regardless of agent
count. More agents improve standard accuracy but don't proportionally improve
robustness to perturbations. Human-like typos maintain the highest attack success
rate even with 25 agents.

### The Lazy Agent Problem

**"From Lazy Agents to Deliberation" ([2511.02303])** identified that scaling
agents introduces a lazy agent problem — one agent dominates while others
contribute nothing, effectively collapsing to single-agent behavior. Solutions
require causal influence measurement and verifiable reward mechanisms.

### Optimal Counts by Task Type

| Task Type | Optimal Agents | Notes |
|-----------|---------------|-------|
| Math reasoning | 3-5 | Beyond 5, gains are marginal |
| Factuality/QA | 3-5 | Diversity matters more than count |
| Research ideation | 3 critics | Parallelism optimal at 3 ([2507.08350]) |
| Evaluation/judging | 3-5 advocates + 1 judge | Panel structure (D3) |
| Code generation | 2-3 | Reviewer/author pair sufficient |

### Cost Scaling

Token consumption scales roughly linearly with agents × rounds. Given that
sparse topology with 3-5 agents matches or beats fully-connected with 10+,
the cost-effectiveness strongly favors smaller, diverse teams.

### Verdict on Q4

**3-5 agents is the sweet spot for most tasks.** Beyond 5, marginal returns
diminish rapidly. Beyond 10, you're paying compute for negligible gain. The
budget is better spent on model diversity than on more copies of the same model.

---

## Synthesis: Practical Recommendations

### What Actually Works

1. **Self-Consistency first** — sample N independent responses from a single
   model and take majority vote. This is your baseline to beat.
2. **Heterogeneous models** — if you have budget for multi-agent, use different
   model families. This is the single biggest lever.
3. **3-5 agents, sparse topology** — don't fully connect. Use a judge/arbiter.
4. **Domain-expert critics** — assign specialized critic personas, not proposer
   personas. Avoid demographic or rigid adversarial personas.
5. **Confidence-weighted voting** — let agents express confidence; weight votes
   accordingly (ReConcile approach).
6. **Budget-aware stopping** — don't run fixed rounds. Stop when consensus
   stabilizes (D3's budgeted stopping, FREE-MAD's trajectory scoring).

### What Doesn't Work

1. **Homogeneous debate** — N copies of GPT-4 debating is expensive
   Self-Consistency with extra steps.
2. **Rigid devil's advocate** — agents assigned to always disagree produce worse
   results than flexible personas.
3. **Fully-connected topology** — encourages conformity, kills productive
   disagreement.
4. **More than 10 agents** — waste of compute with near-zero marginal returns.
5. **Debate on commonsense tasks** — conformity pressure actually degrades
   accuracy on tasks where the "common" answer is wrong.

### Open Questions

- Can MAD be made to work for open-ended generation (not just classification/QA)?
- How do reasoning models (o1, DeepSeek-R1) change the MAD landscape?
  ([2601.22297] explores training models for debate via Self-Debate RL)
- Can adaptive topology selection be learned end-to-end?
- How does MAD interact with tool use and retrieval-augmented generation?

---

## Key Papers Referenced

| Paper | Venue | Key Contribution |
|-------|-------|-----------------|
| Du et al. "Improving Factuality and Reasoning through Multiagent Debate" [2305.14325] | ICML 2024 | Foundational MAD paper |
| Chen et al. "ReConcile: Round-Table Conference" [2309.13007] | ACL 2024 | Confidence-weighted multi-model debate, up to 11.4% gain |
| "Improving MAD with Sparse Communication Topology" [2406.11776] | 2024 | Sparse beats dense, +7.5% accuracy, -44% cost |
| "D3: Debate, Deliberate, Decide" [2410.04663] | 2024 | Cost-aware adversarial framework with role specialization |
| "Stop Overvaluing Multi-Agent Debate" [2502.08788] | NeurIPS 2025 | Systematic eval: MAD fails to beat SC; heterogeneity is the key |
| "Talk Isn't Always Cheap" [2509.05396] | 2025 | Failure modes: correct→incorrect flips, conformity pressure |
| "FREE-MAD: Consensus-Free Multi-Agent Debate" [2509.11035] | 2025 | Single-round debate with trajectory scoring, anti-conformity |
| "Peacemaker or Troublemaker" [2509.23055] | 2025 | Sycophancy analysis, r=0.902 correlation with error |
| "Topological Structure Learning" [2505.22467] | 2025 | Topology design as research priority, up to 10% variance |
| "Multi-Agent LLM Dialogues for Research Ideation" [2507.08350] | SIGDIAL 2025 | Persona assignment: critics > proposers, 3 parallel optimal |
| "Debate or Vote" [2508.17536] | NeurIPS 2025 Spotlight | Voting alone explains most MAD gains; debate is a martingale |
| "More Agents Helps but Robustness Gap Persists" [2511.07112] | 2025 | 1→5 big gains, 5→10 diminishing, >10 negligible |
| "Can LLM Agents Really Debate?" [2511.07784] | 2025 | Controlled study: reasoning strength + diversity dominate |
| "From Lazy Agents to Deliberation" [2511.02303] | 2025 | Lazy agent problem, causal influence solutions |
| "From Biased Chatbots to Biased Agents" [2602.12285] | 2026 | Persona assignment degrades performance up to 26.2% |
| "Prepare Reasoning LMs for MAD" [2601.22297] | 2026 | Self-Debate RL for training debate-capable models |
