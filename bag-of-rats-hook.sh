#!/usr/bin/env bash
#
# bag-of-rats-hook.sh — Bag of Rats pipeline round tracker
#
# The hooks exist to answer one question: has the current round finished so
# the next phase can be dispatched? Everything else is advisory.
#
# Contract:
#   1. /bor (or /bag-of-rats) activates the pipeline. /bor off deactivates it.
#   2. Every Agent dispatch is registered in PreToolUse as a member of the
#      current round. N-at-a-time: any number of concurrent agents per round.
#   3. Each SubagentStop marks one registered agent finished. When every agent
#      of the round has finished, the round completes and the pipeline
#      advances to the next phase automatically.
#   4. Phases the main session works itself (no subagents) are closed with the
#      `advance` CLI command.
#   5. Stop is async-first: agents still pending is the pipeline working —
#      let the turn end and let SubagentStop re-drive it. Stop is blocked
#      only when the pipeline is idle (no agents running) with work left.
#   6. Fail closed on Stop: an unreadable state file blocks rather than disarms.
#   7. Write safety: never block async on conflict. When a round dispatches
#      more than one agent, each subsequent Agent dispatch automatically
#      provisions a git worktree shadow under .claude/worktrees/bor-<claim_id>/
#      off the repo HEAD at dispatch time. Rats edit freely in their shadow.
#      On SubagentStop, the shadow is reconciled back into the working tree
#      with `git merge-file` (3-way). True unresolvable conflicts land in
#      `bor_pending_merges[]`; the orchestrator (main session) is then
#      required to resolve before the round advances. Configuration:
#      `merge_policy` in bor-settings.json = `auto` (merge-file, fall back
#      to last-writer-wins on text conflicts) | `last-writer-wins`
#      | `manual` (every shadow lands in the queue).
#
# Hook events (JSON payload on stdin, per the Claude Code hook contract):
#   prompt-expansion   UserPromptExpansion  — /bor | /bor-off toggle
#   pre-tool           PreToolUse           — register Agent dispatches, guard read-only phases
#   subagent-stop      SubagentStop         — mark one agent finished, advance the round
#   stop               Stop                 — hold the turn until the pipeline completes
#   prompt             UserPromptSubmit     — one-line pipeline context
#
# CLI commands (no stdin payload required):
#   activate [objective] [phases-csv]   build a fresh active pipeline
#   deactivate                          clear activation (recovers corrupt state)
#   advance                             close the current round, start the next phase
#   status                              print the state document
#
# State: ${BOR_STATE_DIR:-${TMPDIR:-/tmp}/harvardclaude-bagofrats-$UID}/<session-id>.json
# Hook events key state by the payload session_id. CLI commands prefer
# BOR_SESSION_ID, then the most recently updated state file (single active
# session), so the model can drive the pipeline without knowing the id.

set -euo pipefail
umask 077

HOOK_EVENT="${1:-}"
PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD="$(cat 2>/dev/null || true)"
fi

STATE_DIR="${BOR_STATE_DIR:-${TMPDIR:-/tmp}/harvardclaude-bagofrats-${UID:-0}}"
PROFILE_DIR="${BOR_PROFILE_DIR:-${CLAUDE_CONFIG_DIR:-${HOME}/.config/claude-code/freeinference}}"

# --- payload helpers ---------------------------------------------------------

payload_fields() {
  # Print one line per requested dotted key ("tool_input.subagent_type").
  # The payload travels as argv[1] so stdin stays free; `python3 -c` because a
  # heredoc would occupy stdin and starve json.load below.
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    d = {}
for key in sys.argv[2:]:
    v = d
    for part in key.split("."):
        v = v.get(part, "") if isinstance(v, dict) else ""
    print(v if isinstance(v, str) else json.dumps(v))
' "$PAYLOAD" "$@" 2>/dev/null || true
}

state_file_for_session() {
  local sid=""
  if [ -n "$PAYLOAD" ]; then
    sid="$(payload_fields session_id)"
  fi
  if [ -z "$sid" ]; then
    sid="${BOR_SESSION_ID:-}"
  fi
  if [ -z "$sid" ]; then
    sid="cli"
  fi
  printf '%s/%s.json' "$STATE_DIR" "$sid"
}

resolve_state_file() {
  if [ -n "${BOR_SESSION_ID:-}" ] || [ -n "$PAYLOAD" ]; then
    state_file_for_session
    return
  fi
  local latest=""
  latest="$(ls -1t "$STATE_DIR"/*.json 2>/dev/null | head -1 || true)"
  if [ -n "$latest" ]; then
    printf '%s' "$latest"
  else
    printf '%s/cli.json' "$STATE_DIR"
  fi
}

lock_state() {
  # Serialize read-modify-write cycles against parallel SubagentStop hooks.
  exec 9>>"$1.lock"
  flock -w 3 9
}


# --- commands ----------------------------------------------------------------

cmd_activate() {
  local objective="${1:-}"
  local phases="${2:-}"
  mkdir -p -m 700 "$STATE_DIR"
  local f
  f="$(state_file_for_session)"
  local merge_policy="auto"
  if [ -f "$PROFILE_DIR/bor-settings.json" ]; then
    merge_policy="$(jq -r '.merge_policy // "auto"' "$PROFILE_DIR/bor-settings.json" 2>/dev/null || echo auto)"
  fi
  lock_state "$f"
  BOR_REPO_ROOT="" python3 - "$f" "$objective" "$phases" "$merge_policy" <<'PY'
import json, sys, os, tempfile, datetime, subprocess
f, objective, phases_arg, merge_policy = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])

