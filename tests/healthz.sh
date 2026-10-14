#!/usr/bin/env bash
# Integration test for the unauthenticated liveness probe GET /healthz.
#
# Exercises the running tickets server (127.0.0.1:8443) via raw curl, covering:
#   - GET /healthz with NO Authorization header -> 200 + {"status":"ok"}
#   - the bearer gate is still enforced on authed routes (GET /v1/tickets
#     without a token -> 401)
#
# Prereqs:
#   - acceptor running on 127.0.0.1:8443
#   (no token needed — the whole point is that /healthz is tokenless)
#
# Usage:  tests/healthz.sh

set -euo pipefail

API=${TICKETS_API:-127.0.0.1:8443}

pass=0; fail=0
ok()   { printf "  \033[32mok\033[0m   %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail+1)); }

# `curl_noauth METHOD PATH` → echoes "HTTP_CODE<TAB>BODY" (no Authorization header)
curl_noauth() {
  local method=$1 path=$2
  local code
  code=$(curl -sS -o /tmp/tickets-healthz.body -w '%{http_code}' \
         -X "$method" "http://$API$path")
  printf '%s\t' "$code"
  cat /tmp/tickets-healthz.body
}

echo "test 1: GET /healthz with no Authorization header -> 200 + {\"status\":\"ok\"}"
r=$(curl_noauth GET /healthz)
code=${r%%	*}; body=${r#*	}
[ "$code" = "200" ] && echo "$body" | grep -q '"status":"ok"' \
  && ok "healthz returned 200 + status:ok" \
  || bad "expected 200 + status:ok, got $code: $body"

echo
echo "test 2: authed route still requires a bearer (GET /v1/tickets, no token -> 401)"
r=$(curl_noauth GET /v1/tickets)
code=${r%%	*}; body=${r#*	}
[ "$code" = "401" ] && ok "unauthenticated /v1/tickets rejected with 401" \
  || bad "expected 401 for tokenless /v1/tickets, got $code: $body"

echo
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
