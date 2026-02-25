# guild: Design Document

*Drafted: 2026-02-25. Status: Working draft — brainstormed with Mighty, ready for review.*

---

## Vision

A general-purpose framework for defining **teams of agents** that collaborate to solve problems. Any problem domain. Any agents. Any orchestration pattern.

MetaSwarm is the inspiration — a 9-phase multi-agent software development pipeline — but it is one instance of what this framework should be able to express. A trading signal pipeline, a customer service triage workflow, a research synthesis team: all expressible with the same primitives.

The goal is not to build a better MetaSwarm. The goal is to build the thing MetaSwarm would be built on top of if it were designed as a library, not a product.

---

## Guiding Principles

1. **Agents are filesystem artifacts, not framework objects.** You own your agent definitions. You version them. You copy them from other projects (MetaSwarm, OpenClaw, anywhere). The framework reads them. It does not define them.

2. **The team config is minimal.** A team config names agents and defines how work flows between them. All intelligence lives in the agent definitions, not the config.

3. **Work items are opaque bytes.** The framework does not interpret payloads. Agents decide what data means. This enables interoperability with any domain without requiring schema changes in the framework.

4. **The runtime is a thin executor.** Validate the graph. Drive state transitions. Evaluate gates. Route work. Persist run state. Nothing more.

5. **No lock-in.** Copy agents from MetaSwarm, from OpenClaw, or write your own. The framework does not mandate an agent format beyond what is minimally needed to invoke it.

6. **Compounding via structured memory.** The `.beads/` knowledge system is a first-class part of the framework — not an add-on. Every run is an opportunity to make the next run smarter.

---

## Core Primitives

### 1. Agents

An agent is anything that takes input and produces output (or waits for a condition). The framework supports five agent classes:

| Class | Description |
|---|---|
| `LLMAgent` | Calls a language model (Anthropic, OpenAI, local Ollama); produces output |
| `Sensor` | Waits for an external condition to become true; emits success/failure signal only |
| `HumanAgent` | Defers execution, notifies human, waits for approval; a specialized Sensor |
| `AutomatedAgent` | Runs a shell command or deterministic function |
| `SubPipelineAgent` | Delegates to another pipeline definition (recursive composition) |

**LLMAgents** and **AutomatedAgents** are *operators*: they do work, produce named output slots, and complete. **Sensors** and **HumanAgents** are *watchers*: they wait for an external condition, don't produce payload output, and succeed or fail based on what they observe.

This distinction matters for the runtime: operators block a worker for the duration of their execution. Sensors use deferred scheduling — they check a condition, and if it isn't met, they release the worker and reschedule after `poke_interval`. A HumanAgent waiting 4 hours for approval should not hold a worker slot.

All five classes satisfy the same interface from the caller's perspective: `StateInput -> IO StateResult`. The caller does not need to know which class it's talking to.

### 2. Work Items

A work item is a bundle of bytes with a name, produced by one state and consumed by downstream states. It carries:
- A **key** — the name under which this output is stored (e.g., `plan`, `work_units`, `review_verdict`)
- A **payload** — raw bytes, opaque to the framework
- A **content-type hint** — `text/plain`, `application/json`, `application/octet-stream`, etc. Agents use this to deserialize; the framework does not.
- A **lineage** — which state produced it, for audit

**Named slots (XCom-style):** Agents declare what they produce and what they read. The framework routes named outputs to named inputs — downstream agents don't receive the full accumulated blob, they pull specific named slots from specific prior states:

```yaml
states:
  - name: plan
    agent: architect
    outputs:         # declares what this state pushes into the slot store
      - plan
      - work_units

  - name: implement
    agent: coder
    reads:           # declares what this state pulls from the slot store
      - from: plan
        key: work_units   # pulls work_units produced by the "plan" state
      - from: plan
        key: plan         # pulls plan produced by the "plan" state
```

This is more surgical than `context_passing: accumulate` (which forces every agent to receive everything). Parallel agents can pull different slots from the same upstream output without stepping on each other.

**Storage backends (pluggable):** LLM outputs can be large (hundreds of KB for plans, conversation transcripts). The named slot store should be pluggable from the start:
- `sqlite` (default) — good for small payloads, single-machine runs
- `filesystem` — writes blobs to `.agentic/runs/<id>/slots/` as files, SQLite stores only references
- `s3` — for distributed execution or very large payloads

> **Open question:** Should the framework support optional JSON Schema validation on named slots at gate evaluation time? This would enable a `schema_valid` builtin gate without the framework needing to interpret payloads. Lean: yes, optional, never mandatory.

