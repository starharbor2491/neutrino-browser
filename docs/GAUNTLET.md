# Interface rebuild gauntlet

Owner constraint: one implementer; independent code, UI and UX critics only. The application icon is owned by another agent and is outside this change.

Reference: Arc for macOS, its published interface and documented tab/Space workflows. Compare actual rendered output at matched window sizes, with labels removed where practical. A source review is not a visual pass. A screenshot is not an interaction pass. No score inflation or fixed number of rounds: record the largest remaining gap, fix it, and resubmit.

Method adapted from [Gauntlet Loop](https://github.com/robonuggets/gauntlet-loop), by Jay E / RoboNuggets (CC BY 4.0), based on Matt Shumer's builder/critic technique. Use [REA](https://github.com/morluto/rea) for shipped-artifact/runtime evidence; use ordinary source tools for this repository.

## Design constraints

- [Arc](https://arc.net/): page-first composition, a coherent sidebar, persistent pins and folders, quick keyboard navigation, guided personal setup.
- [Laws of UX](https://lawsofux.com/): familiar browser shortcuts (Jakob), progressive decisions (Hick), reachable targets (Fitts), visible immediate feedback (Doherty), spatial grouping (proximity/common region).
- [Material Design](https://m3.material.io/components/buttons/overview): consistent action hierarchy and hover/focus/pressed/disabled states.
- [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop): direct manipulation, native window behavior, keyboard/VoiceOver alternatives, reduced motion, and meaningful drag previews/drop feedback.
- [IBM Carbon](https://www.carbondesignsystem.com/building-blocks/core/patterns/empty-states): purposeful empty states, explicit labels and recovery, no decorative controls without actions.

## Evidence required

1. Real shell, populated workspace, setup, editor, settings, and command palette at narrow/wide sizes and light/dark appearances.
2. Pointer and keyboard tab reordering; folder/pin/Space moves; sidebar resize; docking with insertion feedback; cancellation and undo.
3. Setup Back/Continue, defaults, validation, optional import/AI, interrupted-save retry, first successful navigation.
4. Engine focus/geometry, split panes, popups, private/profile isolation, shared live documents, normal save/quit/relaunch.
5. Rust reducer/FFI tests, adversarial bridge messages, escaped untrusted titles, and no remote navigation or credential leakage into the privileged shell.
6. Mac compiled-app acceptance and independent final critic findings tied to source and binary identity.

Baseline: `327af19`. Initial critiques are independent and read-only. Audit findings and review evidence will be recorded as the loop progresses. Arc-equivalent acceptance remains unverified until the critics inspect real comparable evidence.
