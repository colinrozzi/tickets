# agent onboarding — the tickets system

You (specialist agent: theater-dev, inbox-dev, sentinel-dev, …) are about to start receiving work as **tickets** in addition to email. This is the 90-second intro. Read it once, fold the snippet at the bottom into your own `CLAUDE.md`, and you're set up.

## what tickets is

A small work-tracking system on Theater, running locally on Colin's dev box. It complements email — both are your inbound channels.

|                  | email                                  | ticket                                            |
|------------------|----------------------------------------|---------------------------------------------------|
| shape            | freeform message                       | structured: status + assignee + comment thread    |
| lifetime         | thread, eventually goes stale          | persists; history attached to the ticket forever  |
| good for         | fuzzy conversation, coordination       | discrete work items with state                    |
| who owns it      | inbox specialist (inbox-dev)           | tickets specialist (tickets-dev)                  |

Think of email as "what we're talking about" and tickets as "what we're tracking." A status-change discussion happens by email; the ticket itself records the outcome.

## how you get paged

You don't need new tooling. The tickets server fires a notification email to the assignee whenever a ticket is **created**, its **status changes**, or a **new comment** is added. Your existing inbox monitor catches it.

- **From**: `tickets@colinrozzi.com` (always — that's how you recognize bridge mail)
- **Subjects**:
  - create:  `[ticket #N] <title>`
  - status:  `[ticket #N] status: <old> -> <new>`
  - comment: `[ticket #N] new comment from <author>`
- **Body**: first 200 chars carry the signal (body / new status / comment text), then a 2-line context tail (reporter + assignee, or author + ticket title).

If your monitor is armed, you'll see these arrive the same way you see normal mail. No special handling.

A comment author isn't notified about their own comment. If you commented, you already know what you said.

## the cli

Live at `/home/colin/work/actors/tickets/cli/tickets`. Requires `~/.config/tickets/token` (already populated on this box).

```sh
# what's on your plate right now
./cli/tickets list --assignee <your-address> --status open

# read one
./cli/tickets show <id>

# move it
./cli/tickets status <id> in-progress   # valid: open|in-progress|done|closed

# leave a durable note
./cli/tickets comment <id> --author <your-address> --body "ack — taking a look this afternoon"
```

`tickets list` with no filter shows everything; `tickets show` renders the ticket plus its comment thread inline with ISO-8601 timestamps.

Habit: at the start of every session, alongside reading your inbox, run

```sh
./cli/tickets list --assignee <your-address> --status open
```

to see anything outstanding. The notification emails are good for *new* events; the list is good for *picking up where you left off* after a session ends.

## comment vs email — when to use which

Comment on a ticket when:
- the content is specifically about this ticket and should live attached to it (decisions, blockers, "done" acknowledgements, sub-task results)
- you're answering a question scoped to this ticket
- future-you or someone else reading the ticket history would want to see this

Reply by email when:
- the topic is cross-cutting (touches multiple tickets, or doesn't fit any one ticket)
- the conversation is exploratory / fuzzy and hasn't earned a ticket of its own
- you're coordinating logistics that don't belong in any specific ticket's history
- you need to reach someone who isn't a participant on the ticket

When in doubt: comment. A misplaced comment costs nothing; a thread that should have been on a ticket but ended up in email is lost context.

If a comment is going to spawn a real back-and-forth, file a new ticket from inside the comment ("filed #N to track this — taking it from here") and continue there. Keeps the parent ticket clean.

## state transitions

Workflow is **any-to-any** for now (phase 2). Suggested happy path: `open → in-progress → done`. Use `closed` for tickets that won't be acted on (won't-fix, duplicates, obsolete). Re-opening from `done` or `closed` is fine — no enforcement.

Transition the ticket when the state actually changes — not on every comment. `in-progress` means you're actively working on it; `done` means the work is shipped (PR merged, deploy live).

## drop this into your CLAUDE.md

```markdown
## Tickets

Some of your work arrives as tickets at /home/colin/work/actors/tickets/, in addition to email. Notification emails from `tickets@colinrozzi.com` page you when a ticket assigned to you is created, transitions status, or gets a comment — your inbox monitor catches them like any other mail.

The CLI is at `/home/colin/work/actors/tickets/cli/tickets`:

```sh
# at session start, alongside your inbox check:
/home/colin/work/actors/tickets/cli/tickets list --assignee <your-address> --status open

# read / comment / transition:
/home/colin/work/actors/tickets/cli/tickets show <id>
/home/colin/work/actors/tickets/cli/tickets comment <id> --author <your-address> --body B
/home/colin/work/actors/tickets/cli/tickets status <id> <open|in-progress|done|closed>
```

Comment on a ticket when the content lives forever attached to that ticket (decisions, blockers, acknowledgements). Email when the conversation is cross-cutting or fuzzy. When in doubt, comment.

Full intro: `/home/colin/work/actors/tickets/AGENT-ONBOARDING.md`.
```

## who to ask

- tickets system itself (bugs, feature requests, the bridge): **tickets-dev@colinrozzi.com**
- inbox / mail server: **inbox-dev@colinrozzi.com**
- Theater runtime: **theater-dev@colinrozzi.com**
- general coordination: **claude@colinrozzi.com**
- the human: **colinrozzi@gmail.com** (cc on completion + blocking replies, per usual)
