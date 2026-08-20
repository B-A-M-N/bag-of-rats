---
name: bor-config
description: View or change Bag of Rats settings — role count (2 or 3) and max concurrent agents per round. Use "/bor config" to show current settings, "/bor config roles 2" or "/bor config concurrency 5" to change them.
disable-model-invocation: true
argument-hint: [show | roles <2|3> | concurrency <n>]
---

Configure the **Bag of Rats** pipeline. All settings live in
`${CLAUDE_CONFIG_DIR:-~/.config/claude-code/freeinference}/bor-settings.json`
and take effect on the next round — the current running round finishes under
the settings it started with.

## Settings

- **roles** (2 or 3, default 3) — how many role tiers the rats are organized into.
  - `2`: implement (main + forks) and review (qwen → minimax ladder).
  - `3`: adds the **arbiter** tier — one tier above implement and review
    (kimi/glm). Arbiters handle escalated disputes and final signoff. The
    orchestrator is always the main model regardless of role count.
- **concurrency** (default 3) — max agents dispatched concurrently per round.
  The hook enforces this cap at dispatch time: extra Agent calls are denied
  until earlier agents stop.

## What to do

Run the `bor-config` CLI action of the hook to view or mutate settings:

```bash
"${CLAUDE_CONFIG_DIR:-$HOME/.config/claude-code/freeinference}/bag-of-rats-hook.sh" config show
"${CLAUDE_CONFIG_DIR:-$HOME/.config/claude-code/freeinference}/bag-of-rats-hook.sh" config roles 2
"${CLAUDE_CONFIG_DIR:-$HOME/.config/claude-code/freeinference}/bag-of-rats-hook.sh" config concurrency 5
```

Show the user the resulting settings after any change. Do not edit
bor-settings.json by hand while a pipeline is running; use these commands so
the active state records the change.

$ARGUMENTS