TYPE_MAP = {
    'GROUND': 'GROUNDING', 'GROUNDING': 'GROUNDING',
    'DESIGN': 'DESIGN',
    'IMPLEMENT': 'IMPLEMENTING', 'IMPLEMENTING': 'IMPLEMENTING', 'IMPL': 'IMPLEMENTING',
    'REPAIR': 'REPAIR', 'REVIEW': 'REPAIR', 'FIX': 'REPAIR',
    'VERIFY': 'VERIFY', 'TEST': 'VERIFY', 'CHECK': 'VERIFY',
}
MODEL_MAP = {
    'GROUNDING': 'qwen', 'DESIGN': 'kimi', 'IMPLEMENTING': 'main',
    'REPAIR': 'qwen', 'VERIFY': 'qwen',
}
ROSTER = ['main', 'qwen', 'minimax', 'kimi', 'glm']
REPAIR_LADDER = ['qwen', 'minimax', 'glm']

names = [p.strip() for p in phases_arg.split(',') if p.strip()]
names = [n for n in names if n.lower() not in ('on', '')]
if not names:
    names = ['GROUNDING', 'IMPLEMENTING', 'REPAIR', 'VERIFY']

pipeline = []
for i, raw in enumerate(names):
    t = TYPE_MAP.get(raw.upper(), raw.upper())
    m = MODEL_MAP.get(t, ROSTER[i % len(ROSTER)])
    if t == 'REPAIR':
        rungs = sum(1 for p in pipeline if p['type'] == 'REPAIR')
        m = REPAIR_LADDER[min(rungs, len(REPAIR_LADDER) - 1)]
    pipeline.append({
        'name': raw.upper(), 'type': t, 'assigned_model': m,
        'required_inputs': [pipeline[-1]['name']] if pipeline else [],
        'status': 'pending',
    })
pipeline.append({
    'name': 'COMPLETE', 'type': 'COMPLETE', 'assigned_model': '',
    'required_inputs': [pipeline[-1]['name']] if pipeline else [],
    'status': 'pending',
})
pipeline[0]['status'] = 'running'

now = datetime.datetime.now(datetime.timezone.utc).isoformat()
state = {
    'active': True,
    'phase': pipeline[0]['type'],
    'round': 1,
    'roster_position': 0,
    'source_revision': 0,
    'objective': objective,
    'objective_revision': 1,
    'custom_phases': phases_arg,
    'pipeline_phases': pipeline,
    'completed_phases': [],
    'running_agents': {},
    'file_claims': {},
    'bor_pending_merges': [],
    'merge_policy': merge_policy,
    'round_dispatched': False,
    'round_complete': False,
    'complete': False,
    'blocked_reason': '',
    'created_at': now,
    'updated_at': now,
    'state_version': 1,
    'repo_root': (os.environ.get('BOR_REPO_ROOT') or
                 (subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                                 capture_output=True, text=True).stdout.strip()
                  if os.path.isdir('.git') else '')),
}

d = os.path.dirname(f)
fd, tmp = tempfile.mkstemp(dir=d)
with os.fdopen(fd, 'w') as out:
    json.dump(state, out, indent=2)
os.replace(tmp, f)
print('bag-of-rats: activated — ' + ' -> '.join(p['type'] for p in pipeline))
PY
}

cmd_deactivate() {
  local f
  f="$(resolve_state_file)"
  if [ ! -f "$f" ]; then
    echo "bag-of-rats: not active"
    exit 0
  fi
  lock_state "$f"
  python3 -c "
import json, sys, os, tempfile, datetime
f = sys.argv[1]
try:
    with open(f) as fh:
        state = json.load(fh)
except Exception:
    # Corrupt state: deactivate must still succeed so /bor off is the recovery.
    state = {}
state['active'] = False
state['phase'] = ''
state['blocked_reason'] = ''
state['running_agents'] = {}
state['file_claims'] = {}
state['bor_pending_merges'] = []
state['round_dispatched'] = False
d = os.path.dirname(f)
fd, tmp = tempfile.mkstemp(dir=d)
with os.fdopen(fd, 'w') as out:
    json.dump(state, out, indent=2)
os.replace(tmp, f)
print('bag-of-rats: deactivated')
" "$f"
}

