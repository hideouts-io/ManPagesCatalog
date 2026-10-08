import Foundation

/// mandoc preserves semantic roff markup; an app-owned stylesheet adds responsive reading.
func manualHTML(source: URL) async throws -> String {
    let input = try await manualInput(source: source)
    let result = try await formatManual(input: input, arguments: ["-Thtml", "-O", "fragment,man=manpagescatalog://open?name=%N&section=%S"])
    let fragment = String(decoding: result.bytes, as: UTF8.self)
    let notice = result.diagnostic.isEmpty ? "" : "<aside role=\"note\"><strong>Formatting issue in the original manual</strong><p>Some markup could not be interpreted. Review the source for exact formatting. PDF export requires an error-free rendering.</p><pre>" + escapedHTML(result.diagnostic) + "</pre></aside>"
    return """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; img-src 'none'">
    <style>
    :root { color-scheme: light dark; --ink:#20252c; --muted:#606976; --paper:#fff; --line:#e1e5e9; --accent:#1764aa; --code:#f2f5f8; }
    @media(prefers-color-scheme:dark) { :root { --ink:#e5e9ef; --muted:#a7b1be; --paper:#202328; --line:#414750; --accent:#8fc5ff; --code:#2d333c; } }
    * { box-sizing:border-box; } body { margin:0 auto; padding:28px 36px 64px; max-width:960px; font:16px/1.65 -apple-system,BlinkMacSystemFont,sans-serif; color:var(--ink); background:var(--paper); overflow-wrap:break-word; }
    .head,.foot { color:var(--muted); font-size:12px; display:flex; justify-content:space-between; gap:16px; }
    .head-rtitle { display:none; } .foot { border-top:1px solid var(--line); margin-top:40px; padding-top:16px; }
    h1,h2,h3 { line-height:1.3; scroll-margin-top:20px; } h2 { font-size:15px; letter-spacing:.07em; margin:32px 0 16px; padding-bottom:8px; border-bottom:1px solid var(--line); } h3 { font-size:17px; }
    a { color:var(--accent); text-decoration:none; } a:hover { text-decoration:underline; } a:focus-visible { outline:2px solid var(--accent); outline-offset:3px; } h2 a { color:inherit; }
    p { margin:12px 0; } code,pre,kbd,.Li,.Cm,.Fl,.Pa { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.91em; }
    pre,.Bd { overflow:auto; background:var(--code); padding:14px 16px; border-radius:8px; white-space:pre-wrap; } .Nm,.Fl { font-weight:600; } .Ar { color:var(--muted); }
    dt { margin-top:14px; font-weight:600; } dd { margin-left:24px; } table { border-collapse:collapse; max-width:100%; } td,th { padding:4px 10px 4px 0; vertical-align:top; } .tbl td,.tbl th { border-bottom:1px solid var(--line); }
    @media(max-width:550px) { body { padding:20px; } } @media print { body { color:#000; background:#fff; font-size:11pt; } a { color:#000; } }
    </style></head><body>\(notice)\(fragment)</body></html>
    """
}

func escapedHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}