### 3. Transitions

A transition is a directed edge in the pipeline state machine. It connects a source state to a destination state and carries a list of gates that must all pass for the transition to fire.

Transition types:

| Type | Description |
|---|---|
| `Deterministic` | Always fires when source state completes. No gates. |
| `Gated` | Fires only if all listed gates pass. Otherwise: retry, escalate, or halt. |
| `Conditional` | Source state output is inspected; transition target selected based on a field value or predicate. Enables branching without gates. |
| `FanOut` | One source state fans out to multiple parallel destination states. |
| `FanIn` | Multiple parallel source states aggregate into one destination state. |
| `Dynamic` | A `RouterAgent` receives the work item and decides the next state from a declared set of candidates. |

The `Dynamic` type is the key addition beyond the current design. It is what makes a team feel like a team rather than an assembly line: a triage agent decides who handles a ticket, a coordinator decides which specialist gets a task.

---

## Agent Definitions: Filesystem-Native

This is the most important design decision in the document.

**The agent definitions are not embedded in the team config. They live on the filesystem, in a format native to the agent system that produced them.**

### The Agent Repository Model

Agents live in a directory — call it an *agent library*. Each agent is a subdirectory:

```
~/agent-library/
  metaswarm/              ← cloned/copied from the MetaSwarm project
    agents/
      architect/
        config.yaml
        SOUL.md           ← system prompt
      coder/
        config.yaml
        SOUL.md
      adversarial_reviewer/
        config.yaml
        SOUL.md
  custom/
    risk_assessor/
      config.yaml
      SOUL.md
    triage_router/
      config.yaml
      SOUL.md
```

The team config references agents by path relative to the library:

```yaml
agents_dir: ~/agent-library

team:
  - metaswarm/agents/architect
  - metaswarm/agents/coder
  - metaswarm/agents/adversarial_reviewer
  - custom/risk_assessor
```

You can clone the MetaSwarm repository, point `agents_dir` at it, and immediately use those agents. No reformatting, no reimporting. Copy, point, run.

### The Canonical Agent Format

An agent directory contains exactly two required files and a few optional ones:

```
architect/
  SOUL.md          ← REQUIRED: system prompt (markdown, sent to the LLM)
  config.yaml      ← REQUIRED: backend, tools, output schema
  tools/           ← OPTIONAL: executable scripts available as tools
    run_tests.sh
    lint.sh
  schema/          ← OPTIONAL: JSON Schema for output validation
    output.json
```

**`SOUL.md`** is the system prompt. Plain markdown. The framework sends its content verbatim as the `system` message. This is also readable by Claude Code, OpenClaw, or any other agent system that uses markdown-based prompts — no translation required.

**`config.yaml`** is minimal machine-readable configuration:

```yaml
# architect/config.yaml
backend:
  provider: anthropic         # anthropic | openai | local | human | automated
  model: claude-opus-4-20250514
  api_key_env: ANTHROPIC_API_KEY   # env var to read key from

tools:
  - name: read_file
    command: "read"           # built-in tool alias
  - name: run_tests
    command: "./tools/run_tests.sh"  # local script

max_tokens: 16384

# Optional: JSON Schema for structured output.
# If present, the framework validates agent output against this schema.
output_schema: schema/output.json
```

That's it. The system prompt is in SOUL.md, not in config.yaml. The config is pure machine concerns: which model, which tools, which API key, how to validate output.

### Format Compatibility

The current MetaSwarm YAML format (`name`, `system_prompt`, `backend`, `tools` all in one file) is close. The difference is extracting the system prompt into SOUL.md. The agent loader should support both formats:
- **Directory format** (canonical): `SOUL.md` + `config.yaml`
- **Single-file format** (MetaSwarm compat): `architect.yaml` with inline `system_prompt`

Auto-detection: if the agent path is a directory, use directory format. If it's a `.yaml` file, use single-file format.

---

## Team Configuration

The team config is the glue between the agent library and the runtime. It is intentionally minimal.

