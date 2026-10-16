# Design: singleton write-serialization (TOCTOU fix)

Status: **proposed** (tickets-dev, 2026-10-16). Seeking design sign-off before
farming the sub-slices. Realizes the README's deferred "phase-2 part-3 singleton
`tickets-actor`."

## Problem

`tickets-list` is a single `theater:simple/store` label holding `Vec<Ticket>`
as JSON. Every mutating path in `ticket-handler` does an unserialized
read-modify-write:

```
let mut all = load_tickets();   // store get-by-label + get
... mutate (create / set-status / add-comment) ...
save_tickets(&all);             // store store-at-label  (rewrites the whole Vec)
```

The acceptor spawns a **fresh ephemeral `ticket-handler` actor per TCP
connection** (`runtime.spawn` → `tcp.transfer`). So two concurrent requests are
two concurrent handler actors, each loading the same list, mutating its own
copy, and writing back — **last write wins**:

- two concurrent creates → both compute `next_id = max+1` from the same stale
  read → **duplicate id**, and one create is lost;
- a create racing a comment → whichever saves second **clobbers** the other;
- a status change racing a comment → one is lost.

This was acceptable when traffic was a trickle. The **worker-farm model makes it
real**: many agents + one-shot workers mutate tickets concurrently. Correctness,
not just theory.

## Key lever

A Theater actor is **sequential** — it processes at most one
call/message at a time, with no intra-actor concurrency. Therefore a **single
long-lived actor that owns all writes serializes them by construction.** No
locks, no CAS — the actor model is the mutex.

## Proposed design

Introduce a singleton **`ticket-store`** actor (long-lived; naming mirrors
`ticket-handler`). It is the **sole writer** of the `tickets-list` label.

```
acceptor (singleton)
  ├── ticket-store (singleton, long-lived)      ← owns tickets-list; serial writer
  └── ticket-handler (ephemeral, per connection) ← HTTP⇄message adapter
          │  writes: request/response message to ticket-store, awaits reply
          │  reads:  direct store get-by-label (tickets-list is always a
          │          committed snapshot because ticket-store is the only writer)
          ↓
     theater:simple/store (label: tickets-list)
```

### Division of labor

- **`ticket-handler`** keeps: HTTP parse (the full-request read from #33), auth,
  routing, **syntactic validation** (empty-field 400s, invalid-status 400), and
  **notifications** (the best-effort inbox POST + the #4a retry). It no longer
  writes the store. For a mutation it sends a typed request to `ticket-store`,
  awaits the reply, fires the notification, and writes the HTTP response.
- **`ticket-store`** owns: the authoritative `Vec<Ticket>`, **id assignment**,
  the **no-op status guard** (#31), the **`updated_at` bumps** (#32), and
  persistence. It returns stateful outcomes (created ticket / updated ticket /
  not-found / no-op).

### Reads stay off the singleton

Writes are the only racy path; a store label read is an atomic read of the last
committed value. Because `ticket-store` is the *only writer*, readers
(`GET /v1/tickets`, `GET /v1/tickets/<id>`) can keep reading the store label
directly in the handler — no need to route reads through the singleton, which
keeps it off the read path (no read bottleneck). *(Alternative, stricter: route
reads through the singleton too, for read-your-writes / in-memory-only state. Not
needed for the race fix; deferred.)*

### Notifications stay in the handler

`ticket-store` is a **pure state actor** — no network/TLS. The handler fires the
notification after it gets the reply, so the serialized write path is never
blocked on an outbound POST (no head-of-line blocking on the singleton). This
also means **#4a (notify-retry) is unaffected** by this change and can land
first.

## The contract to freeze (before farming)

### 1. Request/response messages (handler → store)

Tagged JSON over `theater:simple/message-server` request/response. Requests
carry already-validated inputs:

```
// request
{"op":"create","title":..,"body":..,"reporter":..,"assignee":..,"project":..}
{"op":"set_status","id":N,"status":".."}      // status already enum-validated by handler
{"op":"add_comment","id":N,"author":..,"body":..}

// response
{"ok":true,"ticket":{..}}                      // created/updated (or no-op) ticket
{"ok":false,"error":"not_found"}               // unknown id
```

`ticket-store` applies the create/set-status/add-comment logic (lifted verbatim
from the handler, including #31 no-op + #32 `updated_at`), persists, and replies.

### 2. Spawn + addressing

The **acceptor spawns `ticket-store` once at init** (before binding the socket),
stores its actor-id in `AcceptorState`, and **passes that id as init-state to
each `ticket-handler`** it spawns (today it passes `None`). The handler reads the
id in `init`, holds it in `HandlerState`, and uses it to message the store.
`ticket-store.init` loads `tickets-list` from the store into in-module state
(re-fold on boot → survives restart).

### 3. Robustness (note, may be v1.1)

Restart rotates actor-ids, and the store id is captured once at acceptor init. If
`ticket-store` dies, in-flight handlers hold a stale id. v1: acceptor supervises
`ticket-store` and respawns it (re-publishing the id is the open question — a
well-known store label holding the current id, re-read by handlers on send
failure, is the likely answer). Flagging as the one non-trivial robustness item;
the happy path does not need it.

## Farmable sub-slices

- **(a) `ticket-store` skeleton** — new actor crate (Cargo + manifest + lib.rs):
  `init` loads `tickets-list` into in-module state; a message handler decodes the
  request enum and dispatches to stubs. Host-only import surface (store, self,
  message-server). One PR.
- **(b)+(c) cutover** (likely one PR — interdependent): move the create/
  set-status/add-comment logic into `ticket-store`'s handlers (b); rewire the
  acceptor to spawn the store + pass its id, and the handler to message the store
  instead of `store_store_at_label`, keeping parse/validate/notify (c).
- **(d) concurrency test** — fire N parallel writers (concurrent creates +
  comments on one ticket) and assert: no lost comment, unique/monotonic ids, no
  clobbered status. Can fold into the cutover PR or stand alone.

## Explicitly out of scope

- **Incremental persistence** — `ticket-store` still rewrites the whole `Vec` per
  mutation (same `O(n)` as today). Fine at ticket volumes; a seq-keyed append is a
  future optimization, not a correctness need.
- Dedup (4b), multi-token auth (5), reply-by-email (6), secrets-from-file (7) —
  tracked separately; several now have a natural home on `ticket-store`.

## Open questions for sign-off

1. Writes-only-through-singleton (reads direct from store) — agreed, vs route
   reads too?
2. `ticket-store` supervision/respawn (the §3 robustness item) — land in v1, or
   ship the happy path first and fast-follow?
3. New actor name `ticket-store` — ok, or keep the README's `tickets-actor`?
