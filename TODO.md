# ManPagesCatalog implementation priorities

This is the single implementation backlog. Runtime behavior and operating limits are documented in [README](README.md); repository comparisons remain in [Workflow research](docs/Workflow-research.md). Checked items require implementation and verification, not just a successful build.

## Verified foundation

- [x] Native manual discovery, semantic HTML reading, separate command search and page Find, PDF export, attributed command drafts and explicit optional PTY execution. Verification: real installed-manual, WebKit, PDFKit and PTY integration tests; prior packaged-app validation.
- [x] Preserve prior catalog entries across failed/cancelled scans; guard stale asynchronous results; retain aliases, languages and distinct content identities. Verification: real hidden bundle, localized, duplicate, alias, compressed and missing-root integration cases.
- [x] Durable scan checkpoints with exact pending paths, periodic partial publication, same-boot resume and stale-write protection. Acceptance: resumed installed-manual traversal has the same identities, locations and file count as a fresh scan; reopening retains partial results without starting a different scan. Verification: DiscoveryIntegrationTests.testDurablePauseResumeAndStaleCheckpointIsolation.
- [x] Recognize renamed gzip/bzip2 containers by signatures. Acceptance: real launchctl source compressed under nonstandard filenames is discovered and described. Verification: gzip and bzip2 integration cases; historical compress signature path shares the system gzip decoder, but live .Z corpus verification remains below.

- [x] Scan cards, explicit discovery/indexing phases, visible Scan & Sources and Find actions, clearer source/language/version details, separate pause/resume/index controls and app appearance preference. Verification: extracted universal app, fresh isolated catalog, selected hidden bundle, active-scan search/read retention, Find previous/next, 12-page PDF export, Light/Dark rendering and same-boot relaunch/resume. Full keyboard/VoiceOver and minimum-window audit remain in P2.

## Implemented, validation still incomplete

- [ ] Whole-local-volume traversal, per-location coverage and resumable checkpoints at machine scale. Acceptance: complete a real Deep Scan, account for every queued location and explain all inaccessible/excluded/failed/unsupported paths; no complete-machine claim based only on traversal completion. Verification: exported coverage plus retained checkpoint and a subsequent resumed scan. A bounded integration corpus is not whole-machine verification.
- [ ] Cloud-placeholder exclusion and explicit network-folder opt-in. Acceptance: an offline cloud placeholder is not hydrated and an unselected mounted network share is not read; explicit selection includes only its authorized subtree. Verification: controlled real File Provider and mounted-share cases without changing security settings. Metadata guards are implemented; live provider/network behavior is unverified.
- [ ] macOS 13+ and Intel deployment support. Acceptance: extracted application discovers, reads and exports on the oldest supported OS and Intel hardware without checkout/tools installed by a developer. Verification: clean-machine matrix; universal compilation alone is insufficient.

## P0 — next coherent milestone: finish and harden resumable discovery

Dependencies: verified checkpoint foundation above. Keep the native reader and PDF export; do not add unrelated features.

- [ ] Complete a resumable whole-filesystem measurement. Outcome: measured coverage for all accessible local mounted volumes. Acceptance: no pending paths, all skipped paths classified, duplicates explained, filesystem changes between start/resume clearly scoped. Verification: real long scan, pause/relaunch/resume, exported report; preserve the current session checkpoint until measured.
- [ ] Bound checkpoint, inventory and search costs on large libraries. Outcome: smooth reading/search during multi-million-file scans. Acceptance: measured memory/disk use and search latency; main-actor inventory serialization does not freeze UI; partial-result sorting and coverage rendering stay bounded. Verification: Instruments/signposts and a large real corpus, including cancellation during checkpoint writes and low-disk/write failures. Current snapshots are atomic JSON, not a transactional change journal.
- [ ] Reconcile directory aliases without redundant traversal. Outcome: retain alternate directory-symlink paths for discovered manuals while visiting physical directories once. Acceptance: every encountered alias location is represented or explicitly linked to its canonical coverage record; cycles terminate. Verification: real man-root symlinks and an isolated cyclic tree. Current directory aliases are recorded as exclusions; file aliases are preserved.
- [ ] Strengthen recovery across filesystem change, remount and reboot. Outcome: resume safely or restart only affected work. Acceptance: changed volume identity and directory contents cannot be mistaken for previously covered data; interrupted indexing resumes from durable metadata. Verification: controlled mounted-volume/reboot tests. Current checkpoints deliberately require the same boot and a stable clock; fresh scans reconcile already visited folders.

