import Foundation

struct ManualSearchResult: Identifiable, Sendable {
    var id: String { page.id }
    let page: ManualPage
    let reason: String
    let rank: Int
}

/// Small, explicit task vocabulary supplements literal descriptions; it does not invent documentation.
func manualKeywords(name: String) -> String {
    switch name.lowercased() {
    case "networksetup", "ifconfig", "netstat", "route", "scutil", "networkquality", "arp", "ping", "traceroute", "tcpdump":
        return "network networking connection connectivity"
    case "ps", "top", "pgrep", "kill", "launchctl", "launchd": return "process processes running services"
    case "find", "du", "df", "ls", "diskutil": return "files filesystem storage disk large files"
    default: return ""
    }
}

func rankedManuals(pages: [ManualPage], query: String, section: String?, root: String?, fullText: Set<String>) -> [ManualSearchResult] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let tokens = term.split(whereSeparator: \.isWhitespace).map(String.init)
    return pages.compactMap { page -> ManualSearchResult? in
        guard section == nil || page.section == section, root == nil || page.root.path == root else { return nil }
        let name = page.name.lowercased()
        if term.isEmpty { return ManualSearchResult(page: page, reason: "", rank: 0) }
        if name == term || page.title.lowercased() == term { return ManualSearchResult(page: page, reason: "Exact name", rank: 0) }
        if name.hasPrefix(term) { return ManualSearchResult(page: page, reason: "Name prefix", rank: 1) }
        if name.contains(term) { return ManualSearchResult(page: page, reason: "Name", rank: 2) }
        let description = page.description.lowercased()
        if tokens.allSatisfy({ description.contains($0) }) { return ManualSearchResult(page: page, reason: "Description", rank: 3) }
        let keywords = manualKeywords(name: name)
        if tokens.allSatisfy({ (keywords + " " + description).contains($0) }) { return ManualSearchResult(page: page, reason: "Related concept", rank: 4) }
        if term.count >= 4 && abs(name.count - term.count) <= 1 && editDistanceOne(name, term) {
            return ManualSearchResult(page: page, reason: "Similar spelling", rank: 5)
        }
        if page.indexed && fullText.contains(page.id) { return ManualSearchResult(page: page, reason: "Full text", rank: 6) }
        return nil
    }.sorted { left, right in
        if left.rank != right.rank { return left.rank < right.rank }
        if left.page.name != right.page.name { return left.page.name.localizedStandardCompare(right.page.name) == .orderedAscending }
        if left.page.section != right.page.section { return left.page.section.localizedStandardCompare(right.page.section) == .orderedAscending }
        return left.page.id < right.page.id
    }
}

func editDistanceOne(_ left: String, _ right: String) -> Bool {
    let a = Array(left), b = Array(right)
    var i = 0, j = 0, edits = 0
    while i < a.count && j < b.count {
        if a[i] == b[j] { i += 1; j += 1; continue }
        edits += 1
        if edits > 1 { return false }
        if a.count >= b.count { i += 1 }
        if b.count >= a.count { j += 1 }
    }
    return edits + (a.count - i) + (b.count - j) <= 1
}
