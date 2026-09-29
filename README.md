# Man Page Catalog

A native Swift/SwiftUI browser for installed macOS manual pages. Search command names and descriptions, read the original documentation as semantic HTML, follow references, and export individual manuals as PDF. The application needs no Python, Homebrew, groff, or Ghostscript runtime.

The ZIP at the repository root is an older artifact and does not represent the current source. Build the current application using the instructions below. Local builds are ad-hoc signed, not notarized distribution releases; no security settings or quarantine attributes need to be changed to build and test them locally.

## Browse and search

- **Command-K** focuses global search and clears section/source restrictions. Search remains available while reading; typing does not replace the open document.
- Filter by descriptive manual section and source directory. Exact names rank before partial names, descriptions, curated topic matches, similar spellings, and full-text matches. Try `network` or `processes` to discover related installed commands.
- **Include full text** searches the indexed original documentation using SQLite FTS5. The displayed count identifies current indexing coverage. Names are available before background indexing finishes; the first 1,000 results are shown with a prompt to refine broad searches.
- **Command-F** opens separate in-page Find. **Command-G / Shift-Command-G** navigate highlighted matches. Contents, adjustable text, selectable examples, and linked manual references are available in the reader.
- Back/Forward (**Command-[ / Command-]**) restore the prior manual, search filters, reading position, text size, and Find query within the current session. Ordinary view updates keep the existing WebKit document and selection.
- **Source & paths** identifies the original file, collection, and an executable found on PATH. A matching executable name does not establish that the manual describes that version.
- **Copy & Open Terminal** copies a quoted command name and opens Terminal. Paste and execute it yourself. This external-terminal action never inserts or executes text; selected examples have a separate copy action.
- **Export PDF** opens a native Save dialog and generates a paginated, selectable PDF from the original source using the system formatter. It does not bulk-generate PDFs. Formatting errors are reported explicitly; a failed export leaves an existing destination unchanged.

## Prepare and run, optionally

**Prepare → Prepare Command Name / Prepare Selected Example** opens an editable draft with its original manual path. It never starts a process. Replace placeholders and copied shell prompts, check quotes and all lines, choose the working folder, then mark the draft reviewed. Every edit or folder change clears review. Common placeholder/control-character notation blocks Run; this is not a shell safety analyzer and cannot recognize every placeholder or predict command effects. Multiline drafts run exactly as entered through `/bin/zsh -f -c`.

**Run Draft** explicitly starts a fresh PTY session. **Start Interactive Shell** starts `/bin/zsh -f -i` for ordinary typing, Ctrl-C, Unicode, selection, copy/paste and scrolling. These clean zsh sessions skip user startup files; aliases and custom shell configuration are not imported. They inherit the app's PATH. End the current session before running another draft; drafts are never injected into an existing prompt or foreground program.

**Command-J** shows or hides the workspace without discarding the manual or stopping a running session. **End Session** confirms stopping its shell and attached jobs; closing the browser also stops them, and quitting asks before ending an active session. Cleanup sends hangup and then kills remaining processes in that PTY's session. Programs deliberately detached into another session, services launched through launchd, and effects already performed by commands are outside this cleanup boundary.

Commands run on the actual Mac as the current user, **not in an isolated practice environment**. The app never adds sudo. It displays the shell and starting directory, not an unverified current directory; use `pwd` after changing folders. PATH-name resolution is documentation context, not proof of the executable or version used by an edited script.

Drafts and terminal scrollback stay in memory. The app does not record terminal sessions or credentials; its clean shell uses no history file. Programs you run can still write their own files or logs. Clipboard escape requests and terminal output links do not trigger app actions. **Copy Draft**, **Copy Command Name**, and **Copy & Open Terminal** remain available.

## Sources and coverage

The application uses `/usr/bin/manpath`, conventional system/Homebrew/MacPorts/user roots that exist, and folders added through **Sources & Index**. The system manpath normally includes the selected Xcode/Command Line Tools documentation. Other SDKs and tool collections can be added explicitly. Discovery covers manual-section directories and one locale directory level; it does not recursively search every file on the computer.

Duplicate manuals remain distinct by source path. Plain files, symlinks, gzip, Unix compress (`.Z`), bzip2, and whole-file `.so` aliases are supported. Alias targets can be compressed. XZ sources are listed with an explicit unsupported-format issue. Cycles, missing files, inaccessible directories, parser failures, and index errors are surfaced rather than converted into empty descriptions. Usable HTML with formatter diagnostics displays a visible notice; PDF export requires an error-free rendering.

