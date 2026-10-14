# Local capability and acceptance ledger

The target is equivalent local user workflows from Arc, Chrome, and Opera/Opera GX. Split groups into per-workflow acceptance tests before marking them complete. Record tested source/binary and actual outcomes; this table is not a shipped-feature claim.

| Area | Target | Current boundary |
| --- | --- | --- |
| Navigation | Address/search, back/forward, reload/stop, zoom/find, shortcuts, site identity | Basic native navigation/custom tab/address checks pass; complete workflow acceptance pending |
| Tabs | Restore/pin/tree/folders/duplicate/reorder/close/reopen, mute/suspend/discard/search/groups | Organization, restore, direct reordering and command search present; mute/suspend and advanced tab management incomplete |
| Spaces/windows | Separate Profiles, shared Spaces, live-page transfer, splits, per-Space setups | WebKit native document-transfer/state/setup tests pass; full everyday and Blink acceptance pending |
| Setup/import | Complete guided setup, optional import/AI, default browser, review | Flow present; import currently HTML bookmarks only |
| Library | Bookmarks/history/download control/notes/import/export | Services retained; advanced managers and full download history need review |
| Credentials | Local vault, save/update prompts, login/contact/payment autofill, passkeys | Manual Keychain add/requested login fill present; capture/general autofill/passkeys incomplete |
| Blocking/privacy | Filtering/exceptions/filter management, private isolation, permissions/site data | Starter domain list and privacy services; full filtering/site-permission UI incomplete |
| Extensions | Store/local installs, MV3 workers/scripts/storage/permissions, actions/popups/options/side panels, restart/removal | Installed clipped-native hosting verifies Web Store installation, MV3 workers/scripts/storage, action popups, options, side panels, updates and removal; the complete-run shutdown/restart gate and broader API compatibility remain pending |
| Media | Codecs, picture-in-picture, local casting, protected streaming, capture permissions | Engine acceptance pending; licensed DRM/codecs and verified streaming blocked |
| Editor | Direct docking/select/resize/remove/replace/style, undo, app/per-Space setups/recovery | Rust docking, width dragging, Undo/Redo, SVG packs, styling, live preview and named setup CRUD present; native research checks verify named setup reload and retained splits. Arbitrary replacement and full accessibility acceptance remain pending |
| AI | BYOK/local, supported account OAuth, explicit selected/page sharing, summaries, reviewed organization | Selected text/page/organization/OpenAI source present; native account acceptance pending; xAI blocked |
| Arc local | Favorites/Spaces/splits, Peek/Little Arc/Boosts/Easels, archive/search | Workspace/splits/archive started; other equivalents later |
| Chrome tools | DevTools/task manager/site settings/print/PDF/save page/local translation/reading/accessibility/shortcuts | Reader/capture retained; complete tool surfaces require implementation/acceptance |
| Opera local | Sidebar web apps/workspaces/tab islands/search/pinboards/snapshot annotation/media controls | Basic workspaces/panels/capture; broader equivalents later |
| GX | Enforced CPU/RAM/network limits, hot tabs, media/music, sounds/shaders/mods/customization | Monitoring retained; enforcement and GX equivalents unimplemented |
| Distribution | One offline ARM installer, signing/notarization/trust/payload closure/clean-Mac setup | ARM development DMGs built; installed WebKit copy/launch/quit/removal pass; full Blink, consumer trust and clean-Mac core acceptance pending |

Before declaring core complete, resolve daily-use gaps, pass native/installed acceptance, verify extensions, and demonstrate protected streaming. Stubs, hidden stock controls, untested logins, and historical receipts do not satisfy gates.

Cloud sync/storage, VPN, and a Neutrino store are excluded. Optional AI services and extension downloads are allowed.
