#!/usr/bin/env bash
# Integration test for status transitions (phase 2 / part 1).
#
# Exercises the running tickets server (127.0.0.1:8443) via raw curl, covering:
#   - happy path: open -> in-progress
#   - idempotent done -> done (same status accepted twice)
#   - invalid status value rejected with 400
#   - unknown ticket id rejected with 404
#   - non-numeric ticket id rejected with 400
#
# Prereqs:
#   - acceptor running on 127.0.0.1:8443
#   - bearer token in ~/.config/tickets/token (or $TICKETS_TOKEN)
#
# Usage:  tests/status.sh

set -euo pipefail

API=${TICKETS_API:-127.0.0.1:8443}
if [ -z "${TICKETS_TOKEN:-}" ] && [ -f "$HOME/.config/tickets/token" ]; then
  TICKETS_TOKEN=$(< "$HOME/.config/tickets/token")
fi
: "${TICKETS_TOKEN:?set TICKETS_TOKEN or populate ~/.config/tickets/token}"

pass=0; fail=0
ok()   { printf "  \033[32mok\033[0m   %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail+1)); }

# `curl_status METHOD PATH BODY` → echoes "HTTP_CODE<TAB>BODY"
curl_status() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -o /tmp/tickets-test.body -w '%{http_code}'
              -H "Authorization: Bearer $TICKETS_TOKEN"
              -X "$method" "http://$API$path")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  local code
  code=$(curl "${args[@]}")
  printf '%s\t' "$code"
  cat /tmp/tickets-test.body
}

# Setup: create a fresh ticket so the test is self-contained.
echo "creating test ticket..."
create_resp=$(curl_status POST /v1/tickets \
  '{"title":"status-test","body":"created by tests/status.sh","reporter":"tests@local","assignee":"tests@local"}')
create_code=${create_resp%%	*}
create_body=${create_resp#*	}
if [ "$create_code" != "201" ]; then
  echo "setup failed: create returned $create_code: $create_body"
  exit 1
fi
# Parse id without jq — grep the first integer after `"id":`.
id=$(printf '%s' "$create_body" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')
echo "created ticket #$id"
echo

echo "test 1: open -> in-progress"
r=$(curl_status POST "/v1/tickets/$id/status" '{"status":"in-progress"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "200" ] || { bad "expected 200, got $code: $body"; }
[ "$code" = "200" ] && {
  echo "$body" | grep -q '"status":"in-progress"' \
    && ok "status updated to in-progress" \
    || bad "response missing status:in-progress; body=$body"
}

echo
echo "test 2: idempotent done -> done (second set is a side-effect-free no-op)"
# First done: a genuine in-progress -> done transition (persists + notifies).
r=$(curl_status POST "/v1/tickets/$id/status" '{"status":"done"}')
code=${r%%	*}; body1=${r#*	}
[ "$code" = "200" ] && ok "first done transition (200)" || bad "first done: got $code"
# Second done: status already == done, so this must be a true no-op — still
# 200, and the returned ticket must be byte-identical to the first (no store
# rewrite, no field churn). We can't read the handler log over HTTP, so the
# unchanged body is our observable proxy for "no side effects".
r=$(curl_status POST "/v1/tickets/$id/status" '{"status":"done"}')
code=${r%%	*}; body2=${r#*	}
if [ "$code" = "200" ] && echo "$body2" | grep -q '"status":"done"'; then
  ok "second done still 200 + status:done"
else
  bad "second done: got $code, body=$body2"
fi
[ "$body2" = "$body1" ] \
  && ok "second done is a no-op (ticket unchanged)" \
  || bad "second done changed the ticket; before=$body1 after=$body2"

echo
echo "test 3: invalid status value rejected (400)"
r=$(curl_status POST "/v1/tickets/$id/status" '{"status":"bogus"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "400" ] && ok "invalid status rejected with 400" \
  || bad "expected 400 for invalid status, got $code: $body"

echo
echo "test 4: unknown ticket id (404)"
r=$(curl_status POST /v1/tickets/999999/status '{"status":"open"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "404" ] && ok "unknown id returns 404" \
  || bad "expected 404, got $code: $body"

echo
echo "test 5: non-numeric ticket id (400)"
r=$(curl_status POST /v1/tickets/abc/status '{"status":"open"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "400" ] && ok "non-numeric id returns 400" \
  || bad "expected 400, got $code: $body"

echo
echo "test 6: verify final state via GET /v1/tickets/<id>"
r=$(curl_status GET "/v1/tickets/$id" '')
code=${r%%	*}; body=${r#*	}
[ "$code" = "200" ] && echo "$body" | grep -q '"status":"done"' \
  && ok "ticket #$id is done after all transitions" \
  || bad "final state check: code=$code body=$body"

echo
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
