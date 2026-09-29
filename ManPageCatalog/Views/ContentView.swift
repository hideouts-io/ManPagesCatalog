import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var reader: ManualReader
    @EnvironmentObject var terminal: TerminalSession
    @Environment(\.openWindow) private var openWindow
    @State private var selectedID: String?
    @State private var linkMessage = ""
    @State private var pendingReference: (name: String, section: String)?
    @State private var searchFocusRequest = UUID()

    var body: some View {
        NavigationSplitView {
            List(selection: $library.section) {
                Label("All Manuals", systemImage: "books.vertical").tag(Optional<String>.none).accessibilityIdentifier("sectionAll")
                Section("MANUAL SECTIONS") {
                    ForEach(library.sections, id: \.self) { section in
                        Text(sectionLabel(section)).tag(Optional(section)).accessibilityIdentifier("section-\(section)")
                    }
                }
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Button { openWindow(id: "sources") } label: { Label("Sources & Index", systemImage: "externaldrive") }
                        .accessibilityIdentifier("showSources")
                    Text("\(library.pages.count) manuals\n\(library.indexedCount) indexed manuals")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        } content: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(library.section.map { "Section \($0)" } ?? "All sections").font(.headline).accessibilityIdentifier("searchScope")
                        Spacer()
                        if library.section != nil || library.root != nil {
                            Button("Search All") { library.searchAll(); searchFocusRequest = UUID() }.accessibilityIdentifier("searchAll")
                        }
                    }
                    Picker("Source", selection: $library.root) {
                        Text("All sources").tag(Optional<String>.none)
                        ForEach(library.coverage) { source in Text(source.root.path).tag(Optional(source.root.path)) }
                    }.labelsHidden().accessibilityLabel("Source filter").accessibilityIdentifier("sourceFilter")
                    Toggle("Include full text", isOn: $library.fullText).toggleStyle(.checkbox).accessibilityIdentifier("fullTextSearch")
                    if library.fullText { Text("Covers \(library.indexedCount) of \(library.pages.count) indexed manuals").font(.caption).foregroundStyle(.secondary) }
                    Text("\(library.results.count) results").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("resultCount")
                }.padding(12).background(.bar)
                Divider()
                List(Array(library.results.prefix(1000)), selection: $selectedID) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.page.title).font(.system(.body, design: .monospaced)).fontWeight(.semibold)
                        Text(result.page.description.isEmpty ? (result.page.problem != nil ? "Description unavailable — see Sources" : result.page.indexed ? "No description in this manual" : "Description not indexed yet") : result.page.description)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        HStack {
                            Text(result.page.root.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(result.reason)
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(result.page.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("result-\(result.page.source.path)")
                }.accessibilityIdentifier("searchResults")
                .overlay {
                    if library.results.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                            Text(library.isIndexing && library.pages.isEmpty ? "Discovering manuals…" : library.errorMessage != nil && library.pages.isEmpty ? "Library unavailable" : library.pages.isEmpty ? "No manuals discovered" : "No matching manuals").font(.headline)
                            Text("Try a command name, network, or processes.").font(.caption).foregroundStyle(.secondary)
                            Button("Search All Sources & Sections") { library.searchAll(); searchFocusRequest = UUID() }.accessibilityIdentifier("emptySearchAll")
                            if library.pages.isEmpty { Button("Review Sources") { openWindow(id: "sources") }.accessibilityIdentifier("emptyReviewSources") }
                        }.padding().multilineTextAlignment(.center)
                    }
                }
                if library.results.count > 1000 { Text("First 1,000 results shown. Refine your search to see more.").font(.caption).padding(8) }
            }.navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 430)
        } detail: {
            VStack(spacing: 0) {
                if !linkMessage.isEmpty { Text(linkMessage).font(.caption).padding(8).accessibilityIdentifier("referenceStatus") }
                VStack(spacing: 0) {
                    ManualDetailView(reader: reader).frame(minHeight: 220, maxHeight: .infinity)
                    if terminal.expanded {
                        Divider()
                        TerminalPane(session: terminal).frame(height: terminal.view == nil ? 320 : 460)
                    }
                }
            }
        }
        .navigationTitle("Man Page Catalog")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { Task { if let context = await reader.back() { restore(context) } } } label: { Image(systemName: "chevron.left") }
                    .disabled(!reader.canBack || reader.loading).help("Back (⌘[)").accessibilityIdentifier("navBack").keyboardShortcut("[", modifiers: .command)
                Button { Task { if let context = await reader.forward() { restore(context) } } } label: { Image(systemName: "chevron.right") }
                    .disabled(!reader.canForward || reader.loading).help("Forward (⌘])").accessibilityIdentifier("navForward").keyboardShortcut("]", modifiers: .command)
            }
            ToolbarItem {
                GlobalSearchField(text: $library.query, focusRequest: searchFocusRequest) {
                    Task { if let page = await library.firstResultForCurrentSearch() { open(page) } }
                }.frame(minWidth: 240, idealWidth: 320, maxWidth: 420)
            }
            ToolbarItem {
                Button { terminal.expanded.toggle() } label: {
                    Label(terminal.active ? "Terminal • Running" : "Commands", systemImage: "terminal")
                }.accessibilityIdentifier("toggleTerminalPane").keyboardShortcut("j", modifiers: .command)
            }
            ToolbarItem {
                Button { openWindow(id: "sources") } label: { Label(library.isIndexing ? "Indexing…" : "Sources", systemImage: library.isIndexing ? "arrow.triangle.2.circlepath" : "externaldrive") }
                    .accessibilityIdentifier("manageSources")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(library.errorMessage ?? library.status).lineLimit(2).textSelection(.enabled).accessibilityIdentifier("libraryStatus")
                Spacer()
                if library.isIndexing { Button("Stop") { library.stop() }.accessibilityIdentifier("stopIndexing") }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6).background(.bar)
        }
        .task {
            reader.onReference = { name, section in followReference(name: name, section: section) }
            library.scan()
        }
        .onChange(of: selectedID) { id in if let page = library.pages.first(where: { $0.id == id }) { open(page) } }
        .onChange(of: library.pages.count) { count in
            if count > 0, let reference = pendingReference {
                pendingReference = nil
                followReference(name: reference.name, section: reference.section)
            }
        }
        .onChange(of: library.isIndexing) { indexing in
            if !indexing, let reference = pendingReference {
                pendingReference = nil
                followReference(name: reference.name, section: reference.section)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchCommands)) { _ in
            library.searchAll()
            searchFocusRequest = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadCatalog)) { _ in library.scan() }
        .onDisappear { terminal.stop() }
        .onOpenURL { url in
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), url.scheme == "manpagescatalog" else { return }
            if let name = parts.queryItems?.first(where: { $0.name == "name" })?.value,
               let section = parts.queryItems?.first(where: { $0.name == "section" })?.value { followReference(name: name, section: section) }
            else { library.searchAll(); library.query = parts.queryItems?.first(where: { $0.name == "query" })?.value ?? url.host ?? ""; searchFocusRequest = UUID() }
        }
        .frame(minWidth: 1060, minHeight: terminal.expanded ? 820 : 650)
    }

    private func open(_ page: ManualPage) {
        linkMessage = ""
        let context = BrowseContext(query: library.query, section: library.section, root: library.root, fullText: library.fullText)
        Task { await reader.open(page: page, context: context) }
    }

    private func followReference(name: String, section: String) {
        if library.pages.isEmpty && library.isIndexing {
            pendingReference = (name, section)
            linkMessage = "Discovering sources for \(name)(\(section))…"
            return
        }
        if let page = library.reference(name: name, section: section, preferredRoot: reader.page?.root) { open(page) }
        else {
            library.searchAll()
            library.query = name
            linkMessage = "\(name)(\(section)) is not in the current library. Search remains available; review Sources to add documentation."
        }
    }

    private func restore(_ context: BrowseContext) {
        library.query = context.query; library.section = context.section; library.root = context.root; library.fullText = context.fullText
        linkMessage = ""
    }
}
