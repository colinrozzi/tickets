# tickets

A small work-tracking system built on [Theater](https://github.com/colinrozzi/theater).

Lets agents and humans coordinate via tickets instead of email threads. Companion to the [inbox](https://github.com/colinrozzi/inbox) — both run locally; tickets stores structured work state, inbox carries the unstructured human/agent conversation around it.

## Status: phase 1 (MVP)

What works:

- `POST /v1/tickets` — create a ticket
- `GET /v1/tickets[?status=&assignee=]` — list, optionally filtered
- `GET /v1/tickets/<id>` — show one
- Bearer-token auth (single shared token, stored in the acceptor's manifest `initial_state`)
- Persistent storage via `theater:simple/store`

What's deferred to phase 2+:

- Comments on tickets
- Status transitions (open → in-progress → done / closed)
- Email bridge — notify the assignee's inbox when a ticket is assigned or changes
- Multi-token / per-user auth
- TLS on the listen socket

## Run locally

```sh
nix build .#default .#theater
mkdir -p /var/lib/tickets/store
./result-1/bin/theater start acceptor/manifest.toml
```

The acceptor listens on `127.0.0.1:8443` (plain HTTP, bearer auth). The default token in the manifest is `dev-token-change-me` — change it before sharing.

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
```

## Architecture

Three actors:

```
acceptor (singleton, :8443 HTTP)
  └── ticket-handler (one per HTTP connection, ephemeral)
              ↓
         theater:simple/store  (label: tickets-list → Vec<Ticket> as JSON)

cli (one-shot, runs locally; talks HTTP+bearer to the acceptor)
```

The `tickets-actor` singleton from the original design got dropped — handlers read/write the store directly. The current write path is racy under contention (two handlers creating tickets simultaneously can collide on the id assignment). For phase 1 we accept the race; the singleton goes back in as part of phase 2 if it matters.

## Phase 2 sketch

- A singleton `tickets-actor` mediates writes so id assignment + status transitions are serializable
- Comments live as a list inside each ticket
- `POST /v1/tickets/<id>/comment` appends
- `POST /v1/tickets/<id>/status` transitions
- An email bridge actor watches the tickets store and posts notifications to `inbox`'s `/v1/mailboxes/<addr>/messages` API

## Phase 3 sketch

- Per-user auth (each agent gets its own token)
- Web UI: read-only browse view
- Tickets ↔ inbox cross-link: agents can reply to a ticket by replying to the notification email
