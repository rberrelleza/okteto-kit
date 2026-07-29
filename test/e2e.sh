#!/bin/bash
#
# Manual end-to-end test for the okteto kit.
#
# Creates a real sandbox with this kit applied, then verifies from inside it
# that the Okteto CLI installed for the right architecture and that the proxy
# substitutes the real token for the placeholder when talking to your Okteto
# instance.
#
# Usage:
#   test/e2e.sh [sandbox-name]
#
# The Okteto host is read from OKTETO_CONTEXT in spec.yaml, so this follows
# whatever instance the kit is pointed at. No need to edit the test.
#
# Prerequisites:
#   1. sbx installed and signed in    (sbx login)
#   2. The token registered for your host, matching spec.yaml:
#        sbx secret set-custom -g --host <your-host> \
#            --env OKTETO_TOKEN --placeholder "okteto-{rand}" --value "$OKTETO_TOKEN"
#
# On macOS, run this from a session that can reach the login keychain, i.e. a
# GUI session (physical console or screen sharing). The sbx CLI reads the Docker
# Hub token and custom secrets from the keychain itself, and a process in an SSH
# or background session cannot prompt for keychain access, so it fails with
# "cannot prompt the user for password". See the README's Testing section.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$REPO_ROOT/spec.yaml"
NAME="${1:-okteto-e2e}"
LOG="$REPO_ROOT/test/e2e.log"
WORKSPACE="$(mktemp -d)"

exec > >(tee "$LOG") 2>&1

step()   { echo; echo "=================== $* ==================="; }
failed=0
check()  { if [ "$1" -eq 0 ]; then echo "  PASS: $2"; else echo "  FAIL: $2"; failed=1; fi; }

# The instance the kit points at, e.g. "demo.okteto.dev".
CONTEXT_URL="$(sed -nE 's/^[[:space:]]*OKTETO_CONTEXT:[[:space:]]*(.+)$/\1/p' "$SPEC" | tr -d '"'"'"' \r')"
HOST="${CONTEXT_URL#https://}"; HOST="${HOST#http://}"; HOST="${HOST%%/*}"

step "0. Environment"
command -v sbx >/dev/null 2>&1 || { echo "sbx not on PATH, see https://docs.docker.com/ai/sandboxes/"; exit 1; }
sbx version
echo "kit       : $REPO_ROOT"
echo "commit    : $(git -C "$REPO_ROOT" log --oneline -1 2>/dev/null || echo 'not a git checkout')"
echo "host arch : $(uname -m)"
echo "instance  : $CONTEXT_URL (host: $HOST)"
[ -n "$HOST" ]; check $? "resolved the Okteto host from spec.yaml"

step "1. The token is registered for $HOST"
# If this errors with "cannot prompt the user for password", you are not in a
# GUI session. See the header comment.
sbx secret ls
sbx secret ls 2>/dev/null | grep -q "$HOST"
check $? "a custom secret targets $HOST"

step "2. Remove any previous '$NAME' sandbox"
sbx rm -f "$NAME" 2>/dev/null || true

step "3. Create the sandbox with the kit (runs the install command)"
sbx create --name "$NAME" --kit "$REPO_ROOT" claude "$WORKSPACE"
check $? "sandbox created"

step "4. Inside the sandbox: architecture, placeholder, CLI"
sbx exec "$NAME" sh -c '
  echo "  uname -m       : $(uname -m)"
  echo "  OKTETO_CONTEXT : $OKTETO_CONTEXT"
  echo "  OKTETO_TOKEN   : $OKTETO_TOKEN"
  case "$OKTETO_TOKEN" in
    okteto-*)
      echo "  PASS: OKTETO_TOKEN is the placeholder, the real token stayed on the host" ;;
    "")
      echo "  FAIL: OKTETO_TOKEN is empty. The secret is not registered, or --value was empty."
      exit 1 ;;
    proxy-managed)
      echo "  FAIL: got the proxy-managed sentinel instead of the set-custom placeholder."
      echo "        The kit should not declare credentials.sources or environment.proxyManaged."
      exit 1 ;;
    *)
      echo "  FAIL: unexpected OKTETO_TOKEN value (is the real token leaking in?)"
      exit 1 ;;
  esac
  command -v okteto >/dev/null || { echo "  FAIL: okteto not on PATH"; exit 1; }
  okteto version
'
check $? "CLI installed and token is a placeholder"

step "5. Authenticate to Okteto through the proxy"
# The real test. The CLI sends the placeholder; the proxy swaps in the real
# token on requests to the configured host. If this fails, the host in
# --host / serviceDomains / OKTETO_CONTEXT probably disagree.
sbx exec "$NAME" sh -c 'okteto context use "$OKTETO_CONTEXT"'
check $? "okteto context use succeeded (proxy substituted the token)"

step "6. Confirm the token really authenticated"
sbx exec "$NAME" sh -c 'okteto namespace list'
check $? "namespace list returned data from the instance"

step "7. Proxy decisions"
# Expect the Okteto API host as "forward" (intercepted, so the Authorization
# header can be injected) and downloads.okteto.com as "forward-bypass".
sbx policy log "$NAME" 2>&1 | tail -20 || echo "(no policy log)"

step "RESULT"
rm -rf "$WORKSPACE"
if [ "$failed" -eq 0 ]; then
  echo "PASS: all checks passed"
else
  echo "FAIL: at least one check failed, see above"
fi
echo
echo "Log      : $LOG"
echo "Clean up : sbx rm -f $NAME"
exit "$failed"