```yaml
# team.yaml
name: software-dev-team
description: MetaSwarm software development workflow

# Where to find agent definitions
agents_dir: ~/agent-library

# Which agents are on this team
agents:
  - id: architect
    path: metaswarm/agents/architect
  - id: coder
    path: metaswarm/agents/coder
  - id: adversarial_reviewer
    path: metaswarm/agents/adversarial_reviewer
    fresh_instance: true        # spawn with zero prior context each invocation
  - id: pr_shepherd
    path: metaswarm/agents/pr_shepherd

# The workflow: states and transitions
workflow:
  initial: plan
  terminal: [done]

  states:
    - name: plan
      agent: architect

    - name: plan_review
      parallel:
        agents: [feasibility_reviewer, completeness_reviewer, scope_reviewer]
        aggregate: all_passed

    - name: implement
      agent: coder

    - name: review
      agent: adversarial_reviewer
      fresh_instance: true

    - name: done
      automated: true

  transitions:
    - "plan -> plan_review"
    - "plan_review -> implement: [plan_quality]"
    - "implement -> review: [tests_pass, lint_pass]"
    - "review -> done: [review_passed]"
    - "review -> implement: [review_failed]"    # retry loop

# Gate definitions (or reference a shared gate library)
gates:
  - name: plan_quality
    check:
      builtin: llm_judge
      rubric: ./rubrics/plan-review-rubric.md

  - name: tests_pass
    check:
      shell: "npm test"

  - name: lint_pass
    check:
      shell: "npm run lint"

  - name: review_passed
    check:
      predicate: "output.verdict == 'PASS'"

  - name: review_failed
    check:
      predicate: "output.verdict == 'FAIL'"

# Runtime settings
settings:
  max_retries: 3
  context_passing: accumulate   # accumulate | last_only | explicit
  parallel_work_units: false
  persistence: sqlite           # sqlite | files | memory
```

The entire workflow for a 9-phase MetaSwarm pipeline fits in ~80 lines of YAML. Agents are referenced by ID, defined externally. Gates are either inline or pulled from a shared library file.

---

## Gate Library

Gates are reusable, composable, and shareable. The framework ships a standard library of built-in gates:

| Gate | Type | Description |
|---|---|---|
| `shell` | Shell | Runs a command; exit 0 = pass |
| `predicate` | Expression | Evaluates a JSONPath/expression over agent output |
| `schema_valid` | Builtin | Validates output against a JSON Schema |
| `llm_judge` | Builtin | Asks an LLM to evaluate output against a rubric |
| `human_approval` | Builtin | Sends notification, waits for explicit human approval |
| `field_equals` | Builtin | `output.X == value` shorthand |
| `all_passed` | Aggregate | All parallel agent outputs carry passing verdict |
| `majority_approved` | Aggregate | Majority of parallel agents approved |

Custom gates can be defined inline in the team config (as above) or in a shared `gates.yaml` file that multiple team configs reference.

Project-level gate libraries (`./gates/`) and agent-level gate libraries (`~/agent-library/gates/`) compose. The runtime resolves gates by name, checking: builtin → project → agent library → not found.

---

## The Binary: `guild`

The CLI interface is the primary user-facing surface:

```bash
# Validate a team config and agent definitions
guild validate team.yaml

# Visualize the pipeline as a graph (outputs DOT or ASCII)
guild graph team.yaml

# Run a pipeline with an initial work item
guild run team.yaml "Implement user authentication per issue #42"

# Run from a file (for binary or large payloads)
guild run team.yaml --input ./work-item.json

# List available agents in the agent library
guild agents list ~/agent-library/

# Show the resolved configuration (useful for debugging)
guild config show team.yaml

# Resume a failed run from its last checkpoint
guild resume run-id-abc123

# Show run history
guild runs list
guild runs show run-id-abc123
```

---

## Run Persistence

Multi-step agent pipelines can take hours. The runtime persists run state to SQLite by default:

```
.agentic/
  runs/
    run-abc123/
      state.db          ← SQLite: current state, transition history, gate results
      work-items/
        step-01-plan.json
        step-02-review.json
        step-03-impl.json
      audit.log         ← append-only transition log
```

On crash or interrupt: `guild resume run-id-abc123` reloads state, replays to the last committed state, and continues from there. Work items from completed states are not re-executed.

---

## Knowledge Compounding: Beads Integration

The `.beads/` system is the mechanism by which experience accumulates across runs.

Every pipeline has two special automated states that the framework injects at the start and end if a `.beads/` directory is present:

```
knowledge_priming (automated) → [user states] → knowledge_extraction (LLM)
```

**`knowledge_priming`** loads relevant facts from `.beads/knowledge/` into the pipeline's shared context before the first agent runs. Every agent invocation has access to this primed context. This is the "feed forward" half of the compounding loop.

