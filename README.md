# Man Page Catalog

A native macOS app that converts every man page on your system into a searchable PDF and lets you browse them in a clean three-column interface.

## Requirements

- macOS 13+
- Xcode 15+
- Homebrew

## Setup

```bash
# 1. Install system dependencies
brew install groff ghostscript

# 2. Install Python test dependencies (optional)
pip3 install hypothesis pypdf --break-system-packages
```

## Open in Xcode

Open `ManPageCatalog/` as a new Xcode project (File → New → Project, or drag the folder in).  
Set the deployment target to macOS 13, add `PDFKit` to the linked frameworks, and run.

## Usage

1. Launch the app
2. Click the **Generate** button (↻) in the toolbar
3. Choose an output folder (e.g. `~/ManPages`)
4. Click **Generate** — a live progress bar shows rendering status
5. When done, browse sections in the sidebar, search by name or description, and click any entry to read the PDF inline

## Running the backend directly

```bash
python3 -m manpage_pdf_catalog --output-dir ~/ManPages
```

## Project structure

```
manpage_pdf_catalog/     # Python backend
  __main__.py            # CLI entry point
  discoverer.py          # MANPATH traversal
  renderer.py            # groff + ps2pdf pipeline
  catalog.py             # catalog.json builder
  models.py              # shared dataclasses

ManPageCatalog/          # SwiftUI macOS app
  ManPageCatalogApp.swift
  Models/CatalogEntry.swift
  Store/CatalogStore.swift
  Views/
    ContentView.swift    # three-column navigation
    PDFDetailView.swift  # inline PDF viewer (PDFKit)
    GenerateView.swift   # generate sheet with live progress

tests/                   # Python tests (pytest + Hypothesis)
```
