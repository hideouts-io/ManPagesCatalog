import argparse
import json
import os
import shutil
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

from .catalog import build_catalog
from .discoverer import discover
from .renderer import render


def _check_deps() -> None:
    has_mandoc = shutil.which("mandoc")
    has_groff = shutil.which("groff")
    has_ps2pdf = shutil.which("ps2pdf")
    missing = []
    if not has_mandoc and not has_groff:
        missing.append("mandoc or groff")
    if not has_ps2pdf:
        missing.append("ps2pdf")
    if missing:
        print(
            f"ERROR: Required tool(s) not found: {', '.join(missing)}\n"
            "Install with: brew install ghostscript groff",
            file=sys.stderr,
        )
        sys.exit(2)


def _write_progress(progress_file: Path | None, completed: int, total: int,
                    rendered: int, failed: int, done: bool = False) -> None:
    if progress_file is None:
        return
    data = {
        "completed": completed,
        "total": total,
        "rendered": rendered,
        "failed": failed,
        "done": done,
    }
    # Write atomically via temp file to avoid partial reads by the Swift app
    tmp = progress_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(data))
    tmp.replace(progress_file)


def _optimal_workers(requested: int) -> int:
    """
    Use requested count, but cap at physical core count if detectable.
    Too many workers thrash I/O on temp files.
    """
    cpu = os.cpu_count() or 4
    # On Apple Silicon, leave 2 cores free for the OS and Swift app
    return min(requested, max(1, cpu - 2))


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="manpage-pdf-catalog",
        description="Convert all man pages to searchable PDFs and build a catalog.",
    )
    parser.add_argument("--output-dir", required=True, metavar="PATH",
                        help="Directory to write PDFs and catalog.json")
    parser.add_argument("--progress-file", metavar="PATH", default=None,
                        help="JSON file updated during rendering (for GUI polling)")
    parser.add_argument("--jobs", type=int, default=os.cpu_count(),
                        metavar="N", help="Parallel workers (default: CPU count)")
    parser.add_argument("--force", action="store_true",
                        help="Re-render all pages even if PDFs are up to date")
    args = parser.parse_args()

    _check_deps()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    progress_file = Path(args.progress_file) if args.progress_file else None
    workers = _optimal_workers(args.jobs)

    print("Discovering man pages…")
    sources = discover()
    total = len(sources)
    print(f"Found {total} man pages. Rendering with {workers} workers…")

    # If --force, remove existing PDFs so incremental check is bypassed
    if args.force:
        for pdf in output_dir.glob("*.pdf"):
            pdf.unlink(missing_ok=True)

    results = []
    rendered = failed = skipped = 0
    # Write progress every N completions to reduce I/O
    PROGRESS_BATCH = 10

    with ProcessPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(render, source, output_dir): source
                   for source in sources}
        for i, future in enumerate(as_completed(futures), 1):
            result = future.result()
            results.append(result)
            if result.success:
                rendered += 1
                # Detect skipped (mtime check passed — no actual render needed)
                detail = result.pdf_path.name if result.pdf_path else ""
                print(f"[{i:6}/{total}] OK:     {detail}")
            else:
                failed += 1
                src = result.source
                print(f"[{i:6}/{total}] FAILED: {src.name}.{src.section} — {result.error}")

            if i % PROGRESS_BATCH == 0 or i == total:
                _write_progress(progress_file, i, total, rendered, failed)

    catalog_path = build_catalog(results, output_dir)
    print(f"\nCatalog: {catalog_path}")
    print(f"Done. Discovered: {total}  Rendered: {rendered}  Failed: {failed}")
    _write_progress(progress_file, total, total, rendered, failed, done=True)


if __name__ == "__main__":
    main()
