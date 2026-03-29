import gzip
import shutil
import subprocess
import tempfile
from pathlib import Path

from .models import ManPageSource, RenderResult

_MANDOC = shutil.which("mandoc")
_GROFF = shutil.which("groff")
_PS2PDF = shutil.which("ps2pdf")

# Test once at import time whether mandoc supports -Tpdf
def _mandoc_supports_pdf() -> bool:
    if not _MANDOC:
        return False
    try:
        r = subprocess.run(
            [_MANDOC, "-Tpdf"],
            input=b".TH T 1\n.SH NAME\nt \\- t\n",
            capture_output=True,
        )
        return r.stdout[:4] == b"%PDF"
    except Exception:
        return False

_USE_MANDOC_PDF = _mandoc_supports_pdf()


def render(source: ManPageSource, output_dir: Path) -> RenderResult:
    """
    Render a single man page to a searchable PDF.
    Fast path: mandoc -Tpdf (single process, no temp PS file).
    Fallback: groff -mandoc -Tps | ps2pdf.
    Skips pages whose PDF is already newer than the source.
    """
    pdf_path = output_dir / f"{source.name}.{source.section}.pdf"

    # Incremental: skip if PDF is already up to date
    try:
        if pdf_path.exists() and pdf_path.stat().st_size > 0:
            if pdf_path.stat().st_mtime >= source.path.stat().st_mtime:
                return RenderResult(source=source, success=True, pdf_path=pdf_path)
    except OSError:
        pass

    tmp_src: Path | None = None
    tmp_ps: Path | None = None

    try:
        # Decompress .gz
        if source.path.suffix == ".gz":
            fd, tmp_str = tempfile.mkstemp(suffix=".man")
            tmp_src = Path(tmp_str)
            with gzip.open(source.path, "rb") as gz_in, open(fd, "wb") as out:
                shutil.copyfileobj(gz_in, out)
            src = tmp_src
        else:
            src = source.path

        # Fast path: mandoc → PDF directly (no intermediate PS, no ps2pdf)
        if _USE_MANDOC_PDF:
            result = subprocess.run(
                [_MANDOC, "-Tpdf", str(src)],
                capture_output=True,
            )
            if result.returncode == 0 and result.stdout[:4] == b"%PDF":
                pdf_path.write_bytes(result.stdout)
                return RenderResult(source=source, success=True, pdf_path=pdf_path)
            # Fall through to groff fallback

        # Fallback: groff → PS → ps2pdf
        if not _GROFF or not _PS2PDF:
            return RenderResult(source=source, success=False,
                                error="mandoc -Tpdf failed and groff/ps2pdf not available")

        _, tmp_ps_str = tempfile.mkstemp(suffix=".ps")
        tmp_ps = Path(tmp_ps_str)

        groff = subprocess.run(
            [_GROFF, "-mandoc", "-Tps", str(src)],
            stdout=open(tmp_ps, "wb"),
            stderr=subprocess.PIPE,
        )
        if tmp_ps.stat().st_size == 0:
            err = groff.stderr.decode(errors="replace").strip()
            return RenderResult(source=source, success=False, error=f"groff: {err}")

        ps2pdf = subprocess.run(
            [_PS2PDF, str(tmp_ps), str(pdf_path)],
            stderr=subprocess.PIPE,
        )
        if ps2pdf.returncode != 0 or not pdf_path.exists() or pdf_path.stat().st_size == 0:
            err = ps2pdf.stderr.decode(errors="replace").strip()
            return RenderResult(source=source, success=False, error=f"ps2pdf: {err}")

        return RenderResult(source=source, success=True, pdf_path=pdf_path)

    except Exception as exc:
        return RenderResult(source=source, success=False, error=str(exc))

    finally:
        for p in (tmp_src, tmp_ps):
            if p and p.exists():
                try:
                    p.unlink()
                except OSError:
                    pass
