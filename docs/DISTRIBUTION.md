# Apple Silicon distribution

Neutrino targets macOS 14+ on Apple Silicon. The intended installer is one offline DMG containing the app, ARM64 Blink/CEF framework and sandbox helpers, default modules, workers, and updater. WebKit is supplied by macOS. End users need no developer tools or separate engine installation.

## Build paths

```sh
./scripts/build-app.sh
python3 scripts/package-release.py --development
python3 scripts/installed-smoke.py --chromium-restart
```

The default build embeds pinned Blink. An explicitly incomplete WebKit-only development package requires both `NEUTRINO_WEBKIT_DEVELOPMENT_ONLY=1` for the build and `--development --allow-webkit-development` for packaging. Production rejects missing Blink and non-ARM64 metadata.

Development signatures establish integrity only. Development packages are labeled, never emit consumer catalog entries, and cannot use the trusted consumer updater. A development installer does not establish core-release readiness.

## Trust

The retained consumer service verifies bounded download bytes/digest, read-only mounting, Developer ID identity and matching Team ID/bundle ID, strict nested signatures, notarization, architecture, sealed metadata, and monotonic build/security floors. Candidate claims in a catalog do not authorize execution.

Updates stage a complete replacement app. The signed helper waits for genuine process exit, verifies the copied candidate, and uses a journaled sibling rename with rollback/recovery. Website data is outside this transaction. Cancelling quit keeps live pages and cancels requested activation. There is no user-facing trust bypass.

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

No signing credentials or licensed CDM are configured in this workspace. No new Neutrino DMG has been built or accepted here. This Linux environment cannot perform macOS signing, native launch, Gatekeeper, TCC, or installed restart checks. Historical Radius artifacts and receipts do not satisfy these gates.


## Publishing receipt

The publishing job requires the repository variable `NEUTRINO_CORE_ACCEPTANCE_JSON` after manual testing of the uploaded candidate. It identifies format `1`, `sourceCheckout`, `installerSHA256`, `testedBy`, and `checks`: one `{ "id": "...", "result": "passed", "evidence": "actual test outcome and evidence location" }` for each of `onboarding`, `workspaces`, `editor`, `dailyBrowsing`, `passwordsAutofill`, `blocking`, `extensions`, `protectedStreaming`, `offlineInstaller`, and `accessibility`.

The validator binds that record to the exact signed/notarized DMG and successful installed/restart receipt. Configure the variable after testing, then rerun the failed publishing job without rebuilding the candidate. The record is a publisher attestation; the validator does not perform those manual tests. Missing/skipped/stale checks cannot publish. No passing record is supplied in this checkout.
