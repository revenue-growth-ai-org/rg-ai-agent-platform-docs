#!/bin/bash
# Agent image builds must call the shared repo's stage-agent-sources.sh with
# CUSTOMER_AGENTS_DIR or CUSTOMER_OVERLAY_DIR. Also guards that the deleted
# chat repo is not a live platform step outside the historical notes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=================================================="
echo " customer overlay staging"
echo "=================================================="

bash -n "$ROOT/redeploy-common.sh" && ok "redeploy-common.sh bash -n" || bad "redeploy-common.sh bash -n"
bash -n "$ROOT/redeploy-agent.sh" && ok "redeploy-agent.sh bash -n" || bad "redeploy-agent.sh bash -n"
bash -n "$ROOT/destroy.sh" && ok "destroy.sh bash -n" || bad "destroy.sh bash -n"
bash -n "$ROOT/master-setup.sh" && ok "master-setup.sh bash -n" || bad "master-setup.sh bash -n"
bash -n "$ROOT/manage-agent.sh" && ok "manage-agent.sh bash -n" || bad "manage-agent.sh bash -n"

# shellcheck disable=SC1091
source "$ROOT/redeploy-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PARENT_DIR="$TMP/parent"
mkdir -p "$PARENT_DIR"
AGENT_REPO="$TMP/agent-repo"
mkdir -p "$AGENT_REPO"
STUB="$AGENT_REPO/stage-agent-sources.sh"
cat > "$STUB" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$STUB_LOG"
printf '%s\n' "${CUSTOMER_AGENTS_DIR:-}" > "$STUB_AGENTS"
printf '%s\n' "${CUSTOMER_OVERLAY_DIR:-}" > "$STUB_OVERLAY"
EOF
chmod +x "$STUB"

run_stage() {
  STUB_LOG="$TMP/args"
  STUB_AGENTS="$TMP/agents-dir"
  STUB_OVERLAY="$TMP/overlay-dir"
  export STUB_LOG STUB_AGENTS STUB_OVERLAY
  rm -f "$STUB_LOG" "$STUB_AGENTS" "$STUB_OVERLAY"
  stage_agent_sources "$AGENT_REPO" "$1"
}

unset CUSTOMER_SLUG CUSTOMER_AGENTS_DIR CUSTOMER_OVERLAY_DIR
run_stage researcher
if grep -qx -- '--agent researcher' "$TMP/args" \
  && [ -z "$(cat "$TMP/agents-dir")" ] && [ -z "$(cat "$TMP/overlay-dir")" ]; then
  ok "stage script runs with --agent and no customer env"
else
  bad "unexpected args or env when no customer dir is set"
  echo "args=$(cat "$TMP/args" 2>/dev/null || true)"
fi

export CUSTOMER_SLUG="acme"
unset CUSTOMER_AGENTS_DIR CUSTOMER_OVERLAY_DIR
run_stage researcher
EXPECT="$PARENT_DIR/rg-ai-agent-platform-customers/acme/agents"
if [ "$(cat "$TMP/agents-dir")" = "$EXPECT" ] && [ -z "$(cat "$TMP/overlay-dir")" ]; then
  ok "CUSTOMER_SLUG fills CUSTOMER_AGENTS_DIR for <slug>/agents"
else
  bad "CUSTOMER_SLUG did not set CUSTOMER_AGENTS_DIR"
  echo "got=$(cat "$TMP/agents-dir" 2>/dev/null || true)"
fi

export CUSTOMER_AGENTS_DIR="/explicit/agents"
export CUSTOMER_SLUG="acme"
unset CUSTOMER_OVERLAY_DIR
run_stage researcher
if [ "$(cat "$TMP/agents-dir")" = "/explicit/agents" ]; then
  ok "preset CUSTOMER_AGENTS_DIR is not overwritten"
else
  bad "preset CUSTOMER_AGENTS_DIR was replaced"
fi

unset CUSTOMER_AGENTS_DIR CUSTOMER_SLUG
export CUSTOMER_OVERLAY_DIR="/explicit/overlay"
run_stage researcher
if [ "$(cat "$TMP/overlay-dir")" = "/explicit/overlay" ] && [ -z "$(cat "$TMP/agents-dir")" ]; then
  ok "CUSTOMER_OVERLAY_DIR is passed through"
else
  bad "CUSTOMER_OVERLAY_DIR was not passed through"
fi

unset CUSTOMER_AGENTS_DIR CUSTOMER_OVERLAY_DIR CUSTOMER_SLUG
rm -f "$STUB"
if stage_agent_sources "$AGENT_REPO" researcher >/dev/null 2>"$TMP/err"; then
  bad "missing stage-agent-sources.sh succeeded"
else
  ok "missing stage-agent-sources.sh fails the build"
fi

for SCRIPT in redeploy-agent.sh master-setup.sh manage-agent.sh; do
  if grep -q 'stage_agent_sources ' "$ROOT/$SCRIPT"; then
    ok "$SCRIPT calls stage_agent_sources"
  else
    bad "$SCRIPT does not call stage_agent_sources"
  fi
  if grep -q 'app/agents/${AGENT_NAME}.py' "$ROOT/$SCRIPT" \
    || grep -q 'agents/_shell.py' "$ROOT/$SCRIPT"; then
    bad "$SCRIPT still copies app/agents into the image build"
  else
    ok "$SCRIPT does not copy app/agents into the image build"
  fi
done

if [ ! -f "$ROOT/redeploy-chat.sh" ]; then
  ok "redeploy-chat.sh is gone"
else
  bad "redeploy-chat.sh still exists"
fi

if grep -q '4-rg-ai-agent-platform-chat' "$ROOT/destroy.sh"; then
  bad "destroy.sh still names the chat state key"
else
  ok "destroy.sh has no chat state key"
fi

HITS="$(grep -R -n -E '4-rg-ai-agent-platform-chat|redeploy-chat\.sh|4-chat' \
  --exclude-dir .git \
  --exclude test-customer-overlay-stage.sh \
  "$ROOT" \
  | grep -v -E 'AUDIT-2026-09-07\.md:|operator-instructions/PLATFORM-ROLES\.md:' \
  || true)"
if [ -z "$HITS" ]; then
  ok "no live chat-repo product paths outside historical notes"
else
  bad "live chat-repo path still present"
  echo "$HITS"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
