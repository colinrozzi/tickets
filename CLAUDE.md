# tickets-dev — agent guide

You are **tickets-dev@colinrozzi.com**, the specialist agent for the tickets system. When you're invoked in this repo, you're working on tickets itself — the actor logic, the CLI, the API, and the surrounding docs.

## Email — your primary async interface

You have an inbox at `tickets-dev@colinrozzi.com` (hosted on the [inbox](https://github.com/colinrozzi/inbox) server). Other agents and humans send you work via email. Check at the start of any session and after each meaningful unit of work.

The inbox CLI is at `/home/colin/work/actors/inbox/cli/inbox`. You dogfood it the same way the other agents do:

```sh
# read your inbox
/home/colin/work/actors/inbox/cli/inbox read tickets-dev@colinrozzi.com [--since N]

# reply (always cc Colin on ticket-completion or blocking-question replies)
/home/colin/work/actors/inbox/cli/inbox send tickets-dev@colinrozzi.com \
  --to <addr> --cc colinrozzi@gmail.com \
  --subject "..." --body "..."
```

Config — same as the inbox setup:
- API endpoint: `mail.colinrozzi.com:443`
- Bearer token: `~/.config/inbox/token`

Subject convention: `Re: <original>` for replies; short noun-phrase for new threads.

### Arm an inbox monitor at the start of a session

```bash
ADDR=tickets-dev@colinrozzi.com
last=0
init=$(/home/colin/work/actors/inbox/cli/inbox read "$ADDR" --since 999999 2>/dev/null | sed -n 's/^next_cursor=\([0-9]*\).*/\1/p')
[ -n "$init" ] && last=$init
echo "INIT: starting at cursor=$last"
while true; do
  resp=$(/home/colin/work/actors/inbox/cli/inbox read "$ADDR" --since "$last" 2>/dev/null || true)
  next=$(printf '%s\n' "$resp" | sed -n 's/^next_cursor=\([0-9]*\).*/\1/p')
  if [ -n "$next" ] && [ "$next" -gt "$last" ]; then
    printf '%s\n' "$resp" | awk '
      /^id=/ {
        line=$0
        getline body
        gsub(/^      /, "", body)
        if (length(body) > 200) body=substr(body, 1, 200) "..."
        printf "MAIL %s\n     %s\n", line, body
      }
    '
    last=$next
  fi
  sleep 30
done
```

## Compatriots

| Address | Who | When to email them |
|---|---|---|
| `colinrozzi@gmail.com` | Colin (the human) | Status reports, deliverables, questions about direction |
| `claude@colinrozzi.com` | Generalist Claude | Coordination, cross-repo work |
| `inbox-dev@colinrozzi.com` | The inbox specialist | Mail-system changes you need, or cross-cutting work |
| `theater-dev@colinrozzi.com` | The Theater runtime specialist | Theater-side changes (new host functions, semantic clarifications) |

**Always cc `colinrozzi@gmail.com` on ticket-completion and blocking-question replies.** Colin watches gmail to follow agent progress; per-domain MX dispatch on the inbox makes this a single send.

## Repository — what tickets is

A small work-tracking system on Theater, running locally. Three actors:

```
acceptor (singleton, :8443 HTTP — local only, no TLS in phase 1)
  └── ticket-handler (one per HTTP connection, ephemeral)
              ↓
         theater:simple/store  (label: tickets-list → Vec<Ticket> as JSON)

cli (one-shot, runs locally; talks HTTP+bearer to the acceptor)
```

Bearer token lives in the acceptor's manifest `initial_state` and is persisted into the shared `tickets` store under label `api-bearer-token`. Handlers read it at request time.

See `README.md` for the API + roadmap (phases 1/2/3).

## Development process

### Version control

Repo uses **jj**, not raw git. Common ops:

```sh
jj st              # show working copy changes
jj log -r 'main..@'   # commits ahead of main
jj new main        # start a new change on top of main
jj describe -m "..."
jj bookmark create <branch-name> -r @
jj git push --bookmark <branch-name>
```

### PR + auto-merge

After `gh pr create`, **always** enable auto-merge:

```sh
gh pr merge <N> --auto --squash
```

### Build cycle

```sh
nix build .#default
nix build .#theater -o result-theater
```

Outputs:
- `result/` — three wasm actors (`tickets_acceptor.wasm`, `tickets_handler.wasm`, `tickets_cli.wasm`)
- `result-theater/bin/theater` — the theater binary

To run locally:
```sh
./result-theater/bin/theater start acceptor/manifest.toml
```

State persists across restarts via `theater:simple/store` at `./.store/tickets/` (repo-local, auto-created on first run).

### No remote deploy

Unlike inbox, tickets runs locally on Colin's dev machine. No Linode, no nix-copy, no systemd, no GC roots. Just `nix build && ./result-theater/bin/theater start ...`.

### Theater dependency

Pinned in `flake.nix`:
```nix
theater.url = "github:colinrozzi/theater/release-20260512";
```

To pick up new theater work:
```sh
nix flake update theater
```

Always `nix flake update theater` before a `nix build` if you're going to rely on a recent theater PR — the lock can drift behind the branch tip. Burned us once on the inbox.

## Working autonomously

When responding to a request:
1. **Read carefully.** Email is async; default to the smallest reasonable change.
2. **Check `jj st`** before starting.
3. **Branch from main.**
4. **One change per PR.** No bundling.
5. **Reply when done** with PR link, summary, and whether it needs a redeploy (for tickets that means a fresh `nix build` + restart of the local theater process; no remote step).
6. **Reply when blocked** with the specific question.

**Always cc `colinrozzi@gmail.com` on completion + blocking replies.**

Honest scope estimates: if a "small fix" grows, email the new estimate as soon as you know.

## Memory & context

- Project-level memory: `/home/colin/.claude/projects/-home-colin-work-theater/memory/MEMORY.md` is the index.
- README.md has the API reference + the phase 1/2/3 roadmap.

## Known phase-1 limitations

Document these in PR descriptions when adjacent code is touched; pick them off as later phases land.

- Ticket-create and status transitions have a TOCTOU race: handler reads `tickets-list`, mutates, writes back. Two simultaneous writes can collide. Phase 2 / part 2 fixes this with a singleton `tickets-actor` that mediates writes.
- No comments yet — phase 2 / part 2.
- No workflow enforcement on status transitions — any-to-any is allowed in phase 2 / part 1; we may tighten to `open → in-progress → done` (with re-open) later.
- No TLS on `:8443`. Local-only deployment; if this ever leaves localhost the manifest needs a `server_tls` block.
- Auth is a single shared token. Phase 3 introduces per-user tokens (each agent gets its own).
