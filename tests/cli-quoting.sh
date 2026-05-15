#!/usr/bin/env bash
# Regression test for the wrapper-level encoding pipeline.
#
# The wrapper at cli/tickets builds a JSON document, embeds it as a TOML
# string in a temp manifest, and hands it to the wasm CLI which JSON-parses.
# A TOML basic multi-line string ("""…""") would interpret backslash escapes
# and silently corrupt the embedded JSON; a literal multi-line string
# ('''…''') leaves it byte-for-byte. The wrapper uses '''…'''.
#
# A second prior bug: `getline line < "/dev/stdin"` doesn't update NR in awk,
# so multi-line bodies were silently flattened to one line.
#
# Both regress without observable error (bash exits 0, the wasm parse fails
# and never POSTs). curl-based tests never catch them because curl bypasses
# the wrapper. Drive the wrapper directly and read back via the API to
# verify the round-trip.

set -euo pipefail

API=${TICKETS_API:-127.0.0.1:8443}
if [ -z "${TICKETS_TOKEN:-}" ] && [ -f "$HOME/.config/tickets/token" ]; then
  TICKETS_TOKEN=$(< "$HOME/.config/tickets/token")
fi
: "${TICKETS_TOKEN:?set TICKETS_TOKEN or populate ~/.config/tickets/token}"

repo=$(cd "$(dirname "$0")/.." && pwd)
cli="$repo/cli/tickets"

pass=0; fail=0
ok()  { printf "  \033[32mok\033[0m   %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail+1)); }

# Create a ticket via the wrapper, parse the id from its output line:
#   "created #N  [open]  ..."
create_via_cli() {
  local title=$1 body=$2
  local out
  out=$("$cli" new --title "$title" --reporter tests@local --assignee tests@local --body "$body" 2>&1)
  if ! grep -qE '^created #[0-9]+' <<<"$out"; then
    echo "$out" >&2
    return 1
  fi
  grep -oE '^created #[0-9]+' <<<"$out" | head -1 | grep -oE '[0-9]+'
}

# Read the body field of a ticket back via the API.
fetch_body() {
  local id=$1
  curl -s -H "Authorization: Bearer $TICKETS_TOKEN" "http://$API/v1/tickets/$id" \
    | sed -n 's/.*"body":"\(.*\)","reporter".*/\1/p'
}

echo "test 1: body containing literal double-quotes"
id=$(create_via_cli "quoting-1" 'wraps a "quoted phrase" inline')
if [ -n "$id" ]; then
  body=$(fetch_body "$id")
  expected='wraps a \"quoted phrase\" inline'  # JSON-encoded form
  if [ "$body" = "$expected" ]; then
    ok "quoted body round-tripped (#$id)"
  else
    bad "quoted body corrupted; got=$body  expected=$expected"
  fi
else
  bad "wrapper did not create the ticket"
fi

echo
echo "test 2: body with embedded newlines (NR-update fix)"
id=$(create_via_cli "quoting-2" $'line one\nline two\nline three')
if [ -n "$id" ]; then
  body=$(fetch_body "$id")
  expected='line one\nline two\nline three'  # JSON-encoded form
  if [ "$body" = "$expected" ]; then
    ok "multi-line body preserved (#$id)"
  else
    bad "newlines flattened or corrupted; got=$body  expected=$expected"
  fi
else
  bad "wrapper did not create the ticket"
fi

echo
echo "test 3: body with backslash + quote (worst-case escape interaction)"
id=$(create_via_cli "quoting-3" 'path /home/foo\bar plus a "quote"')
if [ -n "$id" ]; then
  body=$(fetch_body "$id")
  expected='path /home/foo\\bar plus a \"quote\"'  # JSON-encoded form
  if [ "$body" = "$expected" ]; then
    ok "backslash + quote round-tripped (#$id)"
  else
    bad "got=$body  expected=$expected"
  fi
else
  bad "wrapper did not create the ticket"
fi

echo
echo "test 4: comment body with quotes (same encoding path, different verb)"
id=$(create_via_cli "quoting-4" "host ticket for comment test")
if [ -n "$id" ]; then
  out=$("$cli" comment "$id" --author tests@local --body 'comment with "quotes" and a newline:
second line' 2>&1)
  if grep -qE '^commented on' <<<"$out"; then
    body=$(curl -s -H "Authorization: Bearer $TICKETS_TOKEN" "http://$API/v1/tickets/$id" \
           | sed -n 's/.*"comments":\[\(.*\)\].*/\1/p')
    if echo "$body" | grep -q '\\"quotes\\"' && echo "$body" | grep -q '\\nsecond line'; then
      ok "comment quotes + newline preserved"
    else
      bad "comment encoding broke; comments=$body"
    fi
  else
    bad "wrapper failed to post comment: $out"
  fi
else
  bad "could not create host ticket for comment test"
fi

echo
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
