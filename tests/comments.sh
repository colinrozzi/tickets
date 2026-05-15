#!/usr/bin/env bash
# Integration test for the comment endpoint + show rendering
# (phase 2 / part 2).
#
# Exercises the running tickets server (127.0.0.1:8443) via raw curl:
#   - happy path: POST /v1/tickets/<id>/comment appends + returns the updated ticket
#   - missing author/body rejected with 400
#   - unknown ticket id rejected with 404
#   - non-numeric ticket id rejected with 400
#
# We use addresses on a fake domain (tests@local) so the email bridge fires
# but fails harmlessly against a non-existent mailbox — that's exercised by
# the live demo flow, not here.
#
# Prereqs: acceptor running on 127.0.0.1:8443; ~/.config/tickets/token populated.

set -euo pipefail

API=${TICKETS_API:-127.0.0.1:8443}
if [ -z "${TICKETS_TOKEN:-}" ] && [ -f "$HOME/.config/tickets/token" ]; then
  TICKETS_TOKEN=$(< "$HOME/.config/tickets/token")
fi
: "${TICKETS_TOKEN:?set TICKETS_TOKEN or populate ~/.config/tickets/token}"

pass=0; fail=0
ok()   { printf "  \033[32mok\033[0m   %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail+1)); }

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

echo "creating test ticket..."
create_resp=$(curl_status POST /v1/tickets \
  '{"title":"comment-test","body":"created by tests/comments.sh","reporter":"tests@local","assignee":"tests@local"}')
create_code=${create_resp%%	*}
create_body=${create_resp#*	}
if [ "$create_code" != "201" ]; then
  echo "setup failed: create returned $create_code: $create_body"
  exit 1
fi
id=$(printf '%s' "$create_body" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')
echo "created ticket #$id"
echo

echo "test 1: happy-path comment append"
r=$(curl_status POST "/v1/tickets/$id/comment" '{"author":"alice@local","body":"first comment"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "201" ] || bad "expected 201, got $code: $body"
if [ "$code" = "201" ]; then
  echo "$body" | grep -q '"comments":\[' && echo "$body" | grep -q '"author":"alice@local"' \
    && ok "comment appended; ticket returned with comments[]" \
    || bad "comment not visible in response; body=$body"
fi

echo
echo "test 2: second comment appends (order preserved)"
r=$(curl_status POST "/v1/tickets/$id/comment" '{"author":"bob@local","body":"reply"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "201" ] || bad "second comment expected 201, got $code"
# crude check: alice should appear before bob in the JSON
alice_pos=$(echo "$body" | grep -bo '"alice@local"' | head -1 | cut -d: -f1)
bob_pos=$(echo "$body" | grep -bo '"bob@local"' | head -1 | cut -d: -f1)
if [ -n "$alice_pos" ] && [ -n "$bob_pos" ] && [ "$alice_pos" -lt "$bob_pos" ]; then
  ok "comments ordered by insertion (alice before bob)"
else
  bad "ordering check failed: alice_pos=$alice_pos bob_pos=$bob_pos"
fi

echo
echo "test 3: missing author rejected (400)"
r=$(curl_status POST "/v1/tickets/$id/comment" '{"body":"no author"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "400" ] && ok "missing author -> 400" \
  || bad "expected 400, got $code: $body"

echo
echo "test 4: missing body rejected (400)"
r=$(curl_status POST "/v1/tickets/$id/comment" '{"author":"alice@local"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "400" ] && ok "missing body -> 400" \
  || bad "expected 400, got $code: $body"

echo
echo "test 5: empty author string rejected (400)"
r=$(curl_status POST "/v1/tickets/$id/comment" '{"author":"","body":"hi"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "400" ] && ok "empty author -> 400" \
  || bad "expected 400, got $code: $body"

echo
echo "test 6: unknown ticket id (404)"
r=$(curl_status POST /v1/tickets/999999/comment '{"author":"alice@local","body":"hi"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "404" ] && ok "unknown id -> 404" \
  || bad "expected 404, got $code: $body"

echo
echo "test 7: non-numeric id (400)"
r=$(curl_status POST /v1/tickets/abc/comment '{"author":"alice@local","body":"hi"}')
code=${r%%	*}; body=${r#*	}
[ "$code" = "400" ] && ok "non-numeric id -> 400" \
  || bad "expected 400, got $code: $body"

echo
echo "test 8: GET /v1/tickets/<id> returns both comments"
r=$(curl_status GET "/v1/tickets/$id" '')
code=${r%%	*}; body=${r#*	}
if [ "$code" = "200" ] \
  && echo "$body" | grep -q '"alice@local"' \
  && echo "$body" | grep -q '"bob@local"'; then
  ok "show endpoint returns both comments"
else
  bad "show check: code=$code body=$body"
fi

echo
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
