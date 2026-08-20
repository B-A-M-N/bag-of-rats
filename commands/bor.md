---
name: bor
description: Activate the Bag of Rats multi-model async pipeline. Use "bor on" to start, or just /bor. Models alternate implementing and reviewing in an N-at-a-time pipeline. DeepSeek remains the implementation lead. Toggle off with /bor off.
disable-model-invocation: true
argument-hint: [on | custom phases...]
---

Activate the **Bag of Rats** pipeline.

## Usage

- `/bor` or `/bor on` — start Bag of Rats with the default phase pipeline
- `/bor ground, implement, review, verify` — start with custom phases
- `/bor off` — deactivates (see `bor-off.md`)

## What happens when you activate

The pipeline starts. The main model (you) is the orchestrator and implementation lead. Models in the roster — Qwen, MiniMax, Kimi, GLM — alternate as implementers and reviewers. Each phase dispatches as soon as its inputs are ready. The hook tracks the active round and blocks Stop until the pipeline completes or you explicitly deactivate.

$ARGUMENTS
