import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src")


def run(tmp_path, document, settings=None, cwd=HERE):
    inp = tmp_path / "in"
    out = tmp_path / "out"
    inp.mkdir()
    out.mkdir()
    if document is not None:
        (inp / "document.cdx").write_text(document, encoding="utf-8")
    if settings is not None:
        (inp / "settings.cfg").write_text(settings, encoding="utf-8")
    env = dict(os.environ, PYTHONPATH=SRC)
    proc = subprocess.run([sys.executable, "-m", "typeset", str(inp), str(out)],
                          cwd=cwd, env=env, capture_output=True)
    return proc, out


def test_success_writes_layout_and_report(tmp_path):
    proc, out = run(tmp_path, "Hello world.\n")
    assert proc.returncode == 0
    assert sorted(os.listdir(out)) == ["layout.txt", "report.txt"]
    assert (out / "layout.txt").read_text().startswith("layout 1\npages 1\n")


def test_error_writes_only_error_txt_and_exits_zero(tmp_path):
    proc, out = run(tmp_path, "{z|x}\n")
    assert proc.returncode == 0
    assert os.listdir(out) == ["error.txt"]
    assert (out / "error.txt").read_text() == "document.cdx:1:1: unknown-inline\n"


def test_missing_document(tmp_path):
    proc, out = run(tmp_path, None)
    assert proc.returncode == 0
    assert (out / "error.txt").read_text() == "-:0:0: missing-document\n"