## P1 — broaden verified input support

Depends on P0 coverage data to prioritize observed gaps.

- [ ] Safe embedded `.so` includes. Outcome: read/index/export the installed zshall aggregate (14 includes) with per-include provenance. Acceptance: validate permissions, network consent, materialization, cycles, depth and expanded size for every target; include changes invalidate fingerprints; `.mso` and conditional/macro-generated includes are never silently misinterpreted. Verification: real zshall plus bounded include-chain/cycle cases. Whole-file aliases already work; embedded includes currently report unsupported.
- [ ] Additional compression using the smallest supported runtime. Outcome: decode XZ/LZMA/Zstandard/LZ4/lzip where a reliable native/system or bundled dependency is justified. Acceptance: validate container contents, cancellation and decompression limits; include licenses/resources and test extracted packaging. Verification: real compressed manuals, renamed containers, corrupt input and oversized expansion. Current signatures identify unsupported containers but do not decode them; archives are not traversed. Evaluate available SDK/system APIs before adding a dependency.
- [ ] Preformatted cat pages and unusual headers. Outcome: display validated preformatted manuals with an explicit format label and usable metadata. Acceptance: distinguish formatted text from arbitrary numbered files, handle overstrike/ANSI safely, preserve native reading and PDF export semantics, and identify uncertain names/languages. Verification: installed cat-page corpus or pages generated from real installed manuals. Headerless nonstandard filenames and headers after the initial 64 KiB currently remain discovery gaps.
- [ ] Formatter compatibility and actionable diagnostics. Outcome: resolve observed sudoers/table/macro failures and make formatting issues reachable from the selected manual. Acceptance: readable HTML, searchable text and export agree, or each operation explains its own limitation without silently substituting incomplete output. Verification: affected installed sources and source-to-rendered comparison.
- [ ] Verify live legacy `.Z` decoding. Outcome: evidence for the implemented signature/system-gzip path. Acceptance: real compressed manual yields the same fingerprint, description and rendered text as its uncompressed source. Verification: installed .Z corpus or system compress output from a real manual.

## P2 — accessibility, polish and provenance

Depends on stable discovery and reader behavior.

- [ ] Complete keyboard/VoiceOver audit. Outcome: coherent focus order, useful status announcements, labeled matches and readable terminal accessibility. Acceptance: scan, filter, select, read, Find, source details, export and pause/resume work without a pointer; no disruptive progress announcements. Verification: manual VoiceOver session and stable-ID UI automation. Native controls/IDs and keyboard shortcuts are implemented; this is not accessibility certification.
- [ ] Compact-window and appearance audit. Outcome: all primary reader controls remain reachable at minimum width and large text in Light, Dark and System. Acceptance: no clipped actions, adequate contrast and persistent reading state when appearance changes. Verification: rendered screenshots and resize/zoom checks on supported OS versions.
- [ ] More explicit version and language provenance. Outcome: understandable installed-package/version context without claiming an executable matches a manual. Acceptance: unknown language remains unknown, aliases and distinct content versions are distinguishable, exact manual path and independently verified executable path stay separate. Verification: SDK/Homebrew/localized duplicates and commands absent from PATH.

## P3 — packaging and release readiness

Depends on P0/P1 reliability and P2 accessibility checks.

- [ ] Repeat standalone runtime verification on clean supported hosts. Acceptance: extracted app needs no source checkout, existing catalog, Python or package-manager runtime; every required system tool has a clear missing-tool error; SwiftTerm resources/license are present. Verification: clean-host launch/search/read/Find/export/PTY matrix.
- [ ] Signed, notarized distribution and release automation. Acceptance: Developer ID/hardened runtime/notarization/stapling verified with normal Gatekeeper behavior, correct architecture/resources, no private catalogs/checkpoints/logs included. Verification: inspect final ZIP and test normal first launch. Requires release credentials and explicit publication authorization; local builds are ad-hoc signed only.
- [ ] Verify published release downloads against the validated source. Acceptance: release download instructions point to the actual validated version and checksums. Verification: download and inspect the published artifact after release authorization. The tracked local app ZIP includes the current branding; publishing or replacing GitHub release assets remains separate work.
