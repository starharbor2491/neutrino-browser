# Neutrino interface

The intended default feels like Arc: a quiet lavender canvas, vertical workspace rail, persistent pinned/folder tabs, and a rounded page area with room to breathe. Vivaldi/Shift inform customization; Helium/Safari inform restraint. Familiar keyboard shortcuts and macOS window behavior remain useful.

The shell uses shared Neutrino button, choice-card, icon, surface, and typography components. Native file pickers, Keychain, system default-browser approval, and website permission dialogs retain their system behavior. These choices are not a claim of completed visual or accessibility acceptance.

## Organization

Spaces own tab organization and optional named setups. Profiles independently own website identity and engine data. Several Spaces may use one Profile. The app has a default setup; individual Spaces may select a named setup.

Tabs are shared across windows, but each live document appears in one window/pane at a time. Selecting it elsewhere moves its original view; Duplicate creates a separate tab. Regular tabs restore by default, pinned/folder tabs persist, and optional archiving is recoverable. Private browsing does not persist website/session records.

## Setup

An eight-stage first-run flow covers welcome, Profile/Space naming, optional bookmarks import, layout/theme, search/privacy, features, optional AI, and final review/default-browser selection. Browsing begins after completion. Import currently accepts HTML bookmarks; other data import needs implementation and verification.

## Editing

Edit mode has a component palette, docking preview, and inspector. Tabs dock on any edge; navigation docks top/bottom; panels dock beside the page. Selection, drag/drop, tab width, density, colors, corners, removal, undo, and reset are present. Advanced controls preserve detailed styles and setup import/export.

Advanced editing returns changes to the parent draft. Cancel exits without applying that draft. Live preview has stable ownership and does not create browsing tabs. Save reviews actual module requirements and can assign a named setup to the current Space.

Site identity, permission confirmations, and exit/reset/recovery must stay reachable. Future replacement/custom components must uphold those functions.

## Review gates

Run the app on macOS before judging completion. Review every default screen at multiple window sizes and in light/dark modes; check keyboard focus, VoiceOver names, contrast, hit targets, reduced motion/transparency, and interaction feedback. Verify docking regions and per-Space previews match the actual browser. Source syntax and conceptual previews are insufficient visual evidence.

Retained services include storage, profile cleanup, privacy, downloads, modules/workers, reader, recovery, and trusted distribution. [PARITY.md](PARITY.md) identifies remaining product work; [PRODUCT_PLAN.md](PRODUCT_PLAN.md) is the accepted brief.
