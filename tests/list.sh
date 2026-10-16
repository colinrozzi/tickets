#!/usr/bin/env bash
# Integration test for GET /v1/tickets list filters.
#
# Exercises the running tickets server (127.0.0.1:8443) via raw curl, covering
# the ?reporter= / ?project= filters alongside the existing ?status= / ?assignee=:
#   - reporter-only filter
#   - assignee-only filter
#   - reporter + assignee (AND / intersection)
#   - status + reporter + assignee (three-way AND)
#   - unknown reporter -> valid empty list (200)
#   - project-only filter
#   - project + assignee (AND / intersection)
#   - unknown project -> valid empty list (200)
#
# Run-id isolation: every ticket this script creates tags its reporter,
# assignee, and project with a unique per-run token, so the filters only ever
# match tickets created by *this* run. That makes the assertions independent of
# whatever else is already in the store.
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

# Unique token for this run so filters are isolated from existing store state.
RUN="list-$$-${RANDOM}"

pass=0; fail=0
ok()   { printf "  \033[32mok\033[0m   %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail+1)); }

# `curl_status METHOD PATH BODY` → echoes "HTTP_CODE<TAB>BODY"
curl_status() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -o /tmp/tickets-list-test.body -w '%{http_code}'
              -H "Authorization: Bearer $TICKETS_TOKEN"
              -X "$method" "http://$API$path")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  local code
  code=$(curl "${args[@]}")
  printf '%s\t' "$code"
  cat /tmp/tickets-list-test.body
}

# Count "id" occurrences in a tickets-list JSON body.
count_ids() { printf '%s' "$1" | grep -oE '"id":[0-9]+' | wc -l | tr -d ' '; }

# create_ticket REPORTER ASSIGNEE [PROJECT] -> echoes new ticket id (exits on failure)
create_ticket() {
  local reporter=$1 assignee=$2 project=${3:-}
  local resp code body
  resp=$(curl_status POST /v1/tickets \
    "{\"title\":\"list-test\",\"body\":\"created by tests/list.sh\",\"reporter\":\"$reporter\",\"assignee\":\"$assignee\",\"project\":\"$project\"}")
  code=${resp%%	*}; body=${resp#*	}
  if [ "$code" != "201" ]; then
    echo "setup failed: create returned $code: $body" >&2
    exit 1
  fi
  printf '%s' "$body" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+'
}

echo "run token: $RUN"
echo "creating test tickets..."
# t1: reporter alice, assignee bob, project proj-a
id1=$(create_ticket "alice-$RUN" "bob-$RUN" "proj-a-$RUN")
# t2: reporter alice, assignee carol, project proj-a (will be moved to done)
id2=$(create_ticket "alice-$RUN" "carol-$RUN" "proj-a-$RUN")
# t3: reporter dave, assignee bob, project proj-b
id3=$(create_ticket "dave-$RUN" "bob-$RUN" "proj-b-$RUN")
echo "created #$id1 #$id2 #$id3"

# Move t2 to done so the status+reporter+assignee test has a distinguishing status.
r=$(curl_status POST "/v1/tickets/$id2/status" '{"status":"done"}')
[ "${r%%	*}" = "200" ] || { echo "setup failed: could not set #$id2 to done" >&2; exit 1; }
echo

echo "test 1: reporter-only filter (alice-$RUN) -> t1,t2"
r=$(curl_status GET "/v1/tickets?reporter=alice-$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "2" ] \
   && echo "$body" | grep -q "\"id\":$id1" && echo "$body" | grep -q "\"id\":$id2" \
   && ! echo "$body" | grep -q "\"id\":$id3"; then
  ok "reporter=alice returns exactly t1,t2"
else
  bad "reporter-only: code=$code count=$n body=$body"
fi

echo
echo "test 2: assignee-only filter (bob-$RUN) -> t1,t3"
r=$(curl_status GET "/v1/tickets?assignee=bob-$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "2" ] \
   && echo "$body" | grep -q "\"id\":$id1" && echo "$body" | grep -q "\"id\":$id3" \
   && ! echo "$body" | grep -q "\"id\":$id2"; then
  ok "assignee=bob returns exactly t1,t3"
else
  bad "assignee-only: code=$code count=$n body=$body"
fi

echo
echo "test 3: reporter + assignee AND (alice + bob) -> t1 only"
r=$(curl_status GET "/v1/tickets?reporter=alice-$RUN&assignee=bob-$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "1" ] && echo "$body" | grep -q "\"id\":$id1"; then
  ok "reporter=alice&assignee=bob returns exactly t1"
else
  bad "reporter+assignee: code=$code count=$n body=$body"
fi

echo
echo "test 4: status + reporter + assignee AND (done + alice + carol) -> t2 only"
r=$(curl_status GET "/v1/tickets?status=done&reporter=alice-$RUN&assignee=carol-$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "1" ] && echo "$body" | grep -q "\"id\":$id2"; then
  ok "status=done&reporter=alice&assignee=carol returns exactly t2"
else
  bad "status+reporter+assignee: code=$code count=$n body=$body"
fi

echo
echo "test 5: three-way AND with mismatched status -> empty (open + alice + carol)"
# t2 is done, so filtering alice/carol on status=open must exclude it.
r=$(curl_status GET "/v1/tickets?status=open&reporter=alice-$RUN&assignee=carol-$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "0" ]; then
  ok "mismatched status yields empty intersection (200)"
else
  bad "status mismatch: code=$code count=$n body=$body"
fi

echo
echo "test 6: unknown reporter -> valid empty list (200)"
r=$(curl_status GET "/v1/tickets?reporter=nobody-$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "0" ] && echo "$body" | grep -q '"tickets"'; then
  ok "unknown reporter returns empty list with 200"
else
  bad "unknown reporter: code=$code count=$n body=$body"
fi

echo
echo "test 7: project-only filter (proj-a-$RUN) -> t1,t2"
r=$(curl_status GET "/v1/tickets?project=proj-a-$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "2" ] \
   && echo "$body" | grep -q "\"id\":$id1" && echo "$body" | grep -q "\"id\":$id2" \
   && ! echo "$body" | grep -q "\"id\":$id3"; then
  ok "project=proj-a returns exactly t1,t2"
else
  bad "project-only: code=$code count=$n body=$body"
fi

echo
echo "test 8: project + assignee AND (proj-a + carol) -> t2 only"
r=$(curl_status GET "/v1/tickets?project=proj-a-$RUN&assignee=carol-$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "1" ] && echo "$body" | grep -q "\"id\":$id2"; then
  ok "project=proj-a&assignee=carol returns exactly t2"
else
  bad "project+assignee: code=$code count=$n body=$body"
fi

echo
echo "test 9: project + assignee with cross-project assignee -> empty (proj-b + carol)"
# carol is only on t2 (proj-a); filtering her within proj-b must be empty.
r=$(curl_status GET "/v1/tickets?project=proj-b-$RUN&assignee=carol-$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "0" ]; then
  ok "project=proj-b&assignee=carol yields empty intersection (200)"
else
  bad "project+assignee mismatch: code=$code count=$n body=$body"
fi

echo
echo "test 10: unknown project -> valid empty list (200)"
r=$(curl_status GET "/v1/tickets?project=nope-$RUN" '')
code=${r%%	*}; body=${r#*	}
n=$(count_ids "$body")
if [ "$code" = "200" ] && [ "$n" = "0" ] && echo "$body" | grep -q '"tickets"'; then
  ok "unknown project returns empty list with 200"
else
  bad "unknown project: code=$code count=$n body=$body"
fi

echo
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
