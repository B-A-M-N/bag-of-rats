#!/usr/bin/env bash
# bag-of-rats-install-smoke.test.sh — functional smoke for Bag of Rats
#
# Two layers:
#   Static: files exist, executable, valid JSON, hooks registered.
#   Functional: drive the hook CLI end-to-end in a private state dir —
#     activate -> register dispatches -> close rounds -> complete -> Stop
#     releases; and deactivate-recovery from corrupt state.
#
# Self-contained: BOR_STATE_DIR is pointed at a private temp dir; live session
# state is never touched.

set -uo pipefail

# Profile dir: the directory containing this test (package-relative),
# or an explicit full profile via BOR_PROFILE_DIR.
PROGDIR="${BOR_PROFILE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BOR_STATE_DIR="$(mktemp -d)"
export BOR_STATE_DIR
# Sandbox the config file too: tests mutate roles/concurrency and must
# never touch the live profile settings.
BOR_PROFILE_TEST_DIR="$(mktemp -d)"
mkdir -p "$BOR_PROFILE_TEST_DIR"
cp "$PROGDIR/bor-settings.json" "$BOR_PROFILE_TEST_DIR/bor-settings.json"
export BOR_PROFILE_DIR="$BOR_PROFILE_TEST_DIR"
export BOR_SESSION_ID="smoke-test"
HOOK="$PROGDIR/bag-of-rats-hook.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

state() { jq -r "$1" "$BOR_STATE_DIR/$BOR_SESSION_ID.json"; }

echo "Bag of Rats functional smoke test"
echo "Profile: $PROGDIR  State dir: $BOR_STATE_DIR"
echo ""

echo "== Static checks =="
for f in bag-of-rats-hook.sh bag-of-rats-state.schema.json \
         commands/bor.md commands/bor-off.md \
         commands/bag-of-rats.md commands/bag-of-rats-off.md \
         agents/bag-of-rats-orchestrator.md; do
  check "file exists: $f" test -f "$PROGDIR/$f"
done
check "hook is executable" test -x "$HOOK"
check "hook passes bash -n" bash -n "$HOOK"
check "schema is valid JSON" python3 -c "import json; json.load(open('$PROGDIR/bag-of-rats-state.schema.json'))"
check "settings.json registers bor hooks" python3 - "
import json
s = json.load(open('$PROGDIR/settings.json'))
n = sum('bag-of-rats-hook.sh' in h.get('command','')
        for lst in s.get('hooks',{}).values() for e in lst for h in e.get('hooks',[]))
assert n >= 4, f'only {n} bor hooks'
"
check "prompt-expansion matcher covers /bor short forms" python3 - "
import json, re
s = json.load(open('$PROGDIR/settings.json'))
matched = None
for e in s['hooks'].get('UserPromptExpansion', []):
    if any('bag-of-rats' in h.get('command','') for h in e.get('hooks', [])):
        matched = e.get('matcher','')
        break
assert matched, 'no bor prompt-expansion registration'
for cmd in ('bor', 'bor-off', 'bor-config', 'bag-of-rats', 'bag-of-rats-off'):
    assert re.search(matched, cmd), f'{cmd} not matched by {matched}'
"
check "no bor PostToolUse leftovers" python3 - "
import json
s = json.load(open('$PROGDIR/settings.json'))
for ev in ('PostToolUse', 'PostToolUseFailure'):
    for e in s['hooks'].get(ev, []):
        for h in e.get('hooks', []):
            assert 'bag-of-rats' not in h.get('command',''), f'{ev} still has bor registration'
"
if [ -f "$PROGDIR/freeinference-statusline.sh" ]; then
  check "statusline references BoR" grep -q 'BOR_SEGMENT' "$PROGDIR/freeinference-statusline.sh"
else
  echo "  SKIP: statusline segment (no freeinference-statusline.sh in package)"
fi
echo ""