**`knowledge_extraction`** runs a `KnowledgeCuratorAgent` after the terminal state. It reads the run's state history, identifies patterns, gotchas, and decisions, and appends them to `.beads/knowledge/`. This is the "feed back" half.

Over time: each project run makes the next run smarter. Lessons from DojoLens inform the trading pipeline. Anti-patterns caught in project A are loaded as GOTCHAS in project B. This is the compounding mechanism the README describes — and it is implemented as a first-class feature of the runtime, not left as aspirational text.

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│                  guild CLI                   │
│         validate | graph | run | resume           │
├──────────────────────────────────────────────────┤
│               Pipeline Runtime                    │
│  State machine · Gate evaluation · Retry logic   │
│  Parallel fan-out/fan-in · Run persistence       │
├──────────────────────────────────────────────────┤
│               Agent Loader                        │
│  Directory format (SOUL.md + config.yaml)        │
│  Single-file format (MetaSwarm compat YAML)      │
│  Format auto-detection                           │
├──────────────────────────────────────────────────┤
│               Work Item Bus                       │
│  Raw bytes · Content-type hints · Lineage        │
│  SQLite persistence                              │
├──────────────────────────────────────────────────┤
│               Gate Library                        │
│  Builtin · Shell · Predicate · LLM Judge        │
│  Human Approval · Aggregate                      │
├──────────────────────────────────────────────────┤
│               LLM Backend                         │
│  Anthropic · OpenAI · Local (Ollama)             │
├──────────────────────────────────────────────────┤
│               Beads Knowledge System              │
│  Priming (load) · Extraction (write) · Compound  │
└──────────────────────────────────────────────────┘
```

---

## Relationship to Existing Code

The current `meta-metaswarm/` Haskell library has the right instincts but the wrong scope. Its types model MetaSwarm-specific concepts rather than the general primitives. The recommended path:

1. **Rename** the library to `guild-core` (or just keep it as the main lib in this repo)
2. **Redesign `Types.hs`** around the general primitives described here. The current `AgentSpec` embeds the system prompt inline — in the new design, system prompt lives in SOUL.md and the type just holds a reference.
3. **Build the Agent Loader** as a new module (`MetaAgent.Loader`) that reads both directory format and single-file format. This is the key new component.
4. **Move MetaSwarm** from being the implicit target to being an explicit example in `examples/metaswarm-full/`. The pipeline.yaml stays; the YAML agent files become the reference single-file format.
5. **Keep `.beads/`** as-is. Wire it into the runtime as the knowledge priming/extraction mechanism.

The `.claude/plugins/metaswarm/` Claude Code skill is a separate thing — it's a Claude Code plugin that implements MetaSwarm as a series of Claude Code slash commands. It can coexist with this framework and doesn't need to be merged.

---

## Open Questions

These are unresolved and need a decision before implementation begins:

**Q1: Should work items have optional typed schemas?**
Raw bytes is maximally flexible. Optional JSON Schema validation on a per-gate basis (using the `schema_valid` builtin) gives structure where desired without imposing it. Lean: raw bytes + optional schema validation at gate boundaries.

**Q2: Should agents be stateful within a run?**
Stateless (each invocation: fresh system prompt + accumulated work items as context) is simpler and more composable. Stateful (agent retains a conversation across invocations in a run) enables progressive refinement. Lean: stateless default, with an opt-in `stateful: true` in config.yaml that preserves the conversation history for that agent across invocations within a single run.

**Q3: How does the agent loader handle the MetaSwarm `.claude/` format?**
MetaSwarm's `.claude/plugins/metaswarm/skills/beads/agents/architect-agent.md` is a different format from the YAML agent files. The markdown format is richer (includes workflow details, diagrams) but is less machine-structured. Options: (a) don't support it, require YAML or directory format, (b) support it with a heuristic parser that extracts system prompt from the markdown. Lean: don't support it initially. The YAML agents in `examples/metaswarm-full/agents/` are the reference implementation.

**Q4: Parallel execution model?**
`FanOut` and `FanIn` transitions require concurrent agent execution. Options: (a) `async`/`STM` in Haskell — correct and composable, (b) sequential fan-out with result collection — simpler but slower. Lean: `async` from the start. The Haskell concurrency primitives make this tractable and it's too painful to bolt on later.

**Q5: OSS strategy?**
This is potentially the most interesting open-source contribution we could make in the agent tooling space. The framework is domain-agnostic, Haskell-native, and takes a fundamentally different approach from LangGraph/CrewAI/AutoGen (all Python, all code-first, none with filesystem-native agent definitions or a compounding knowledge system). Lean: make it public. Not yet — wait until the core runtime is working — but design it as if it will be.

**Q6: Should slots be addressable across runs?**
Airflow's XComs are per-DAG-run. Our slot store is also per-run by default. But the `.beads/` knowledge system intentionally crosses run boundaries — it's how compounding happens. Should named slots from completed runs ever be readable by new runs? One use case: a "research" pipeline produces a `market_research` slot, and a "planning" pipeline run an hour later wants to read it. Could be modeled as a slot store query rather than a cross-run reference. Lean: keep runs isolated by default; cross-run access goes through beads (explicit extraction + priming).

**Q7: Default slot store backend for large outputs?**
LLM outputs can be large. An implementation plan with 10 work units might be 50KB. A full conversation transcript might be 200KB. SQLite handles this fine (blob storage), but retrieval gets slow at scale. The filesystem backend (blobs in `.agentic/runs/<id>/slots/`) is simpler and more debuggable. Lean: filesystem as default (easier to inspect), SQLite for metadata/lineage only.

---

## Milestone 1: Spec Compiler (Do This First)

*Revised 2026-02-25. The execution engine comes later. Start here.*

Milestone 1 is a **scaffolding generator**, not a runtime. It reads a compact team spec in TOML and writes exactly what `npx metaswarm install` currently writes to a project. No state machine. No LLM calls. No SQLite. Just a Haskell binary that reads a spec and emits files.

### What MetaSwarm Writes (the output target)

When you run `npx metaswarm install` in a project, MetaSwarm writes:

```
CLAUDE.md                          ← project instructions for Claude Code
.claude/
  commands/
    start-task.md                  ← slash commands for each pipeline phase
    prime.md
    review-design.md
    pr-shepherd.md
    ...
  plugins/metaswarm/skills/
    plan-review-gate/SKILL.md      ← agent skill definitions
    orchestrated-execution/SKILL.md
    beads/agents/architect-agent.md
    beads/agents/coder-agent.md
    ...
  guides/
    agent-coordination.md
    build-validation.md
    coding-standards.md
    ...
  rubrics/
    adversarial-review-rubric.md
    plan-review-rubric.md
    ...
  settings.local.json              ← Claude Code tool permissions
