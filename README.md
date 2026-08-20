# Bag of Rats

A toggleable multi-model async pipeline for Claude Code. Type `/bor` and the
main model starts fanning work out to a pack of agents instead of doing
everything itself, one thing at a time.

## Why this exists

Parallelism in agentic coding is usually available but rarely used, because
using it costs more than doing the work serially. You have to decide how to
split the task, dispatch the workers, track which ones are still running,
notice when they've all finished, and merge whatever they each did to the
same files. That is real bookkeeping, and it is the kind of bookkeeping a
model quietly skips under pressure. So the default behavior becomes: one
agent, one file at a time, and the other N-1 available slots sit idle.

Bag of Rats exists to make maximum parallelism the easy path — the thing you
get by default rather than the thing you opt into and manage. It moves the
bookkeeping into a hook, so the orchestrating model only has to answer "what
can run right now?" and dispatch it.

The hook handles the rest:

- **Round tracking.** Every agent dispatch registers into the current round.
  When the last one stops, the round closes and the pipeline advances on its
  own. Nobody has to poll or remember.
- **Concurrent writes don't block.** Each agent past the first gets its own
  git worktree to edit in. Rats never wait on each other, and never fail a
  write because a sibling holds the file.
- **Merging is automatic by default.** Shadow trees reconcile back with a
  3-way merge when the round closes. Only genuine textual conflicts surface
  to a human, and they surface as an explicit queue rather than as silently
  lost edits.
- **One sync point, not many.** The pending-merge queue is the only place the
  pipeline stops to wait. Everything else runs async.

The result is that "dispatch three agents at once" costs about as much
thought as "dispatch one." The design bias throughout is async first, sync
only when a phase genuinely needs an upstream result — and the enforcement
lives in a hook, so it holds even when the model would rather cut corners.

It is also deliberately small. Bag of Rats is not a gate system and does not
review your work: there is no grounder gate, no design gate, no signoff
gate, no tier enforcement. It tracks rounds, keeps read-only phases
read-only, isolates concurrent writers, and holds Stop until the pipeline is
done. That is the entire scope.

Completely independent of `/fi-flow` — separate state root, separate hook,
separate commands. Neither workflow reads, writes, or knows about the other's
state. Activating one has zero effect on the other.

## What it is

Bag of Rats runs an N-at-a-time async pipeline where the main model
orchestrates a pack of rat agents that alternate between implementing and
reviewing. Rounds advance the moment their agents finish — the hook's only
job is to answer "did the round finish?" and hold Stop until the pipeline
completes.

## Commands

| command | effect |
|---------|--------|
| `/bor` or `/bor on` | activate with the default pipeline (GROUNDING → IMPLEMENTING → REPAIR → VERIFY) |
| `/bor <objective>` | activate with the objective recorded in state |
| `/bor design, implement, implement, repair, verify` | activate with a custom phase pipeline |
| `/bor off` (or `/bor-off`) | deactivate, release the Stop hold |
| `/bor config` | show current roles/concurrency/policy settings |
| `/bor config roles 2` | two-role structure: implement + review |
| `/bor config roles 3` | three-role structure: implement + review + arbiter |
| `/bor config concurrency 5` | raise the per-round agent dispatch cap |
| `/bor config policy auto` | git 3-way merge on shadow reconciliation, fall back to last-writer-wins |
| `/bor config policy last-writer-wins` | most recent shadow wins per file (fast, no merging) |
| `/bor config policy manual` | every shadow queued for orchestrator review (safest) |

Full aliases `/bag-of-rats`, `/bag-of-rats-off` also exist.

## Requirements

- Claude Code with hook support (`PreToolUse`, `SubagentStop`, `Stop`,
  `UserPromptSubmit`, `UserPromptExpansion`)
- `bash`, `python3`, `jq`
- `git` — required for shadow worktrees. Outside a git repo, multi-agent
  rounds run without shadow isolation.

## Install

