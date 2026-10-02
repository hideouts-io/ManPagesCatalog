import Foundation

struct DiscoveryPlan: Codable, Sendable {
    let roots: [URL]
    let allowedNetworkRoots: [URL]
    let exclusions: [DiscoveryIssue]
}

/// MANPATH remains an explicit bounded scope. manpath itself reads the platform's man.conf files.
func systemLibraryRoots(environment: [String: String], additional: [String]) async throws -> [URL] {
    var roots = try await manualRoots(environment: environment)
    if environment["MANPATH"] == nil || environment["MANPATH"] == "" {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/usr/share/man", "/usr/local/share/man", "/opt/homebrew/share/man", "/opt/local/share/man",
                          "/Library/Apple/usr/share/man", home + "/.local/share/man", home + "/share/man", home + "/man",
                          "/Library/Developer/CommandLineTools/usr/share/man"]
        roots += candidates.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        // Inspect known SDK containers, not every developer source file, during the quick scan.
        var developers = [URL(fileURLWithPath: "/Library/Developer/CommandLineTools")]
        for appRoot in ["/Applications", home + "/Applications"] where FileManager.default.fileExists(atPath: appRoot) {
            let apps = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: appRoot), includingPropertiesForKeys: nil)
            developers += apps.filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
                .map { $0.appendingPathComponent("Contents/Developer") }
        }
        for developer in developers {
            let containers = [developer.appendingPathComponent("SDKs"), developer.appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs")]
            for container in containers where FileManager.default.fileExists(atPath: container.path) {
                for sdk in try FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: nil) where sdk.pathExtension == "sdk" {
                    let man = sdk.appendingPathComponent("usr/share/man")
                    if FileManager.default.fileExists(atPath: man.path) { roots.append(man) }
                }
            }
        }
    }
    roots += additional.map { URL(fileURLWithPath: $0) }
    var seen = Set<String>()
    return roots.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
}

func standardDiscoveryPlan(environment: [String: String], additional: [String]) async throws -> DiscoveryPlan {
    DiscoveryPlan(roots: try await systemLibraryRoots(environment: environment, additional: additional),
                  allowedNetworkRoots: additional.map { URL(fileURLWithPath: $0) }, exclusions: [])
}

func deepDiscoveryPlan(additional: [String]) throws -> DiscoveryPlan {
    guard let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: []) else {
        throw ManualToolError(message: "Cannot list mounted volumes. Add a folder explicitly and retry discovery.")
    }
    // Yield useful manuals early; the filesystem pass still visits every other accessible directory.
    var roots = ["/usr/share/man", "/opt/homebrew/share/man", "/opt/local/share/man", "/Library/Developer/CommandLineTools/usr/share/man"]
        .filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    roots.append(URL(fileURLWithPath: "/"))
    var exclusions: [DiscoveryIssue] = []
    for volume in volumes.sorted(by: { $0.path < $1.path }) where volume.path != "/" {
        do {
            guard let local = try volume.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal else {
                throw ManualToolError(message: "The filesystem did not report whether this volume is local.")
            }
            if local { roots.append(volume) }
            else { exclusions.append(DiscoveryIssue(path: volume.path, kind: .excluded, reason: "Network volume: select it explicitly to include it.")) }
        } catch { exclusions.append(discoveryIssue(url: volume, error: error)) }
    }
    // Explicit selections authorize network traversal only beneath those selected paths.
    let selected = additional.map { URL(fileURLWithPath: $0).standardizedFileURL }
    roots += selected
    var seen = Set<String>()
    return DiscoveryPlan(roots: roots.filter { seen.insert($0.path).inserted }, allowedNetworkRoots: selected,
                         exclusions: exclusions.filter { issue in !selected.contains { pathContains(root: $0.path, path: issue.path) } })
}