.beads/
  config.yaml
  hooks/
  knowledge/
.metaswarm/project-profile.json
.coverage-thresholds.json
SERVICE-INVENTORY.md
```

**That's the output.** The milestone 1 binary generates this from a compact TOML.

### The Input: Compact TOML

```toml
[project]
name = "dojolens"
description = "Judo video analytics SaaS"

[agents]
library = "~/agent-library"        # path to agent definitions on disk
use = [
  "metaswarm/agents/architect",
  "metaswarm/agents/coder",
  "metaswarm/agents/adversarial_reviewer",
  "metaswarm/agents/pr_shepherd",
  "metaswarm/agents/feasibility_reviewer",
  "metaswarm/agents/completeness_reviewer",
  "metaswarm/agents/scope_reviewer",
]

[[phases]]
name = "research"
agent = "researcher"

[[phases]]
name = "plan"
agent = "architect"

[[phases]]
name = "plan_review"
agents = ["feasibility_reviewer", "completeness_reviewer", "scope_reviewer"]
require = "all_passed"
fresh_instance = true

[[phases]]
name = "implement"
agent = "coder"

[[phases]]
name = "adversarial_review"
agent = "adversarial_reviewer"
fresh_instance = true

[[gates]]
name = "plan_quality"
type = "shell"
command = "npx tsc --noEmit && npx eslint . && npx vitest run"

[[gates]]
name = "review_passed"
type = "predicate"
expr = "output.verdict == 'PASS'"

[build]
test = "npm test"
lint = "npm run lint"
typecheck = "npx tsc --noEmit"
coverage = "npm run test:coverage"
coverage_threshold = 100
```

~50 lines. Describes the full MetaSwarm software dev team. Compare to the hundreds of files MetaSwarm installs.

### What the Binary Does

```bash
# Initialize a project with a team spec
guild init team.toml

