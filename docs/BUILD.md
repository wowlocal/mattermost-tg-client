# Building

Working commands for this fork. Upstream's notes live in the root `CLAUDE.md` (written for Telegram's own signing setup; the commands below replace its build command for us).

## Requirements

- Xcode **27.0** (the fork is pinned to upstream `5c20d095d1ab`, see [PROGRESS.md](PROGRESS.md)).
- Metal toolchain: `xcodebuild -downloadComponent MetalToolchain` (Xcode 27 ships without it; the build fails in `MetalCompile` otherwise).
- An iOS simulator runtime. The app's minimum iOS is 15.0, so the installed iOS 26.5 runtime works.
- Bazel is downloaded by `Make.py` into `build-input/` (version pinned in `versions.json`).
- Disk cache on `/Volumes/X5/relay-bazel-cache` (any APFS volume works; not ExFAT, Bazel needs symlinks). The Bazel output base stays in `~/Library/Caches/bazel`.

## Simulator build

```sh
python3 build-system/Make/Make.py --cacheDir /Volumes/X5/relay-bazel-cache build \
  --configurationPath build-config/development-configuration.json \
  --xcodeManagedCodesigning --disableProvisioningProfiles \
  --buildNumber=1 --configuration=debug_sim_arm64
```

- `--disableProvisioningProfiles` is our addition to `Make.py build` (simulator only). The upstream fake profiles only match Telegram's own bundle ID.
- Add `--continueOnError` after `build` to collect all compile errors in one pass.
- First build: ~9 minutes on this machine (3,869 actions). Incremental builds are much faster.
- Output: `bazel-bin/Telegram/Telegram.ipa`. Always install from the `.ipa`, never from `Telegram_archive-root/`, which goes stale on incremental builds (see root `CLAUDE.md`).

## Run on the simulator

A dedicated simulator, "Relay iPhone 17 Pro" (iOS 26.5), is used so other projects' simulators aren't touched. Its UDID is in `build-input/relay-sim-udid`.

```sh
UDID=$(cat build-input/relay-sim-udid)
STAGE=$(mktemp -d)
unzip -q -o bazel-bin/Telegram/Telegram.ipa -d "$STAGE"
xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl terminate "$UDID" org.relaychat.Relay 2>/dev/null
xcrun simctl install "$UDID" "$STAGE/Payload/Telegram.app"
xcrun simctl launch "$UDID" org.relaychat.Relay
xcrun simctl io "$UDID" screenshot /tmp/relay.png
```

If `simctl install` doesn't pick up a rebuilt binary (same build number), replace the installed bundle in place as described in the root `CLAUDE.md` ("Updating the running simulator after a rebuild").

## Pure Swift packages

`submodules/MattermostKit` and `submodules/MattermostSyncCore` are SwiftPM packages with no Telegram dependencies:

```sh
cd submodules/MattermostKit && swift test
cd submodules/MattermostSyncCore && swift test
```

## Local Mattermost server

See `infra/dev-server/README.md`.
