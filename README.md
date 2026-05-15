# tickets

A small work-tracking system built on [Theater](https://github.com/colinrozzi/theater).

Lets agents and humans coordinate via tickets instead of email threads. Companion to the [inbox](https://github.com/colinrozzi/inbox) — both run locally; tickets stores structured work state, inbox carries the unstructured human/agent conversation around it.

New here? See [`AGENT-ONBOARDING.md`](AGENT-ONBOARDING.md) — 90-second intro for specialist agents picking up work via tickets.

## Status: phase 2 in progress

What works:

- `POST /v1/tickets` — create a ticket
- `GET /v1/tickets[?status=&assignee=]` — list, optionally filtered
- `GET /v1/tickets/<id>` — show one
- `POST /v1/tickets/<id>/status` — set status (`open`, `in-progress`, `done`, `closed`); any-to-any transitions
- `POST /v1/tickets/<id>/comment` — append a comment (`{author, body}`)
- Email bridge — POSTs a notification from `tickets@colinrozzi.com` to the assignee's inbox on create / status change / new comment (best-effort, no retry)
- Bearer-token auth (single shared token); acceptor config now a JSON blob with `api_token` + inbox creds
- Persistent storage via `theater:simple/store`

What's deferred to later phase 2 work:

- Singleton `tickets-actor` to mediate writes (eliminates the TOCTOU race on `tickets-list` shared by create / status / comment)
- Bridge dedup / retry

Phase 3+:

- Multi-token / per-user auth
- TLS on the listen socket
- Reading `initial_state` from a file path or env var so secrets don't have to live in the manifest

## Run locally

```sh
nix build .#default
nix build .#theater -o result-theater
./result-theater/bin/theater start acceptor/manifest.toml
```

The acceptor listens on `127.0.0.1:8443` (plain HTTP, bearer auth). State persists across restarts in `./.store/tickets/` (repo-local, auto-created).

The `initial_state` field in `acceptor/manifest.toml` is a JSON blob — populate it before deploy:

```json
{
  "api_token":   "<bearer for the tickets HTTP API>",
  "inbox_api":   "mail.colinrozzi.com:443",
  "inbox_token": "<bearer for the inbox API, for outbound notifications>"
}
```

## CLI

The bash wrapper at `cli/tickets` is the ergonomic surface. It:

1. Builds a JSON command document
2. Drops it into a temp manifest's `initial_state`
3. Runs `theater start` on a one-shot `tickets-cli` actor that talks HTTP to the tickets server and writes formatted output

```sh
echo dev-token-change-me > ~/.config/tickets/token

./cli/tickets new \
  --title "build the email bridge" \
  --body "notify the assignee's mailbox on create + status change" \
  --reporter claude@colinrozzi.com \
  --assignee inbox-dev@colinrozzi.com

./cli/tickets list --status open --assignee inbox-dev@colinrozzi.com

./cli/tickets show 1

./cli/tickets status 1 in-progress
./cli/tickets status 1 done

./cli/tickets comment 1 --author tickets-dev@colinrozzi.com --body "ack — picking this up"
```

## Architecture

Three actors:

```
acceptor (singleton, :8443 HTTP)
  └── ticket-handler (one per HTTP connection, ephemeral)
              ↓                          ↑ (outbound TLS)
         theater:simple/store    inbox  /v1/mailboxes/<rcpt>/messages
       (label: tickets-list → Vec<Ticket> as JSON)

cli (one-shot, runs locally; talks HTTP+bearer to the acceptor)
```

The `tickets-actor` singleton from the original design got dropped for phase 1 — handlers read/write the store directly. The current write path is still racy under contention (two handlers creating, transitioning, or commenting on tickets simultaneously can collide on `tickets-list`). The singleton lands in phase 2 / part 3.

## Phase 2 part 3 sketch

- A singleton `tickets-actor` mediates writes so id assignment + status / comment transitions are serializable
- Bridge dedup or retry on transient inbox-API failures (currently best-effort, one-shot)

## Phase 3 sketch

- Per-user auth (each agent gets its own token)
- Web UI: read-only browse view
- Tickets ↔ inbox cross-link: agents can reply to a ticket by replying to the notification email
