import gzip
import json
import re
import shutil
from pathlib import Path

from .models import CatalogEntry, RenderResult

# Sections where the man page name corresponds to a runnable command
_EXECUTABLE_SECTIONS = {"1", "1m", "1ssl", "1tcl", "8"}


def _find_executable(name: str, section: str) -> str:
    """Return the full path to the executable, or '' if not applicable/found."""
    if section not in _EXECUTABLE_SECTIONS:
        return ""
    return shutil.which(name) or ""


def _extract_description(source_path: Path) -> str:
    """Extract the one-line description from a man page source (troff or mdoc format)."""
    try:
        opener = gzip.open(source_path, "rt", errors="replace") \
            if source_path.suffix == ".gz" \
            else open(source_path, "r", errors="replace")

        in_name = False
        with opener as f:
            for line in f:
                stripped = line.strip()

                # mdoc format: .Nd is the one-liner description
                if stripped.startswith(".Nd "):
                    desc = stripped[4:].strip()
                    return re.sub(r"\\f[A-Za-z]", "", desc).strip()

                # troff/man format: .SH NAME followed by "name - description"
                if re.match(r"^\.SH\s+NAME", stripped, re.IGNORECASE):
                    in_name = True
                    continue

                if in_name:
                    if re.match(r"^\.[A-Z]", stripped) and not stripped.startswith(".\\"):
                        break
                    if stripped:
                        clean = re.sub(r"\\f[A-Za-z]", "", stripped)
                        clean = re.sub(r"\\-", "-", clean)
                        clean = re.sub(r"\\&", "", clean)
                        if " - " in clean:
                            return clean.split(" - ", 1)[1].strip()
                        if " \\- " in clean:
                            return clean.split(" \\- ", 1)[1].strip()
                        return clean.strip()
    except Exception:
        pass
    return ""


def build_catalog(results: list[RenderResult], output_dir: Path) -> Path:
    """Build catalog.json from successful render results."""
    entries: list[CatalogEntry] = []

    for result in results:
        if not result.success or result.pdf_path is None:
            continue
        description = _extract_description(result.source.path)
        rel_pdf = result.pdf_path.relative_to(output_dir)
        executable_path = _find_executable(result.source.name, result.source.section)
        entries.append(
            CatalogEntry(
                name=result.source.name,
                section=result.source.section,
                description=description,
                pdf_path=str(rel_pdf),
                source_path=str(result.source.path),
                executable_path=executable_path,
            )
        )

    entries.sort(key=lambda e: (e.name.lower(), e.section))

    catalog_path = output_dir / "catalog.json"
    data = {
        "entries": [
            {
                "name": e.name,
                "section": e.section,
                "description": e.description,
                "pdf_path": e.pdf_path,
                "source_path": e.source_path,
                "executable_path": e.executable_path,
            }
            for e in entries
        ]
    }
    catalog_path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return catalog_path
