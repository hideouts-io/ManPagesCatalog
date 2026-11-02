import Foundation
@main struct Check {
  static func main() {
    let base = URL(fileURLWithPath: CommandLine.arguments[1])
    func read(_ name: String) -> String? { FileUtilities.readTextContent(at: base.appendingPathComponent(name)) }
    precondition(read("utf8.txt") == "Fixture text")
    precondition(read("latin1.txt") == "café")
    precondition(read("empty.txt") == nil)
    precondition(read("missing.txt") == nil)
    precondition(read("invalid.pdf") == nil)
    let text = read("two-pages.pdf")!
    precondition(text.contains("Page one") && text.contains("Page two"))
    precondition(text.range(of: "Page one")!.lowerBound < text.range(of: "Page two")!.lowerBound)
    print("PASS six file/PDF behavior cases")
    print(text)
  }
}
