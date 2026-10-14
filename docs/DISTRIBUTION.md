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

Dispatch **Publish Neutrino preview** with a version such as `1.0.1-preview.1`, push a matching `v*-preview.*` tag, or merge an intentional version bump in `PREVIEW_VERSION` to main. Only changes to that file trigger preview publication from main. It builds the complete app on Apple Silicon, requires native tests, real updater replacement/data-preservation tests, and installed shell launch/normal-quit acceptance. It also requires research acceptance in both engines and full Blink/extension acceptance against the packaged app; the receipts and log are attached. Only the consumer workflow can publish a core-accepted production release; its full Blink, streaming, signing and manual acceptance gates remain required.

Both publishing workflows attach `.app.zip`, DMG, `SHA256SUMS`, package metadata, and `catalog.json`. The archive is generated from the final sealed/stapled bundle; installed acceptance expands the actual ZIP and verifies its sealed code and metadata against the app in the DMG. **Add compiled apps to release assets** backfills ZIPs from actual existing DMGs without rebuilding or changing old versions, skips historical Intel payloads, and runs on release publication or manual dispatch with `tag=all`.

Published apps check GitHub's release API 20 seconds after startup and every six hours. Preview apps include prereleases; consumer apps use stable releases. Drafts and releases without a catalog are skipped. Same/older builds, incompatible Macs, security rollback, and automatic engine removal are rejected. Automatic download and installation are enabled by default and can be disabled in Settings > Updates & engines. “Check for updates…” is also in the Neutrino menu.

Updates stage a complete app and wait for normal quit, data flush, and actual process exit before replacing it. An ordinary quit stays quit; “Restart and install” reopens Neutrino. Cancelled quit leaves the old app running. App Translocation/read-only copies must be moved to a writable Applications folder. The swap touches only the app bundle: SQLite, tabs/Spaces, Profile website data, custom modules, preferences, and Keychain credentials stay outside it. No Radius data migration or legacy updater compatibility is provided.

## Trust

The retained consumer service verifies bounded download bytes/digest, read-only mounting, Developer ID identity and matching Team ID/bundle ID, strict nested signatures, notarization, architecture, sealed metadata, and monotonic build/security floors. Candidate claims in a catalog do not authorize execution.

The verified helper waits for genuine process exit, verifies the copied candidate again, and uses a journaled sibling rename with rollback/recovery. Preview candidates must match the advertised CDHash throughout staging/copy/activation. Consumer candidates must retain the same Developer ID publisher and notarization. No update removes quarantine or disables Gatekeeper.

The new host requires ABI 8 / `chromeViews` with `hostPresentation=clippedNative`; predecessor runtime packages must fail compatibility checks.

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

## Complete app and engine updates

The published Apple Silicon ZIP expands into one `Neutrino.app`; the DMG contains that same app. CEF's sandbox/helper executables are private background components inside the app, not separate installations or user-facing applications. Chromium requires these subprocesses for rendering and isolation.

The updater downloads a digest-checked complete release and replaces the app after normal quit. Chromium updates travel in the same sealed bundle; Profiles, website data, passwords, module data and layouts stay in Application Support/Keychain. The runtime never loads a downloaded, unverified engine outside the app.

`chromium-updates.yml` checks the trusted upstream stable CEF index daily, verifies both SDK archive sizes/digests, and emits a SHA-256 pin candidate. A macOS job must compile the integration, pass native tests and real updater checks, and pass installed launch/save/quit before a fast-forward-only source update and a new preview release are dispatched. Incompatible upstream builds or concurrent main changes stop publication. Full browser parity remains a separate consumer gate.

Preview packaging checks the configured Developer ID and App Store Connect secret bindings. Complete credentials enable signing, notarization, stapling and Gatekeeper assessment even for previews. Missing credentials produce an explicit ad-hoc preview with a `signing-status.json` receipt; this does not remove macOS's first-launch warning. No quarantine or Gatekeeper bypass is embedded in the app.

## Sparkle and full removal

Sparkle 2.10.0 is checksum-pinned and bundled. Keyed builds seal `SUPublicEDKey`, `SUFeedURL`, `SURequireSignedFeed`, and `SUVerifyUpdateBeforeExtraction`. Publication verifies the persistent private seed against the sealed public key, signs/verifies the complete app ZIP and feed, and publishes immutable GitHub asset URLs. The `updates` branch provides separate stable/preview feeds. Native validation enforces the app-build and Chromium security-epoch floors. Feed publication rereads after conflicts and refuses older builds, epoch rollback, or changed bytes for an existing build.

Enable keyed publication with repository variable `NEUTRINO_SPARKLE_PUBLIC_KEY` and matching secret `NEUTRINO_SPARKLE_PRIVATE_KEY` (32-byte seed, Base64). They are not configured in this workspace. Such previews retain the verified GitHub updater and publish an explicit `sparkle-status.json` instead of claiming Sparkle is active. Previously installed binaries gain Sparkle by updating to a keyed build through that bridge; their compiled update implementation cannot be changed retroactively.

Settings → General → Uninstall Neutrino asks for permanent removal. Cancel remains the default. Removal joins pending update and interface work, freezes writes, stops/reaps workers and engines, releases WebKit stores, erases only Neutrino's allowlisted browser paths and Keychain services, then deletes its installed app. Downloads and exports remain. Pending installers block removal; canceled quits disarm the request. A failed cleanup reports what remains and keeps the app available for retry.

The `chromeViews` manifest family label is retained for complete-application updates from existing previews. ABI 8 and `hostPresentation=clippedNative` identify the actual new hosting integration; the replacement host enforces both. This does not allow predecessor engine packages to load in Studio.
