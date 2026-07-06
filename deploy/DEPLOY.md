# tickets prod deploy runbook

Standing up the tickets-acceptor on the `mail.colinrozzi.com` box as the
backend tickets-ui POSTs/GETs against (`127.0.0.1:8443`, loopback plaintext,
bearer auth). Mirrors the inbox systemd deploy (`inbox/RUNBOOK.md` §7–9); the
tickets-specific difference is that the manifests are deploy-agnostic — store
location comes from `THEATER_HOME`, not a per-deploy `base_path` edit.

Phase A: tickets runs on its own systemd unit, NOT under sentinel. Public
access comes later via frontdoor, same as the UIs.

## What ships

A tickets release provides everything as https release assets — theater's
`resolve_reference` fetches them directly, so nothing but the manifest +
theater binary needs to land on the box:

- `tickets_acceptor-<STAGE_TAG>.wasm` — the acceptor (manifest `package`)
- `ticket-handler-<STAGE_TAG>.toml` — the child handler manifest, with a
  self-referential `package` URL pointing at `tickets_handler-<STAGE_TAG>.wasm`
  (the acceptor's `initial_state.handler_manifest`)
- `tickets_handler-<STAGE_TAG>.wasm` — fetched by the handler manifest above
- `tickets_cli-<STAGE_TAG>.wasm`, tarball + sha256 — for humans / local use

Release: `release-20260706-2d428a7` (built against theater f852aec3).
STAGE_TAG: `20260706-2d428a7`.

## 1. Layout + store dir

```sh
mkdir -p /var/lib/tickets/gc-roots /var/log/tickets
mkdir -p /mnt/main-volume/tickets/store
```

## 2. gc-root the theater binary (prod-pinned f852aec3)

Same f852aec3 rev the rest of the box runs. Either reuse inbox's existing
f852aec3 gc-root, or realise tickets' own (the tickets flake is pinned to
f852aec3, so `nix build .#theater` produces exactly this binary):

```sh
# Option A — reuse inbox's (works today, both point at the same f852aec3 build):
ln -snf /var/lib/inbox/gc-roots/theater /var/lib/tickets/gc-roots/theater

# Option B — tickets' own gc-root (keeps the units independent):
#   (locally) nix build .#theater -o result-theater  # -> f852aec3 theater
#   nix copy --no-check-sigs --to ssh-ng://<box> ./result-theater
#   on box: nix-store --add-root /var/lib/tickets/gc-roots/theater \
#             --indirect --realise /nix/store/XXXX-theater...
```

## 3. Manifest

Drop `deploy/manifest.prod.toml` at `/var/lib/tickets/manifest.toml` and fill
the placeholders (`__RELEASE_TAG__`, `__STAGE_TAG__`, `__API_TOKEN__`,
`__INBOX_BEARER__`). `__INBOX_BEARER__` is the shared inbox API bearer already
on the box (the one inbox.service uses) — it lets the handler POST ticket
notification emails as tickets@colinrozzi.com. `chmod 600` it (holds secrets).

## 4. systemd unit

Install `deploy/tickets.service` at `/etc/systemd/system/tickets.service`,
then:

```sh
systemctl daemon-reload
systemctl enable --now tickets.service
ss -tlnp | grep '127.0.0.1:8443'   # acceptor listening on loopback
```

## 5. Smoke test (on the box)

```sh
TOK=<API_TOKEN>
H="Authorization: Bearer $TOK"
# empty list on a fresh store:
curl -s -H "$H" http://127.0.0.1:8443/v1/tickets
# create one:
curl -s -H "$H" -X POST -H 'Content-Type: application/json' \
  -d '{"title":"prod smoke","reporter":"tickets-dev@colinrozzi.com","assignee":"tickets-dev@colinrozzi.com","body":"first ticket on prod"}' \
  http://127.0.0.1:8443/v1/tickets
curl -s -H "$H" http://127.0.0.1:8443/v1/tickets/1
```

A 401 means the bearer is wrong; a connection refused means the unit did not
bind — check `/var/log/tickets/theater.log`.

## 6. Redeploy / rollback

New build = cut a new tickets release, then on the box: update the two release
URLs (`package` + `initial_state.handler_manifest`) in
`/var/lib/tickets/manifest.toml` to the new STAGE_TAG and
`systemctl restart tickets`. Rollback = point them back at the previous tag.
The store on `/mnt/main-volume/tickets/store` is independent of the wasm
version, so ticket state survives redeploys.