echo "== CLI: activate =="
out="$("$HOOK" activate "test objective" "" 2>&1)"
if echo "$out" | grep -q 'GROUNDING'; then pass "activate builds GROUNDING pipeline"; else fail "activate output: $out"; fi
check "state file created" test -f "$BOR_STATE_DIR/$BOR_SESSION_ID.json"
[ "$(state .active)" = "true" ] && pass "active=true" || fail "active=$(state .active)"
[ "$(state .phase)" = "GROUNDING" ] && pass "phase=GROUNDING" || fail "phase=$(state .phase)"
[ "$(state .round)" = "1" ] && pass "round=1" || fail "round=$(state .round)"
echo ""

echo "== CLI: custom phases =="
"$HOOK" activate "obj2" "design, implement, implement, repair, verify" >/dev/null 2>&1
types="$(state '.pipeline_phases | map(.type) | join(",")')"
[ "$types" = "DESIGN,IMPLEMENTING,IMPLEMENTING,REPAIR,VERIFY,COMPLETE" ] \
  && pass "custom phases parse ($types)" || fail "custom phases: $types"
models="$(state '.pipeline_phases | map(.assigned_model) | join(",")')"
[ "$models" = "kimi,main,main,qwen,qwen," ] \
  && pass "model assignment ladder ($models)" || fail "models: $models"
echo ""

echo "== Rounds: register + auto-advance =="
# Re-activate the default pipeline so section-local state is independent of
# the custom-phases section above.
"$HOOK" activate "test objective" "" >/dev/null 2>&1
# Round 1 (GROUNDING): dispatch two agents in parallel
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"qwen-grounder"}}' | "$HOOK" pre-tool >/dev/null 2>&1
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork"}}' | "$HOOK" pre-tool >/dev/null 2>&1
[ "$(state '.running_agents["qwen-grounder"].pending')" = "1" ] && pass "qwen dispatch registered" || fail "qwen pending=$(state '.running_agents["qwen-grounder"].pending // "missing"')"
[ "$(state '.running_agents.fork.pending')" = "1" ] && pass "fork dispatch registered" || fail "fork pending=$(state '.running_agents.fork.pending // "missing"')"
# First stop: round must NOT advance (one agent still pending)
echo '{"session_id":"smoke-test","agent_type":"qwen-grounder"}' | "$HOOK" subagent-stop >/dev/null 2>&1
[ "$(state .phase)" = "GROUNDING" ] && pass "round holds while agent pending" || fail "premature advance to $(state .phase)"
# Second stop: round closes, advances to IMPLEMENTING
echo '{"session_id":"smoke-test","agent_type":"fork"}' | "$HOOK" subagent-stop >/dev/null 2>&1
[ "$(state .phase)" = "IMPLEMENTING" ] && pass "round auto-advances on last stop" || fail "phase=$(state .phase)"
[ "$(state .round)" = "2" ] && pass "round counter increments" || fail "round=$(state .round)"
[ "$(state '.completed_phases | length')" = "1" ] && pass "completed phase recorded with models" || fail "completed_phases=$(state '.completed_phases | length')"
[ "$(state '.completed_phases[0].models | join("+")')" = "qwen-grounder+fork" ] && pass "models attributed" || fail "models=$(state '.completed_phases[0].models | join("+")')"
echo ""

echo "== advance: main-session phase =="
# Round 2 (IMPLEMENTING): worked by main, no agents dispatched
"$HOOK" advance >/dev/null 2>&1
[ "$(state .phase)" = "REPAIR" ] && pass "advance closes main-session round" || fail "phase=$(state .phase)"
[ "$(state .round)" = "3" ] && pass "round=3 after advance" || fail "round=$(state .round)"
echo ""

echo "== Stop gating =="
# Pipeline idle + incomplete -> block (work left to dispatch)
if echo '{"session_id":"smoke-test","stop_hook_active":false}' | "$HOOK" stop >/dev/null 2>&1; then
  fail "stop released while idle and incomplete"
