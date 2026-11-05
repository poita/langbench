#!/usr/bin/env python3
"""Run a problem's test suite against an implementation command.

Usage:
    python3 run_tests.py <problem> [--timeout SECS] [--verbose] -- <command...>

Two test layouts are supported and detected automatically.

Stdin mode: each problems/<problem>/tests/*.in file is piped to the command's
stdin and its stdout is checked either by problems/<problem>/verify.py (when it
exists) or by exact comparison against the matching .out file.

Directory mode: each problems/<problem>/tests/<name>/ holds an `input` entry
(a file or a directory) and an `expected` directory. The command is run as
`<cmd> <input path> <fresh output dir>` and the produced tree is compared with
`expected` file by file (text files with whitespace normalisation, other files
byte for byte), or handed to verify.py.

verify.py contract:
    python3 verify.py <input> <actual_output> [<expected_output>]
    exit 0 = pass, nonzero = fail (print a reason to stdout)
"""
import argparse
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))


def normalize(text):
    return "\n".join(line.rstrip() for line in text.replace("\r\n", "\n").split("\n")).rstrip("\n")


def is_text(data):
    return b"\0" not in data[:8192]


def tree_files(root):
    out = {}
    for dp, dns, fns in os.walk(root):
        dns.sort()
        for fn in sorted(fns):
            full = os.path.join(dp, fn)
            out[os.path.relpath(full, root)] = full
    return out


def compare_trees(expected, actual):
    """Return None when the trees match, else a short reason."""
    exp, act = tree_files(expected), tree_files(actual)
    missing = sorted(set(exp) - set(act))
    extra = sorted(set(act) - set(exp))
    if missing:
        return f"missing output files: {', '.join(missing[:5])}"
    if extra:
        return f"unexpected output files: {', '.join(extra[:5])}"
    for rel in sorted(exp):
        with open(exp[rel], "rb") as f:
            e = f.read()
        with open(act[rel], "rb") as f:
            a = f.read()
        if is_text(e) and is_text(a):
            if normalize(e.decode("utf-8", "replace")) != normalize(a.decode("utf-8", "replace")):
                return f"content mismatch in {rel}"
        elif e != a:
            return f"binary mismatch in {rel}"
    return None


def run_dir_case(cmd, pdir, tdir, name, verifier, timeout, verbose):
    case = os.path.join(tdir, name)
    inp = os.path.join(case, "input")
    expected = os.path.join(case, "expected")
    with tempfile.TemporaryDirectory(prefix="run_tests_") as out_dir:
        try:
            proc = subprocess.run(cmd + [inp, out_dir], capture_output=True, timeout=timeout, cwd=pdir)
        except subprocess.TimeoutExpired:
            return f"timeout after {timeout}s"
        if proc.returncode != 0:
            return f"exit code {proc.returncode}: {proc.stderr.decode('utf-8', 'replace').strip()[:300]}"
        if verifier:
            vargs = [sys.executable, verifier, inp, out_dir]
            if os.path.isdir(expected):
                vargs.append(expected)
            v = subprocess.run(vargs, capture_output=True, text=True, timeout=timeout or 600)
            if v.returncode != 0:
                return "verifier: " + (v.stdout + v.stderr).strip()[:300]
            return None
        if not os.path.isdir(expected):
            return "missing expected directory"
        return compare_trees(expected, out_dir)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("problem")
    ap.add_argument("--timeout", type=float, default=None, help="per-test limit in seconds (default: none)")
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--filter", default="", help="only run tests whose name contains this")
    ap.add_argument("--tests-dir", default=None, help="run the tests in this directory instead of problems/<problem>/tests")
    argv = sys.argv[1:]
    if "--" not in argv:
        ap.error("missing implementation command after --")
    split = argv.index("--")
    args = ap.parse_args(argv[:split])
    cmd = argv[split + 1:]
    if not cmd:
        ap.error("missing implementation command after --")
    # The command runs with cwd set to the problem directory, so a path given
    # relative to the caller's cwd is resolved to an absolute path here.
    if os.sep in cmd[0] and os.path.exists(cmd[0]):
        cmd[0] = os.path.abspath(cmd[0])

    pdir = os.path.join(ROOT, "problems", args.problem)
    tdir = os.path.abspath(args.tests_dir) if args.tests_dir else os.path.join(pdir, "tests")
    verifier = os.path.join(pdir, "verify.py")
    if not os.path.isdir(tdir):
        print(f"no such problem: {args.problem}")
        return 2
    has_verifier = os.path.exists(verifier)

    dir_cases = sorted(d for d in os.listdir(tdir)
                       if os.path.isdir(os.path.join(tdir, d)) and args.filter in d
                       and os.path.exists(os.path.join(tdir, d, "input")))
    inputs = sorted(f for f in os.listdir(tdir) if f.endswith(".in") and args.filter in f)
    passed = failed = 0
    for name in dir_cases:
        reason = run_dir_case(cmd, pdir, tdir, name, verifier if has_verifier else None, args.timeout, args.verbose)
        if reason is None:
            passed += 1
            if args.verbose:
                print(f"ok   {name}")
        else:
            failed += 1
            print(f"FAIL {name}: {reason}")
    for name in inputs:
        base = name[:-3]
        in_path = os.path.join(tdir, name)
        out_path = os.path.join(tdir, base + ".out")
        with open(in_path, "rb") as f:
            stdin = f.read()
        try:
            proc = subprocess.run(cmd, input=stdin, capture_output=True, timeout=args.timeout, cwd=pdir)
        except subprocess.TimeoutExpired:
            failed += 1
            print(f"FAIL {base}: timeout after {args.timeout}s")
            continue
        except FileNotFoundError as e:
            print(f"cannot run command: {e}")
            return 2
        actual = proc.stdout.decode("utf-8", errors="replace")
        reason = None
        if proc.returncode != 0:
            reason = f"exit code {proc.returncode}: {proc.stderr.decode('utf-8', 'replace').strip()[:300]}"
        elif has_verifier:
            with tempfile.NamedTemporaryFile("w", suffix=".out", delete=False) as tf:
                tf.write(actual)
                tmp = tf.name
            try:
                vargs = [sys.executable, verifier, in_path, tmp]
                if os.path.exists(out_path):
                    vargs.append(out_path)
                v = subprocess.run(vargs, capture_output=True, text=True, timeout=args.timeout or 600)
                if v.returncode != 0:
                    reason = "verifier: " + (v.stdout + v.stderr).strip()[:300]
            finally:
                os.unlink(tmp)
        else:
            if not os.path.exists(out_path):
                reason = "missing expected output file"
            else:
                with open(out_path, encoding="utf-8") as f:
                    expected = f.read()
                if normalize(actual) != normalize(expected):
                    reason = "output mismatch"
                    if args.verbose:
                        reason += f"\n  expected: {normalize(expected)[:200]!r}\n  actual:   {normalize(actual)[:200]!r}"
        if reason is None:
            passed += 1
            if args.verbose:
                print(f"ok   {base}")
        else:
            failed += 1
            print(f"FAIL {base}: {reason}")
    print(f"{args.problem}: {passed}/{passed + failed} passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
