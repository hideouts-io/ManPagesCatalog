from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class ManPageSource:
    path: Path      # absolute path to source file (may be .gz)
    name: str       # e.g. "ls"
    section: str    # e.g. "1"


@dataclass
class RenderResult:
    source: ManPageSource
    success: bool
    pdf_path: Path | None = None    # set on success
    error: str | None = None        # set on failure


@dataclass
class CatalogEntry:
    name: str           # man page name
    section: str        # section number
    description: str    # one-line description from NAME section, or ""
    pdf_path: str       # relative path to PDF within output_dir
    source_path: str    # absolute path to the original man page source file
    executable_path: str = ""  # full path to the executable, e.g. /bin/ls (section 1/8 only)