cmd_pre_tool() {
  local f
  f="$(resolve_state_file)"
  if [ ! -f "$f" ]; then
    exit 0
  fi
  # Fields needed: tool_name, subagent_type, agent identity (for write claims),
  # and tool_input.file_path / notebook_path / command (for writes).
  mapfile -t V < <(payload_fields tool_name tool_input.subagent_type \
                                       tool_input.agent_id tool_input.agent_name \
                                       tool_input.agent_type \
                                       tool_input.file_path tool_input.notebook_path \
                                       tool_input.command)
  local tool="${V[0]:-}"
  local subtype="${V[1]:-}"
  local i_agent_id="${V[2]:-}"
  local i_agent_name="${V[3]:-}"
  local i_agent_type="${V[4]:-}"
  local i_file_path="${V[5]:-}"
  local i_notebook_path="${V[6]:-}"
  local i_command="${V[7]:-}"
  [ -n "$PAYLOAD" ] || { tool="${2:-}"; subtype="${3:-}"; i_agent_id=""; i_agent_name=""; i_agent_type=""; i_file_path=""; i_notebook_path=""; i_command=""; }
  local cfg_roles="" cfg_conc=""
  if [ -f "$PROFILE_DIR/bor-settings.json" ]; then
    cfg_roles="$(jq -r '.roles // 3' "$PROFILE_DIR/bor-settings.json" 2>/dev/null || echo 3)"
    cfg_conc="$(jq -r '.max_concurrent // 3' "$PROFILE_DIR/bor-settings.json" 2>/dev/null || echo 3)"
  fi
  lock_state "$f" || true
  python3 - "$f" "$tool" "$subtype" "$cfg_roles" "$cfg_conc" \
                  "$i_agent_id" "$i_agent_name" "$i_agent_type" \
                  "$i_file_path" "$i_notebook_path" "$i_command" <<'PY'
import json, sys, os, tempfile, datetime, re
(f, tool, subtype, cfg_roles, cfg_conc,
 in_agent_id, in_agent_name, in_agent_type,
 in_file_path, in_notebook_path, in_command) = sys.argv[1:13]
try:
    with open(f) as fh:
        state = json.load(fh)
except Exception:
    sys.exit(0)
if not state.get('active'):
    sys.exit(0)

running = state.setdefault('running_agents', {})
claims = state.setdefault('file_claims', {})  # path -> owner_id

# Resolve the calling agent's identity. Subagent tool calls in Claude Code
# carry session_id (the subagent's own) plus tool_input. We try in_agent_id
# first (the explicit dispatch id Claude Code sometimes emits on a subagent's
# own PreToolUse), then agent_name, then agent_type. The main session has no
# such field — that's how we leave the orchestrator unrestricted, because the
# orchestrator sequences the round and writes serially by definition.
owner_id = next((v for v in (in_agent_id, in_agent_name, in_agent_type) if v), '')
owner_label = in_agent_id or in_agent_name or in_agent_type or 'main'

def pending_total():
    return sum(v.get('pending', 0) for v in running.values())

def write_paths_from_tool():
    """Return the list of absolute paths this write tool would touch."""
    paths = []
    if tool in ('Edit', 'Write'):
        if in_file_path:
            paths.append(os.path.abspath(in_file_path))
    elif tool == 'MultiEdit':
        # MultiEdit's file_path is the outer target; nested edits are within
        # that one file, so we only need to claim the outer file.
        if in_file_path:
            paths.append(os.path.abspath(in_file_path))
    elif tool == 'NotebookEdit':
        if in_notebook_path:
            paths.append(os.path.abspath(in_notebook_path))
    elif tool == 'Bash':
        # Detect shell redirects: `> file`, `>> file`, `tee file`,
        # `tee -a file`, `dd of=file`, `cp src dst`, `mv src dst`, `sed -i`.
        # We only claim the *target* (the file being written), not the source.
        cmd = in_command or ''
        # Quoted-string-aware token split: split on whitespace, but keep runs
        # of quoted text as one token. We don't need a full shell parser —
        # only simple unquoted, single-quoted, and double-quoted forms.
        tokens = re.findall(r'"[^"]*"|\'[^\']*\'|\S+', cmd)
        def unquote(t):
            return t[1:-1] if (len(t) >= 2 and t[:1] in ('"', "'") and t[-1:] == t[:1]) else t
        i = 0
        while i < len(tokens):
            tok = tokens[i]
            unquoted = unquote(tok)
            low = unquoted.lower()
            if tok in ('>', '>>', '&>', '&>>'):
                if i + 1 < len(tokens):
                    nxt = tokens[i + 1]
                    candidate = unquote(nxt)
                    if candidate and not candidate.startswith('&'):
                        paths.append(os.path.abspath(candidate))
                    i += 2
                    continue
            elif low == 'tee':
                j = i + 1
                while j < len(tokens):
                    t = tokens[j]
                    if t.startswith('-'):
                        j += 1
                        continue
                    paths.append(os.path.abspath(unquote(t)))
                    j += 1
                break
            elif low == 'dd' and 'of=' in unquoted:
                m = re.search(r'\bof=(\S+)', unquoted)
                if m:
                    paths.append(os.path.abspath(m.group(1)))
            elif low == 'sed' and re.search(r'(^|\s)-i(\s|=|$)', unquoted):
                j = i + 1
                while j < len(tokens):
                    t = tokens[j]
                    if t.startswith('-'):
                        j += 1
                        continue
                    paths.append(os.path.abspath(unquote(t)))
                    break
            elif low in ('cp', 'mv', 'install') and i + 1 < len(tokens):
                dest = tokens[-1]
                last = unquote(dest)
                paths.append(os.path.abspath(last))
            i += 1
    return [p for p in paths if p]

if tool == 'Agent':
    subtype = subtype or 'general-purpose'
    try:
        cap = int(cfg_conc)
    except ValueError:
        cap = 3
    if pending_total() >= cap:
        print(f"BLOCKED: Bag of Rats concurrency cap reached ({pending_total()}/{cap} "
              f"agents already running this round). Wait for SubagentStop events "
              f"before dispatching more, or raise max_concurrent in bor-settings.json.",
              file=sys.stderr)
        sys.exit(2)
    entry = running.setdefault(subtype, {'pending': 0, 'done': 0, 'instances': []})
    # Stamp a unique claim id for this dispatch.
    claim_id = f"{subtype}:{entry.get('seq', 0)}"
    entry['seq'] = entry.get('seq', 0) + 1
    entry['pending'] += 1
    # Shadow-tree policy: when this round has more than one dispatched agent,
    # and the project is a git repo, auto-provision a per-dispatch worktree
    # so rats can edit freely without clobbering each other. The reconciler
    # runs on SubagentStop. See README for the resolve flow.
    shadow = None
    if pending_total() + 1 > 1:  # after this dispatch, >1 agents active
        # Avoid provisioning twice for the same instance in a race.
        repo_root = os.environ.get('BOR_REPO_ROOT', '') or os.getcwd()
        shadow_root = os.path.join(repo_root, '.claude', 'worktrees')
        if os.path.isdir(os.path.join(repo_root, '.git')):
            shadow_path = os.path.join(shadow_root, f"bor-{claim_id.replace(':', '-')}")
            if not os.path.isdir(shadow_path):
                # Best-effort: failures here are advisory, not blocking.
                # The reconciler will fall back to "merge against current
                # working tree" if the worktree can't be created.
                try:
                    import subprocess
                    os.makedirs(shadow_root, exist_ok=True)
                    subprocess.run(
                        ['git', 'worktree', 'add', '-f', shadow_path, 'HEAD'],
                        cwd=repo_root, capture_output=True, check=True,
                        timeout=10)
                    shadow = shadow_path
                except Exception:
                    shadow = None
    entry.setdefault('instances', []).append({
        'claim_id': claim_id, 'pending': True, 'shadow': shadow,
    })
    state['round_dispatched'] = True
elif tool in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit'):
    phase = state.get('phase', '')
    if phase in ('GROUNDING', 'VERIFY'):
        print(f"BLOCKED: {tool} is not allowed during the read-only {phase} "
              f"phase of Bag of Rats.", file=sys.stderr)
        sys.exit(2)
    # No more BLOCKED-on-conflict: shadow trees absorb concurrent writes.
    # We still record the write for diagnostics in the round's manifest.
    if owner_id:
        for p in write_paths_from_tool():
            claims[p] = owner_id
elif tool == 'Bash':
    # Read-only phases still allow shell test-runs (cargo test, ls, cat).
    # Any redirect-target the shell would write is recorded as a claim but
    # never BLOCKED — the shadow tree is the actual isolation mechanism.
    phase = state.get('phase', '')
    paths = write_paths_from_tool()
    if phase in ('GROUNDING', 'VERIFY') and paths:
        print(f"BLOCKED: shell write to {paths[0]} is not allowed during the "
              f"read-only {phase} phase of Bag of Rats.", file=sys.stderr)
        sys.exit(2)
    if owner_id:
        for p in paths:
            claims[p] = owner_id
else:
    sys.exit(0)

state['roles'] = cfg_roles
state['max_concurrent'] = (
    int(cfg_conc) if cfg_conc.isdigit() else (cap if 'cap' in dir() else 3))
state['updated_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
d = os.path.dirname(f)
fd, tmp = tempfile.mkstemp(dir=d)
with os.fdopen(fd, 'w') as out:
    json.dump(state, out, indent=2)
os.replace(tmp, f)
PY
}

cmd_subagent_stop() {
  local f
  f="$(resolve_state_file)"
  if [ ! -f "$f" ]; then
    exit 0
  fi
  mapfile -t V < <(payload_fields agent_type agent_name agent_id)
  local atype="${V[0]:-}"
  local aname="${V[1]:-}"
  local aid="${V[2]:-}"
  [ -n "$PAYLOAD" ] || atype="${2:-}"
  lock_state "$f" || true
  # Resolve repo root: prefer BOR_REPO_ROOT, fall back to the session's cwd
  # if it lives in a git repo (the orchestrator's session cwd).
  local repo_root="${BOR_REPO_ROOT:-}"
  if [ -z "$repo_root" ] && command -v git >/dev/null; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  BOR_REPO_ROOT="$repo_root" python3 - "$f" "$atype" "$aname" "$aid" "$repo_root" <<'PY'
import json, sys, os, tempfile, datetime, subprocess, shutil
f, atype, aname, aid, repo_root = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
try:
    with open(f) as fh:
        state = json.load(fh)
except Exception:
    sys.exit(0)
if not state.get('active'):
    sys.exit(0)

running = state.setdefault('running_agents', {})
pending_merges = state.setdefault('bor_pending_merges', [])

def pending_total():
    return sum(v.get('pending', 0) for v in running.values())

def reconcile_shadow(shadow_path, instance_label):
    """Reconcile the rat's git worktree shadow into the working tree.
    Policy:
      merge_policy=auto: try git merge-file per-file; if conflict,
        record a true-conflict in bor_pending_merges[] and skip that file.
      merge_policy=last-writer-wins: take the shadow's version wholesale.
      merge_policy=manual: every touched file goes into bor_pending_merges[].
    Returns the list of files that landed (reconciled or queued)."""
    if not shadow_path or not os.path.isdir(shadow_path):
        return []
    policy = state.get('merge_policy', 'auto')
    repo = repo_root if repo_root else os.getcwd()
    if not os.path.isdir(os.path.join(repo, '.git')):
        return []
    # Diff shadow vs base ref (HEAD at the time the shadow was created).
    try:
        diff_proc = subprocess.run(
            ['git', '-C', repo, 'diff', '--name-only', 'HEAD', '--', shadow_path],
            capture_output=True, text=True, timeout=15,
        )
    except Exception:
        return []
    # `git diff --name-only <ref> -- <path>` doesn't filter by worktree; we
    # need files modified inside the shadow worktree itself. Use status.
    try:
        st = subprocess.run(
            ['git', '-C', shadow_path, 'status', '--porcelain', '-uall'],
            capture_output=True, text=True, timeout=15,
        )
    except Exception:
        return []
    touched = []
    for line in (st.stdout or '').splitlines():
        # format: "XY path" with possible leading whitespace / submodule info
        if not line.strip():
            continue
        parts = line[3:].strip().split(' -> ', 1)
        path = parts[-1]
        touched.append(path)
    reconciled = []
    for relpath in touched:
        shadow_file = os.path.join(shadow_path, relpath)
        repo_file = os.path.join(repo, relpath)
        if not os.path.exists(shadow_file):
            continue
        os.makedirs(os.path.dirname(repo_file) or '.', exist_ok=True)
        if policy == 'last-writer-wins':
            shutil.copyfile(shadow_file, repo_file)
            reconciled.append(relpath)
            continue
        if policy == 'manual':
            pending_merges.append({
                'claim_id': instance_label, 'path': relpath,
                'shadow': shadow_path, 'repo': repo,
                'note': 'manual merge policy: orchestrator must reconcile',
            })
            continue
        # auto: try a 3-way merge against the file at HEAD (the base).
        # If the file doesn't exist at HEAD, it's a new file -> take the
        # shadow's version outright.
        base_proc = subprocess.run(
            ['git', '-C', repo, 'show', f'HEAD:./{relpath}'],
            capture_output=True, text=True, timeout=10,
        )
        if base_proc.returncode != 0:
            # new file
            shutil.copyfile(shadow_file, repo_file)
            reconciled.append(relpath)
            continue
        try:
            mf = subprocess.run(
                ['git', 'merge-file', '--diff3', '-p',
                 base_proc.stdout, repo_file, shadow_file],
                capture_output=True, text=True, timeout=10,
            )
        except FileNotFoundError:
            # git merge-file not on PATH — fall back to last-writer-wins.
            shutil.copyfile(shadow_file, repo_file)
            reconciled.append(relpath)
            continue
        if mf.returncode == 0:
            with open(repo_file, 'w') as fh:
                fh.write(mf.stdout)
            reconciled.append(relpath)
        elif mf.returncode == 1:
            # conflict markers present in mf.stdout
            pending_merges.append({
                'claim_id': instance_label, 'path': relpath,
                'shadow': shadow_path, 'repo': repo,
                'note': 'git merge-file 3-way conflict; orchestrator must resolve',
                'merged_preview': mf.stdout,
            })
        else:
            # rc>1: unexpected error, log as pending
            pending_merges.append({
                'claim_id': instance_label, 'path': relpath,
                'shadow': shadow_path, 'repo': repo,
                'note': f'git merge-file rc={mf.returncode}; orchestrator must resolve',
            })
    return reconciled

# Resolve which registered agent finished. Exact identity binding would need
# a dispatch packet; matching by type (then any pending slot) keeps rounds
# flowing and never over-advances, because completion requires pending == 0.
key = None
for cand in (atype, aname, aid):
    if cand and cand in running and running[cand].get('pending', 0) > 0:
        key = cand
        break
if key is None:
    for k, v in running.items():
        if v.get('pending', 0) > 0:
            key = k
            break

reconciled_files = []
finished_instance = None
if key is not None:
    running[key]['pending'] -= 1
    running[key]['done'] = running[key].get('done', 0) + 1
    # Reconcile the FIRST still-pending instance of this key (we don't have
    # exact dispatch-order info, so take head-of-list). The round advances
    # only when pending_total==0, so any unreconciled instance's shadow is
    # still reconciled when *its* SubagentStop arrives.
    for inst in running[key].get('instances', []):
        if inst.get('pending'):
            inst['pending'] = False
            shadow = inst.get('shadow')
            if shadow:
                reconciled_files = reconcile_shadow(shadow, inst.get('claim_id', key))
                inst['reconciled'] = reconciled_files
            finished_instance = inst
            break
    # If this finish drained the type to zero pending, release any claims
    # owned by the just-finished agent.
    if running[key].get('pending', 0) == 0:
        for inst in running[key].get('instances', []):
            cid = inst.get('claim_id')
            if not cid:
                continue
            state['file_claims'] = {
                p: o for p, o in state.get('file_claims', {}).items() if o != cid
            }

# Round advances only when: round was dispatched AND no agents pending AND
# no pending merges are unresolved (the orchestrator must reconcile).
advanced = False
if (state.get('round_dispatched') and pending_total() == 0
        and not pending_merges):
    pipeline = state.get('pipeline_phases', [])
    for i, p in enumerate(pipeline):
        if p.get('status') == 'running':
            p['status'] = 'completed'
            models = [k for k, v in running.items() if v.get('done', 0) > 0]
            state['completed_phases'].append({
                'phase': p['type'], 'name': p['name'], 'models': models,
                'round': state.get('round', 0),
                'finished_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            })
            nxt = i + 1
            if nxt < len(pipeline) and pipeline[nxt]['type'] != 'COMPLETE':
                pipeline[nxt]['status'] = 'running'
                state['phase'] = pipeline[nxt]['type']
                state['round'] = state.get('round', 1) + 1
                state['running_agents'] = {}
                state['file_claims'] = {}
                state['bor_pending_merges'] = []
                state['round_dispatched'] = False
                state['round_complete'] = False
            else:
                pipeline[nxt]['status'] = 'completed' if nxt < len(pipeline) else None
                state['phase'] = 'COMPLETE'
                state['complete'] = True
                state['round_complete'] = True
            advanced = True
            break

if advanced or key is not None:
    state['updated_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    d = os.path.dirname(f)
    fd, tmp = tempfile.mkstemp(dir=d)
    with os.fdopen(fd, 'w') as out:
        json.dump(state, out, indent=2)
    os.replace(tmp, f)
PY
  exit 0
}

cmd_advance() {
  local f
  f="$(resolve_state_file)"
  if [ ! -f "$f" ]; then
    echo "bag-of-rats: not active"
    exit 0
  fi
  lock_state "$f"
  python3 - "$f" <<'PY'
import json, sys, os, tempfile, datetime
f = sys.argv[1]
try:
    with open(f) as fh:
        state = json.load(fh)
except Exception:
    print('bag-of-rats: state unreadable — run /bor off to recover', file=sys.stderr)
    sys.exit(1)
if not state.get('active'):
    print('bag-of-rats: not active')
    sys.exit(0)
if state.get('complete'):
    print('bag-of-rats: pipeline already complete')
    sys.exit(0)

pipeline = state.get('pipeline_phases', [])
for i, p in enumerate(pipeline):
    if p.get('status') == 'running':
        p['status'] = 'completed'
        state['completed_phases'].append({
            'phase': p['type'], 'name': p['name'], 'models': ['main'],
            'round': state.get('round', 0),
            'finished_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        })
        nxt = i + 1
        if nxt < len(pipeline) and pipeline[nxt]['type'] != 'COMPLETE':
            pipeline[nxt]['status'] = 'running'
            state['phase'] = pipeline[nxt]['type']
            state['round'] = state.get('round', 1) + 1
            state['running_agents'] = {}
            state['file_claims'] = {}
            state['bor_pending_merges'] = []
            state['round_dispatched'] = False
            state['round_complete'] = False
            msg = f"bag-of-rats: round closed — next phase {pipeline[nxt]['type']} (round {state['round']})"
        else:
            if nxt < len(pipeline):
                pipeline[nxt]['status'] = 'completed'
            state['phase'] = 'COMPLETE'
            state['complete'] = True
            state['round_complete'] = True
            msg = 'bag-of-rats: pipeline complete'
        state['updated_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        d = os.path.dirname(f)
        fd, tmp = tempfile.mkstemp(dir=d)
        with os.fdopen(fd, 'w') as out:
            json.dump(state, out, indent=2)
        os.replace(tmp, f)
        print(msg)
        sys.exit(0)
print('bag-of-rats: no running phase found')
sys.exit(0)
PY
}

cmd_stop() {
  if [ -z "$PAYLOAD" ]; then
    exit 0
  fi
  mapfile -t V < <(payload_fields stop_hook_active session_id)
  if [ "${V[0]:-}" = "true" ]; then
    exit 0
  fi
  local f
  f="$(resolve_state_file)"
  if [ ! -f "$f" ]; then
    exit 0
  fi
  python3 - "$f" <<'PY'
import json, sys
f = sys.argv[1]
try:
    with open(f) as fh:
        state = json.load(fh)
except Exception:
    print("BLOCKED: Bag of Rats state is unreadable. Recover with /bor off.",
          file=sys.stderr)
    sys.exit(2)
if not state.get('active') or state.get('complete'):
    sys.exit(0)
phase = state.get('phase') or '?'
round_no = state.get('round', 0)
running = state.get('running_agents') or {}
pending = sum(v.get('pending', 0) for v in running.values())
# Parallelism-first: agents still running is the async pipeline working as
# designed — their SubagentStop events advance the round and re-invoke the
# session. Hold Stop only when the model is idling with undispatched work:
# a phase is current, nothing is running, and the pipeline isn't finished.
if pending > 0:
    sys.exit(0)
print(f"BLOCKED: Bag of Rats pipeline is active (phase {phase}, round {round_no}) "
      f"with no agents running. Dispatch the next round's agents, close a "
      f"main-session phase with the bag-of-rats advance command, or deactivate "
      f"with /bor off.",
      file=sys.stderr)
sys.exit(2)
PY
}

cmd_prompt() {
  local f
  f="$(resolve_state_file)"
  if [ ! -f "$f" ]; then
    exit 0
  fi
  python3 - "$f" <<'PY' 2>/dev/null || true
import json, sys
f = sys.argv[1]
try:
    with open(f) as fh:
        state = json.load(fh)
except Exception:
    sys.exit(0)
if not state.get('active') or state.get('complete'):
    sys.exit(0)
phase = state.get('phase') or '?'
round_no = state.get('round', 0)
running = state.get('running_agents') or {}
parts = [f"{k}:{v.get('pending',0)}" for k, v in running.items() if v.get('pending', 0)]
queue = ' '.join(
    ('✓' if p.get('status') == 'completed' else '▶' if p.get('status') == 'running' else '·')
    + p['type'] for p in state.get('pipeline_phases', []))
line = f"[bag-of-rats] active | phase {phase} | round {round_no}"
if parts:
    line += " | running " + ', '.join(parts)
line += f" | {queue}"
print(line)
PY
  exit 0
}

cmd_prompt_expansion() {
  mapfile -t V < <(payload_fields command command_name slash_command arguments session_id)
  local cmd="${V[0]:-}"
  if [ -z "$cmd" ]; then cmd="${V[1]:-}"; fi
  if [ -z "$cmd" ]; then cmd="${V[2]:-}"; fi
  local args="${V[3]:-}"
  local f
  f="$(state_file_for_session)"
  mkdir -p -m 700 "$STATE_DIR"
  lock_state "$f"
  python3 - "$f" "$cmd" "$args" <<'PY'
import json, sys, os, tempfile, datetime
f, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3]

cmd_l = (cmd or '').lower()
args_l = (args or '').strip().lower()

wants_off = ('off' in cmd_l) or args_l in ('off', 'stop', 'false') or args_l.startswith('off ')

if wants_off:
    try:
        with open(f) as fh:
            state = json.load(fh)
    except Exception:
        # Corrupt state: deactivate must still succeed so /bor off is the recovery.
        state = {}
    state['active'] = False
    state['phase'] = ''
    state['running_agents'] = {}
    state['round_dispatched'] = False
    state['updated_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    d = os.path.dirname(f)
    fd, tmp = tempfile.mkstemp(dir=d)
    with os.fdopen(fd, 'w') as out:
        json.dump(state, out, indent=2)
    os.replace(tmp, f)
    print('bag-of-rats: deactivated (/bor off)')
    sys.exit(0)

# Activation: only when we can positively identify a bor command, so an
# unrelated expansion payload never starts a pipeline by accident.
if cmd_l not in ('bor', 'bag-of-rats', 'bag-of-rats-on'):
    sys.exit(0)

TYPE_MAP = {
    'GROUND': 'GROUNDING', 'GROUNDING': 'GROUNDING',
    'DESIGN': 'DESIGN',
    'IMPLEMENT': 'IMPLEMENTING', 'IMPLEMENTING': 'IMPLEMENTING', 'IMPL': 'IMPLEMENTING',
    'REPAIR': 'REPAIR', 'REVIEW': 'REPAIR', 'FIX': 'REPAIR',
    'VERIFY': 'VERIFY', 'TEST': 'VERIFY', 'CHECK': 'VERIFY',
}
MODEL_MAP = {
    'GROUNDING': 'qwen', 'DESIGN': 'kimi', 'IMPLEMENTING': 'main',
    'REPAIR': 'qwen', 'VERIFY': 'qwen',
}
ROSTER = ['main', 'qwen', 'minimax', 'kimi', 'glm']
REPAIR_LADDER = ['qwen', 'minimax', 'glm']

def looks_like_phases(s):
    toks = [t.strip() for t in s.split(',') if t.strip()]
    if not toks:
        return False
    return all(t.upper() in TYPE_MAP or t.upper() == 'COMPLETE' for t in toks)

raw = (args or '').strip()
# "/bor on", "/bor" with no args, and a bare objective string all use the
# default pipeline; a comma list of known phase words is a custom pipeline.
if raw.lower() in ('on', ''):
    objective, phases = '', ''
else:
    objective, phases = (raw, '') if not looks_like_phases(raw) else ('', raw)

names = [p.strip() for p in phases.split(',') if p.strip()]
names = [n for n in names if n.lower() not in ('on', '')]
if not names:
    names = ['GROUNDING', 'IMPLEMENTING', 'REPAIR', 'VERIFY']

pipeline = []
for i, raw_name in enumerate(names):
    t = TYPE_MAP.get(raw_name.upper(), raw_name.upper())
    m = MODEL_MAP.get(t, ROSTER[i % len(ROSTER)])
    if t == 'REPAIR':
        rungs = sum(1 for p in pipeline if p['type'] == 'REPAIR')
        m = REPAIR_LADDER[min(rungs, len(REPAIR_LADDER) - 1)]
    pipeline.append({
        'name': raw_name.upper(), 'type': t, 'assigned_model': m,
        'required_inputs': [pipeline[-1]['name']] if pipeline else [],
        'status': 'pending',
    })
pipeline.append({
    'name': 'COMPLETE', 'type': 'COMPLETE', 'assigned_model': '',
    'required_inputs': [pipeline[-1]['name']] if pipeline else [],
    'status': 'pending',
})
pipeline[0]['status'] = 'running'

now = datetime.datetime.now(datetime.timezone.utc).isoformat()
state = {
    'active': True,
    'phase': pipeline[0]['type'],
    'round': 1,
    'roster_position': 0,
    'source_revision': 0,
    'objective': objective,
    'objective_revision': 1,
    'custom_phases': phases,
    'pipeline_phases': pipeline,
    'completed_phases': [],
    'running_agents': {},
    'file_claims': {},
    'bor_pending_merges': [],
    'merge_policy': 'auto',
    'round_dispatched': False,
    'round_complete': False,
    'complete': False,
    'blocked_reason': '',
    'created_at': now,
    'updated_at': now,
    'state_version': 1,
}

d = os.path.dirname(f)
fd, tmp = tempfile.mkstemp(dir=d)
with os.fdopen(fd, 'w') as out:
    json.dump(state, out, indent=2)
os.replace(tmp, f)
print('bag-of-rats: activated (/bor) — ' + ' -> '.join(p['type'] for p in pipeline))
PY
}

cmd_status() {
  ensure_dir() { mkdir -p -m 700 "$STATE_DIR"; }
  ensure_dir
  local f
  f="$(resolve_state_file)"
  if [ -f "$f" ]; then
    python3 -m json.tool < "$f" 2>/dev/null || cat "$f"
  else
    echo "No Bag of Rats state found"
  fi
}

cmd_config() {
  # config show | config roles <2|3> | config concurrency <n>
  #        | config policy <auto|last-writer-wins|manual>
  local action="${1:-show}"
  local value="${2:-}"
  local cfg="$PROFILE_DIR/bor-settings.json"
  case "$action" in
    show)
      if [ -f "$cfg" ]; then
        jq '{roles, max_concurrent, merge_policy, role_structure: {(["2", "3"] | map({key: ., value: .role_structure[.]}) | from_entries)}}' "$cfg" 2>/dev/null \
          || jq '{roles, max_concurrent, merge_policy}' "$cfg" 2>/dev/null \
          || cat "$cfg"
      else
        echo "bor-settings.json not found at $cfg"
        exit 1
      fi
      ;;
    roles)
      if [ "$value" != "2" ] && [ "$value" != "3" ]; then
        echo "Usage: config roles <2|3>" >&2
        exit 1
      fi
      python3 - "$cfg" "$value" <<'PY'
import json, sys, os, tempfile
cfg, value = sys.argv[1], int(sys.argv[2])
try:
    with open(cfg) as fh:
        d = json.load(fh)
except Exception:
    d = {}
d['roles'] = value
cfg_dir = os.path.dirname(cfg)
fd, tmp = tempfile.mkstemp(dir=cfg_dir)
with os.fdopen(fd, 'w') as out:
    json.dump(d, out, indent=2)
os.replace(tmp, cfg)
print(f'bag-of-rats config: roles = {value} ' +
      ('(implement + review)' if value == 2 else '(implement + review + arbiter)'))
PY
      ;;
    concurrency)
      if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "Usage: config concurrency <positive integer>" >&2
        exit 1
      fi
      python3 - "$cfg" "$value" <<'PY'
import json, sys, os, tempfile
cfg, value = sys.argv[1], int(sys.argv[2])
try:
    with open(cfg) as fh:
        d = json.load(fh)
except Exception:
    d = {}
d['max_concurrent'] = value
cfg_dir = os.path.dirname(cfg)
fd, tmp = tempfile.mkstemp(dir=cfg_dir)
with os.fdopen(fd, 'w') as out:
    json.dump(d, out, indent=2)
os.replace(tmp, cfg)
print(f'bag-of-rats config: max_concurrent = {value}')
PY
      ;;
    policy|merge_policy)
      case "$value" in
        auto|last-writer-wins|manual) ;;
        *)
          echo "Usage: config policy <auto|last-writer-wins|manual>" >&2
          exit 1
          ;;
      esac
      python3 - "$cfg" "$value" <<'PY'
import json, sys, os, tempfile
cfg, value = sys.argv[1], sys.argv[2]
try:
    with open(cfg) as fh:
        d = json.load(fh)
except Exception:
    d = {}
d['merge_policy'] = value
cfg_dir = os.path.dirname(cfg)
fd, tmp = tempfile.mkstemp(dir=cfg_dir)
with os.fdopen(fd, 'w') as out:
    json.dump(d, out, indent=2)
os.replace(tmp, cfg)
descs = {'auto': 'git merge-file with last-writer-wins fallback',
         'last-writer-wins': 'most recent shadow wins per file',
         'manual': 'every shadow queued for orchestrator review'}
print(f'bag-of-rats config: merge_policy = {value} ({descs[value]})')
PY
      ;;
    *)
      echo "Usage: config {show|roles <2|3>|concurrency <n>|policy <auto|last-writer-wins|manual>}" >&2
      exit 1
      ;;
  esac
}

# --------------------------------------------------------------------- main --

case "$HOOK_EVENT" in
  activate)
    shift
    cmd_activate "$@"
    ;;
  deactivate)
    cmd_deactivate
    ;;
  advance)
    cmd_advance
    ;;
  config)
    shift
    cmd_config "$@"
    ;;
  pre-tool)
    cmd_pre_tool "${2:-}"
    ;;
  subagent-stop)
    cmd_subagent_stop "${2:-}"
    ;;
  stop)
    cmd_stop
    ;;
  prompt)
    cmd_prompt
    ;;
  prompt-expansion)
    cmd_prompt_expansion
    ;;
  status)
    cmd_status
    ;;
  *)
    echo "Usage: bag-of-rats-hook.sh {activate|deactivate|advance|pre-tool|subagent-stop|stop|prompt|prompt-expansion|status}" >&2
    exit 1
    ;;
esac
