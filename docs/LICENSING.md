# Licensing

The initial repository's LICENSE is MIT and is retained unchanged.

New Neutrino-authored implementation source in Sources, Tests, Resources, crates, Package.swift, and scripts is licensed under MPL-2.0, identified with SPDX headers where the file format permits comments. The full text is in COPYING.MPL. This does not retroactively relicense the original repository content.

The upstream Karpathy guidelines copied into KARPATHY_GUIDELINES.md remain under their upstream MIT license; source: https://github.com/multica-ai/andrej-karpathy-skills. They are not represented as official work authored by Andrej Karpathy.

CEF and Chromium binaries are not vendored in the source repository. The optional development builder downloads pinned upstream archives and embeds the runtime in the Chromium application variant. CEF/Chromium retain their own licenses; the package copies the upstream license notices into its Legal resources. The complete Apple Silicon installer includes CEF; explicitly WebKit-only development builds contain no CEF runtime. Apple frameworks are operating-system dependencies and are not part of Neutrino's open-source distribution.

No trademark rights are granted by the code license.

The review method adapts [Gauntlet Loop](https://github.com/robonuggets/gauntlet-loop) by Jay E / RoboNuggets (CC BY 4.0), based on Matt Shumer’s builder/critic technique. REA is used as a development inspection tool under its upstream MIT license and is not bundled. Rust dependencies retain their upstream licenses; their locked versions are recorded in Cargo.lock.
