#!/usr/bin/env python3
"""Consistency checks for the repository; exits nonzero if any fail.

    tools/check.py                    structure, run configuration, run provenance, canonical
                                      implementations, unit tests
    tools/check.py --references [S]  also run each problem's reference on its public tests (slow)
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from audit import INTEGRITY  # noqa: E402
PROBLEM_FILES = ["SPEC.md", "APPROACH.md", "reference/main.py", "bench/gen_bench.py"]


def problems():
    return sorted(d for d in os.listdir(os.path.join(ROOT, "problems"))
                  if os.path.isfile(os.path.join(ROOT, "problems", d, "SPEC.md")))


def check_structure():
    errors = []
    for slug in problems():
        pdir = os.path.join(ROOT, "problems", slug)
        errors += [f"problems/{slug}: missing {f}" for f in PROBLEM_FILES if not os.path.isfile(os.path.join(pdir, f))]
        if not os.listdir(os.path.join(pdir, "tests")):
            errors.append(f"problems/{slug}: no tests")
    return errors


def check_run_config():
    """run-config.json names existing problems and known languages, and the task prompt renders with it."""
    import runner
    config = json.load(open(os.path.join(ROOT, "run-config.json")))
    errors = [f"run-config.json: unknown problem {p}" for p in config.get("repProblems", []) + config.get("problems", [])
              if p not in problems()]
    errors += [f"run-config.json: unknown language {l}" for l in config.get("langs", []) if l not in runner.LANG_NAMES]
    try:
        for lang in config.get("langs", []):
            runner.render_prompt({**config, "root": "/sandbox"},
                                 {"rep": "rep1", "lang": lang, "slug": problems()[0], "label": "x"})
    except (KeyError, IndexError, ValueError) as e:
        errors.append(f"tools/task_prompt.txt does not render: {e!r}")
    return errors


def check_provenance():
    dirs = ([os.path.join(ROOT, "implementations")] + glob.glob(os.path.join(ROOT, "runs-*"))
            + glob.glob(os.path.join(ROOT, "case-studies", "*", "runs-*")))
    return [f"{os.path.relpath(d, ROOT)}: no run.json" for d in sorted(dirs)
            if os.path.isdir(d) and not os.path.isfile(os.path.join(d, "run.json"))]


def canonical_errors(d):
    """Runs recorded in d/run.json that are not canonical: language tips, machine notes or the efficiency note in
    the prompt, no APPROACH.md, or (for sandboxed runs) no audit, or an audit with integrity findings that are not
    listed, each with a reason, in audit/<run>.reviewed.json (findings a person has inspected and found harmless,
    such as a read the sandbox refused whose error message the command discarded).
    Rule violations by individual agents (dependencies, banned facilities) are results, not errors."""
    path = os.path.join(d, "run.json")
    errors = []
    for run in json.load(open(path)).get("runs", []) if os.path.isfile(path) else []:
        name, o = run.get("workflow_run"), run.get("options", {})
        if o.get("notes") or o.get("machineNotes") or o.get("efficiency") or o.get("approach") is False:
            errors.append(f"{name}: non-canonical options {o}")
        if run.get("sandbox"):
            audit = os.path.join(d, run.get("audit") or f"audit/{name}.json")
            if not os.path.isfile(audit):
                errors.append(f"{name}: no audit ({os.path.relpath(audit, d)})")
            else:
                reviewed_path = audit[:-len(".json")] + ".reviewed.json"
                reviewed = json.load(open(reviewed_path)) if os.path.isfile(reviewed_path) else []
                accepted = {(r.get("agent"), r.get("kind"), r.get("detail")) for r in reviewed if r.get("reason")}
                open_findings = [f for f in json.load(open(audit)) if f.get("kind") in INTEGRITY
                                 and (f.get("agent"), f.get("kind"), f.get("detail")) not in accepted]
                if open_findings:
                    errors.append(f"{name}: audit has {len(open_findings)} unreviewed integrity finding(s) "
                                  f"({os.path.relpath(audit, d)})")
    return errors


def check_canonical():
    return [f"implementations: {e}" for e in canonical_errors(os.path.join(ROOT, "implementations"))]


def check_unit_tests():
    p = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests"], cwd=ROOT,
                       capture_output=True, text=True)
    return [] if p.returncode == 0 else ["unit tests failed:\n" + p.stderr[-2000:]]


def check_references(slugs):
    errors = []
    for slug in slugs:
        p = subprocess.run([sys.executable, "run_tests.py", slug, "--", sys.executable,
                            os.path.join(ROOT, "problems", slug, "reference", "main.py")], cwd=ROOT, capture_output=True, text=True)
        line = (p.stdout.strip().splitlines() or ["no output"])[-1]
        print(f"  reference {slug}: {line}", flush=True)
        if p.returncode != 0:
            errors.append(f"reference {slug}: {line}")
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--references", nargs="*", metavar="SLUG",
                    help="run references on their public tests (all problems when no slug is given)")
    a = ap.parse_args()
    checks = [("structure", check_structure), ("run configuration", check_run_config),
              ("run provenance", check_provenance), ("canonical implementations", check_canonical),
              ("unit tests", check_unit_tests)]
    if a.references is not None:
        checks.append(("references", lambda: check_references(a.references or problems())))
    failed = False
    for name, fn in checks:
        errors = fn()
        print(f"{'ok  ' if not errors else 'FAIL'} {name}")
        for e in errors:
            print(f"     {e}")
        failed = failed or bool(errors)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
