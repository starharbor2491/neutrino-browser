# Apple Silicon distribution

Neutrino targets macOS 14+ on Apple Silicon. Every release packages one offline DMG and a Finder-expandable `.app.zip` containing the same compiled app, ARM64 Blink/CEF framework and sandbox helpers, default modules, workers, and updater. WebKit is supplied by macOS. End users need no developer tools or separate engine installation.

## Build paths

```sh
./scripts/build-app.sh
python3 scripts/package-release.py --development
python3 scripts/installed-smoke.py --chromium-restart
```

The default build embeds pinned Blink. An explicitly incomplete WebKit-only development package requires both `NEUTRINO_WEBKIT_DEVELOPMENT_ONLY=1` for the build and `--development --allow-webkit-development` for packaging. Production rejects missing Blink and non-ARM64 metadata.

Local development builds have no update subscription. Published previews explicitly seal `NeutrinoUpdateChannel=preview` into the app and emit a GitHub update catalog. Their provenance is the pinned `starharbor2491/neutrino-browser` GitHub repository over HTTPS, with bounded download size/SHA-256 and an advertised application CDHash checked against strict nested code integrity. GitHub repository control is the preview publisher trust boundary; ad-hoc signatures do not establish an Apple publisher identity or notarization. Arbitrary offline imports are unavailable in previews. A preview does not establish core-release readiness.

## GitHub releases and automatic updates

Dispatch **Publish Neutrino preview** with a version such as `1.0.1-preview.1`, or push a matching `v*-preview.*` tag. It builds the complete app on Apple Silicon, requires native tests, real updater replacement/data-preservation tests, and installed shell launch/normal-quit acceptance. It also runs full Blink/extension acceptance independently and attaches the result, including a failed receipt/log if parity is incomplete. Only the consumer workflow can publish a core-accepted production release; its full Blink, streaming, signing and manual acceptance gates remain required.

Both publishing workflows attach `.app.zip`, DMG, `SHA256SUMS`, package metadata, and `catalog.json`. The archive is generated from the final sealed/stapled bundle; installed acceptance expands the actual ZIP and verifies its sealed code and metadata against the app in the DMG. **Add compiled apps to release assets** backfills ZIPs from actual existing DMGs without rebuilding or changing old versions, skips historical Intel payloads, and runs on release publication or manual dispatch with `tag=all`.

Published apps check GitHub's release API 20 seconds after startup and every six hours. Preview apps include prereleases; consumer apps use stable releases. Drafts and releases without a catalog are skipped. Same/older builds, incompatible Macs, security rollback, and automatic engine removal are rejected. Automatic download and installation are enabled by default and can be disabled in Settings > Browsing engines > Installation and updates. “Check for updates…” is also in the Neutrino menu.

Updates stage a complete app and wait for normal quit, data flush, and actual process exit before replacing it. An ordinary quit stays quit; “Restart and install” reopens Neutrino. Cancelled quit leaves the old app running. App Translocation/read-only copies must be moved to a writable Applications folder. The swap touches only the app bundle: SQLite, tabs/Spaces, Profile website data, custom modules, preferences, and Keychain credentials stay outside it. No Radius data migration or legacy updater compatibility is provided.

## Trust

The retained consumer service verifies bounded download bytes/digest, read-only mounting, Developer ID identity and matching Team ID/bundle ID, strict nested signatures, notarization, architecture, sealed metadata, and monotonic build/security floors. Candidate claims in a catalog do not authorize execution.

The verified helper waits for genuine process exit, verifies the copied candidate again, and uses a journaled sibling rename with rollback/recovery. Preview candidates must match the advertised CDHash throughout staging/copy/activation. Consumer candidates must retain the same Developer ID publisher and notarization. No update removes quarantine or disables Gatekeeper.

The new host requires ABI 5 / `chromeViews`; predecessor runtime packages must fail compatibility checks.

## Production prerequisites

The manually dispatched consumer workflow builds one complete Apple Silicon artifact. Publishing must follow native/installed acceptance and the core gates, including complete daily browsing, extension surfaces, and representative protected streaming. Developer ID and notarization alone do not certify browser behavior.

Required configured secrets:

| Secret | Purpose |
| --- | --- |
| `NEUTRINO_SIGNING_IDENTITY` | Developer ID Application identity |
| `NEUTRINO_SIGNING_CERTIFICATE_BASE64` | PKCS#12 signing certificate/private key |
| `NEUTRINO_SIGNING_CERTIFICATE_PASSWORD` | Certificate password |
| `NEUTRINO_NOTARY_KEY_BASE64` | App Store Connect notarization key |
| `NEUTRINO_NOTARY_KEY_ID` | Key ID |
| `NEUTRINO_NOTARY_ISSUER` | Issuer UUID |

Local signing may use an existing keychain identity and `NEUTRINO_NOTARY_PROFILE`. Version, build number, and security epoch are sealed before signing. Ephemeral CI credential files/keychains are removed during cleanup.

No signing credentials or licensed CDM are configured in this workspace. macOS builds and development installer acceptance run on GitHub's Apple Silicon runners; this Linux workspace cannot perform native launch, Gatekeeper, or TCC checks. Historical Radius artifacts and receipts do not satisfy Neutrino core-release gates.


## Publishing receipt

The publishing job requires the repository variable `NEUTRINO_CORE_ACCEPTANCE_JSON` after manual testing of the uploaded candidate. It identifies format `1`, `sourceCheckout`, `installerSHA256`, `testedBy`, and `checks`: one `{ "id": "...", "result": "passed", "evidence": "actual test outcome and evidence location" }` for each of `onboarding`, `workspaces`, `editor`, `dailyBrowsing`, `passwordsAutofill`, `blocking`, `extensions`, `protectedStreaming`, `offlineInstaller`, and `accessibility`.

The validator binds that record to the exact signed/notarized DMG and successful installed/restart receipt. Configure the variable after testing, then rerun the failed publishing job without rebuilding the candidate. The record is a publisher attestation; the validator does not perform those manual tests. Missing/skipped/stale checks cannot publish. No passing record is supplied in this checkout.