```bash
git clone https://github.com/B-A-M-N/bag-of-rats.git
cd bag-of-rats
./install.sh                 # installs to $CLAUDE_CONFIG_DIR, or
                             # ~/.config/claude-code/freeinference
./install.sh /path/to/profile # or an explicit profile directory
```

The installer copies the hook, schema, smoke suite, commands, and orchestrator
agent into the profile, then merges its hook registrations into that profile's
`settings.json`. The merge is **additive and idempotent** — existing hooks,
permissions, model slots, and status line are left alone, and re-running
removes stale Bag of Rats registrations before adding current ones. An
existing `bor-settings.json` is never overwritten.

It then runs the smoke suite against the installed copy and restores
`settings.json` from its backup if any check fails.

## Roles

Configured in `bor-settings.json`, changeable via `/bor config`.

- **roles=2** — implement (main + forks) and review (qwen → minimax ladder).
- **roles=3** (default) — adds the **arbiter** tier, one tier above implement
  and review: kimi/glm arbitrate escalated disputes and provide final
  signoff. The orchestrator is always the main model regardless of role count.

**Concurrency** (`max_concurrent`, default 3) is hook-enforced: an `Agent`
dispatch beyond the cap is denied until earlier agents of the round stop.

## Rounds and phases

Every `Agent` dispatch registers into the current round. Each `SubagentStop`
marks one agent finished. When all registered agents of the round have
stopped, the round closes and the next phase becomes current automatically —
that's the whole state machine. Phases worked entirely in the main session
are closed with the hook's `advance` CLI command.

- GROUNDING / VERIFY are read-only: Edit/Write/MultiEdit/NotebookEdit and
  any shell write are denied during them. Read-only Bash (e.g. `cargo test`,
  `cat`, `ls`) is still allowed.
- **Write-safety via shadow trees, never blocks**: when a round dispatches
  more than one agent, each subsequent Agent dispatch auto-provisions a
  git worktree shadow under `.claude/worktrees/bor-<claim_id>/` against
  repo HEAD at dispatch time. Rats edit freely in their shadow — no
  blocking, no waiting. On `SubagentStop`, the shadow is reconciled into
  the working tree by `merge_policy` (see below). Single-agent rounds
  skip shadowing entirely (no concurrent writers).
- **Reconciliation policy** (`merge_policy` in `bor-settings.json`):
  - `auto` (default) — `git merge-file` 3-way against HEAD on every file
    the shadow touched. Clean merges land immediately; textual conflicts
    queue into `bor_pending_merges[]`.
  - `last-writer-wins` — most recent shadow wins per file, no merging.
  - `manual` — every shadowed file goes straight into
    `bor_pending_merges[]` for orchestrator review.
- **The round holds while merges are pending.** True conflicts under
  `auto` (or any shadow under `manual`) are the orchestrator's
  responsibility: read the queue, resolve by editing `bor_pending_merges[]`
  and applying the merged file, then continue. The round cannot advance
  until the queue is empty — that is the only sync point.
- Stop is blocked while the pipeline is active and incomplete, and passes
  through `stop_hook_active=true` retry sentinels.
- `/bor off` always deactivates, even from corrupt state — it is the recovery
  path.

## Isolation from /fi-flow

- Separate state roots: `harvardclaude-bagofrats-$UID/` vs
  `harvardclaude-flow-$UID/`. No shared files.
- The BoR hook never references fi-flow state, agent names, or gates; it is
  agent-agnostic (any subagent_type is a valid rat).
- With no BoR state (or inactive state), every BoR hook event is a strict
  no-op — exit 0, no writes. FI-flow behavior is byte-identical whether or
  not BoR is installed.
- BoR has no grounder gate, no design gate, no signoff gate, no tier system.
  The only enforcement is: round tracking, read-only-phase write denial,
  per-agent shadow worktrees with policy-driven reconciliation, the
  pending-merge queue (the only sync point), concurrency cap, and the Stop
  hold.

