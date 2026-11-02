import Foundation

enum GuidedCommandInputKind: String {
    case text, file, directory
}

enum GuidedCommandInputValidation {
    case absolutePath, diskIdentifier
}

struct GuidedCommandInput: Identifiable, Equatable {
    let id: String
    let title: String
    let placeholder: String
    let kind: GuidedCommandInputKind
    let required: Bool
    let validation: GuidedCommandInputValidation
}

struct GuidedCommandOption: Identifiable, Equatable {
    let id: String
    let flag: String
    let title: String
    let explanation: String
    let conflicts: [String]
}

struct GuidedCommandReference: Equatable {
    let manualPath: String
    let executablePath: String
    let section: String
    let compatibilityExplanation: String
}

struct GuidedCommandRecipe: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let effects: String
    let resultHelp: String
    let options: [GuidedCommandOption]
    let inputs: [GuidedCommandInput]
    let argumentsPrefix: [String]
    let reference: GuidedCommandReference
}

enum GuidedCommandError: LocalizedError {
    case unknownOption(String)
    case conflictingOptions(String, String)
    case unknownInput(String)
    case missingInput(String)
    case invalidInput(String, String)

    var errorDescription: String? {
        switch self {
        case .unknownOption(let id): return "The option \(id) is not supported by this action. Choose an option shown in the builder."
        case .conflictingOptions(let first, let second): return "Choose either \(first) or \(second); these options select different results."
        case .unknownInput(let id): return "The input \(id) is not supported by this action. Choose the action again."
        case .missingInput(let title): return "Enter \(title) before reviewing the command."
        case .invalidInput(let title, let reason): return "\(title): \(reason)"
        }
    }
}

/// Curated Apple syntax is offered only for its system executable and system manual.
/// Matching paths establishes applicability, not the installed executable's version.
func guidedCommandRecipes(name: String, executablePath: String, manualSourcePath: String) -> [GuidedCommandRecipe] {
    let supported: [(name: String, executable: String, manual: String, section: String)] = [
        ("ls", "/bin/ls", "/usr/share/man/man1/ls.1", "1"),
        ("du", "/usr/bin/du", "/usr/share/man/man1/du.1", "1"),
        ("diskutil", "/usr/sbin/diskutil", "/usr/share/man/man8/diskutil.8", "8")
    ]
    guard let match = supported.first(where: { $0.name == name && $0.executable == executablePath }),
          [match.manual, match.manual + ".gz", match.manual + ".bz2"].contains(manualSourcePath) else { return [] }
    let reference = GuidedCommandReference(manualPath: manualSourcePath, executablePath: executablePath,
        section: match.section,
        compatibilityExplanation: "Uses documented macOS syntax for this Apple system command. The manual location alone does not verify the executable's version.")
    let folder = GuidedCommandInput(id: "folder", title: "Folder", placeholder: "/absolute/path/to/folder",
        kind: .directory, required: true, validation: .absolutePath)
    switch name {
    case "ls":
        return [GuidedCommandRecipe(id: "ls.folder", title: "List files in a folder",
            summary: "Show the names of files and folders inside the folder you choose.",
            effects: "Reads folder entries and file information, following the selected folder link. Links inside it remain links. Cloud storage may download entries when the folder is accessed.",
            resultHelp: "Names are entries in your chosen folder. With Show file details, ordinary-file rows show permissions, link count, owner, group, size in bytes, modification date, and name. A leading d marks a folder; l marks a symbolic link.",
            options: [
                GuidedCommandOption(id: "hidden", flag: "-A", title: "Include hidden files",
                    explanation: "Show names beginning with a dot, excluding the special . and .. entries.", conflicts: []),
                GuidedCommandOption(id: "detailed", flag: "-l", title: "Show file details",
                    explanation: "Include permissions, owner, size, and modification date.", conflicts: []),
                GuidedCommandOption(id: "modified", flag: "-t", title: "Newest files first",
                    explanation: "Sort by modification time. Choose this or sort by size.", conflicts: ["size"]),
                GuidedCommandOption(id: "size", flag: "-S", title: "Largest files first",
                    explanation: "Sort by file size. Choose this or sort by modification time.", conflicts: ["modified"]),
                GuidedCommandOption(id: "reverse", flag: "-r", title: "Reverse the order",
                    explanation: "Reverse the chosen order: names, modification time, or size.", conflicts: [])
            ], inputs: [folder], argumentsPrefix: ["-H"], reference: reference)]
    case "du":
        return [GuidedCommandRecipe(id: "du.folder", title: "Measure a folder's disk usage",
            summary: "Read the folder's contents and report their total allocated storage.",
            effects: "Reads the selected folder and its subfolders, following a link to the selected folder but not links inside it. Large folders can take time; unreadable files produce errors. Cloud storage may download files.",
            resultHelp: "The total measures allocated storage for the chosen folder and its contents. Use readable sizes adds units such as K, M, and G based on powers of 1024. Otherwise, values count 512-byte blocks unless the BLOCKSIZE environment setting changes the unit.",
            options: [
                GuidedCommandOption(id: "readable", flag: "-h", title: "Use readable sizes",
                    explanation: "Show size units such as K, M, and G using powers of 1024. Without this, the block size follows the command's environment.", conflicts: []),
                GuidedCommandOption(id: "sameFilesystem", flag: "-x", title: "Stay on this file system",
                    explanation: "Skip folders that are mount points for other file systems.", conflicts: [])
            ], inputs: [folder], argumentsPrefix: ["-s", "-H"], reference: reference)]
    case "diskutil":
        let structured = GuidedCommandOption(id: "plist", flag: "-plist", title: "Use property list output",
            explanation: "Show structured XML instead of the usual readable report.", conflicts: [])
        return [
            GuidedCommandRecipe(id: "diskutil.list", title: "List disks",
                summary: "Show whole disks and their partitions, optionally limiting the report.",
                effects: "Reads disk metadata. Disk identifiers can change after reconnecting a device.",
                resultHelp: "The report groups partitions under whole disks. An identifier such as disk0 names a whole disk; disk0s3 names one of its partitions. Enter an identifier in Inspect one disk or partition for more detail. Property-list output provides structured data instead of the readable report.",
                options: [structured,
                    GuidedCommandOption(id: "internal", flag: "internal", title: "Internal disks only",
                        explanation: "Limit the report to internal disks. Choose this or external disks.", conflicts: ["external"]),
                    GuidedCommandOption(id: "external", flag: "external", title: "External disks only",
                        explanation: "Limit the report to external disks. Choose this or internal disks.", conflicts: ["internal"]),
                    GuidedCommandOption(id: "physical", flag: "physical", title: "Physical disks only",
                        explanation: "Limit the report to physical disks. Choose this or virtual disks.", conflicts: ["virtual"]),
                    GuidedCommandOption(id: "virtual", flag: "virtual", title: "Virtual disks only",
                        explanation: "Limit the report to virtual disks. Choose this or physical disks.", conflicts: ["physical"])
                ], inputs: [], argumentsPrefix: ["list"], reference: reference),
            GuidedCommandRecipe(id: "diskutil.info", title: "Inspect one disk or partition",
                summary: "Show detailed information about a disk identifier from List disks.",
                effects: "Reads disk metadata. Check the identifier against a current disk listing before running.",
                resultHelp: "Read this as details about the single disk identifier you entered. Choose List disks to compare its place among disks and partitions. Property-list output replaces the readable report with structured data.",
                options: [structured], inputs: [
                    GuidedCommandInput(id: "device", title: "Disk identifier", placeholder: "disk0 or disk0s1",
                        kind: .text, required: true, validation: .diskIdentifier)
                ], argumentsPrefix: ["info"], reference: reference)
        ]
    default: return []
    }
}

