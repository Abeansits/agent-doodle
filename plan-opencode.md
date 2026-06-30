# Plan: agent-doodle — Living Dashboard for Multi-Agent Conductor Work
### Parallel plan by opencode (2026-06-30)

This is my take, running parallel to `plan.md`. Same problem, same principles (KISS, no Node hell, open source, Mac-first), different decisions on a few things. I've folded in the concerns and suggestions I raised in review and made calls on them.

---

## What this is

An external, glanceable "state radiator" for your conductor + multi-agent setup. Agents write status to a file via a tiny CLI instead of you asking "what's cooking?" You see a living dashboard in the MacBook notch (badge + hover-expand), modeled on your existing Arthur app.

It is **not** an AI. It's a structured scratchpad that agents write to and you glance at. The structure *supports* better conductor communication (separating "what's happening" from "what I need from you"), but it does not *fix* the alien-jargon problem on its own — that's a prompting/house-style thing the tool enables, not solves. Being honest about this keeps scope honest.

---

## Decisions (where I differ from the original plan)

### 1. Locking is MVP, not "later"
Multiple agents will write `board.json` simultaneously on day one. Naive read-modify-write = silent lost updates. Fix is ~5 lines: `flock(LOCK_EX)` around the whole read-modify-write in the CLI. Single locked JSON file is simpler than per-item files and matches KISS. This is in the spike, not a fast-follow.

### 2. Collapse the command surface
Four nouns (`session`/`question`/`blocker`/`note`) is 4× the surface for agents to fumble after compaction. One mutable command:
```
doodle set "Auth middleware" --type session --status waiting_on_user --summary "..." --detail "Decision: token bucket vs fixed window + existing patterns"
doodle set "JWT vs sessions" --type question --status waiting_on_user --summary "Mobile clients need stateless auth" --detail "Concerns around refresh rotation"
```
`type` is just a field. Questions/blockers are `type=X` + the right `status`. Half the commands, same expressiveness, less for AGENTS.md to teach.

Read stays simple:
```
doodle board                      # default JSON for agents
doodle board --status waiting_on_user
doodle board --pretty             # human text
```
Plus `doodle rm "Name"` and `doodle get "Name"` (single item, for conductor to pull context without loading the whole board).

### 3. Badge = one rule
Badge count = items with `status == "waiting_on_user"`. Full stop. Posting a question *sets* that status. No "question OR waiting" ambiguity.

### 4. `source` from env, not flags
`DOODLE_SOURCE` (fallback `AGENT_NAME`, fallback `unknown`). Agents forget `--source` after compaction; env vars survive in their shell. Zero-arg, honest attribution.

### 5. `DOODLE_BOARD_PATH` from day one
Testable, overridable, agnostic to your personal `~/.agent-doodle/board.json`. Defaults to `~/.agent-doodle/board.json` if unset. Costs nothing.

### 6. Poll, don't watch
Badge count: poll the file every ~5s via `Timer.scheduledTimer` (Arthur already does this pattern). Full reload on notch expand. File watchers (FSEvents/DispatchSource) are more code for no MVP gain.

### 7. Build CLI + notch UI together (not CLI-only first)
You pushed back on phasing — fair, coding is cheap. Both tracks share `DoodleCore` (models + load/save + lock). Lock the data model in a 30-min pass *before* UI work gets heavy, then build both in parallel. Bad data model discovered after UI is the only real risk, and the model is small enough that locking it is quick.

### 8. Dashboard section order: Waiting first
Original plan had Active / Waiting / Blocked. Reorder to **Waiting on You → Active → Blocked**. Waiting is the actionable thing the badge promised you; it goes first. Blocked is informational, last.

---

## Data model (small, locked early)

```json
{
  "version": 1,
  "items": [
    {
      "name": "auth middleware",
      "display_name": "Auth Middleware",
      "type": "session",
      "status": "waiting_on_user",
      "summary": "Rate limiting in progress.",
      "detail": "Decision: token bucket vs fixed window. Any existing patterns to follow?",
      "source": "conductor",
      "updated_at": "2026-06-30T14:22:01Z"
    }
  ]
}
```

