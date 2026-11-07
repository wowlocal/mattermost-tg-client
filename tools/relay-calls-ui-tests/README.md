# Native call UI checks

Run these on a dedicated build Mac with Xcode and XcodeGen. They attach to an
already installed `org.relaychat.Relay`; they do not compile the Telegram app.
Use dedicated iPhone and iPad simulators and an isolated private Mattermost
channel. Do not use a real conversation.

1. Install the freshly packaged IPA, after running `tools/relay-calls-bundle-check.py`.
2. Log the macOS creator in as `relaytester`, the iPhone as `alex.rivera`, and
   the iPad as `sam.lee`. Add all three accounts to the private test channel.
3. Open the private channel and press the phone icon in all three clients.
   Telegram's current navigation renderer does not consistently expose the
   icon's accessibility label; use the remote screen for this step.
4. Run the member and controls tests separately for each simulator:

```sh
xcodegen generate
xcodebuild test -project RelayCallsIntegration.xcodeproj \
  -scheme RelayCallsIntegration -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$TEST_DERIVED_DATA" -jobs 1 -parallel-testing-enabled NO \
  -only-testing:RelayCallsUITests/RelayCallsUITests/testDistinctMemberCall \
  -only-testing:RelayCallsUITests/RelayCallsUITests/testJoinAndMute \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
```

`testDistinctMemberCall` checks all three display names and that ordinary
members do not see the creator's **End call for everyone** control. For the
separate same-account/device-identity scenario, log all clients in as
`relaytester` and run `testGroupScreenPresentation` on each receiver: it expects
three sessions named **Relay Tester**, plus the shared screen's label.

Open `share-fixture.html` in its own browser window on the build Mac, then
share that window from Relay. Confirm the changing clock and bar are received
on both simulators and retain screenshots in the integration results. Inspect
the room's microphone and screen publications independently; a receive-only
SDK participant can also count decoded audio/video frames without recording
their contents.

Run `testLeave` on one simulator and independently confirm that the server
participant count falls from three to two while the other clients stay
connected. Rejoin using the phone button, stop sharing, and end the room from
the creator's macOS UI. Confirm both receivers disconnect. Archive the private
test channel and restore any simulator sessions stopped for testing.

Simulator checks establish call UI behavior and received screen rendering.
They do not establish physical-device ReplayKit broadcasting, background
microphone behavior, speaker routing, or audible quality. Keep those results
separate in the integration report. Do not save credentials or join tokens in
the test project, arguments, result bundles, or repository.
