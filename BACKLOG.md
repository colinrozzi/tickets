# tickets — backlog

Living queue for the tickets work-tracking system, maintained by **tickets-dev**
(PM + reviewer). Until formal ticket-binding lands (worker binds to a ticket and
status-comments back on it — spawn-service step 3), this file is the durable
queue. Items are farmed to one-shot worker pr-agents (one clean PR each) and
reviewed by tickets-dev.

**Definition of worker-sized:** clear-shape, bounded, independently verifiable,
achievable as ONE clean PR; reads like a brief to a careful contributor who
knows the repo but not the intent (what / why / where / how-to-confirm).

**How work is verified:** CI (`.github/workflows/ci.yml`) runs `nix build` + a
host-only import-surface assertion — it does **not** run the integration shell
tests (those need a live acceptor). So each item's behavioral confirm means
running/extending the relevant `tests/*.sh` against a spawn; CI-green proves it
builds and stays self-contained.

## Farmable queue (ranked mechanical → more involved)

### A — `GET /healthz` unauthenticated liveness route · _in flight_
- **Why:** every route requires the bearer and unknown paths 404, so a
  supervisor/frontdoor liveness probe has no tokenless endpoint (the tickets-ui
  actor exposes `/healthz`; the API has none).
- **Where:** `ticket-handler/src/lib.rs`, `fn route()` — the sole HTTP router.
- **Change:** add a `("GET", "/healthz")` arm returning `200` + `{"status":"ok"}`
  **before** the `check_auth()` call. Purely additive.
- **Confirm:** `curl -i http://127.0.0.1:8443/healthz` with no `Authorization`
  header → 200 + JSON; authed routes still work; CI green; add `tests/healthz.sh`
  (or a case in `status.sh`).

### B — `?reporter=` list filter (API + CLI parity) · _in flight_
- **Why:** list filters on `?status=` and `?assignee=` but not reporter, so an
  agent can't query "tickets I filed." Symmetric with the assignee filter.
- **Where:** `ticket-handler/src/lib.rs` `fn parse_query` + `fn handle_list`;
  mirror in `cli/src/lib.rs` list path + the `cli/tickets` bash wrapper
  (`--reporter`, like `--assignee`).
- **Confirm:** `?reporter=X` returns only matching tickets; `?status=&reporter=&assignee=`
  all AND together; `tickets list --reporter X` works; CI green; extend a list test.

### C — skip notify + store-rewrite on no-op status set
- **Why:** any-to-any transitions mean setting a ticket to the status it already
  has re-fires notification emails to reporter+assignee and does a needless full
  `tickets-list` rewrite. Idempotent sets should be side-effect-free.
- **Where:** `ticket-handler/src/lib.rs` `fn handle_set_status`.
- **Change:** if `old_status == req.status`, return 200 with the unchanged ticket
  without calling `save_tickets` or `notify_status_changed`. Preserve the
  200/idempotent contract; only drop the side effects.
- **Confirm:** set the same status twice → 2nd call 200, no second notification,
  ticket unchanged; a real transition still notifies; CI green; tighten the
  `done -> done` case in `status.sh`.

### D — add `updated_at` timestamp, bumped on status/comment
- **Why:** tickets carry `created_at` but nothing records last activity, so
  clients can't sort by recency or show "last updated."
- **Where:** `ticket-handler/src/lib.rs`: `Ticket` struct + `handle_create` /
  `handle_set_status` / `handle_add_comment`.
- **Change:** add `updated_at: u64` with `#[serde(default)]` (old stored tickets
  deserialize to 0). Set `= created_at` on create; `= timer_now()` on status
  change and comment add.
- **Confirm:** create → `updated_at == created_at`; comment/status → `updated_at`
  advances; GET show reflects it; pre-existing tickets still load; CI green;
  extend a test.

### E — handler must read the FULL request (loop `tcp_receive` by Content-Length)
- **Why:** `handle_connection_transfer` does one `tcp_receive(conn, 65536)`.
  `theater` `tcp.receive` is partial, so a request split across TCP segments or a
  body larger than the first chunk is truncated → spurious 400. Intermittent,
  size/load-dependent.
- **Where:** `ticket-handler/src/lib.rs` `fn handle_connection_transfer`. Copy the
  in-repo pattern: `fn inbox_post` already loops `tcp_receive` until headers +
  Content-Length bytes are read (treating Err/empty as EOF).
- **Change:** read-loop until headers (`\r\n\r\n`) seen and, if Content-Length is
  set, that many body bytes accumulated; stop on EOF; bounded total. GET/no-body
  requests must still work.
- **Confirm:** POST a body larger than one chunk succeeds instead of 400; small
  requests unchanged; CI green; add a test POSTing a >64KiB comment body (→ 201).

## KEEP (held by tickets-dev — design / ambiguity-heavy, not farmable yet)

- **Singleton `tickets-actor` to serialize writes** — fix the TOCTOU race on
  `tickets-list` shared by create/status/comment (README phase-2 part-3). The
  right shape is itself the work.
- **Bridge dedup** — currently best-effort one-shot; dedup needs persistent
  cross-handler state (handlers are ephemeral). (A bounded notify *retry* alone
  could be farmed later.)
- **Tickets ↔ inbox reply-by-email cross-link** — reply to a ticket by replying
  to the notification; protocol/threading design.
- **Multi-token / per-user auth** — token model + storage + rotation.
- **TLS on the listen socket** — deploy/security-coupled; coordinate with frontdoor.
- **`initial_state` secrets from a file/env** instead of the manifest — farmable
  once the mount/secret convention is decided; deploy-coupled today.
