# Phase 4G: an exported diagnostics bundle (debug build, simulator), Relay-Diagnostics-20261026-221312.zip (588 KB)

## Files
- logs/app-logs/log-2026-10-26_17-25-58.583.txt (2097188 bytes)
- logs/app-logs/log-2026-10-26_17-26-02.590.txt (2062188 bytes)
- logs/app-logs/log-2026-10-26_17-28-54.466.txt (2090166 bytes)
- logs/app-logs/log-2026-10-26_17-46-08.296.txt (2093344 bytes)
- logs/app-logs/log-2026-10-26_18-04-05.300.txt (2073562 bytes)
- logs/app-logs/log-2026-10-26_19-43-29.782.txt (1785178 bytes)
- logs/share-logs/log-2026-10-26_16-43-35.185.txt (248586 bytes)
- metrickit/20261026T205626Z-diagnostics-d10ae805.json (265 bytes)
- metrickit/20261026T205627Z-metrics-3f71c3db.json (125 bytes)
- summary.txt (589 bytes)

## summary.txt
```
Relay diagnostics
Created: 2026-10-26T21:13:16Z

App: Relay 0.1.0 (1)
iOS: 26.5
Device: arm64
Language: en-US

Accounts: 3
  1. localhost:8065, Mattermost 11.7.14, syncing
  2. localhost:8065, Mattermost 11.7.14, syncing
  3. localhost:8065, Mattermost 11.7.14, syncing

Passcode: off
Managed configuration: copy/paste protection, organization name
Diagnostic logs saved: yes; 7 log file(s) included, redacted (ids pseudonymized, credentials and email addresses removed)

iOS reports (MetricKit): 2
  2026-10-26T20:56:26Z diagnostics (265 bytes)
  2026-10-26T20:56:27Z metrics (125 bytes)
```

## logs/app-logs (redacted), sample lines
```
[Mattermost] 2026-10-26 19:45:46.681 push: APNs sandbox token <redacted>
[Mattermost] 2026-10-26 19:45:46.822 account -6422078681813746674: starting sync for http://localhost:8065 as <id:8c19c8>
[Mattermost] 2026-10-26 19:45:46.828 account 3841996869622163099: starting sync for http://localhost:8065 as <id:bdade9>
[Mattermost] 2026-10-26 19:45:46.834 account 5008489688141644893: starting sync for http://localhost:8065 as <id:65d32d>
[Mattermost] 2026-10-26 19:46:19.947 push: APNs sandbox token <redacted>
[Mattermost] 2026-10-26 19:46:20.314 account 3841996869622163099: starting sync for http://localhost:8065 as <id:bdade9>
[Mattermost] 2026-10-26 19:46:20.321 account -6422078681813746674: starting sync for http://localhost:8065 as <id:8c19c8>
[Mattermost] 2026-10-26 19:46:20.325 account 5008489688141644893: starting sync for http://localhost:8065 as <id:65d32d>
```

## metrickit/ (a synthetic report from the debug remote: MetricKit delivers nothing on the simulator)
```
{"crashDiagnostics":[{"callStackTree":{"callStackPerThread":true,"callStacks":[]},"diagnosticMetaData":{"appBuildVersion":"debug","exceptionType":1,"signal":11}}],"relayDebugSample":true,"timeStampBegin":"2026-10-26T19:56:26Z","timeStampEnd":"2026-10-26T20:56:26Z"}
```