else
  pass "stop blocked when idle and incomplete"
fi
# stop_hook_active=true is the Stop-retry sentinel: the hook must pass it
# through, else Claude Code loops forever on a blocked turn.
if echo '{"session_id":"smoke-test","stop_hook_active":true}' | "$HOOK" stop >/dev/null 2>&1; then
  pass "stop_hook_active=true passes through"
else
  fail "stop blocked on retry flag"
fi
# Agents pending is async-by-design: the turn may end; SubagentStop re-drives
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"qwen-grounder"}}' | "$HOOK" pre-tool >/dev/null 2>&1
if echo '{"session_id":"smoke-test","stop_hook_active":false}' | "$HOOK" stop >/dev/null 2>&1; then
  pass "stop allowed while agents pending (async-first)"
else
  fail "stop blocked with agents pending — breaks parallelism"
fi
echo '{"session_id":"smoke-test","agent_type":"qwen-grounder"}' | "$HOOK" subagent-stop >/dev/null 2>&1
echo ""

echo "== read-only phase write guard =="
# Stop-gating section left the pipeline in VERIFY (round 4)
echo '{"session_id":"smoke-test","tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}' | "$HOOK" pre-tool >/dev/null 2>&1
[ $? -ne 0 ] && pass "Edit denied in VERIFY" || fail "Edit allowed in VERIFY"
echo '{"session_id":"smoke-test","tool_name":"Bash","tool_input":{"command":"cargo test"}}' | "$HOOK" pre-tool >/dev/null 2>&1
[ $? -eq 0 ] && pass "Bash allowed in VERIFY (read-only run)" || fail "Bash denied in VERIFY"
echo ""

echo "== completion =="
"$HOOK" advance >/dev/null 2>&1   # closes VERIFY -> COMPLETE
[ "$(state .complete)" = "true" ] && pass "pipeline completes" || fail "complete=$(state .complete)"
echo '{"session_id":"smoke-test","stop_hook_active":false}' | "$HOOK" stop >/dev/null 2>&1
[ $? -eq 0 ] && pass "stop releases when complete" || fail "stop still blocked at COMPLETE"
echo ""

echo "== deactivate + corrupt recovery =="
"$HOOK" activate "again" "" >/dev/null 2>&1
echo 'not json {{{' > "$BOR_STATE_DIR/$BOR_SESSION_ID.json"
echo '{"session_id":"smoke-test","stop_hook_active":false}' | "$HOOK" stop >/dev/null 2>&1
[ $? -ne 0 ] && pass "corrupt state blocks stop (fail closed)" || fail "corrupt state disarmed stop"
"$HOOK" deactivate >/dev/null 2>&1
echo '{"session_id":"smoke-test","stop_hook_active":false}' | "$HOOK" stop >/dev/null 2>&1
[ $? -eq 0 ] && pass "deactivate recovers from corrupt state" || fail "deactivate failed on corrupt state"
echo ""

echo "== /bor off via prompt-expansion =="
"$HOOK" activate "x" "" >/dev/null 2>&1
[ "$(state .active)" = "true" ] && pass "re-activated for off test" || fail "re-activation failed"
echo '{"session_id":"smoke-test","command":"bor","arguments":"off"}' | "$HOOK" prompt-expansion >/dev/null 2>&1
[ "$(state .active)" = "false" ] && pass "/bor off deactivates" || fail "active=$(state .active)"
# prompt-expansion of an unrelated command must not activate anything
rm -f "$BOR_STATE_DIR/$BOR_SESSION_ID.json"
echo '{"session_id":"smoke-test","command":"goal","arguments":"status"}' | "$HOOK" prompt-expansion >/dev/null 2>&1
[ ! -f "$BOR_STATE_DIR/$BOR_SESSION_ID.json" ] && pass "unrelated command ignored" || fail "unrelated command created state"
echo ""

