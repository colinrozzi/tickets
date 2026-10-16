#!/usr/bin/env bash
# Concurrency test for the serialized write path (phase 2 / part 3).
#
# This is the behavioral proof of the singleton write-serialization cutover
# (#40): all writes now route through the long-lived `ticket-store` actor, so
# concurrent create / comment / status writes are serialized (the actor model
# is the mutex) and the phase-1 TOCTOU race on `tickets-list` is gone.
#
# Fires many concurrent writers at a running tickets server and asserts no lost
# updates:
#   1. Concurrent creates -> unique, non-colliding ids, none lost (the
#      pre-cutover race produced duplicate max+1 ids and clobbered writes).
#   2. Concurrent comment-appends -> every comment persisted, none lost.
#   3. Concurrent status sets -> no 5xx, final status is one of the set values.
#
# Before the cutover this would FAIL (duplicate ids / clobbered writes); after,
# it passes. CI does NOT run this (there is no live server in CI) — like the
# other tests/*.sh it must run against a live `theater spawn` with the cutover
# deployed.
#
# Run-id isolation: every ticket this script creates tags its reporter,
# assignee, and project with a unique per-run token, so the list cross-check
# only ever matches tickets created by *this* run. That makes the assertions
# independent of whatever else is already in the store.
#
# Prereqs:
#   - acceptor running on 127.0.0.1:8443
#   - bearer token in ~/.config/tickets/token (or $TICKETS_TOKEN)
#
# Usage:  tests/concurrency.sh

set -euo pipefail

API=${TICKETS_API:-127.0.0.1:8443}
if [ -z "${TICKETS_TOKEN:-}" ] && [ -f "$HOME/.config/tickets/token" ]; then
  TICKETS_TOKEN=$(< "$HOME/.config/tickets/token")
fi
: "${TICKETS_TOKEN:?set TICKETS_TOKEN or populate ~/.config/tickets/token}"

# Unique token for this run so the list cross-check is isolated from existing
# store state, and a scratch dir for the concurrent responses.
RUN="conc-$$-${RANDOM}"
N=${CONC_N:-20}
WORK=$(mktemp -d "/tmp/tickets-conc-$$.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { printf "  \033[32mok\033[0m   %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail+1)); }

# `curl_status METHOD PATH BODY` → echoes "HTTP_CODE<TAB>BODY".
# Used for the sequential setup / cross-check requests (not the parallel fires,
# which need per-job output files — see curl_bg below).
curl_status() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -o "$WORK/seq.body" -w '%{http_code}'
              -H "Authorization: Bearer $TICKETS_TOKEN"
              -X "$method" "http://$API$path")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  local code
  code=$(curl "${args[@]}")
  printf '%s\t' "$code"
  cat "$WORK/seq.body"
}

# `curl_bg METHOD PATH BODY OUT` → writes HTTP code to $OUT.code and body to
# $OUT.body. Safe to background (&) since each job owns distinct files; this is
# what makes the concurrent fires independent instead of clobbering a shared
# temp file the way curl_status would.
curl_bg() {
  local method=$1 path=$2 body=$3 out=$4
  local args=(-sS -o "$out.body" -w '%{http_code}'
              -H "Authorization: Bearer $TICKETS_TOKEN"
              -X "$method" "http://$API$path")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  curl "${args[@]}" > "$out.code"
}

# Count "id" occurrences in a tickets-list JSON body (no jq, matching the other
# tests' style).
count_ids() { printf '%s' "$1" | grep -oE '"id":[0-9]+' | wc -l | tr -d ' '; }

echo "run token: $RUN   concurrency: N=$N"
echo

# ---------------------------------------------------------------------------
echo "test 1: $N concurrent creates -> unique ids, none lost"
# Fire N creates in parallel, each tagged with this run's reporter + project.
for ((i=1; i<=N; i++)); do
  curl_bg POST /v1/tickets \
    "{\"title\":\"conc-create-$i\",\"body\":\"concurrent create $i ($RUN)\",\"reporter\":\"reporter-$RUN\",\"assignee\":\"assignee-$RUN\",\"project\":\"$RUN\"}" \
    "$WORK/create-$i" &
done
wait