## Files

```
install.sh                      installer (additive settings.json merge + smoke gate)
bag-of-rats-hook.sh             state machine + CLI (activate/deactivate/advance/config/status)
bag-of-rats-state.schema.json   pipeline state schema
bag-of-rats-install-smoke.test.sh  functional suite (74 checks)
bor-settings.json               roles + concurrency + merge policy
hooks-registration.json         hook registrations merged into settings.json
commands/bor.md                 /bor activation
commands/bor-off.md             /bor off
commands/bor-config.md          /bor config
commands/bag-of-rats.md         full-name alias
commands/bag-of-rats-off.md     full-name alias
agents/bag-of-rats-orchestrator.md  main-model orchestrator instructions
```

## Verify it works

From the source package:

```bash
bash bag-of-rats-install-smoke.test.sh
```

Against an installed profile (default profile path shown; `install.sh` honors
`CLAUDE_CONFIG_DIR` and an explicit directory argument):

```bash
bash ~/.config/claude-code/freeinference/bag-of-rats-install-smoke.test.sh
```

`install.sh` runs this suite automatically against the installed copy and
rolls `settings.json` back from its backup if any check fails.

74 checks: static files, activation, custom phases, round tracking and
auto-advance, concurrency caps, Stop gating, read-only-phase guards,
shadow-tree provisioning for >1-agent rounds, auto-reconciliation under
last-writer-wins, auto-policy 3-way merge with pending-queue gating,
diagnostic claim recording, shell-redirect-target detection, merge-policy
config (auto / last-writer-wins / manual), completion, corrupt-state
recovery, `/bor on|off` via prompt expansion, config persistence, and
fi-flow isolation.

## A note on FreeInference.org

Bag of Rats was developed and tested using inference made available by **FreeInference.org**. Access to that capacity materially enabled the experimentation that produced this project, and I want to acknowledge that plainly.

**Disclosure:** I have no affiliation with FreeInference.org. I am not sponsored, compensated, employed, or otherwise incentivized by them. They did not request, review, approve, endorse, or participate in Bag of Rats or in this acknowledgement. I speak only for myself.

Just as importantly, **this is not a recommendation to run Bag of Rats against FreeInference.org.**

Bag of Rats makes it easy to fan a task out across multiple model agents concurrently. It does not itself provide inference or require FreeInference.org, but when the models behind those agents are served by a remote provider, using Bag of Rats can multiply the amount of inference consumed by a single task.

That is exactly why a small, freely accessible inference service is the wrong target for sustained Bag of Rats workloads.

Free inference is not free to operate. Someone is supplying the GPUs, electricity, bandwidth, engineering, and maintenance. A parallel agent harness can consume that shared capacity much faster than an ordinary interactive session, potentially reducing what remains available to everybody else.

If you use Bag of Rats regularly, point its agents at **local models, infrastructure you control, or inference capacity you are paying for.**

My reason for mentioning FreeInference.org is therefore not "go consume this service." It is nearly the opposite.

I think infrastructure that keeps capable inference accessible to people without significant funding is worth recognizing and supporting. Independent developers, researchers, students, and hobbyists can only experiment with systems like this when they can reach the underlying models in the first place. If access to capable models exists only for those able to purchase substantial compute, experimentation and capability increasingly concentrate in the same places as capital.

Making inference openly accessible is expensive and largely invisible infrastructure work. It enables projects whose authors may never be in a position to repay the compute they consumed.

So the distinction I want to make is simple:

**If what you have is a workload, send it somewhere else.**

**If what you have is money, hardware, infrastructure, or other resources you want to direct toward keeping inference accessible, FreeInference.org is worth considering.**

And if neither applies, you do not need to do anything. This acknowledgement is not intended to drive traffic to their inference endpoints or encourage additional consumption of their service.

FreeInference.org did not solicit this statement, and I am not soliciting anything on their behalf.

## License

MIT — see [LICENSE](LICENSE).


