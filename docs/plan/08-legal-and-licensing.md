# 8 · Legal and licensing

> This is an engineering summary, not legal advice. Get counsel before any public release.

## Telegram‑iOS is GPL‑2.0

- The fork as a whole must be distributed under the **GPL‑2.0**.
- Anyone who receives the app must be able to get the **complete corresponding source**. This includes App Store and TestFlight users. The simplest way is a public repository at the exact released commit.
- Check the `LICENSE` file at the pinned tag, and whether it says "version 2 only" or "version 2 or later". This affects which other licenses we can combine with it.
- Code we write is our copyright. `MattermostKit` contains no Telegram code, so it could also be published separately under a permissive license if we want to reuse it. Combined into the app, it is distributed under the GPL.
- Telegram‑iOS bundles third‑party code under various licenses (e.g. FFmpeg, WebRTC, Opus). Keep their notices. Review them again after stripping features, because some may no longer be needed.

## App Store and the GPL

- Apple's App Store terms add usage restrictions. The FSF considers these incompatible with the GPL.
- Precedent:
  - VLC was removed from the App Store in 2011 after a GPL complaint. It returned after relicensing.
  - Several Telegram‑iOS forks are distributed on the App Store today.
- The risk comes from copyright holders: Telegram, or contributors whose code is in the fork.
- Options by audience:
  - **Internal company use** (TestFlight, Apple Business Manager custom app, MDM): lower exposure. GPL obligations still apply to recipients.
  - **Public App Store:** get legal advice first.

## Trademarks

- **Telegram:** don't use the Telegram name or logo (including the paper plane in a blue circle). Telegram's guidelines for apps built from its source ask for exactly this. Remove "Telegram" from user‑facing strings, icons, the About screen and metadata.
- **Mattermost:** don't name or brand the app as "Mattermost". Check Mattermost's trademark guidelines for whether wording like "for Mattermost" or "works with Mattermost" is allowed.

## Mattermost code

| Project | License | How we use it |
|---|---|---|
| Mattermost server and REST/WebSocket APIs | Server is source‑available/open source | We only call its public API. No license combination. |
| `mattermost-mobile` (official app) | Apache‑2.0 | **Reference for behaviour only. Do not copy code.** Apache‑2.0 is generally considered incompatible with GPLv2. |
| `mattermost-push-proxy` | Apache‑2.0 | Run as a separate service, unmodified. No combination issue. |

## Privacy and compliance

- App Store privacy "nutrition" labels and a privacy policy URL are required.
- Data stays between the device and the user's own Mattermost server. Avoid third‑party analytics. If crash reporting is added, disclose it and make it opt‑in, or self‑host it.
- For company deployments: support managed app configuration (AppConfig/MDM), remote wipe on logout, and passcode lock.