# Collect: every create must be 201, and we gather the returned ids.
all_201=1; got=0
: > "$WORK/ids"
for ((i=1; i<=N; i++)); do
  code=$(cat "$WORK/create-$i.code")
  body=$(cat "$WORK/create-$i.body")
  if [ "$code" != "201" ]; then
    all_201=0
    echo "    create $i returned $code: $body"
    continue
  fi
  id=$(printf '%s' "$body" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')
  if [ -n "$id" ]; then
    echo "$id" >> "$WORK/ids"
    got=$((got+1))
  else
    echo "    create $i: 201 but no id in body: $body"
  fi
done

[ "$all_201" = 1 ] \
  && ok "all $N concurrent creates returned 201" \
  || bad "not all concurrent creates returned 201"

[ "$got" = "$N" ] \
  && ok "collected $N ids (none lost)" \
  || bad "expected $N ids, collected $got"

uniq_ids=$(sort -u "$WORK/ids" | wc -l | tr -d ' ')
if [ "$uniq_ids" = "$N" ]; then
  ok "all $N ids are unique (no colliding max+1 ids)"
else
  dupes=$(sort "$WORK/ids" | uniq -d | tr '\n' ' ')
  bad "expected $N unique ids, got $uniq_ids unique (duplicates: $dupes)"
fi

# Cross-check against the store: listing this run's project must return exactly
# N tickets — proving every concurrent write actually committed.
r=$(curl_status GET "/v1/tickets?project=$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "$N" ]; then
  ok "GET ?project=$RUN returns exactly $N tickets"
else
  bad "list cross-check: code=$code count=$n (expected $N)"
fi

echo
# ---------------------------------------------------------------------------
echo "test 2: $N concurrent comments -> none lost"
# One fresh ticket, then N concurrent comment-appends with distinct bodies.
create_resp=$(curl_status POST /v1/tickets \
  "{\"title\":\"conc-comments\",\"body\":\"comment target ($RUN)\",\"reporter\":\"reporter-$RUN\",\"assignee\":\"assignee-$RUN\",\"project\":\"$RUN\"}")
create_code=${create_resp%%	*}; create_body=${create_resp#*	}
if [ "$create_code" != "201" ]; then
  bad "setup: comment-target create returned $create_code: $create_body"
else
  cid=$(printf '%s' "$create_body" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')
  echo "    comment target ticket #$cid"

  for ((i=1; i<=N; i++)); do
    curl_bg POST "/v1/tickets/$cid/comment" \
      "{\"author\":\"commenter-$i-$RUN\",\"body\":\"concurrent comment $i\"}" \
      "$WORK/comment-$i" &
  done
  wait

  all_201=1
  for ((i=1; i<=N; i++)); do
    code=$(cat "$WORK/comment-$i.code")
    if [ "$code" != "201" ]; then
      all_201=0
      echo "    comment $i returned $code: $(cat "$WORK/comment-$i.body")"
    fi
  done
  [ "$all_201" = 1 ] \
    && ok "all $N concurrent comment POSTs returned 201" \
    || bad "not all concurrent comment POSTs returned 201"

  # The ground truth: GET the ticket and count persisted comments. Each comment
  # carries one "author": field, so the count equals the number that survived.
  r=$(curl_status GET "/v1/tickets/$cid" '')
  code=${r%%	*}; body=${r#*	}
  ccount=$(printf '%s' "$body" | grep -oE '"author":' | wc -l | tr -d ' ')
  if [ "$code" = "200" ] && [ "$ccount" = "$N" ]; then
    ok "ticket #$cid has exactly $N comments (none lost)"
  else
    bad "comment count: code=$code count=$ccount (expected $N)"
  fi
fi

echo
# ---------------------------------------------------------------------------
echo "test 3: $N concurrent status sets -> no 5xx, final status is valid"
STATUSES=(open in-progress done closed)
create_resp=$(curl_status POST /v1/tickets \
  "{\"title\":\"conc-status\",\"body\":\"status target ($RUN)\",\"reporter\":\"reporter-$RUN\",\"assignee\":\"assignee-$RUN\",\"project\":\"$RUN\"}")
create_code=${create_resp%%	*}; create_body=${create_resp#*	}
if [ "$create_code" != "201" ]; then
  bad "setup: status-target create returned $create_code: $create_body"
else
  sid=$(printf '%s' "$create_body" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')
  echo "    status target ticket #$sid"

  for ((i=1; i<=N; i++)); do
    s=${STATUSES[$(( i % ${#STATUSES[@]} ))]}
    curl_bg POST "/v1/tickets/$sid/status" "{\"status\":\"$s\"}" "$WORK/status-$i" &
  done
  wait

  no_5xx=1
  for ((i=1; i<=N; i++)); do
    code=$(cat "$WORK/status-$i.code")
    if [ "$code" -ge 500 ] 2>/dev/null; then
      no_5xx=0
      echo "    status set $i returned $code: $(cat "$WORK/status-$i.body")"
    fi
  done
  [ "$no_5xx" = 1 ] \
    && ok "no concurrent status set returned 5xx" \
    || bad "a concurrent status set returned 5xx"

  r=$(curl_status GET "/v1/tickets/$sid" '')
  code=${r%%	*}; body=${r#*	}
  final=$(printf '%s' "$body" | grep -oE '"status":"[a-z-]+"' | head -1 | sed -E 's/.*"status":"([a-z-]+)"/\1/')
  valid=0
  for s in "${STATUSES[@]}"; do [ "$final" = "$s" ] && valid=1; done
  if [ "$code" = "200" ] && [ "$valid" = 1 ]; then
    ok "final status converged to a valid value (\"$final\")"
  else
    bad "final status check: code=$code final=\"$final\""
  fi
fi

echo
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