/// Produces argument words without evaluating shell syntax or modifying supplied values.
/// Path existence and executable availability must be checked at the execution boundary.
func guidedCommandArguments(recipe: GuidedCommandRecipe, selectedOptions: Set<String>, inputs: [String: String]) throws -> [String] {
    let optionIDs = Set(recipe.options.map(\.id))
    if let id = selectedOptions.subtracting(optionIDs).sorted().first { throw GuidedCommandError.unknownOption(id) }
    let inputIDs = Set(recipe.inputs.map(\.id))
    if let id = Set(inputs.keys).subtracting(inputIDs).sorted().first { throw GuidedCommandError.unknownInput(id) }
    for option in recipe.options where selectedOptions.contains(option.id) {
        if let conflict = recipe.options.first(where: { option.conflicts.contains($0.id) && selectedOptions.contains($0.id) }) {
            throw GuidedCommandError.conflictingOptions(option.title, conflict.title)
        }
    }
    let values: [String] = try recipe.inputs.compactMap { input in
        guard let value = inputs[input.id], !value.isEmpty else {
            if input.required { throw GuidedCommandError.missingInput(input.title) }
            return nil
        }
        guard value.utf8.count <= 4096 else {
            throw GuidedCommandError.invalidInput(input.title, "Keep this value within 4096 bytes.")
        }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029 }) else {
            throw GuidedCommandError.invalidInput(input.title, "Remove control characters and line breaks.")
        }
        switch input.validation {
        case .absolutePath:
            guard value.hasPrefix("/") else {
                throw GuidedCommandError.invalidInput(input.title, "Choose a file or folder, or enter its absolute path beginning with /.")
            }
        case .diskIdentifier:
            guard value.range(of: #"\Adisk[0-9]+(?:s[0-9]+)*\z"#, options: .regularExpression) != nil else {
                throw GuidedCommandError.invalidInput(input.title, "Use a disk identifier such as disk0 or disk0s1 from a current List disks report.")
            }
        }
        return value
    }
    return recipe.argumentsPrefix + recipe.options.filter { selectedOptions.contains($0.id) }.map(\.flag) + values
}

func guidedCommandText(executablePath: String, arguments: [String]) -> String {
    ([executablePath] + arguments).map(quotedShellWord).joined(separator: " ")
}