echo "== /bor on via prompt-expansion =="
echo '{"session_id":"smoke-test","command":"bor","arguments":"on"}' | "$HOOK" prompt-expansion >/dev/null 2>&1
sleep 0.2
[ "$(state .active)" = "true" ] && pass "/bor on activates" || fail "active=$(state .active)"
echo '{"session_id":"smoke-test","command":"bor","arguments":"design, implement, verify"}' | "$HOOK" prompt-expansion >/dev/null 2>&1
sleep 0.2
[ "$(state '.pipeline_phases | length')" -ge 3 ] && pass "/bor <phases> activates with custom pipeline" || fail "pipeline len=$(state '.pipeline_phases | length')"
echo ""

echo "== config command =="
if "$HOOK" config show >/dev/null 2>&1; then pass "config show works"; else fail "config show failed"; fi
"$HOOK" config roles 2 >/dev/null 2>&1
[ "$(jq -r .roles "$BOR_PROFILE_DIR/bor-settings.json")" = "2" ] && pass "config roles 2 persists" || fail "roles=$(jq -r .roles "$BOR_PROFILE_DIR/bor-settings.json")"
"$HOOK" config roles 3 >/dev/null 2>&1
[ "$(jq -r .roles "$BOR_PROFILE_DIR/bor-settings.json")" = "3" ] && pass "config roles 3 persists" || fail "roles=$(jq -r .roles "$BOR_PROFILE_DIR/bor-settings.json")"
"$HOOK" config concurrency 5 >/dev/null 2>&1
[ "$(jq -r .max_concurrent "$BOR_PROFILE_DIR/bor-settings.json")" = "5" ] && pass "config concurrency 5 persists" || fail "conc=$(jq -r .max_concurrent "$BOR_PROFILE_DIR/bor-settings.json")"
"$HOOK" config concurrency 3 >/dev/null 2>&1
if "$HOOK" config roles 9 >/dev/null 2>&1; then fail "invalid roles accepted"; else pass "invalid roles rejected"; fi
echo ""

echo "== concurrency cap =="
"$HOOK" activate "cap test" "" >/dev/null 2>&1
for i in 1 2 3; do
  echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork"}}' | "$HOOK" pre-tool >/dev/null 2>&1
done
if echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork"}}' | "$HOOK" pre-tool >/dev/null 2>&1; then
  fail "4th dispatch allowed over cap"
else
  pass "4th dispatch denied at concurrency cap"
fi
# one agent stops -> cap frees a slot
echo '{"session_id":"smoke-test","agent_type":"fork"}' | "$HOOK" subagent-stop >/dev/null 2>&1
if echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"qwen-grounder"}}' | "$HOOK" pre-tool >/dev/null 2>&1; then
  pass "slot frees after SubagentStop"
else
  fail "slot not freed after stop"
fi
echo ""

