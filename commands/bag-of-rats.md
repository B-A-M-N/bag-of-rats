---
name: bag-of-rats
description: Activate the Bag of Rats multi-model async pipeline for this task. Models alternate between implementing and reviewing in an N-at-a-time pipeline — each agent dispatches immediately when its inputs are ready, without waiting for upstream phases to fully complete. DeepSeek (main model) is the implementation lead. Other models (Qwen, MiniMax, Kimi, GLM) rotate as implementers and reviewers. Toggle off with /bag-of-rats-off.
disable-model-invocation: true
argument-hint: [optional custom phases or task description]
---

Activate the **Bag of Rats** — a multi-model async pipeline where different models take turns implementing and reviewing each other's work. The only time things wait is when a phase **requires** synchronous input from the previous phase. Otherwise, everything flows as fast as inputs allow.

## How Bag of Rats works

Bag of Rats is an alternative to `/fi-flow`. It runs alongside it — activating Bag of Rats does NOT disable FI-flow, and vice versa. Both can be active in the same session, but you should only use one at a time for any given task.

The pipeline is an **N-at-a-time async pipeline**: models dispatch as soon as their inputs are ready. There's no "wait for everyone" barrier unless the phase literally depends on all upstream results. The pipeline moves fast — implementers and reviewers alternate, and each model that finishes immediately frees the next one to start.

## Default phase pipeline

Unless you specify custom phases, the default pipeline is:

1. **GROUNDING** — read-only analysis of the request, repository, and acceptance criteria
2. **DESIGN** (T2/T3 only) — design authority produces architecture and contract
3. **IMPLEMENTING** — one or more models write code to the repo
4. **REPAIR** — models review the implementation and directly apply corrections
5. **VERIFY** — read-only validation of the final result against acceptance criteria
6. **COMPLETE** — pipeline finishes, both signoffs recorded

Each phase is assigned to a model in the roster. After one model finishes its phase, the **next model in the roster** gets the next available phase slot that has its inputs ready — no waiting. If multiple phase slots are ready, they dispatch in parallel.

## The roster

| Slot | Model | Role |
|------|-------|------|
| main | deepseek-v4-flash | Implementation lead — always runs IMPLEMENTING phases. Also the default GROUNDING model. |
| haiku | qwen3.6-35b | Quick review, grounding assist, small mechanical tasks |
| sonnet | minimax-m3 | Senior review and direct repair |
| opus | kimi-k2.7-code | Design authority, critical review |
| fable | glm-5.2 | Final signoff, design authority for T3 |

DeepSeek is the **implementation lead** — it stays on implementation phases because that's its strength and it's already available as the session model. The other models rotate between implementation and review phases depending on what the pipeline needs.

## Agent dispatch rules

- Every Agent call in Bag of Rats is a **pipeline stage completion** — when an agent finishes, it either dispatches the next agent in the chain (if inputs are ready) or waits for its inputs.
- **Implementers can write files.** When a model is on an IMPLEMENTING or REPAIR phase, it can directly edit files (Edit, Write, MultiEdit, NotebookEdit, file-mutating Bash).
- **Reviewers are also repair agents.** When a model is reviewing, it doesn't just return a list of issues — it directly applies corrections (like `minimax-review-repair` in FI-flow).
- **Grounding is read-only.** GROUNDING and VERIFY phases only use Read, Grep, Glob, Bash (read-only vocabulary).
- **Dispatch is bounded.** Each agent dispatch has a dispatch_id injected into its context. Results are validated against the active dispatch. Wrong, stale, or duplicate results are ignored.
- **Loop protection.** No model may repeat the same phase more than twice. After two failed repair attempts, escalate to GLM.

## Custom phases

You can override the default pipeline by specifying phases after the command:

```
/bag-of-rats phase1: design, phase2: implement in parser, phase3: test rust, phase4: review
```

Each phase name maps to a pipeline role:
- `design` → DESIGN phase (requires design authority)
- `implement` or `implement:<lang>` → IMPLEMENTING phase (assigned to roster model)
- `review` or `repair` → REPAIR phase (review + direct correction)
- `test` or `verify` or `<lang>-test` → VERIFY phase (read-only validation)
- `ground` or `grounding` → GROUNDING phase

If no phases are specified, the default pipeline runs.

## Synchronous vs async

The golden rule: **async first, sync only when necessary.**

- If multiple phase slots have their inputs ready → dispatch them all in parallel.
- If a phase only needs one upstream result → dispatch as soon as that one result lands.
- If a phase needs ALL upstream results → wait (barrier). This is rare — only for phases like final synthesis where you genuinely need every model's output.
- The pipeline should never "block" just because a model is slow when its output isn't needed by anyone else yet.

## Loop limits

- One GROUNDING pass (default DeepSeek, can be delegated to Qwen for a different perspective).
- One DESIGN pass per design authority (Kimi for T2, GLM for T3).
- Up to TWO IMPLEMENTING passes (if the first round needs rework).
- Up to THREE REPAIR passes (cheap Qwen first, then MiniMax, then GLM for stuck cases).
- One VERIFY pass.
- No model repeats a phase more than twice.
- After two repair attempts that produce the same failure signature → escalate to GLM final decision.

## When to use Bag of Rats vs FI-flow

Use Bag of Rats when:
- You want faster iteration through parallel model collaboration
- The task benefits from multiple models implementing and reviewing each other
- You want max parallelism over strict gate enforcement
- You're working on something where different models bring different strengths

Use FI-flow when:
- You need the strict two-signoff completion gate
- The task requires formal design authority approval before implementation
- You want the structured tier system (T0/T1/T2/T3) with its bounded escalation path

## Task

$ARGUMENTS
