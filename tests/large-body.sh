#!/usr/bin/env bash
# Integration test for the full-request read loop in the per-connection handler.
#
# Regression guard for the handler reading only the first `tcp_receive` chunk
# (65536 bytes). The theater `tcp.receive` host call is partial, so a request
# whose body exceeds one chunk — or that arrives split across TCP segments —
# used to be truncated, producing a spurious 400 (JSON parse error / missing
# body). `handle_connection_transfer` now loops `tcp_receive` until the full
# request (headers + Content-Length body) has arrived.
#
# This POSTs a comment whose body is well over 64 KiB and asserts:
#   - the request succeeds (201), not a truncation-induced 400
#   - the stored comment round-trips byte-for-byte (same length, same head/tail)
#
# We use addresses on a fake domain (tests@local) so the email bridge fires
# but fails harmlessly against a non-existent mailbox.
#
# Prereqs: acceptor running on 127.0.0.1:8443; ~/.config/tickets/token populated.
#
# Usage:  tests/large-body.sh

set -euo pipefail

API=${TICKETS_API:-127.0.0.1:8443}
if [ -z "${TICKETS_TOKEN:-}" ] && [ -f "$HOME/.config/tickets/token" ]; then
  TICKETS_TOKEN=$(< "$HOME/.config/tickets/token")
fi
: "${TICKETS_TOKEN:?set TICKETS_TOKEN or populate ~/.config/tickets/token}"

pass=0; fail=0
ok()   { printf "  \033[32mok\033[0m   %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail+1)); }

# `curl_status METHOD PATH [BODY_FILE]` → echoes "HTTP_CODE<TAB>BODY".
# Body is passed via a file (--data-binary @file) so we can send payloads far
# larger than a command-line argument comfortably holds.
curl_status() {
  local method=$1 path=$2 body_file=${3:-}
  local args=(-sS -o /tmp/tickets-large.body -w '%{http_code}'
              -H "Authorization: Bearer $TICKETS_TOKEN"
              -X "$method" "http://$API$path")
  if [ -n "$body_file" ]; then
    args+=(-H "Content-Type: application/json" --data-binary "@$body_file")
  fi
  local code
  code=$(curl "${args[@]}")
  printf '%s\t' "$code"
  cat /tmp/tickets-large.body
}

echo "creating test ticket..."
printf '%s' '{"title":"large-body-test","body":"created by tests/large-body.sh","reporter":"tests@local","assignee":"tests@local"}' > /tmp/tickets-large.create
create_resp=$(curl_status POST /v1/tickets /tmp/tickets-large.create)
create_code=${create_resp%%	*}
create_body=${create_resp#*	}
if [ "$create_code" != "201" ]; then
  echo "setup failed: create returned $create_code: $create_body"
  exit 1
fi
id=$(printf '%s' "$create_body" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')
echo "created ticket #$id"
echo

# Build a comment body comfortably larger than the 64 KiB first-chunk size:
# 200000 distinct-ish characters so truncation can't accidentally still parse.
# We make it valid JSON-string content (letters only — no escaping needed).
N=200000
echo "building a ${N}-byte comment body (> 64 KiB first chunk)..."
big=$(head -c "$N" /dev/zero | tr '\0' 'x')
# marker head/tail so we can assert the stored value round-trips end-to-end
big="HEAD_MARKER_${big}_TAIL_MARKER"
blen=${#big}
printf '{"author":"alice@local","body":"%s"}' "$big" > /tmp/tickets-large.comment
echo "request body file is $(stat -c%s /tmp/tickets-large.comment) bytes"
echo

echo "test 1: large comment POST succeeds (201, not a truncation 400)"
r=$(curl_status POST "/v1/tickets/$id/comment" /tmp/tickets-large.comment)
code=${r%%	*}; body=${r#*	}
if [ "$code" = "201" ]; then
  ok "large comment accepted -> 201"
else
  bad "expected 201, got $code: $(printf '%s' "$body" | head -c 300)"
fi

echo
echo "test 2: stored comment round-trips (full length preserved)"
# Pull the ticket back and extract the stored comment body length. We grab the
# "body" field of the (single) comment and compare its length to what we sent.
r=$(curl_status GET "/v1/tickets/$id")
code=${r%%	*}; body=${r#*	}
if [ "$code" != "200" ]; then
  bad "show returned $code"
else
  # Prefer jq when present for an exact round-trip check; fall back to markers.
  if command -v jq >/dev/null 2>&1; then
    stored=$(printf '%s' "$body" | jq -r '.comments[-1].body')
    slen=${#stored}
    if [ "$slen" = "$blen" ] && [ "$stored" = "$big" ]; then
      ok "stored comment matches sent body exactly ($slen bytes)"
    else
      bad "round-trip mismatch: sent $blen bytes, stored $slen bytes"
    fi
  else
    if printf '%s' "$body" | grep -q 'HEAD_MARKER_' && printf '%s' "$body" | grep -q '_TAIL_MARKER'; then
      ok "stored comment contains both head and tail markers (install jq for exact check)"
    else
      bad "round-trip markers missing in stored comment"
    fi
  fi
fi

echo
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
