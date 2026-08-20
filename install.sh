#!/usr/bin/env bash
# install.sh — install Bag of Rats into a Claude Code profile
#
# Usage:
#   ./install.sh                # install to ${CLAUDE_CONFIG_DIR:-~/.config/claude-code/freeinference}
#   ./install.sh <profile-dir>  # install to an explicit profile directory
#
# What it does:
#   1. Copies hook, schema, smoke test, settings, commands, and the
#      orchestrator agent into the profile.
#   2. Merges hook registrations into the profile's settings.json (additive:
#      existing hooks, permissions, model slots, status line are untouched).
#      Re-running is idempotent: stale Bag of Rats registrations from a
#      previous install are removed before the current ones are added.
#   3. Merges bor-settings.json if the profile does not already have one
#      (existing user configuration is never overwritten).
#   4. Runs the smoke suite against the installed copy and fails the install
#      if any check fails.
#
# Bag of Rats is fully independent of /fi-flow: separate state root, separate
# hooks, no shared state. Installing this does not modify anything fi-flow
# owns except sharing the same settings.json hook arrays.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-${CLAUDE_CONFIG_DIR:-$HOME/.config/claude-code/freeinference}}"

echo "Installing Bag of Rats"
echo "  package: $SRC"
echo "  profile: $PROFILE"
echo ""

# --- sanity ------------------------------------------------------------------

for f in bag-of-rats-hook.sh bag-of-rats-state.schema.json \
         bag-of-rats-install-smoke.test.sh hooks-registration.json \
         bor-settings.json README.md \
         commands/bor.md commands/bor-off.md commands/bor-config.md \
         commands/bag-of-rats.md commands/bag-of-rats-off.md \
         agents/bag-of-rats-orchestrator.md; do
  if [ ! -f "$SRC/$f" ]; then
    echo "FATAL: missing package file: $f" >&2
    exit 1
  fi
done

bash -n "$SRC/bag-of-rats-hook.sh" || { echo "FATAL: hook has syntax errors" >&2; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 required" >&2; exit 1; }
command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 1; }

if [ ! -d "$PROFILE" ]; then
  echo "FATAL: profile directory does not exist: $PROFILE" >&2
  exit 1
fi

# --- 1. files ----------------------------------------------------------------

mkdir -p "$PROFILE/commands" "$PROFILE/agents"

install -m 755 "$SRC/bag-of-rats-hook.sh"                    "$PROFILE/bag-of-rats-hook.sh"
install -m 644 "$SRC/bag-of-rats-state.schema.json"          "$PROFILE/bag-of-rats-state.schema.json"
install -m 755 "$SRC/bag-of-rats-install-smoke.test.sh"      "$PROFILE/bag-of-rats-install-smoke.test.sh"
install -m 644 "$SRC/README.md"                              "$PROFILE/bag-of-rats.md"
cp "$SRC"/commands/bor.md "$SRC"/commands/bor-off.md "$SRC"/commands/bor-config.md \
   "$SRC"/commands/bag-of-rats.md "$SRC"/commands/bag-of-rats-off.md "$PROFILE/commands/"
cp "$SRC/agents/bag-of-rats-orchestrator.md" "$PROFILE/agents/"

# User settings survive reinstalls; only seed when absent.
if [ ! -f "$PROFILE/bor-settings.json" ]; then
  install -m 644 "$SRC/bor-settings.json" "$PROFILE/bor-settings.json"
  echo "  installed bor-settings.json (defaults)"
else
  echo "  kept existing bor-settings.json"
fi

HOOK_CMD="$PROFILE/bag-of-rats-hook.sh"

# --- 2. settings.json hook merge ----------------------------------------------

if [ -f "$PROFILE/settings.json" ]; then
  cp "$PROFILE/settings.json" "$PROFILE/settings.json.bak"
else
  echo '{}' > "$PROFILE/settings.json"
fi

python3 - "$PROFILE/settings.json" "$SRC/hooks-registration.json" "$HOOK_CMD" <<'PY'
import json, sys, re

settings_path, reg_path, hook_cmd = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings_path) as fh:
    settings = json.load(fh)
with open(reg_path) as fh:
    reg = json.load(fh)

hooks = settings.setdefault('hooks', {})

# Idempotency: drop every existing registration whose command references this
# install's hook script, then re-add the current registrations.
for event, entries in list(hooks.items()):
    kept = []
    for e in entries:
        bor_entries = [h for h in e.get('hooks', []) if 'bag-of-rats-hook.sh' in h.get('command', '')]
        if bor_entries and len(bor_entries) == len(e.get('hooks', [])):
            continue  # whole entry is ours — remove it
        if bor_entries:
            e = dict(e)
            e['hooks'] = [h for h in e['hooks'] if 'bag-of-rats-hook.sh' not in h.get('command', '')]
            kept.append(e)
        else:
            kept.append(e)
    hooks[event] = kept

for event, entries in reg.items():
    if event.startswith('_'):
        continue  # metadata keys (e.g. _comment), not registrations
    for e in entries:
        new_entry = json.loads(json.dumps(e))
        for h in new_entry['hooks']:
            h['command'] = h['command'].replace('@HOOK_CMD@', hook_cmd)
        hooks.setdefault(event, []).append(new_entry)

with open(settings_path, 'w') as fh:
    json.dump(settings, fh, indent=2)
print('  merged hook registrations into settings.json (backup: settings.json.bak)')
PY

# --- 3. verify -----------------------------------------------------------------

echo ""
echo "Running smoke suite against the installed copy..."
if bash "$PROFILE/bag-of-rats-install-smoke.test.sh" >/tmp/bor-install-smoke.log 2>&1; then
  tail -2 /tmp/bor-install-smoke.log
else
  echo "FATAL: smoke suite failed against installed copy:" >&2
  tail -20 /tmp/bor-install-smoke.log >&2
  cp "$PROFILE/settings.json.bak" "$PROFILE/settings.json"
  echo "  settings.json restored from backup" >&2
  exit 1
fi

echo ""
echo "Install complete. In a session, use /bor to activate, /bor off to deactivate,"
echo "/bor config to view or change roles and concurrency."
