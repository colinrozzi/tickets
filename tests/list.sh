#!/usr/bin/env bash
# Integration test for GET /v1/tickets list filtering.
#
# Exercises the running tickets server (127.0.0.1:8443) via raw curl, covering
# the three orthogonal filters and that they AND together:
#   - ?reporter=X returns only tickets reported by X
#   - ?assignee=Y returns only tickets assigned to Y
#   - ?status=&reporter=&assignee= combined narrows to the intersection
#
# Each ticket is tagged with a unique run id in its reporter/assignee/title so
# the assertions are independent of whatever else lives in the store.
#
# Prereqs:
#   - acceptor running on 127.0.0.1:8443
#   - bearer token in ~/.config/tickets/token (or $TICKETS_TOKEN)
#
# Usage:  tests/list.sh

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

# Tag this run so filters resolve to a known, isolated set of tickets. The
# reporter/assignee values are URL-safe (letters, digits, '-', '.') so no
# percent-encoding is needed in the query strings below.
run=$(date +%s)
alice="alice-${run}@local"
bob="bob-${run}@local"

create() {
  local reporter=$1 assignee=$2
  local resp code body
  resp=$(curl_status POST /v1/tickets \
    "{\"title\":\"list-test-${run}\",\"body\":\"created by tests/list.sh\",\"reporter\":\"${reporter}\",\"assignee\":\"${assignee}\"}")
  code=${resp%%	*}; body=${resp#*	}
  if [ "$code" != "201" ]; then
    echo "setup failed: create returned $code: $body" >&2
    exit 1
  fi
  printf '%s' "$body" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+'
}

echo "creating test tickets..."
# alice reports two (one she assigns to herself, one to bob); bob reports one.
id_a_self=$(create "$alice" "$alice")
id_a_bob=$(create "$alice" "$bob")
id_b_bob=$(create "$bob" "$bob")
echo "created #$id_a_self (alice->alice), #$id_a_bob (alice->bob), #$id_b_bob (bob->bob)"
echo

# Count how many of this run's three ids appear in a list response body. We
# match the unique id tokens so unrelated store tickets never interfere.
has_id() { echo "$1" | grep -qE "\"id\":$2(,|})"; }

echo "test 1: ?reporter= returns only matching tickets"
r=$(curl_status GET "/v1/tickets?reporter=${alice}" '')
code=${r%%	*}; body=${r#*	}
if [ "$code" = "200" ] \
  && has_id "$body" "$id_a_self" \
  && has_id "$body" "$id_a_bob" \
  && ! has_id "$body" "$id_b_bob"; then
  ok "reporter=alice → alice's two tickets, not bob's"
else
  bad "reporter filter wrong: code=$code body=$body"
fi

echo
echo "test 2: ?assignee= returns only matching tickets"
r=$(curl_status GET "/v1/tickets?assignee=${alice}" '')
code=${r%%	*}; body=${r#*	}
if [ "$code" = "200" ] \
  && has_id "$body" "$id_a_self" \
  && ! has_id "$body" "$id_a_bob" \
  && ! has_id "$body" "$id_b_bob"; then
  ok "assignee=alice → only the alice->alice ticket"
else
  bad "assignee filter wrong: code=$code body=$body"
fi

echo
echo "test 3: reporter + assignee AND together"
r=$(curl_status GET "/v1/tickets?reporter=${alice}&assignee=${bob}" '')
code=${r%%	*}; body=${r#*	}
if [ "$code" = "200" ] \
  && has_id "$body" "$id_a_bob" \
  && ! has_id "$body" "$id_a_self" \
  && ! has_id "$body" "$id_b_bob"; then
  ok "reporter=alice&assignee=bob → only the alice->bob ticket"
else
  bad "reporter+assignee AND wrong: code=$code body=$body"
fi

echo
echo "test 4: status + reporter + assignee AND together"
# Move the alice->bob ticket to in-progress, leave the others open. Then the
# full triple filter should isolate exactly that one ticket.
curl_status POST "/v1/tickets/$id_a_bob/status" '{"status":"in-progress"}' >/dev/null
r=$(curl_status GET "/v1/tickets?status=in-progress&reporter=${alice}&assignee=${bob}" '')
code=${r%%	*}; body=${r#*	}
if [ "$code" = "200" ] \
  && has_id "$body" "$id_a_bob" \
  && ! has_id "$body" "$id_a_self" \
  && ! has_id "$body" "$id_b_bob"; then
  ok "status+reporter+assignee → only the in-progress alice->bob ticket"
else
  bad "triple AND wrong: code=$code body=$body"
fi

echo
echo "test 5: non-matching reporter → empty-but-valid list"
r=$(curl_status GET "/v1/tickets?reporter=nobody-${run}@local" '')
code=${r%%	*}; body=${r#*	}
if [ "$code" = "200" ] \
  && ! has_id "$body" "$id_a_self" \
  && ! has_id "$body" "$id_a_bob" \
  && ! has_id "$body" "$id_b_bob"; then
  ok "unknown reporter → none of this run's tickets"
else
  bad "unknown reporter filter wrong: code=$code body=$body"
fi

echo
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
