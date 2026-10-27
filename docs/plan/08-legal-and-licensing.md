# 8 · Legal and licensing

> This is an engineering summary, not legal advice. Get counsel before any public release.

## Telegram‑iOS licensing (GPL v2 or later)

- **Checked 2026‑10‑26:** the repository has **no `LICENSE` file**, neither at the pinned commit nor anywhere in its history (GitHub reports no license). The README only says: "Please remember to publish **your** code too in order to comply with the licences."
- **Checked 2026‑10‑27:** Telegram states the license on its apps page, [telegram.org/apps](https://telegram.org/apps) → Source code: Telegram for iOS is "Licensed under GNU GPL v. 2 or later" (as is Android; macOS says v. 2, Desktop v. 3). The engine Telegram added to this tree, `third-party/mtproto-engine`, says `GPL-2.0-or-later` in its Cargo.toml. "Or later" means the fork may be distributed under **GPL v3**, which can be combined with the Apache‑2.0 (Abseil, lottie‑ios, libphonenumber, Texture) and LGPL‑3.0 (tgcalls) parts; under "v2 only" those combinations would be incompatible. Counsel should still confirm that the web page is a sufficient grant for a repository without a license file.
- Plan on the GPL in the meantime: the fork as a whole is distributed under the GPL.
- Anyone who receives the app must be able to get the **complete corresponding source**. This includes App Store and TestFlight users. The simplest way is a public repository at the exact released commit.
- The GPL version affects which other licenses we can combine with it: with "or later", v3 is available (Apache‑2.0 below).
- Code we write is our copyright. `MattermostKit` contains no Telegram code, so it could also be published separately under a permissive license if we want to reuse it. Combined into the app, it is distributed under the GPL.
- Telegram‑iOS bundles third‑party code under various licenses (e.g. FFmpeg, WebRTC, Opus). Keep their notices. Review them again after stripping features, because some may no longer be needed.
- **Shipped components (2026‑10‑27, `Telegram/Relay/RelayLicenses.json`, 38 entries):** permissive (BSD, MIT, Apache‑2.0, BSL‑1.0, zlib, ISC/OpenSSL) except FFmpeg (LGPL‑2.1+, built without `--enable-gpl`), rlottie (LGPL‑2.1), tgcalls (LGPL‑3.0) and the GPL‑2.0+ MTProto engine. None is closed source (4A removed RecaptchaEnterprise). libprisma is MIT (its upstream LICENSE, now copied into the tree); subcodec was written for Telegram‑iOS and has no license of its own, so Telegram‑iOS's terms apply. The LGPL parts are linked statically; the public source of the whole app lets users rebuild and relink them.

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