# Or in a target directory
guild init team.toml --output ./my-project
```

Step by step:
1. **Parse** `team.toml`
2. **Load** each agent definition from `agents.library` + the path in `agents.use`
3. **Copy** agent skill files into `.claude/plugins/guild/skills/<agent-name>/`
4. **Generate** `.claude/commands/` — one slash command per pipeline phase, auto-generated from phase definition and agent's skill description
5. **Generate** `CLAUDE.md` — lists the team, commands table, gates, build commands; no hardcoded MetaSwarm references
6. **Write** `.beads/config.yaml` and standard hooks
7. **Write** `.coverage-thresholds.json` from `[build]` settings
8. **Write** `.agentic/team.toml` — records the spec used (for future `guild update` and drift detection)

### The Generated CLAUDE.md (example)

```markdown
## Agent Team

This project uses an agent team. Team spec: `.agentic/team.toml`.

### Pipeline

research → plan → plan_review (3 agents, all must pass) → implement → adversarial_review

### Available Commands

| Command | Purpose |
|---|---|
| `/project:plan` | Run architect to create implementation plan |
| `/project:plan-review` | Parallel: feasibility + completeness + scope reviewers |
| `/project:implement` | Coder runs current work unit (TDD) |
| `/project:adversarial-review` | Adversarial spec compliance check |

### Agents

- **architect** — Implementation planning and work unit decomposition
- **coder** — TDD implementation
- **adversarial_reviewer** — Binary PASS/FAIL spec compliance check
- **pr_shepherd** — PR monitoring through CI and review
- **feasibility_reviewer**, **completeness_reviewer**, **scope_reviewer** — Parallel plan reviewers

### Gates