echo "== shadow trees: per-agent worktree provisioned when round has >1 agent =="
# The shadow tree contract: when more than one agent is dispatched in a round
# AND the project is a git repo, each dispatch gets a `.claude/worktrees/bor-<claim_id>/`
# worktree. We construct a temp git repo for the hook to operate against.
SHADOW_REPO="$(mktemp -d)"
cd "$SHADOW_REPO"
git init -q .
git config user.email "bor@bag-of-rats" && git config user.name "BoR"
echo seed > seed.txt && git add seed.txt && git commit -qm "seed"
mkdir -p .claude/worktrees
cd - >/dev/null
# Run activate in this repo, advance to IMPLEMENTING, dispatch two agents.
export BOR_REPO_ROOT="$SHADOW_REPO"
"$HOOK" activate "shadow test" "" >/dev/null 2>&1
"$HOOK" advance >/dev/null 2>&1   # GROUNDING -> IMPLEMENTING
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork","agent_id":"s1"}}' | "$HOOK" pre-tool >/dev/null 2>&1
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork","agent_id":"s2"}}' | "$HOOK" pre-tool >/dev/null 2>&1
s1_shadow="$(jq -r '.running_agents.fork.instances[0].shadow // "missing"' "$BOR_STATE_DIR/$BOR_SESSION_ID.json")"
s2_shadow="$(jq -r '.running_agents.fork.instances[1].shadow // "missing"' "$BOR_STATE_DIR/$BOR_SESSION_ID.json")"
[ -d "$s1_shadow" ] && pass "fork:0 shadow provisioned" || fail "no shadow at $s1_shadow"
[ -d "$s2_shadow" ] && pass "fork:1 shadow provisioned" || fail "no shadow at $s2_shadow"
[ "$s1_shadow" != "$s2_shadow" ] && pass "shadows are distinct per dispatch" || fail "shadows collapsed"
# Single-agent round should NOT shadow (the round has only 1 active agent).
"$HOOK" activate "single test" "" >/dev/null 2>&1
"$HOOK" advance >/dev/null 2>&1
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork","agent_id":"solo"}}' | "$HOOK" pre-tool >/dev/null 2>&1
solo_shadow="$(jq -r '.running_agents.fork.instances[0].shadow' "$BOR_STATE_DIR/$BOR_SESSION_ID.json")"
[ "$solo_shadow" = "null" ] && pass "single-agent round skips shadow" || fail "solo round provisioned shadow=$solo_shadow"
unset BOR_REPO_ROOT
echo ""

echo "== shadow trees: reconciliation on SubagentStop (last-writer-wins) =="
SHADOW_REPO="$(mktemp -d)"
cd "$SHADOW_REPO"
git init -q .
git config user.email "bor@bag-of-rats" && git config user.name "BoR"
echo "shared" > shared.txt && git add shared.txt && git commit -qm "init"
mkdir -p .claude/worktrees
cd - >/dev/null
export BOR_REPO_ROOT="$SHADOW_REPO"
"$HOOK" config policy last-writer-wins >/dev/null 2>&1
"$HOOK" activate "reconcile test" "" >/dev/null 2>&1
"$HOOK" advance >/dev/null 2>&1
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork","agent_id":"k1"}}' | "$HOOK" pre-tool >/dev/null 2>&1
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork","agent_id":"k2"}}' | "$HOOK" pre-tool >/dev/null 2>&1
k1_shadow="$(jq -r '.running_agents.fork.instances[0].shadow' "$BOR_STATE_DIR/$BOR_SESSION_ID.json")"
k2_shadow="$(jq -r '.running_agents.fork.instances[1].shadow' "$BOR_STATE_DIR/$BOR_SESSION_ID.json")"
# Each fork writes a different file in its shadow.
echo "k1-wrote" > "$k1_shadow/file1.txt"
echo "k2-wrote" > "$k2_shadow/file2.txt"
# k1 finishes -> its shadow reconciles.
echo '{"session_id":"smoke-test","agent_type":"fork","agent_name":"k1"}' | "$HOOK" subagent-stop >/dev/null 2>&1
[ -f "$SHADOW_REPO/file1.txt" ] && pass "k1 shadow reconciled to repo (file1.txt)" || fail "file1.txt not in repo"
[ -f "$SHADOW_REPO/file2.txt" ] && fail "k2 shadow reconciled early" || pass "k2 shadow not yet reconciled"
# k2 finishes -> its shadow reconciles.
echo '{"session_id":"smoke-test","agent_type":"fork","agent_name":"k2"}' | "$HOOK" subagent-stop >/dev/null 2>&1
[ -f "$SHADOW_REPO/file2.txt" ] && pass "k2 shadow reconciled to repo (file2.txt)" || fail "file2.txt not in repo"
# Round should auto-advance (no pending merges under last-writer-wins).
[ "$(state .round)" = "3" ] && pass "round advanced after both reconciliations" || fail "round stuck at $(state .round)"
unset BOR_REPO_ROOT
echo ""

