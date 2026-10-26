# Managed app configuration (MDM / EMM)

For administrators who deploy Relay with a mobile device management (MDM) or enterprise mobility management (EMM)
system: Jamf, Microsoft Intune, VMware Workspace ONE, Kandji, Mosyle and others. Relay reads Apple's **managed app
configuration** (AppConfig): a dictionary the MDM delivers with the app, which iOS stores under
`com.apple.configuration.managed` in the app's defaults. Implemented in Phase 4G.

Relay uses the **key names of the official Mattermost mobile app** ([Mattermost: deploy using an EMM
provider](https://docs.mattermost.com/deployment-guide/mobile/deploy-mobile-apps-using-emm-provider.html)), so an
existing Mattermost EMM profile works for Relay once it is assigned to Relay's bundle id, **`org.relaychat.Relay`**.
Mattermost documents every value as a string (`"true"` / `"false"` for switches); Relay also accepts booleans and
numbers. Unknown keys are ignored.

## Supported keys

| Key | Type | Default | What Relay does |
|---|---|---|---|
| `serverUrl` | string (URL) | — | Prefills the server address on the login screen (also Settings → Add Account). Without a scheme, `https://` is used. |
| `serverName` | string | — | The managed server's name on the login screens (instead of the server's own site name). |
| `allowOtherServers` | string (`true`/`false`) | `true` | `false` (with `serverUrl` set): Relay connects only to `serverUrl`. The address field is filled in and locked; another address is refused ("Your organization allows Relay to connect only to …"). **Accounts already signed in to another server are signed out** (their data is deleted from the device, as Settings → Log Out does) and the user is told which. Without `serverUrl`, `false` restricts nothing. |
| `username` | string | — | Prefills the login id (username or email) on the managed server's login screen; the user can still change it. |
| `inAppPinCode` | string (`true`/`false`) | `false` | Relay must be protected by a passcode: once an account is signed in, Relay asks for one ("Passcode Required"; it can't be skipped) and uses Telegram's passcode lock (4 or 6 digits, Face ID / Touch ID optional). The passcode can't be turned off, and auto-lock is at most **5 minutes** away (choices: 1 or 5 minutes). See "Differences" below. |
| `blurApplicationScreen` | string (`true`/`false`) | `false` | Relay covers its content with a blurred image whenever it isn't the active app: the app switcher shows no messages, also without a passcode. |
| `copyAndPasteProtection` | string (`true`/`false`) | `false` | Text and links copied in Relay stay in Relay: they are not offered to the user's other devices (Universal Clipboard) and are removed from the pasteboard when Relay goes to the background. Content copied in another app can't be pasted into a message. See "Copy and paste" below for the limits. |
| `jailbreakDetection` | string (`true`/`false`) | `false` | On a device that shows signs of a jailbreak, Relay shows "Device Not Allowed" and can't be used. A heuristic (jailbreak files, a sandbox that can be written outside of, injected libraries), not a guarantee. |
| `vendor` | string | "Your organization" | The organisation's name in Relay's messages ("Example Corp requires a passcode for Relay"). |
| `relayCertificatePins` | string, list of strings, or dictionary | — | **Relay-specific.** Certificate pinning: see below. |

**Not applicable** (accepted and ignored; the diagnostics summary lists them):

| Key | Why |
|---|---|
| `useVPN`, `timeoutVPN` | Mattermost's app waits for a per-app VPN before connecting. iOS routes Relay's connections through a per-app VPN or VPN On Demand configured by the MDM without anything in the app; requests that start before the tunnel is up fail and are retried. |
| `inAppSessionAuth` | Deprecated by Mattermost (server 10.2, mobile 2.2.1). Relay always signs in with SSO through the system's web authentication session. |

## Certificate pinning (`relayCertificatePins`)

Off unless configured. Each entry pins a host to the SHA-256 digest of a certificate's **SubjectPublicKeyInfo**
(SPKI), base64-encoded, the form HPKP, OkHttp and TrustKit use:

```
chat.example.com=sha256/5Kx0dJ…Q4= chat.example.com=sha256/Vf3o…Lk=
```

- Value forms: one string with entries separated by spaces, commas, semicolons or new lines; a list of such strings;
  or a dictionary from host to a pin string or a list of pins. `sha256/` is optional; base64url is accepted.
- The host is matched exactly (case-insensitive); a URL form (`https://chat.example.com:8443/path`) means its host.
  Ports are not part of a pin.
- A connection to a pinned host is accepted only if iOS **trusts the certificate chain** (public CA, or a CA the MDM
  installed) **and** a certificate in the chain (server certificate, intermediate or root) has a pinned key. Pin
  at least two keys (the current one and a backup, or the issuing CA's) so a certificate renewal doesn't lock users
  out.
- **Fail-closed only for pinned hosts**: a mismatch refuses the connection (login: "The certificate of … isn't the
  one your organization requires"; signed-in accounts stop syncing until the pins or the certificate are fixed). A
  host whose entries are all unreadable counts as pinned with no valid pin, so it fails too. Hosts without pins are
  evaluated by iOS as usual.
- Applies to everything Relay itself sends to the server: API requests, the WebSocket, uploads, downloads of files,
  pictures, emoji and link-preview images (which all come from the server or its image proxy), in the app, the
  share extension and the notification service extension. It does not apply to SSO sign-in pages (the system's web
  authentication session) or links opened in a browser.

Compute a pin from the server's certificate (or a CA certificate):

```sh
openssl s_client -connect chat.example.com:443 -servername chat.example.com </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
```

## Differences from Mattermost's app

- **`inAppPinCode`**: Mattermost's app asks for the *device* passcode or Face ID. Relay uses its own app passcode
  (Telegram's lock, which can also unlock with Face ID / Touch ID) because that lock also hides notification text
  while the app is locked, asks for the passcode in the share extension, and applies to every account in the app.
  Once a passcode is set, notification actions (Reply, Mark as Read) need the device to be unlocked.
- **`allowOtherServers`**: Mattermost documents only that users are limited to the configured server. Relay also
  signs out accounts that were added before the restriction arrived (decision taken in Phase 4G), so the app holds
  no data of servers the organisation doesn't allow and nothing can be forwarded or shared between such an account
  and the managed one.
- **`blurApplicationScreen`**: iOS doesn't let apps block screenshots; like Mattermost's iOS app, Relay only hides
  its content in the app switcher.

## Copy and paste

`copyAndPasteProtection` covers what an app can do by itself:

- Everything Relay copies (message text, links, selections, Copy Link) is marked local-only and removed from the
  pasteboard when Relay goes to the background, so it can't be pasted into another app or arrive on another
  device. Copy and paste inside Relay keep working.
- Pasting into the message composer accepts only content Relay copied. Other text fields (search, login, profile)
  use the system's paste.
- Not covered: content that reaches the pasteboard through Universal Clipboard while Relay is open counts as Relay's;
  on iPad, an app beside Relay in Split View can read the pasteboard until Relay goes to the background.

For a boundary the system enforces, deploy Relay as a managed app and use iOS's restrictions **`allowOpenFromManagedToUnmanaged`
/ `allowOpenFromUnmanagedToManaged`** with **`requireManagedPasteboard`** (iOS 15+): iOS then refuses paste between
managed and unmanaged apps in every text field.

## Extensions

Only the app can read the managed configuration. It writes a copy of what the extensions need (the certificate pins
and the server restriction, nothing else) to `relay-managed-configuration.json` in its app group, and the share and
notification service extensions read it. After the MDM changes the configuration, the extensions use the new one once
Relay has been opened. A passcode applies to the share extension (it asks for it) and hides the text of
notifications while Relay is locked.

## Applying changes

Relay reads the configuration at launch, whenever it becomes active, and when iOS reports a change
(`UserDefaults.didChangeNotification`). Changes take effect at once: pins for new connections, the server restriction
(sign-outs), the passcode requirement and the other switches.

## Example

An AppConfig dictionary (the `<dict>` an MDM's "App Configuration" field takes):

```xml
<dict>
  <key>serverUrl</key><string>https://chat.example.com</string>
  <key>serverName</key><string>Example Chat</string>
  <key>allowOtherServers</key><string>false</string>
  <key>inAppPinCode</key><string>true</string>
  <key>blurApplicationScreen</key><string>true</string>
  <key>copyAndPasteProtection</key><string>true</string>
  <key>vendor</key><string>Example Corp</string>
  <key>relayCertificatePins</key>
  <array>
    <string>chat.example.com=sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=</string>
    <string>chat.example.com=sha256/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=</string>
  </array>
</dict>
```

## Testing without an MDM

On a simulator (docs/BUILD.md "Phase 4G"); the app picks a change up when it next becomes active:

```sh
xcrun simctl spawn <udid> defaults write org.relaychat.Relay com.apple.configuration.managed \
  -dict serverUrl https://chat.example.com allowOtherServers false inAppPinCode true
xcrun simctl spawn <udid> defaults delete org.relaychat.Relay com.apple.configuration.managed
```

## What was verified (Phase 4G) and what wasn't

On the simulator with a debug build against the dev server (docs/PROGRESS.md, 4G): every key in the table above,
the sign-out of an account on another server, pins accepted (CA key, leaf key) and refused (login probe, a signed-in
account, a pin changed while connected) through a TLS proxy, the passcode requirement with real taps, the blurred
app-switcher snapshot, paste refused and allowed in the composer, the share extension asking for the passcode.
Not verified: delivery by a real MDM (Jamf, Intune, …) and `UserDefaults.didChangeNotification` on a managed device,
iOS's managed pasteboard restriction, jailbreak detection on a jailbroken device, Face ID unlock.
