# Man Page Catalog

A native macOS app that converts every man page on your system into a searchable PDF and lets you browse them in a clean three-column interface.

## Download

**[Download ManPageCatalog-macOS.zip](ManPageCatalog-macOS.zip)**

1. Unzip and drag `Man Page Catalog.app` to `/Applications`
2. Install dependencies:
   ```bash
   brew install groff ghostscript
   ```
3. Open the app

> macOS may show a security warning on first launch. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Usage

1. Click the **↻ Generate** button in the toolbar
2. Choose an output folder (e.g. `~/ManPages`)
3. Click **Generate** — a live progress bar shows rendering status
4. Browse sections in the sidebar, search by name or description
5. Click any entry to read the PDF inline

Each man page shows:
- The source file path (e.g. `/usr/share/man/man1/ls.1`)
- The executable path for commands (e.g. `/bin/ls`) with a copy button

## Running the backend directly

```bash
python3 -m manpage_pdf_catalog --output-dir ~/ManPages
```

## Requirements

- macOS 13+
- `brew install groff ghostscript` (for PDF generation)

## Build from source

```bash
brew install xcodegen
xcodegen generate
open ManPageCatalog.xcodeproj
```
