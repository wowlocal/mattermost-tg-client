# Telegram‑iOS → native Mattermost client

**Status:** Draft v0.1 · 2026‑10‑26

## Goal

Build a native iOS client for Mattermost by forking [Telegram‑iOS](https://github.com/TelegramMessenger/Telegram-iOS) (GPL‑2.0). Keep Telegram's fast, polished UI and its local database. Replace its networking with a client for the standard Mattermost REST API v4 and WebSocket. The Mattermost server is not modified; the only server‑side addition is our own push proxy.

## Summary

- **Feasible, but a hard fork, not a re‑skin.** Telegram's UI layer (Display / AsyncDisplayKit, chat list, chat screen, media viewer) is reusable. MTProto and TelegramCore's state machine are replaced.
- **Approach:** keep `Postbox` (local DB) and the screens. Add `MattermostKit` (API client) and `MattermostSync` (writes Mattermost data into Postbox). Re‑implement the `TelegramEngine` calls the screens use. See [Architecture](docs/plan/01-architecture.md).
- **Biggest technical risk:** Telegram's 32‑bit integer message IDs vs Mattermost's string IDs. Solved first, in Phase 0. See [Domain mapping → Message IDs](docs/plan/02-domain-mapping.md#message-ids).
- **Effort:** 2–3 senior iOS engineers plus ~0.5 backend/DevOps. MVP in ~3–5 months; near‑parity release in ~7–9 months.

## Documents

| # | Document | Contents |
|---|---|---|
| 1 | [Architecture](docs/plan/01-architecture.md) | Telegram‑iOS layers, approaches considered, target design, new modules, repo layout, upstream strategy |
| 2 | [Domain mapping](docs/plan/02-domain-mapping.md) | Mattermost ↔ Telegram concepts, ID mapping, read state, teams, threads, message content |
| 3 | [Sync engine](docs/plan/03-sync-engine.md) | API surface, bootstrap, WebSocket events, catch‑up, sending, media, history loading |
| 4 | [Push notifications](docs/plan/04-push-notifications.md) | Push proxy, device registration, notification service extension |
| 5 | [Phases](docs/plan/05-phases.md) | Task checklists and exit criteria for each phase |
| 6 | [Feature scope](docs/plan/06-feature-scope.md) | What to keep, hide, build, and defer |
| 7 | [Dev environment](docs/plan/07-dev-environment.md) | Build setup, local Mattermost, testing, CI |
| 8 | [Legal & licensing](docs/plan/08-legal-and-licensing.md) | GPL, App Store, trademarks |
| 9 | [Risks & decisions](docs/plan/09-risks-and-decisions.md) | Risk register, assumptions to verify, open decisions, staffing |

## Timeline at a glance

| Phase | Duration | Outcome |
|---|---|---|
| 0 · Feasibility | 2–3 wks | Real channel history readable in Telegram's chat UI; go/no‑go |
| 1 · Fork hygiene (parallel with 0) | 2–4 wks | Rebranded app, Telegram‑only features hidden, CI running |
| 2 · MVP | 8–12 wks | Daily‑usable for channels and DMs |
| 3 · Parity | 8–12 wks | Push, threads, search, directory, integrations |
| 4 · Hardening & release | 4–6 wks | Performance, accessibility, distribution |

The raw sum is ~6–8 months. With a ~15% buffer for surprises in an undocumented codebase, plan for 7–9 months to a parity release.

## Decisions needed before Phase 0

Full list: [Open decisions](docs/plan/09-risks-and-decisions.md#open-decisions). The ones that change the plan most:

1. Audience: personal, internal company, or public App Store.
2. Oldest Mattermost server version to support.
3. Must‑have v1 features (Calls? Playbooks? interactive bot messages?).
4. Team size.

## Non‑goals for v1

- Talking to Telegram's network, or bridging Telegram ↔ Mattermost.
- Any change to the Mattermost server or its plugins.
- Calls, Playbooks, Boards, Apple Watch, widgets, Siri.