echo "== shadow trees: auto policy (git merge-file 3-way, conflicts queued) =="
SHADOW_REPO="$(mktemp -d)"
cd "$SHADOW_REPO"
git init -q .
git config user.email "bor@bag-of-rats" && git config user.name "BoR"
cat > common.txt <<'EOF'
line1
line2
line3
EOF
git add common.txt && git commit -qm "base"
mkdir -p .claude/worktrees
cd - >/dev/null
export BOR_REPO_ROOT="$SHADOW_REPO"
"$HOOK" config policy auto >/dev/null 2>&1
"$HOOK" activate "merge-file test" "" >/dev/null 2>&1
"$HOOK" advance >/dev/null 2>&1
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork","agent_id":"m1"}}' | "$HOOK" pre-tool >/dev/null 2>&1
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork","agent_id":"m2"}}' | "$HOOK" pre-tool >/dev/null 2>&1
m1_shadow="$(jq -r '.running_agents.fork.instances[0].shadow' "$BOR_STATE_DIR/$BOR_SESSION_ID.json")"
m2_shadow="$(jq -r '.running_agents.fork.instances[1].shadow' "$BOR_STATE_DIR/$BOR_SESSION_ID.json")"
# m1 edits line2 -> "k1:line2"; m2 edits line2 -> "k2:line2" (a textual
# conflict on the same line). Both reconcile in shadow.
printf 'line1\nk1:line2\nline3\n' > "$m1_shadow/common.txt"
printf 'line1\nk2:line2\nline3\n' > "$m2_shadow/common.txt"
echo '{"session_id":"smoke-test","agent_type":"fork","agent_name":"m1"}' | "$HOOK" subagent-stop >/dev/null 2>&1
echo '{"session_id":"smoke-test","agent_type":"fork","agent_name":"m2"}' | "$HOOK" subagent-stop >/dev/null 2>&1
# Pending merges should hold the conflict; round must NOT advance until
# orchestrator resolves.
[ "$(state '.bor_pending_merges | length')" -ge 1 ] && pass "auto policy queues textual conflict" || fail "no pending merge queued"
[ "$(state .round)" = "2" ] && pass "round held until orchestrator resolves" || fail "round advanced prematurely to $(state .round)"
# Orchestrator "resolves" by clearing the queue (the actual merge is the
# orchestrator's responsibility; the hook just holds the round).
state_file="$BOR_STATE_DIR/$BOR_SESSION_ID.json"
python3 - "$state_file" <<'PY'
import json, sys
f = sys.argv[1]
with open(f) as fh:
    s = json.load(fh)
s['bor_pending_merges'] = []
import tempfile, os
d = os.path.dirname(f)
fd, tmp = tempfile.mkstemp(dir=d)
with os.fdopen(fd, 'w') as fh:
    json.dump(s, fh, indent=2)
os.replace(tmp, f)
PY
# Drain by sending one more stop so round advances. (No agents pending, no
# merges, dispatch was already true, round should advance now.)
"$HOOK" advance >/dev/null 2>&1 || true
[ "$(state .round)" = "3" ] && pass "round advances once queue cleared" || fail "round stuck at $(state .round) after clear"
unset BOR_REPO_ROOT
echo ""