- `name` — normalized key (trim + case-fold). Stable update key.
- `display_name` — original casing as last written. What the notch shows.
- `type` — free string: `session` | `question` | `blocker` | `note` | whatever. Secondary metadata; dashboard groups by *status*, not type.
- `status` — `active` | `waiting_on_user` | `blocked` | `done`. Drives badge + sections + `done` exclusion.
- `summary` — one line, what's happening.
- `detail` — the ask / context / blocker reason. Optional. This is where the conductor puts the human-readable "what I need from you and why."
- `source` — which agent wrote it (from env).
- `updated_at` — ISO 8601, set on every write. Drives age-dimming.

No `context` vs `waiting_on` split — unified into `detail`. One optional rich field.

---

## Re-seeding house style after compaction

AGENTS.md only survives compaction if it's in the system prompt or the conductor is re-told to read it. Cheap help: `doodle board` prints a one-line footer hint on every read, e.g.:

```
TIP: use stable names, put the human-readable ask in --detail, prefer updating existing items by name.
```

Tiny, but it re-seeds the habit every time the conductor pulls state. The conductor sees it, the user never does (it's on stderr or below the JSON). This is the one mechanism the tool *does* have against the alien-jargon drift.

---

## Architecture (KISS)

```
agent-doodle/
├── README.md
├── AGENTS.md                 # how agents should use the CLI (house style, survives compaction)
├── Package.swift             # SwiftPM, like Arthur
├── Sources/
│   ├── DoodleCore/           # Item model, Board load/save, flock locking
│   ├── DoodleCLI/            # `doodle` binary (agent entry point)
│   │   └── main.swift
│   └── DoodleNotchApp/       # notch UI (AppDelegate, views, DynamicNotchKit)
│       ├── AppDelegate.swift
│       ├── NotchContentView.swift
│       └── NotchCompactIcon.swift
├── board.example.json
├── .gitignore
└── plan-opencode.md          # this file
```

State at runtime: `~/.agent-doodle/board.json` (or `$DOODLE_BOARD_PATH`), created on first use. No daemon. CLI and UI operate on the same file.

---

## Reuse from Arthur (heavy)

Arthur is the template. Lift directly:
- **Package.swift** structure: SwiftPM, `.macOS(.v14)`, DynamicNotchKit dep.
- **AppDelegate.swift**: notch setup, hover-expand/collapse debounce, `Timer.scheduledTimer` polling pattern. Drop the screen-capture/analysis cycle — we don't need it.
- **NotchContentView / NotchCompactIcon**: the hover behavior, compact icon + badge, expanded panel layout. Replace task sections with status-grouped item cards.
- **TaskManager → BoardManager**: same `@Observable @MainActor` pattern, `reload()` from file. Add `flock`-style atomic write (Arthur uses YAML+Yams; we use JSON+Codable, simpler).

What we *don't* need from Arthur: screen capture, focus analysis, NanoWilliamsClient, ProductivityAnalysis, notifications (for MVP). Arthur is a productivity coach with a notch; agent-doodle is a status board with a notch. Smaller.

---

## MVP scope

- `doodle set "<name>" [--type ...] [--status ...] [--summary ...] [--detail ...]` — create or update by name, locked write.
- `doodle board [--status X] [--all] [--pretty]` — read, JSON default. **Excludes `done` items by default**; `--all` includes them. Optional status filter, optional human text.
- `doodle get "<name>"` — single item (conductor pulls context without full board).
- `doodle rm "<name>"` — remove item.
- Notch app:
  - Compact icon + badge = count of `waiting_on_user`.
  - Hover → expand: sections **Waiting on You / Active / Blocked**, cards show name, summary, detail (truncated), source, relative time.
  - Poll file every ~5s for badge; full reload on expand.
- State in `~/.agent-doodle/board.json` (or `$DOODLE_BOARD_PATH`).
- `DOODLE_SOURCE` / `AGENT_NAME` env for attribution.
- Survives restarts.
- AGENTS.md with house style + the board-output footer hint.

## Out of MVP (fast-follows, not now)

- Multiple named boards / per-project scoping.
- Done archive / history trail (design model so `done` items can be moved to a `done.json` later).
- Rich editing in the notch (mark done / clear waiting from UI).
- MCP wrapper.
- Diagrams / mermaid.
- Export.

---

## Lifecycle: done + staleness (Vigil gap #1)

Two rules, both render-side, no agent janitor needed:

- **`done` excluded from default `doodle board` read.** `doodle board --all` to see them. Rationale: the conductor reads the board to avoid re-deriving status; an ever-growing `done` tail is context bloat sneaking in on the read side — the exact thing the tool kills.
- **Stale items visibly age in the notch.** A crashed/forgetful agent leaves its item `active` forever. Use `updated_at` to dim items older than N hours (suggest N=6, configurable later). The field's already there — just render it. No hard-delete in MVP; dimmed stale items stay until the agent or human clears them.

## Portability: CLI is the OS-agnostic product (Vigil gap #2)

The adoptable open-source product is the CLI + JSON format. The notch is *one* frontend (Mac-only). A Linux dev running 3 Claude Code sessions must get value from `doodle board --pretty` with no notch.

Hard rule: **`DoodleCore` and `DoodleCLI` import nothing Mac-specific** — no AppKit, no SwiftUI, no DynamicNotchKit. Only Foundation. The `DoodleCore / DoodleCLI / DoodleNotchApp` split already supports this; enforce it. If CI on Linux is feasible later, add it. Until then, keep the boundary clean by inspection.

## Name normalization (Vigil gap #3 — decided)

`name` is the stable update key. `Auth middleware` vs `auth-middleware` vs `Auth Middleware` = silent duplicate items.

**Decision: normalize the key, keep a display name.** `DoodleCore` trims + case-folds the name for matching, stores the original as `display_name`. So `doodle set "Auth Middleware"` and `doodle set "auth middleware"` hit the same item; the notch shows whichever casing was last written. Dups can't happen by omission, and humans still see clean names. Footer hint + AGENTS.md reinforce "use stable names" but the tool doesn't depend on agent discipline for correctness.

## Read-side discipline (Vigil gap #4)

The plan is strong on writes; the payoff is the conductor *reading* the board instead of re-deriving "what's cooking." AGENTS.md needs the read pattern too, not just write rules:

> On a status ask, run `doodle board` (or `doodle get "<name>"`) and answer from it — do not re-derive from chat context.

Half the value lives on the read side. This goes in AGENTS.md alongside the write rules and the house-style the footer points at.

---

## Verification

1. Build `DoodleCore` + `DoodleCLI`. Run `doodle set` / `doodle board` manually — items appear/update in JSON.
2. **Concurrency test**: fire 5 parallel `doodle set` for different names in a loop. No updates lost. (This is the test that justifies the lock.)
3. **Name normalization test**: `doodle set "Auth Middleware"` then `doodle set "auth middleware"` — same item, display name updated. No duplicate.
4. **`done` exclusion test**: set an item to `done`, confirm `doodle board` excludes it and `doodle board --all` includes it.
5. Build `DoodleNotchApp` from Arthur template. Confirm badge appears when `waiting_on_user` items exist, clears when none.
6. **Age-dimming test**: set an item, backdate its `updated_at` by 7h, confirm it renders dimmed in the notch.
7. Full loop with a real conductor session: spawn work, use CLI to post status/questions, pull `doodle board`, observe notch.
8. Restart everything — state + badge survive.
9. Human can call `doodle board --pretty` and read it.

---

## Open questions

All closed (2026-06-30):
- **Flagship**: parallel build-in-public project, not the flagship.
- **Prior-art scan**: skipped.
- **`done` lifecycle**: exclude from default read + dim, never hard-delete in MVP. Confirmed.

---

## Suggested start

1. Lock the data model above (this conversation, 10 min).
2. `Package.swift` + `DoodleCore` (Item, Board, load/save, flock, name normalization).
3. `DoodleCLI` — `set`, `board` (default excludes `done`, `--all` to see them), `get`, `rm`. Concurrency test early. Keep Mac-free.
4. Fork Arthur's notch setup into `DoodleNotchApp`. Badge + status-grouped list + age-dimming.
5. `AGENTS.md` — write discipline + **read discipline** + the house-style the footer points at.
6. Full loop with a real conductor session. Iterate on card fields and section ordering.
