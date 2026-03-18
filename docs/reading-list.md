# Reading List: Foundations of the Cell Runtime

From the Sussman dialogue (2026-03-18). These are the prior art and related work
that inform what Cell actually is: a versioned tuple space with LLM agents and
an effect-aware deterministic executor.

Read in order.

---

## Tier 1 — Read This Week

- [ ] **Gelernter, "Generative Communication in Linda" (1985)**
  The direct ancestor. `out`, `in`, `rd` over a shared tuple space.
  You will recognize your system immediately.
  - Paper: https://dl.acm.org/doi/10.1145/2363.2433
  - Free PDF: https://www.cs.unc.edu/~stotts/COMP590-059-f21/slides/lindaGenerative.pdf
  - 10-min summary: https://blog.acolyer.org/2015/02/17/generative-communication-in-linda/

- [ ] **Otávio Carvalho, "Our AI Orchestration Frameworks Are Reinventing Linda" (Feb 2026)**
  Someone already noticed this pattern. Argues modern AI agent frameworks
  are reinventing Linda without knowing it. You are one of the systems
  he's describing.
  - https://otavio.cat/posts/ai-orchestration-reinventing-linda/

## Tier 2 — Read This Month

- [ ] **Hewitt, Bishop, Steiger, "A Universal Modular ACTOR Formalism for Artificial Intelligence" (1973)**
  Actors as the universal primitive. Pistons are actors that communicate
  through a tuple space instead of direct messages.
  - PDF: https://eighty-twenty.org/files/Hewitt,%20Bishop,%20Steiger%20-%201973%20-%20A%20universal%20modular%20ACTOR%20formalism%20for%20artificial%20intelligence.pdf

- [ ] **H. Penny Nii, "The Blackboard Model of Problem Solving" (1986)**
  Two-part AI Magazine survey of blackboard systems starting from Hearsay-II.
  Independent "knowledge sources" opportunistically read/write a shared
  workspace. The AI version of tuple spaces.
  - Part 1: https://ojs.aaai.org/aimagazine/index.php/aimagazine/article/view/537
  - Stanford TR: http://i.stanford.edu/pub/cstr/reports/cs/tr/86/1123/CS-TR-86-1123.pdf

## Tier 3 — When You Have Time

- [ ] **Kartik Agaram's Mu project**
  Building computing from scratch. Taking "live" and "minimal" seriously
  as design constraints. Not directly about your problem, but about the
  philosophy of small languages with big runtimes.
  - Site: https://akkartik.name/
  - GitHub: https://github.com/akkartik

- [ ] **Banatre & Le Metayer, "The GAMMA Model" (1990)**
  Chemical abstract machine — programs as multisets of molecules,
  reactions triggered by the presence of reagents. Another way to think
  about cells reacting in a shared soup.
  - Search: "Programming by multiset transformation" Science of Computer Programming

- [ ] **Carriero & Gelernter, "Linda in Context" (1989)**
  Gelernter's follow-up comparing Linda to actors, CSP, and shared memory.
  Useful for understanding where Cell sits relative to other coordination models.
  - CACM 1989

---

## Key Insight From the Dialogue

Cell is not a programming language in the traditional sense. It is a
**runtime with a very small language on top**. The identity:

> A versioned tuple space (Dolt) with a deterministic executor that runs
> until it hits a boundary — replayable (oracle/LLM, auto-retryable) or
> non-replayable (mutations, cascade-thaw required) — where the agents
> are LLMs and the tuples are natural language.

The contribution is not the computation model. It is:
1. The boundary between deterministic and stochastic execution as a first-class construct
2. Time travel over the tuple space (Dolt versioning) making destructive `in` reversible
3. The evaluator can read the program because the program is natural language

The language should stay small. Build the effect-aware runtime.
