# guild

A general-purpose framework for defining teams of agents that collaborate to solve problems.

Any problem domain. Any agents. Any orchestration pattern.

---

## What It Is

Guild lets you define a **team of agents** — each with a role, a skill set, and a backend — and a **pipeline** describing how work flows between them. You supply the agent definitions (copied from MetaSwarm, OpenClaw, or written from scratch). Guild wires them together and runs them.

```toml
# team.toml — the whole team in ~50 lines
agents_dir = "~/agent-library/metaswarm/agents"

[[phases]]
name  = "plan"
agent = "architect"

[[phases]]
name    = "plan_review"
agents  = ["feasibility_reviewer", "completeness_reviewer", "scope_reviewer"]
require = "all_passed"

[[gates]]
name    = "tests_pass"
type    = "shell"
command = "npm test"
```

```bash
guild init team.toml     # scaffold the project
guild run "add auth"     # run the team on a task
```

## Why Guild

The existing agent orchestration frameworks (LangGraph, CrewAI, AutoGen) are Python-centric and code-first. Agents are Python objects. You can't copy a LangGraph agent into a CrewAI project.

In Guild, an **agent is a directory on disk** — a `SOUL.md` (system prompt) and a `config.yaml` (backend, tools, output schema). You copy agent definitions from anywhere. Point your team config at them. Guild reads them and runs them.

```
~/agent-library/
  metaswarm/agents/architect/
    SOUL.md        ← system prompt
    config.yaml    ← model, tools, output schema
  custom/risk_assessor/
    SOUL.md
    config.yaml
```

## Status

Early design phase. See [DESIGN.md](DESIGN.md) for full architecture.

**Milestone 1 (in progress):** `guild init team.toml` → generates Claude Code project scaffolding equivalent to `npx metaswarm install`. No runtime yet — just the spec compiler.

## Design

Full design document: [DESIGN.md](DESIGN.md)

Key sections:
- [Three Core Primitives](DESIGN.md#core-primitives) — Agents, Work Items, Transitions
- [Filesystem-Native Agents](DESIGN.md#agent-definitions-filesystem-native) — the agent library model
- [Lessons from Apache Airflow](DESIGN.md#lessons-from-apache-airflow) — named slots, sensors, deferred execution
- [Milestone 1: Spec Compiler](DESIGN.md#milestone-1-spec-compiler-do-this-first) — the concrete starting point
- [Roadmap](DESIGN.md#roadmap)

## Relationship to MetaSwarm

[MetaSwarm](https://github.com/dsifry/metaswarm) is the inspiration and the first use case. The MetaSwarm 9-phase software development pipeline is expressible as a single `guild.toml`. See [examples/metaswarm-full.toml](examples/metaswarm-full.toml).

Guild is what MetaSwarm would be built on if it were designed as a library rather than a product.

## Built With

Haskell. Type-driven design, `ReaderT AppEnv IO`, no effect system.

---

*Part of the [PureClaw](https://github.com/pureclaw) organization.*