- **plan_quality**: `npx tsc --noEmit && npx eslint . && npx vitest run` (shell)
- **review_passed**: `output.verdict == 'PASS'` (predicate)
```

### Why Start Here

1. **Immediate value.** A real project can use this today. The output runs with standard MetaSwarm + Claude Code — no new runtime required.
2. **Validates the agent library model.** Forces us to get the filesystem loading and resolution logic right before the runtime depends on it.
3. **Small scope.** The Haskell binary is a file reader + text generator. No concurrency, no IO beyond file reads/writes, no LLM calls.
4. **Forces spec discipline.** Writing the TOML for MetaSwarm-full will reveal every design choice that needs to be made before the runtime is built.

### What Milestone 1 Is NOT

- Not an execution engine. It does not run agents.
- Not a scheduler. It does not invoke LLMs.
- Not a state machine. It does not manage pipeline state.

All of that is milestone 2+. Milestone 1 is purely: **compact spec in → Claude Code project config out**.

---

## Roadmap

### Phase 0: Spec Compiler — Milestone 1 (Start Here)
- [ ] TOML parser for team spec format
- [ ] Agent library loader — resolves paths, reads SOUL.md + config.yaml
- [ ] File generator — copies agent skills into `.claude/plugins/`
- [ ] CLAUDE.md generator — team description, commands table, gates section
- [ ] Slash command generator — one `.claude/commands/<phase>.md` per pipeline phase
- [ ] Beads config writer — standard `.beads/config.yaml` + hooks
- [ ] `guild init team.toml` command end-to-end
- [ ] Test: `guild init` on MetaSwarm-full spec produces identical output to `npx metaswarm install`

### Phase 1: Core Runtime (Foundation)
- [ ] Redesign `Types.hs` around the five agent classes + named slot model
- [ ] Implement `MetaAgent.Loader` — reads directory format and single-file YAML
- [ ] Implement `MetaAgent.SlotStore` — named slot push/pull with SQLite backend
- [ ] Implement `MetaAgent.Machine` — state machine with per-state lifecycle states (`pending | running | success | failed | skipped | up_for_retry | deferred`)
- [ ] Implement `MetaAgent.Gate` — shell, predicate, schema_valid builtins
- [ ] `guild validate`, `guild run`, `guild runs show` commands
- [ ] MetaSwarm example pipeline runs successfully on a real task

### Phase 2: Deferred Execution + Knowledge System
- [ ] `MetaAgent.Triggerer` — deferred state management; HumanAgent notifies and suspends
- [ ] `guild resume <run-id>` and `guild approve <run-id> <checkpoint>`
- [ ] `MetaAgent.Beads` — priming (load at pipeline start) and extraction (write at pipeline end)
- [ ] `KnowledgeCuratorAgent` prompt and config
- [ ] `guild graph` — pipeline visualization (ASCII + DOT output)

### Phase 3: Power Features
- [ ] Dynamic routing (`RouterAgent` transition type)
- [ ] Parallel fan-out/fan-in with `async` + STM
- [ ] `llm_judge` gate (LLM evaluates output against a rubric)
- [ ] Shared gate library files (`gates.yaml`)
- [ ] Pluggable slot store backends: filesystem, S3
- [ ] Sensor agent class with `poke_interval`, `timeout`, `mode: poke | reschedule`
- [ ] `guild agents list` and agent library management

### Phase 4: OSS Launch
- [ ] Public repo, MIT license
- [ ] Getting started guide: "run MetaSwarm on your project in 5 minutes"
- [ ] Published Hackage package
- [ ] Example pipelines: software-dev (MetaSwarm), research synthesis, customer triage
- [ ] Simple web dashboard for run monitoring (`guild serve`)

---

## Lessons from Apache Airflow

Airflow has been orchestrating complex multi-step workflows in production at scale for over a decade. It's worth looking at carefully — not to copy it, but to steal its best ideas and understand where our problem is different.

### What Airflow Gets Right (steal these)

**1. Named Cross-Task Communication (XComs)**

Airflow's XCom system lets tasks push named values and pull them by name from any prior task. This is more powerful than our current "raw bytes flows to next agent" model. Consider:

```yaml
# architect pushes named outputs:
#   plan, work_units, api_contracts
# coder pulls selectively:
#   reads work_units[0], plan
# adversarial_reviewer pulls:
#   reads work_units[0].dod_items, work_units[0].file_scope
```

Named slots make context passing explicit and composable. Parallel agents can pull different parts of the same upstream output without each getting a copy of everything. This should replace the current `context_passing: accumulate` bluntness with something more surgical.

**Design addition:** Each agent declaration can specify `reads` (which prior state outputs it consumes, and under what key) and each state implicitly produces a named output. The runtime handles the mapping; agents don't need to know about each other.

**2. Operator vs. Sensor distinction**

Airflow distinguishes between:
- **Operators** — do work, produce output, complete quickly (or fail)
- **Sensors** — wait for an external condition to become true, then succeed

This maps cleanly to our problem. A `HumanAgent` isn't doing work — it's waiting for a human to approve. A `PRShepherdAgent` is partly waiting for CI to pass. These should be modeled as **Sensors**, not Operators. They have different runtime semantics:
- Sensors poll on an interval (poke mode) or defer and get triggered (reschedule mode)
- They don't produce output payloads — they emit a signal (succeeded or failed)
- They shouldn't hold a "worker slot" for 4 hours while waiting for human input

**Design addition:** Add `Sensor` as a first-class agent class alongside `LLMAgent`, `HumanAgent`, `AutomatedAgent`, `SubPipelineAgent`. Sensors have `poke_interval`, `timeout`, `mode: poke | reschedule` in their config.

**3. Task instance lifecycle states**

Airflow's per-task states are richer than pass/fail: `queued → running → success | failed | skipped | up_for_retry | deferred`. Each state instance in a run gets one of these statuses. This enables:
- Partial re-runs (rerun from the failed state, not from scratch)
- Clear audit trails (why did this state get skipped? was it retried?)
- Human-readable dashboards

**Design addition:** Each state execution in a run has a lifecycle status stored in SQLite: `pending | running | success | failed | skipped | up_for_retry | deferred`. The `guild runs show` command displays this per-state status for a full run view.

**4. Deferred execution for long waits (Triggerer pattern)**

Airflow's Triggerer component handles deferred tasks: a task suspends itself, registers a condition (file exists, API returns 200, human clicks approve), and releases the worker. When the condition fires, the task is rescheduled and resumes.

This is the right model for human checkpoints in guild. A pipeline with a human approval gate should NOT require the `guild` process to stay alive for hours. Instead:

1. HumanAgent fires → sends notification → writes `deferred` to SQLite → process can exit
2. Human responds (via CLI, web hook, or message) → triggers `guild resume run-id`
3. Runtime reloads state from SQLite, re-enters at the deferred state, continues

**Design addition:** `guild resume <run-id>` and `guild approve <run-id> <checkpoint>` commands. Deferred states are persisted in SQLite with their triggering condition.

**5. Provider/Plugin ecosystem**

Airflow's huge operator library is community-built via "providers" — installable packages that add new operators, sensors, and hooks. This community model is a primary reason for Airflow's dominance in data engineering.

We should design guild to support the same pattern:
- `guild-software-dev` — MetaSwarm pipeline + agents (the reference implementation)
- `guild-research` — literature review workflow
- `guild-trading` — signal generation + risk check pipeline
- Community packages on Hackage / a registry

The agent library model (filesystem directories) is already compatible with this. A "provider package" is just a directory of agent definitions + gate definitions + example team configs.

### Where We Diverge from Airflow

**Cycles are first-class.** Airflow's original "A" in DAG means acyclic — no cycles. Our state machine explicitly needs cycles: `adversarial_review → implement → adversarial_review` is a retry loop, not a bug. We model this as a state machine, not a DAG. The retry loop is encoded in transitions, bounded by `max_retries`.

**Event-driven, not schedule-driven.** Airflow is fundamentally a scheduler: "run this pipeline at 6am every day." We're event-driven: "run this pipeline when I submit a work item." Schedule support (trigger a pipeline on a cron, on file arrival, on a webhook) can be added later but is not the core primitive.

**YAML over Python.** Airflow pipelines are Python code that looks declarative. You need to understand Python's execution model to understand what a DAG definition actually does. Our pipelines are YAML — genuine declarations, not programs. This is intentional. The workflow definition should be readable by someone who doesn't write Haskell or Python.

**LLM/Agent as first-class.** Airflow has BashOperator, PythonOperator, DockerOperator. It does not have an LLMAgent or AgentOperator. We're building the layer that should exist above Airflow — one that treats language model invocations as the primary execution primitive, not a shim on top of bash.

**XCom size.** Airflow warns that XComs are for small values (small enough to fit in the metadata DB). Large data goes to object storage backends. We face the same problem: an implementation plan or a full conversation transcript can be hundreds of KB. Design the work item storage layer with pluggable backends from the start: SQLite (default, small), filesystem (medium), S3/object storage (large/distributed).

### Revised Architecture with Airflow Lessons

```
┌──────────────────────────────────────────────────────────────┐
│                     guild CLI                            │
│  validate | graph | run | resume | approve | runs | agents   │
├──────────────────────────────────────────────────────────────┤
│                   Pipeline Runtime                            │
│  State machine · Lifecycle states · Retry · Deferred exec    │
│  Named slot routing (XCom-style) · Fan-out/fan-in           │
├──────────────────────────────────────────────────────────────┤
│              Agent Loader + Type Dispatch                     │
│  LLMAgent · Sensor · AutomatedAgent · SubPipeline           │
│  Directory format (SOUL.md + config.yaml)                    │
│  Single-file format (MetaSwarm compat YAML)                  │
├──────────────────────────────────────────────────────────────┤
│                   Named Slot Store                            │
│  Per-run SQLite · Named key/value · Lineage tracking        │
│  Pluggable: SQLite | Filesystem | S3                        │
├──────────────────────────────────────────────────────────────┤
│                   Gate Library                                │
│  Builtin · Shell · Predicate · LLM Judge                    │
│  Human Approval (deferred) · Schema Valid · Aggregate        │
├──────────────────────────────────────────────────────────────┤
│                   Triggerer                                   │
│  Deferred state management · Condition polling              │
│  Resume on external event                                    │
├──────────────────────────────────────────────────────────────┤
│                   LLM Backend                                 │
│  Anthropic · OpenAI · Local (Ollama)                        │
├──────────────────────────────────────────────────────────────┤
│                   Beads Knowledge System                      │
│  Priming (load) · Extraction (write) · Compound             │
└──────────────────────────────────────────────────────────────┘
```

---

## Comparison: Why Not LangGraph / CrewAI / AutoGen?

| Property | guild | LangGraph | CrewAI | AutoGen |
|---|---|---|---|---|
| Language | Haskell | Python/JS | Python | Python |
| Agent definition | Filesystem (any format) | Python code | Python code | Python code |
| Pipeline definition | YAML | Code | Code | Code |
| Type safety | Compile-time | Runtime | Runtime | Runtime |
| Agent portability | Copy a directory | Rewrite in Python | Rewrite in Python | Rewrite in Python |
| Knowledge compounding | Built-in (beads) | DIY | DIY | DIY |
| Human-in-the-loop | First-class primitive | Plugin | Plugin | Plugin |
| Crash recovery | SQLite persistence | DIY | DIY | DIY |
| Domain | General | General | General | General |

The key differentiator is the agent portability model. In every existing framework, an "agent" is a Python object. You cannot copy a LangGraph agent into a CrewAI project. In guild, an agent is a directory on disk. Copy it anywhere. Point any team config at it. The framework reads it.

This is also the OpenClaw angle: OpenClaw agents (SOUL.md + AGENTS.md + workspace files) are already close to the canonical agent directory format. With a thin adapter, OpenClaw agent configurations become directly usable as agents in guild pipelines.