echo "== write-safety: claims are recorded (diagnostic, not enforced) =="
# Claims are tracked for observability and for manual policy, but the hook
# no longer BLOCKS on overlap. Two writers can race — the shadow tree and
# the reconciler policy are the actual isolation mechanism.
"$HOOK" config policy auto >/dev/null 2>&1
"$HOOK" activate "claim diag" "" >/dev/null 2>&1
"$HOOK" advance >/dev/null 2>&1
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork","agent_id":"d1"}}' | "$HOOK" pre-tool >/dev/null 2>&1
echo '{"session_id":"smoke-test","tool_name":"Agent","tool_input":{"subagent_type":"fork","agent_id":"d2"}}' | "$HOOK" pre-tool >/dev/null 2>&1
echo '{"session_id":"smoke-test","tool_name":"Write","tool_input":{"file_path":"/tmp/diag.txt","agent_id":"d1"}}' | "$HOOK" pre-tool >/dev/null 2>&1
[ "$(state '.file_claims["/tmp/diag.txt"]')" = "d1" ] && pass "write claim recorded" || fail "claim missing"
if echo '{"session_id":"smoke-test","tool_name":"Write","tool_input":{"file_path":"/tmp/diag.txt","agent_id":"d2"}}' | "$HOOK" pre-tool >/dev/null 2>&1; then
  pass "second writer not blocked (shadows absorb it)"
else
  fail "second writer was blocked (should be async-first)"
fi
# Distinct files are still fine.
if echo '{"session_id":"smoke-test","tool_name":"Write","tool_input":{"file_path":"/tmp/diag-other.txt","agent_id":"d2"}}' | "$HOOK" pre-tool >/dev/null 2>&1; then
  pass "distinct files pass"
else
  fail "distinct files blocked"
fi
echo ""

echo "== write-safety: Bash redirect target recorded (diagnostic) =="
echo '{"session_id":"smoke-test","tool_name":"Bash","tool_input":{"command":"printf x > /tmp/redir2.txt","agent_id":"d1"}}' | "$HOOK" pre-tool >/dev/null 2>&1
[ "$(state '.file_claims["/tmp/redir2.txt"]')" = "d1" ] && pass "Bash redirect target recorded" || fail "no redirect claim"
# Read-only Bash does NOT register a claim.
echo '{"session_id":"smoke-test","tool_name":"Bash","tool_input":{"command":"cat /tmp/redir2.txt","agent_id":"d2"}}' | "$HOOK" pre-tool >/dev/null 2>&1
[ "$(state '.file_claims["/tmp/redir2.txt"]')" = "d1" ] && pass "read-only Bash does not steal claim" || fail "read-only Bash overwrote claim"
echo ""

echo "== merge policy command =="
"$HOOK" config policy auto 2>&1 | grep -q 'merge_policy = auto' && pass "policy auto persists" || fail "policy auto"
"$HOOK" config policy last-writer-wins 2>&1 | grep -q 'last-writer-wins' && pass "policy last-writer-wins persists" || fail "policy lww"
"$HOOK" config policy manual 2>&1 | grep -q 'manual' && pass "policy manual persists" || fail "policy manual"
if "$HOOK" config policy bogus >/dev/null 2>&1; then fail "invalid policy accepted"; else pass "invalid policy rejected"; fi
echo ""

echo "== isolation from fi-flow =="
if grep -q 'harvardclaude-flow' "$HOOK"; then fail "bor hook references fi-flow state root"; else pass "bor hook never references fi-flow state"; fi
if grep -qE 'qwen-grounder|minimax-review-repair|kimi-escalation-review|glm-critical-gate|completion-controller|completion-reviewer' "$HOOK"; then
  fail "bor hook hard-codes fi-flow agent names"
else
  pass "bor hook is agent-agnostic (no fi-flow names)"
fi
# no state at all: every hook event must be a no-op
rm -rf "$BOR_STATE_DIR"; mkdir -p "$BOR_STATE_DIR"
if echo '{"session_id":"iso","tool_name":"Edit","tool_input":{}}' | "$HOOK" pre-tool >/dev/null 2>&1; then
  pass "Edit passes with no BoR state"
else
  fail "Edit denied with no BoR state"
fi
if echo '{"session_id":"iso","stop_hook_active":false}' | "$HOOK" stop >/dev/null 2>&1; then
  pass "stop passes with no BoR state"
else
  fail "stop blocked with no BoR state"
fi
echo ""

rm -rf "$BOR_STATE_DIR" "$BOR_PROFILE_TEST_DIR"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
