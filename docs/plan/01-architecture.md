# 1 · Architecture

## Telegram‑iOS today

```
┌───────────────────────────────────────────────────────────────┐
│ Screens: TelegramUI, ChatListUI, PeerInfoUI, GalleryUI, …     │
├───────────────────────────────────────────────────────────────┤
│ AccountContext · TelegramEngine (the API that screens call)   │
├───────────────────────────────────────────────────────────────┤
│ TelegramCore: Account, AccountStateManager, pending messages, │
│ media fetchers, update handling                               │
├───────────────────────────────┬───────────────────────────────┤
│ MtProtoKit · TelegramApi      │ Postbox (SQLite, views)       │
│ (wire protocol, TL types)     │                               │
└───────────────────────────────┴───────────────────────────────┘
  Display · AsyncDisplayKit (rendering) · SwiftSignalKit (reactive)
```

The key property: **screens mostly observe Postbox views** (through SwiftSignalKit signals) and call `TelegramEngine` for actions. They rarely touch the network directly. This is what makes the fork feasible.

## Approaches considered

| Approach | Description | Pros | Cons | Verdict |
|---|---|---|---|---|
| **A. Replace the sync layer** | Keep Postbox and the screens. A new `MattermostSync` writes Mattermost data into Postbox using Telegram's data types. Re‑implement the `TelegramEngine` calls the screens use. | Most screens work unchanged. One data model. No extra servers. | Large rewrite inside TelegramCore. Data‑model mismatches (IDs, read state, threads) must be bridged. | **Recommended** |
| B. MTProto bridge server | Keep the client nearly unchanged. Point it at a Telegram‑compatible server (e.g. Teamgram) that mirrors Mattermost. | Least client work. | We would run a Telegram server plus two‑way sync, i.e. two sources of truth. The client's API layer moves ahead with every Telegram release, and the server must keep up. | Rejected |
| C. Extract UI into a new app | Copy UI components into a fresh app with our own data layer. | Clean data layer. | UI modules are tightly coupled to `AccountContext`, Postbox and TelegramCore types. Extraction costs more than A and loses most of the polish. | Rejected |

## Target design (approach A)

```
┌───────────────────────────────────────────────────────────────┐
│ Screens (kept; Telegram‑only features hidden by flags)        │
│ + MattermostUI (new screens)                                  │
├───────────────────────────────────────────────────────────────┤
│ AccountContext · TelegramEngine  (API shape kept,             │
│                                   implementations swapped)    │
├──────────────────────────────┬────────────────────────────────┤
│ MattermostSync (new)         │ Postbox (kept)                 │
│ ID map · bootstrap · events  │ SQLite · views · MediaBox      │
│ holes · outgoing · media     │                                │
├──────────────────────────────┴────────────────────────────────┤
│ MattermostKit (new): REST v4 · WebSocket · auth · models      │
└───────────────────────────────────────────────────────────────┘
  MtProtoKit / TelegramApi: disconnected first, deleted later
```

## New modules

| Module | Depends on | Responsibility |
|---|---|---|
| `MattermostKit` | Foundation only | REST v4 client, Codable models, WebSocket client, auth (password, MFA, SSO, personal access token), retry and backoff, server capability detection. Contains no Telegram code, so it can be tested on its own (SwiftPM) and possibly licensed separately (see [Legal](08-legal-and-licensing.md)). |
| `MattermostSync` | MattermostKit, Postbox, TelegramCore data types | ID map store and allocator, bootstrap sync, applying WebSocket events, filling history holes, outgoing message pipeline, media resource fetcher, read state. |
| `MattermostUI` | Display, AccountContext, … | New screens: server picker, login and SSO, threads list, message‑attachment and markdown‑block bubbles, channel browser, saved posts, recent mentions. |

All three are Bazel targets under `submodules/`. `MattermostKit` also gets a `Package.swift` for fast standalone tests.

## Strategy for TelegramCore

1. **Disconnect, don't delete.** Leave MtProtoKit and TelegramApi compiled at first, but never started. Deleting them early creates thousands of compile errors before anything works.
2. **Find the boot path.** Phase 0 has to find the smallest change that builds an `Account` / `AccountContext` with no live MTProto `Network`. Candidates: a no‑op network object; refactoring `Account` to take a protocol; reusing the unauthorized or test‑account path. This decides how invasive the TelegramCore changes will be.
3. **Inventory the engine.** List every `TelegramEngine` call reachable from the screens we keep, and classify each one:

   | Engine area (examples) | Treatment |
   |---|---|
   | `messages`: send, edit, delete, reactions, history, search | Backed by Mattermost |
   | `peers`: info, members, mute, pin, join/leave, create | Backed by Mattermost |
   | `resources`: media fetch, upload | Backed by Mattermost |
   | `accountData`: profile, presence, status | Backed by Mattermost |
   | `auth` | Replaced by the Mattermost login flow |
   | `contacts` | Mapped to user directory search, or stubbed |
   | `privacy`, `stickers`, `payments`, `calls`, `secureId`, stories, … | Stubbed (empty or completed signals); UI hidden |
   | `notices`, `localization`, themes | Local only; kept as they are |

4. **Implement behind the same signatures**, so screen code changes as little as possible.
5. **Delete MTProto** after Phase 3, once nothing references it.

## Feature flags

A single `MattermostFeatures` configuration, read at startup, hides UI entry points (menu items, settings rows, attach‑menu items, context actions) instead of deleting screens. This keeps diffs against upstream small and makes hiding reversible. Code for a hidden feature is removed only when it blocks the build or costs real binary size.

## Reactive bridging

Telegram's codebase uses SwiftSignalKit everywhere. `MattermostKit` uses Swift concurrency (`async`/`await`, `URLSession`, `URLSessionWebSocketTask`). `MattermostSync` gets a small set of bridging helpers (`Signal` ⇄ `async`) so each side stays idiomatic. All Postbox writes go through `postbox.transaction { … }` on Postbox's own queue.

## Repository layout

This repository becomes the fork: Telegram‑iOS history plus our commits.

```
tg-mattermost-client/
  Telegram/                  app and extension targets (upstream)
  submodules/                upstream modules
  submodules/MattermostKit/
  submodules/MattermostSync/
  submodules/MattermostUI/
  build-system/              upstream Bazel tooling + our configuration
  infra/dev-server/          local Mattermost (container) + seed scripts
  infra/push-proxy/          push proxy configuration (no secrets)
  docs/plan/                 this plan
  PLAN.md
```

## Upstream strategy

- Pin to one tagged Telegram‑iOS release and record the tag here.
- Treat it as a **hard fork**. Telegram changes TelegramCore heavily in every release, so regular merges are not realistic.
- Keep an `upstream` remote and cherry‑pick targeted UI or crash fixes when worthwhile.
- Keep our changes concentrated in new modules plus small, well‑marked hooks (`// MATTERMOST:` comments) to make cherry‑picks and audits easier.
- Re‑evaluate rebasing onto a newer upstream tag at most once a year, and only after parity.
