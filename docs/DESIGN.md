# Neutrino interface

The default uses charcoal surfaces, violet selection, a compact sidebar, persistent pins/folders, and a framed page area. Arc informs the composition and keyboard flow; Vivaldi/Shift inform customization, and Helium/Safari inform restraint. The supplied Neutrino SVG is used unchanged.

Rust renders custom buttons, segmented choices, switches, menus, tab rows, the command palette, setup, settings, and the editor. Native file pickers, Keychain, default-browser approval, and website permission dialogs retain macOS behavior. See [the implementation boundary](RUST_ARCHITECTURE.md).

## Organization

Spaces own tab organization; Profiles independently own website identity and engine data. Multiple Spaces can use one Profile. Each Space can retain an appearance separate from the browser default.

Tabs share organization across windows, with one owner for each live document. Selecting a tab elsewhere transfers its view; Duplicate creates a separate tab. Drag tabs to reorder, pin, file into folders, or move to another Space using the same Profile. Menus and keyboard commands provide alternatives. Normal tabs restore, and optional auto-archiving remains recoverable. Private browsing does not persist website/session records.

## Setup

Seven screens cover welcome, Profile/Space naming, optional HTML bookmarks import, appearance/layout, search/privacy, optional AI, and final review/default-browser selection. Defaults keep required decisions short; no import file or AI credential is required. Back preserves entered choices. Inline validation focuses the missing field. Browsing begins only after setup is saved, and a failed save keeps the wizard available for retry.

## Editing

The component palette and live layout preview expose tabs, navigation, and Library docking. Tabs support every edge; navigation supports top/bottom; Library supports either side. Drag a component to a highlighted valid edge or use labeled position controls. Sidebar width, accent, light/dark/system appearance, and density are editable. The active page remains mounted in its original engine while its frame follows the draft; interactions with that page are paused during editing. Save applies the draft to this Space or the browser default. Undo, Redo, Cancel, reset, and save/discard before leaving remain reachable.

The live sidebar can be resized with its handle or arrow keys. Tab moves retain their live pages and offer Undo. Site identity and recovery controls remain reachable in supported layouts. Type, spacing, corner radius, colors, density, SVG icon pack/stroke, panel width, and bookmarks bar update the rendered preview. Named setups can be loaded, renamed, replaced, and deleted. Rejected saves keep the draft until the native adapter acknowledges success. Arbitrary component replacement/removal and additional advanced styling remain product work.

## Design rules and review

[Laws of UX](https://lawsofux.com/) guide familiar shortcuts, grouped choices, reachable targets, and immediate feedback. [Material](https://m3.material.io/) informs consistent action hierarchy and control states. [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/) informs window behavior, drag/drop, keyboard access and reduced motion. [Carbon](https://carbondesignsystem.com/) informs labels, empty states, validation and recovery. These are principles, not competing default component libraries.

The [gauntlet record](GAUNTLET.md) separates source, browser-harness, native-image, and interaction evidence. Arc remains the reference. A screenshot cannot establish interaction quality; a portable test cannot establish macOS behavior. Retained storage, modules/workers, privacy, downloads, reader/capture, recovery, and update services remain subject to their own tests.

## Violet default

The default is Graphite/Dark with violet accents drawn from the supplied icon. Neutral surfaces, 6px control corners, concise labels and explicit action hierarchy replace the former cream/serif presentation. The sidebar edits the current address inline. ⌘T opens the destination command bar without creating a blank tab; ⌘K searches tabs and commands. Library, modules and ordinary settings remain direct surfaces. Motion acknowledges selection, setup steps, opening surfaces and dragging, and respects both macOS and app reduced-motion preferences. Optional workspace widgets live in the sidebar instead of a new-tab page.

Modules are directly accessible from the sidebar and Settings. Installed providers project validated settings, menus, path-only SVG icon packs, workspace widgets, theme/layout/tab definitions and removable feature workers. Resources and Focus have visible entry/recovery paths. Theme component scales, densities and corners apply to the Rust shell while site identity, permission confirmations and recovery remain protected.

## Research and familiar layouts

The first setup screen offers Neutrino, Arc, Chrome, Safari, Brave, and Opera GX inspired configurations. Presets set real tab/navigation placement, color mode, density, accent, icons and optional monitor/bookmark surfaces. They ease transition without claiming affiliation or exact feature parity.

Research notes retain the selected quotation, source address/title, source tab identity, and project Space. Open source locates the original document across the same Profile's Spaces before URL fallback. The project note stays in its original Space even if its live source moves. Notes can be filtered by title, source and Space, and newest captures appear first. At narrow window widths, opening a research panel hides the tab rail; Return to tabs restores it.

The editor preview responds to its own canvas width. A narrow preview temporarily hides a vertical rail when a panel is open so the page remains visible. Selection overlays follow only visible components; tabs, navigation, and the Library panel support pointer dragging and keyboard activation.
