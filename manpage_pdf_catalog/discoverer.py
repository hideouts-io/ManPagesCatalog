import os
import re
import sys
from pathlib import Path

from .models import ManPageSource

_FALLBACK_DIRS = [
    Path("/usr/share/man"),
    Path("/usr/local/share/man"),
    Path("/opt/homebrew/share/man"),
    Path("/usr/man"),
    Path("/usr/local/man"),
]

# Matches any man<section> directory: man1, man3ssl, mann, man1tcl, etc.
_SECTION_DIR_RE = re.compile(r"^man(\w+)$")

# Matches man page filenames — extension is anything after the last dot
# that looks like a section: digit-led (1, 3ssl, 1m) or n/ntcl (Tcl pages)
_MAN_FILE_RE = re.compile(
    r"^(.+?)\.((\d\w*|n\w*))(?:\.gz)?$"
)


def _resolve_manpath(manpath: list[Path] | None) -> list[Path]:
    if manpath is not None:
        return manpath
    env = os.environ.get("MANPATH", "")
    if env:
        dirs = [Path(p) for p in env.split(":") if p]
        # Always include Homebrew even if not in MANPATH
        brew = Path("/opt/homebrew/share/man")
        if brew not in dirs and brew.exists():
            dirs.append(brew)
        return dirs
    return _FALLBACK_DIRS


def discover(manpath: list[Path] | None = None) -> list[ManPageSource]:
    """
    Discover all man page source files on the system.
    Handles all section extensions: 1, 3ssl, 1m, n, ntcl, etc.
    """
    dirs = _resolve_manpath(manpath)
    seen: set[tuple[str, str]] = set()  # (name, section) dedup
    sources: list[ManPageSource] = []

    for base in dirs:
        if not base.exists():
            print(f"WARNING: MANPATH directory does not exist: {base}", file=sys.stderr)
            continue
        if not os.access(base, os.R_OK):
            print(f"WARNING: MANPATH directory not readable: {base}", file=sys.stderr)
            continue

        for section_dir in sorted(base.iterdir()):
            if not section_dir.is_dir():
                continue
            dm = _SECTION_DIR_RE.match(section_dir.name)
            if not dm:
                continue
            dir_section = dm.group(1)  # e.g. "1", "3ssl", "n", "ntcl"

            for f in section_dir.iterdir():
                if not f.is_file():
                    continue

                fname = f.name
                # Strip .gz for matching
                bare = fname[:-3] if fname.endswith(".gz") else fname

                # Match: <name>.<section>
                # Section must match the parent directory's section
                m = _MAN_FILE_RE.match(bare)
                if not m:
                    continue

                name, section = m.group(1), m.group(2)

                # The file's section extension may differ from the dir name
                # e.g. openssl.1ssl lives in man1/ — accept it as-is
                # Only skip if the file section doesn't start with the dir section
                if not section.startswith(dir_section) and not dir_section.startswith(section):
                    continue

                key = (name.lower(), section)
                if key in seen:
                    continue
                seen.add(key)

                sources.append(ManPageSource(path=f, name=name, section=section))

    return sources