**Command-R** refreshes sources and changed metadata. Background indexing can be stopped. Source fingerprints reuse cached metadata for unchanged plain files; compressed sources and aliases are refreshed to account for their indirect dependencies. Refresh does not generate PDFs. This version uses explicit refresh, not continuous filesystem monitoring.

The app-owned SQLite index lives at `~/Library/Application Support/ManPagesCatalog/search.sqlite`. Original manuals and existing `~/ManPages` PDF catalogs are not modified. The historical Python implementation remains in `manpage_pdf_catalog/` as a comparison baseline and is not included in the application bundle.

## Build and test

Targets macOS 13+. The current build is verified with Xcode 27; older Xcode versions and macOS versions require validation (the app uses Swift 5 language mode). SwiftPM pins SwiftTerm 1.18.0 and records resolved packages. On Xcode installations with separately delivered Metal tools, run `xcodebuild -downloadComponent MetalToolchain` before building the terminal shader resource. Use the checked-in Xcode project; XcodeGen is needed only when regenerating it after changing `project.yml`.

```sh
xcodebuild -project ManPageCatalog.xcodeproj -scheme ManPageCatalog \
  -configuration Debug -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' test CODE_SIGN_IDENTITY=-

xcodebuild -project ManPageCatalog.xcodeproj -scheme ManPageCatalog \
  -configuration Release -derivedDataPath build/ReleaseDerivedData \
  -destination 'generic/platform=macOS' build CODE_SIGN_IDENTITY=- \
  ONLY_ACTIVE_ARCH=NO ARCHS='arm64 x86_64'

open 'build/ReleaseDerivedData/Build/Products/Release/Man Page Catalog.app'
```

Integration tests use installed `launchctl`, `ping`, `ifconfig`, `netstat`, and `scutil` manuals plus isolated temporary collections. They additionally exercise real PTY startup, resizing, Ctrl-C, exit, foreground/background cleanup, nonexecuting preparation, explicit multiline runs and placeholder validation. They exercise extraction, gzip, aliases, duplicate sources, SQLite search, real WebKit Find/history, PDF rendering, cancellation, and legacy catalog preservation. The test host uses an empty discovery scope and a separate temporary index.

SwiftTerm is linked into the application, including its shader resource bundle and MIT license. Its package also resolves ArgumentParser for an upstream command-line target; that target is not part of this app. The remaining runtime dependencies are Apple frameworks/system SQLite and macOS-provided `/usr/bin/manpath`, `/usr/bin/mandoc`, `/usr/bin/col`, `/usr/bin/gzip`, and `/usr/bin/bzip2`. Tools run directly with bounded concurrency, UTF-8 output, deadlines, and cancellation; no shell evaluates document content. A missing tool produces an actionable failure. Supporting a macOS version in the deployment target does not replace testing on that version and architecture.

For repository strategy, primary-source comparisons, license decisions and ranked opportunities, see [Workflow research](docs/Workflow-research.md).

## Design references

- [Apple WebKit](https://developer.apple.com/documentation/webkit/wkwebview) supplies accessible semantic reading and native Find; [mandoc](https://mandoc.bsd.lv/man/mandoc.1.html) preserves roff/man/mdoc semantics without a new parser. PDF uses mandoc's paginated output instead of a webpage screenshot.
- [SQLite FTS5](https://sqlite.org/fts5.html) supplies an offline index through the system library. SwiftUI provides the native layout; AppKit provides save panels, the clipboard, and application launching.
- [ManOpen](https://github.com/nickzman/ManOpen) informed local discovery and references; [Qman](https://github.com/plp13/qman) informed outline and navigation; [Zeal](https://zealdocs.org/usage.html) and [DevDocs](https://github.com/freeCodeCamp/devdocs) informed persistent search and offline reading. These are design influences; no source code or assets were copied. No comparative performance or superiority claim is made.
- [Terminal's scripting documentation](https://support.apple.com/en-by/guide/terminal/trml1003/mac) and the installed Terminal scripting dictionary were inspected. `do script` executes text, so the app uses an explicit clipboard-and-open workflow.
- [Core Spotlight](https://developer.apple.com/documentation/corespotlight), [App Intents](https://developer.apple.com/documentation/appintents), and [FSEvents](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) were evaluated. They are deferred to keep this version focused on local discovery and reading. The app supports `manpagescatalog://open?name=launchctl&section=1` and `manpagescatalog://search?query=network`; Services, Shortcuts, global Spotlight indexing, persistent history, and continuous source monitoring are not implemented.
