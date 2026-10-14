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
builds and stays self-contained. **Invariant:** a PR merges only after
tickets-dev LGTMs it *and* CI is green — since workers can't build locally, CI is
the only build-proof, so it must conclude before merge.

## Farmable queue

_Empty — wave 1 cleared the triaged backlog (see Shipped below). Next wave TBD._

## Shipped (wave 1 — 2026-10-14)

Farmed to one-shot workers, self-served via the outpost, each reviewed against
its brief with CI green:

| Item | What | PR |
|------|------|----|
| A | `GET /healthz` unauthenticated liveness route | [#28](https://github.com/colinrozzi/tickets/pull/28) |
| B | `?reporter=` list filter (API + CLI) | [#30](https://github.com/colinrozzi/tickets/pull/30) |
| C | idempotent no-op status set (skip store-rewrite + notify when `old == new`) | [#31](https://github.com/colinrozzi/tickets/pull/31) |
| D | `updated_at` timestamp (bumped on status/comment; serde-default back-compat) | [#32](https://github.com/colinrozzi/tickets/pull/32) |
| E | read the full HTTP request (loop `tcp_receive` by `Content-Length`; fixes single-read truncation) | [#33](https://github.com/colinrozzi/tickets/pull/33) |

(B's first attempt, #29, was closed as a same-file conflict after A merged first,
then re-farmed as #30. Lesson banked: serialize workers that touch the same
file — spawn one, let it merge, then spawn the next off updated `main`.)

## KEEP (held by tickets-dev — design / ambiguity-heavy, not farmable yet)

- **Singleton `tickets-actor` to serialize writes** — fix the TOCTOU race on
  `tickets-list` shared by create/status/comment (README phase-2 part-3). The
  right shape is itself the work; highest-value item here.
- **Bridge dedup** — currently best-effort one-shot; dedup needs persistent
  cross-handler state (handlers are ephemeral). (A bounded notify *retry* alone
  could be farmed later.)
- **Tickets ↔ inbox reply-by-email cross-link** — reply to a ticket by replying
  to the notification; protocol/threading design.
- **Multi-token / per-user auth** — token model + storage + rotation.
- **TLS on the listen socket** — deploy/security-coupled; coordinate with frontdoor.
- **`initial_state` secrets from a file/env** instead of the manifest — farmable
  once the mount/secret convention is decided; deploy-coupled today.
