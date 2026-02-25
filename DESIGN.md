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

An agent calls a language model and produces output. It is defined as a directory on disk containing a system prompt (`SOUL.md`) and configuration (`config.yaml`). The framework sends the prompt, collects the response, and stores the output in a named slot.

Automated checks (shell commands, linters, test suites) are handled by **gates**, not agents. Human approval pauses are handled by **checkpoints**, not agents. Agents call LLMs. That's it.

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

The team config points `agents_dir` at the directory containing agent subdirectories. Each phase references an agent by name, resolved as `<agents_dir>/<name>/`:

```yaml
agents_dir: ~/agent-library/metaswarm/agents

team:
  - architect
  - coder
  - adversarial_reviewer
```

You can clone the MetaSwarm repository, point `agents_dir` at its agents directory, and immediately use those agents. No reformatting, no reimporting. Copy, point, run.

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
┌─────────────────────────────────────────────────────────┐
│                       guild CLI                         │
│  validate | graph | run | resume | approve | agents     │
├─────────────────────────────────────────────────────────┤
│                   Pipeline Runtime                      │
│  State machine · Lifecycle states · Retry · Deferred    │
│  Named slot routing · Fan-out/fan-in                    │
├─────────────────────────────────────────────────────────┤
│                   Agent Loader                          │
│  Directory format (SOUL.md + config.yaml)               │
├─────────────────────────────────────────────────────────┤
│                   Gate Library                          │
│  Shell · Predicate · LLM Judge · Human Approval        │
├─────────────────────────────────────────────────────────┤
│                   LLM Backend                          │
│  Anthropic · OpenAI · Local (Ollama)                    │
├─────────────────────────────────────────────────────────┤
│                   Beads Knowledge System                │
│  Priming (load) · Extraction (write) · Compound        │
└─────────────────────────────────────────────────────────┘
```

---

## Open Questions

**Should agents be stateful within a run?**
Stateless (each invocation: fresh system prompt + accumulated work items as context) is simpler and more composable. Stateful (agent retains a conversation across invocations in a run) enables progressive refinement. Lean: stateless default, with an opt-in `stateful: true` in config.yaml that preserves the conversation history for that agent across invocations within a single run.

**OSS strategy?**
Design as if it will be public. Not yet — wait until the core runtime is working.

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
SERVICE-INVENTORY.md
```

**That's the output.** The milestone 1 binary generates this from a compact TOML.

### The Input: Compact TOML

```toml
[project]
name = "dojolens"
description = "Judo video analytics SaaS"

agents_dir = "~/agent-library/metaswarm/agents"

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
2. **Load** each agent definition from `agents_dir/<name>/`
3. **Copy** agent skill files into `.claude/plugins/guild/skills/<agent-name>/`
4. **Generate** `.claude/commands/` — one slash command per pipeline phase, auto-generated from phase definition and agent's skill description
5. **Generate** `CLAUDE.md` — lists the team, commands table, gates, build commands; no hardcoded MetaSwarm references
6. **Write** `.beads/config.yaml` and standard hooks
7. **Write** `.agentic/team.toml` — records the spec used (for future `guild update` and drift detection)

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
- [ ] Redesign `Types.hs` around the agent + named slot model
- [ ] Implement `MetaAgent.Loader` — reads directory format and single-file YAML
- [ ] Implement `MetaAgent.SlotStore` — named slot push/pull with SQLite backend
- [ ] Implement `MetaAgent.Machine` — state machine with per-state lifecycle states (`pending | running | success | failed | skipped | up_for_retry | deferred`)
- [ ] Implement `MetaAgent.Gate` — shell, predicate, schema_valid builtins
- [ ] `guild validate`, `guild run`, `guild runs show` commands
- [ ] MetaSwarm example pipeline runs successfully on a real task

### Phase 2: Deferred Execution + Knowledge System
- [ ] Deferred checkpoints — pipeline suspends, `guild resume` continues
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
- [ ] `guild agents list` and agent library management

### Phase 4: OSS Launch
- [ ] Public repo, MIT license
- [ ] Getting started guide: "run MetaSwarm on your project in 5 minutes"
- [ ] Published Hackage package
- [ ] Example pipelines: software-dev (MetaSwarm), research synthesis, customer triage
- [ ] Simple web dashboard for run monitoring (`guild serve`)
