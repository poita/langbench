#!/usr/bin/env python3
"""Builds the whole `buildsys` test suite, public and hidden.

Every case is a directory-mode test: `tests/NNN_name/input/` holds
`session.txt` plus the initial workspace, and `tests/NNN_name/expected/` holds
the tree that `reference/main.py` produces from it. Cases are written to

  * problems/buildsys/tests/                       (public, about a quarter)
  * $LANGBENCH_HIDDEN (default: langbench-hidden next to this checkout)/buildsys/tests/  (hidden, the rest)

sharing one `NNN` sequence so names never collide, and are stratified so every
feature area appears in both sets.

The hand-written cases come first, grouped by feature area, and each carries an
`expect` list of log lines that must appear in order. That list is written from
SPEC.md, not from the reference, so a disagreement between the two is a
generation failure rather than a silently blessed wrong answer. Three of those
lists are computed rather than typed, by small independent implementations of
the specification written here: the glob matcher of section 11, the FNV-1a-64
hash of section 4 (used to hand-write state files) and the scheduler of
section 19. The generated cases follow: deterministic pseudo-random projects of
growing size built from a fixed seed per case, checked for the absence of any
error line.

There is no verify.py: every observable byte is uniquely determined, so the
harness compares the output tree directly.

    python3 gen_tests.py [--only SUBSTRING] [--jobs N]
"""
import argparse
import os
import random
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE = os.path.join(HERE, "reference", "main.py")
PUBLIC_DIR = os.path.join(HERE, "tests")
HIDDEN_DIR = os.path.join(os.environ.get("LANGBENCH_HIDDEN") or os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "langbench-hidden")), "buildsys", "tests")

CASES = []


def case(name, files, session, pub=False, expect=(), forbid=()):
    """Register one test case.

    `files` maps workspace paths to the initial content, `session` is the text
    of `session.txt`, `expect` lists log lines that must appear in order, and
    `forbid` lists substrings that must not appear in the log at all.
    """
    check_paths(name, files)
    CASES.append({
        "name": name,
        "files": {k: as_bytes(v) for k, v in files.items()},
        "session": as_bytes(session),
        "pub": bool(pub),
        "expect": [as_bytes(x) for x in expect],
        "forbid": [as_bytes(x) for x in forbid],
    })


def as_bytes(v):
    return v if isinstance(v, bytes) else v.encode("utf-8")


def check_paths(name, files):
    """Reject workspaces a real directory cannot hold.

    Two paths that differ only in case collide on a case-insensitive file
    system, and a path cannot be both a file and a directory.
    """
    lowered = {}
    for p in files:
        other = lowered.setdefault(p.lower(), p)
        if other != p:
            raise SystemExit("%s: %r and %r differ only by case" % (name, other, p))
    dirs = set()
    for p in files:
        parts = p.split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))
    clash = sorted(set(files) & dirs)
    if clash:
        raise SystemExit("%s: %s is both a file and a directory" % (name, clash[0]))


def variants(name, mains, pub=False, files=None, expect=(), targets=""):
    """Register a case that rebuilds after rewriting `main.kiln` each time.

    `mains` is a list of `main.kiln` texts; the session builds, edits
    `main.kiln` to the next text, builds again, and so on. One case therefore
    covers a family of related configuration errors without needing a
    directory per error.
    """
    all_files = dict(files or {})
    all_files["main.kiln"] = mains[0]
    lines = ["build" + (" " + targets if targets else "")]
    for text in mains[1:]:
        lines.append("edit main.kiln")
        lines.append(as_bytes(text).decode("utf-8").rstrip("\n"))
        lines.append("---")
        lines.append("build" + (" " + targets if targets else ""))
    case(name, all_files, "\n".join(lines) + "\n", pub=pub, expect=expect)


def errs(*kinds):
    """Turn error kinds into the log lines they produce."""
    return ["  error " + k for k in kinds]


# ---------------------------------------------------------------------------
# materialising and running
# ---------------------------------------------------------------------------

def materialize(spec, root):
    inp = os.path.join(root, "input")
    os.makedirs(inp)
    with open(os.path.join(inp, "session.txt"), "wb") as f:
        f.write(spec["session"])
    for path, content in sorted(spec["files"].items()):
        full = os.path.join(inp, path.replace("/", os.sep))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(content)


def check_expect(spec, log):
    """Confirm every expected line appears in `log`, in order."""
    for bad in spec.get("forbid", ()):
        if bad in log:
            return "forbidden text in log: %r" % bad
    lines = log.split(b"\n")
    i = 0
    for want in spec["expect"]:
        while i < len(lines) and lines[i] != want:
            i += 1
        if i == len(lines):
            return "expected log line not found: %r" % want
        i += 1
    return None


def build_case(index, spec, out_root):
    name = "%03d_%s" % (index, spec["name"])
    root = os.path.join(out_root, name)
    shutil.rmtree(root, ignore_errors=True)
    materialize(spec, root)
    expected = os.path.join(root, "expected")
    os.makedirs(expected)
    proc = subprocess.run([sys.executable, REFERENCE,
                           os.path.join(root, "input"), expected],
                          capture_output=True)
    if proc.returncode != 0:
        raise SystemExit("%s: reference exited %d: %s"
                         % (name, proc.returncode,
                            proc.stderr.decode("utf-8", "replace")[:600]))
    with open(os.path.join(expected, "log.txt"), "rb") as f:
        log = f.read()
    problem = check_expect(spec, log)
    if problem:
        raise SystemExit("%s: %s\n--- log.txt ---\n%s"
                         % (name, problem, log.decode("utf-8", "replace")[:4000]))
    size = sum(os.path.getsize(os.path.join(dp, fn))
               for dp, _, fns in os.walk(root) for fn in fns)
    return name, size, len(log)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="only build cases whose name contains this")
    ap.add_argument("--jobs", type=int, default=8)
    args = ap.parse_args()

    register_all()
    names = [c["name"] for c in CASES]
    if len(set(names)) != len(names):
        dupes = sorted({n for n in names if names.count(n) > 1})
        raise SystemExit("duplicate case names: %s" % ", ".join(dupes))

    if not args.only:
        shutil.rmtree(PUBLIC_DIR, ignore_errors=True)
        shutil.rmtree(HIDDEN_DIR, ignore_errors=True)
    os.makedirs(PUBLIC_DIR, exist_ok=True)
    os.makedirs(HIDDEN_DIR, exist_ok=True)

    work = []
    for i, spec in enumerate(CASES, 1):
        if args.only and args.only not in spec["name"]:
            continue
        work.append((i, spec, PUBLIC_DIR if spec["pub"] else HIDDEN_DIR))

    totals = {PUBLIC_DIR: 0, HIDDEN_DIR: 0}
    counts = {PUBLIC_DIR: 0, HIDDEN_DIR: 0}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for (i, spec, dest), result in zip(
                work, pool.map(lambda t: build_case(*t), work)):
            name, size, loglen = result
            totals[dest] += size
            counts[dest] += 1
            print("%-44s %-6s %8.1f KiB  log %d B"
                  % (name, "public" if dest is PUBLIC_DIR else "hidden",
                     size / 1024.0, loglen))

    print()
    print("public: %d cases, %.1f MiB" % (counts[PUBLIC_DIR], totals[PUBLIC_DIR] / 1048576.0))
    print("hidden: %d cases, %.1f MiB" % (counts[HIDDEN_DIR], totals[HIDDEN_DIR] / 1048576.0))
    return 0


# ---------------------------------------------------------------------------
# shared fragments
# ---------------------------------------------------------------------------

HELLO = '''step {
    out "out/hello.txt"
    cmd write("hello\\n")
}
default "out/hello.txt"
'''

GLOB_CONCAT = '''let srcs = sort(glob("src/*.txt"))
step {
    out "out/all.txt"
    in srcs
    cmd concat()
}
default "out/all.txt"
'''


def two_steps(cost_a=1, cost_b=1):
    return ('step {\n    out "out/a.txt"\n    cmd write("A\\n")\n    cost %d\n}\n'
            'step {\n    out "out/b.txt"\n    cmd write("B\\n")\n    cost %d\n}\n'
            'phony all = ["out/a.txt", "out/b.txt"]\n'
            'default "@all"\n' % (cost_a, cost_b))


def step_of(fields, tail='default "out/z.txt"\n'):
    """One `step` block made of the given field lines, plus a tail statement."""
    body = "".join("    " + f + "\n" for f in fields)
    return "step {\n" + body + "}\n" + tail


# ---------------------------------------------------------------------------
# session mechanics
# ---------------------------------------------------------------------------

def g_session():
    case("sess_empty_session", {"main.kiln": HELLO}, "", pub=True)

    case("sess_comments_and_blanks", {"main.kiln": HELLO},
         "# leading comment\n\n   # indented comment\nbuild\n\t\nbuild\n   \nbuild\n",
         expect=["step 1: build (default) -j 1", "step 2: build (default) -j 1",
                 "step 3: build (default) -j 1", "  ok ran=0 hit=1 time=0"])

    case("sess_six_step_kinds", {"main.kiln": GLOB_CONCAT},
         "create src/a.txt\nalpha\n---\nbuild\ncreate src/b.txt\nbeta\n---\n"
         "build\ntouch src/a.txt\nbuild\nedit src/a.txt\nALPHA\nmore\n---\n"
         "build\ndelete src/b.txt\nbuild\nclean\nbuild\n",
         pub=True,
         expect=["step 1: create src/a.txt", "  ok size=6",
                 "step 3: create src/b.txt", "  ok size=5",
                 "step 5: touch src/a.txt", "  ok",
                 "  ok ran=0 hit=1 time=0",
                 "step 7: edit src/a.txt", "  ok size=11",
                 "step 9: delete src/b.txt", "  ok",
                 "step 11: clean", "  remove .kiln-state",
                 "  remove out/all.txt", "  ok removed=2"])

    case("sess_create_empty_content",
         {"main.kiln": step_of(['out "out/n.txt"', 'in "src/e.txt"',
                                'cmd count_lines()'], 'default "out/n.txt"\n')},
         "create src/e.txt\n---\nbuild\n",
         expect=["  ok size=0", "  run 0 2 w0 out/n.txt count_lines()"])

    case("sess_content_block_edges",
         {"main.kiln": step_of(['out "out/n.txt"', 'in "src/x.txt"',
                                'cmd number()'], 'default "out/n.txt"\n')},
         "create src/x.txt\n\n# not a comment in a content block\n"
         "  indented line\n----\n--\n\n---\nbuild\n",
         pub=False,
         expect=["  ok size=61", "  run 0 2 w0 out/n.txt number()"])

    case("sess_clean_nothing", {"main.kiln": HELLO}, "clean\nclean\nbuild\nclean\n",
         expect=["step 1: clean", "  ok removed=0", "step 2: clean",
                 "  ok removed=0", "step 4: clean", "  remove .kiln-state",
                 "  remove out/hello.txt", "  ok removed=2"])

    case("sess_clean_with_broken_build_files",
         {"main.kiln": 'let x = "unterminated\n'},
         "build\nclean\nbuild\n",
         expect=["  error E_PARSE main.kiln:1", "step 2: clean",
                 "  ok removed=0", "  error E_PARSE main.kiln:1"])

    case("sess_duplicate_and_phony_targets", {"main.kiln": two_steps(2, 3)},
         "build out/a.txt out/a.txt @all -j 3\nbuild @all out/b.txt -j 1\n",
         pub=False,
         expect=["step 1: build out/a.txt out/a.txt @all -j 3",
                 "  run 0 2 w0 out/a.txt write(\"A\\n\")",
                 "  run 0 3 w1 out/b.txt write(\"B\\n\")",
                 "  ok ran=2 hit=0 time=3",
                 "step 2: build @all out/b.txt -j 1",
                 "  ok ran=0 hit=2 time=0"])

    case("sess_worker_counts", {"main.kiln": two_steps(5, 5)},
         "build -j 64\nclean\nbuild -j 2\nclean\nbuild\n",
         expect=["  run 0 5 w0 out/a.txt write(\"A\\n\")",
                 "  run 0 5 w1 out/b.txt write(\"B\\n\")",
                 "  ok ran=2 hit=0 time=5",
                 "  run 5 10 w0 out/b.txt write(\"B\\n\")",
                 "  ok ran=2 hit=0 time=10"])

    case("sess_dash_j_as_target", {"main.kiln": two_steps()},
         "build out/a.txt -j\nbuild -j 2\n", pub=True,
         expect=["step 1: build out/a.txt -j -j 1",
                 "  error E_UNKNOWN_TARGET -j",
                 "step 2: build (default) -j 2"])

    case("sess_no_build_file", {},
         "build\ncreate main.kiln\nstep {\n    out \"out/hello.txt\"\n"
         "    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n---\nbuild\n",
         pub=True,
         expect=["  error E_NO_BUILD_FILE main.kiln", "step 2: create main.kiln",
                 "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"])

    case("sess_delete_then_recreate_main", {"main.kiln": HELLO},
         "build\ndelete main.kiln\nbuild\ncreate main.kiln\n"
         "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\n"
         "default \"out/hello.txt\"\n---\nbuild\n",
         expect=["  run 0 1 w0 out/hello.txt write(\"hello\\n\")",
                 "  error E_NO_BUILD_FILE main.kiln",
                 "  ok ran=0 hit=1 time=0"])

    case("sess_long_mixed", {"main.kiln": GLOB_CONCAT,
                             "src/a.txt": "a1\n", "src/b.txt": "b1\n"},
         "".join(["build -j 2\n", "touch src/a.txt\n", "build\n",
                  "edit src/b.txt\nB1\nB2\n---\n", "build -j 4\n",
                  "create src/c.txt\nc1\n---\n", "build\n", "clean\n",
                  "build -j 3\n", "delete src/c.txt\n", "build\n",
                  "edit main.kiln\n", GLOB_CONCAT.rstrip("\n"), "\n---\n",
                  "build\n"]),
         expect=["step 12: edit main.kiln", "  ok ran=0 hit=1 time=0"])


# ---------------------------------------------------------------------------
# workspace loading, paths and the output tree
# ---------------------------------------------------------------------------

def g_workspace():
    deep = "a/b/c/d/e/f/g/h/i/j/k.txt"
    longcomp = "n" * 200
    case("ws_deep_and_odd_paths",
         {"main.kiln": 'let xs = sort(glob("**/*.txt"))\n' + step_of(
             ['out "out/deep/sub/list.txt"', 'in xs', 'cmd count_lines()'],
             'default "out/deep/sub/list.txt"\n'),
          deep: "deep\n",
          "dir.with.dots/file+plus-minus.v2.txt": "odd\n",
          longcomp + "/x.txt": "long\n",
          "src/_under/.hidden.txt": "hidden\n"},
         "build\nbuild\n", pub=True,
         expect=["  run 0 2 w0 out/deep/sub/list.txt count_lines()",
                 "  ok ran=1 hit=0 time=2"])

    case("ws_binary_contents",
         {"main.kiln": ('step {\n    out "out/c.bin"\n    in "src/raw.bin"\n'
                        '    cmd copy()\n}\n'
                        'step {\n    out "out/h.txt"\n    in ["src/raw.bin", "src/raw.bin"]\n'
                        '    cmd hash()\n}\n'
                        'default ["out/c.bin", "out/h.txt"]\n'),
          "src/raw.bin": bytes(range(256)) + b"\x00\xff\n"},
         "build -j 2\nbuild\n",
         expect=["  ok ran=2 hit=0 time=3", "  ok ran=0 hit=2 time=0"])

    case("ws_preexisting_out_tree",
         {"main.kiln": HELLO, "out/hello.txt": "stale\n",
          "out/unrelated/keep.txt": "keep\n"},
         "build\nbuild\nclean\nbuild\n",
         expect=["  run 0 1 w0 out/hello.txt write(\"hello\\n\")",
                 "  ok ran=0 hit=1 time=0",
                 "  remove .kiln-state", "  remove out/hello.txt",
                 "  remove out/unrelated/keep.txt", "  ok removed=3"])

    case("ws_glob_skips_out_and_state",
         {"main.kiln": ('let xs = sort(glob("**"))\n' + step_of(
             ['out "out/g.txt"', 'cmd write("{join(xs, "|")}\\n")'],
             'default "out/g.txt"\n')),
          "src/a.txt": "a\n", "out/x.txt": "x\n", ".kiln-state": "kiln-state 1\n",
          ".dotfile": "d\n"},
         "build\n", pub=True,
         expect=['  run 0 1 w0 out/g.txt write(".dotfile|main.kiln|src/a.txt\\n")'])


# ---------------------------------------------------------------------------
# the sixteen commands
# ---------------------------------------------------------------------------

LINE_SOURCES = {
    "src/empty.txt": "",
    "src/nl.txt": "\n",
    "src/nonl.txt": "a\nb",
    "src/blank.txt": "a\n\nb\n",
    "src/cr.txt": "a\r\nb\r\n",
}


def g_commands():
    case("cmd_write_escapes",
         {"main.kiln": r'''step {
    out "out/w.txt"
    cmd write("a\\b\"c\nd\te\r\0ü\n")
}
step {
    out "out/e.txt"
    cmd write("")
}
step {
    out "out/h.txt"
    in ["out/w.txt", "out/e.txt"]
    cmd hash()
}
default "out/h.txt"
'''},
         "build -j 2\nbuild\n", pub=True,
         expect=[r'  run 0 1 w0 out/w.txt write("a\\b\"c\nd\te\r\x00ü\n")',
                 '  run 0 1 w1 out/e.txt write("")',
                 "  ok ran=3 hit=0 time=4", "  ok ran=0 hit=3 time=0"])

    case("cmd_copy_concat_dup",
         {"main.kiln": '''step {
    out "out/c.txt"
    in "src/a.txt"
    cmd copy()
}
step {
    out "out/cat.txt"
    in ["src/a.txt", "src/b.txt", "src/a.txt"]
    cmd concat()
}
step {
    out "out/one.txt"
    in "src/b.txt"
    cmd concat()
}
default ["out/c.txt", "out/cat.txt", "out/one.txt"]
''',
          "src/a.txt": "AAA\n", "src/b.txt": "B"},
         "build -j 3\n",
         expect=["  ok ran=3 hit=0 time=2"])

    case("cmd_case_nonascii",
         {"main.kiln": '''step {
    out "out/u.txt"
    in "src/m.txt"
    cmd upper()
}
step {
    out "out/l.txt"
    in "src/m.txt"
    cmd lower()
}
step {
    out "out/h.txt"
    in ["out/u.txt", "out/l.txt"]
    cmd hash()
}
default "out/h.txt"
''',
          "src/m.txt": "aAzZ ÄÖÜ äöü ß 0-9 [{}]\nMiXeD\n"},
         "build -j 2\n", pub=False,
         expect=["  ok ran=3 hit=0 time=5"])

    case("cmd_grep_variants",
         {"main.kiln": '''each i, needle in ["a", "zz", "", "b"] {
    step {
        out "out/g{i}.txt"
        in "src/t.txt"
        cmd grep(needle)
    }
}
step {
    out "out/h.txt"
    in ["out/g0.txt", "out/g1.txt", "out/g2.txt", "out/g3.txt"]
    cmd hash()
}
default "out/h.txt"
''',
          "src/t.txt": "abc\nxyz\nbbb\n\nlast no newline"},
         "build -j 4\n",
         expect=['  run 0 3 w0 out/g0.txt grep("a")',
                 '  run 0 3 w2 out/g2.txt grep("")',
                 "  ok ran=5 hit=0 time=6"])

    case("cmd_replace_variants",
         {"main.kiln": '''step {
    out "out/r0.txt"
    in "src/t.txt"
    cmd replace("aa", "b")
}
step {
    out "out/r1.txt"
    in "src/t.txt"
    cmd replace("a", "")
}
step {
    out "out/r2.txt"
    in "src/t.txt"
    cmd replace("\\n", "|")
}
step {
    out "out/h.txt"
    in ["out/r0.txt", "out/r1.txt", "out/r2.txt"]
    cmd hash()
}
default "out/h.txt"
''',
          "src/t.txt": "aaa\naaaa\nbab\n"},
         "build -j 3\n", pub=False,
         expect=['  run 0 3 w0 out/r0.txt replace("aa", "b")',
                 '  run 0 3 w2 out/r2.txt replace("\\n", "|")',
                 "  ok ran=4 hit=0 time=6"])

    case("cmd_sort_reverse_dedup",
         {"main.kiln": '''each i, c in ["sort", "rev", "dd"] {
    step {
        out "out/{c}.txt"
        in "src/t.txt"
        cmd copy()
    }
}
step {
    out "out/s.txt"
    in "src/t.txt"
    cmd sort_lines()
}
step {
    out "out/v.txt"
    in "src/t.txt"
    cmd reverse_lines()
}
step {
    out "out/d.txt"
    in "src/t.txt"
    cmd dedup()
}
step {
    out "out/h.txt"
    in ["out/s.txt", "out/v.txt", "out/d.txt"]
    cmd hash()
}
default "out/h.txt"
''',
          "src/t.txt": "b\nB\na\n\nZ\nb\nz\n\naa\nü\n"},
         "build -j 2\n",
         expect=["  run 0 4 w0 out/s.txt sort_lines()",
                 "  run 2 5 w1 out/d.txt dedup()",
                 "  ok ran=4 hit=0 time=8"])

    case("cmd_number_indent",
         {"main.kiln": '''step {
    out "out/n.txt"
    in "src/t.txt"
    cmd number()
}
step {
    out "out/i0.txt"
    in "src/t.txt"
    cmd indent(0)
}
step {
    out "out/i3.txt"
    in "src/t.txt"
    cmd indent(3)
}
step {
    out "out/h.txt"
    in ["out/n.txt", "out/i0.txt", "out/i3.txt"]
    cmd hash()
}
default "out/h.txt"
''',
          "src/t.txt": "one\n\nthree\n"},
         "build -j 3\n",
         expect=["  run 0 2 w0 out/n.txt number()",
                 "  run 0 2 w1 out/i0.txt indent(0)",
                 "  run 0 2 w2 out/i3.txt indent(3)",
                 "  ok ran=4 hit=0 time=5"])

    case("cmd_wrap_variants",
         {"main.kiln": '''step {
    out "out/w0.txt"
    in "src/t.txt"
    cmd wrap("<<", ">>")
}
step {
    out "out/w1.txt"
    in "src/t.txt"
    cmd wrap("", "")
}
step {
    out "out/w2.txt"
    in "src/e.txt"
    cmd wrap("P", "S")
}
step {
    out "out/h.txt"
    in ["out/w0.txt", "out/w1.txt", "out/w2.txt"]
    cmd hash()
}
default "out/h.txt"
''',
          "src/t.txt": "body\n", "src/e.txt": ""},
         "build\n",
         expect=['  run 0 1 w0 out/w0.txt wrap("<<", ">>")',
                 '  run 1 2 w0 out/w1.txt wrap("", "")',
                 "  ok ran=4 hit=0 time=6"])

    def line_main(cmd, suffix):
        body = []
        names = []
        for i, p in enumerate(sorted(LINE_SOURCES)):
            names.append('"out/%s%d.txt"' % (suffix, i))
            body.append('step {\n    out "out/%s%d.txt"\n    in "%s"\n    cmd %s\n}\n'
                        % (suffix, i, p, cmd))
        body.append('step {\n    out "out/%sh.txt"\n    in [%s]\n    cmd hash()\n}\n'
                    % (suffix, ", ".join(names)))
        body.append('step {\n    out "out/%sn.txt"\n    in [%s]\n    cmd count_lines()\n}\n'
                    % (suffix, ", ".join('"%s"' % p for p in sorted(LINE_SOURCES))))
        body.append('default ["out/%sh.txt", "out/%sn.txt"]\n' % (suffix, suffix))
        return "".join(body)

    case("cmd_lines_edges", dict(LINE_SOURCES, **{"main.kiln": line_main("number()", "n")}),
         "build -j 3\nbuild\n", pub=True,
         expect=["  ok ran=7 hit=0 time=7", "  ok ran=0 hit=7 time=0"])

    case("cmd_lines_edges_dedup",
         dict(LINE_SOURCES, **{"main.kiln": line_main("dedup()", "d")}),
         "build -j 8\n",
         expect=["  ok ran=7 hit=0 time=6"])

    case("cmd_count_lines_and_hash",
         {"main.kiln": '''step {
    out "out/n.txt"
    in ["src/a.txt", "src/e.txt", "src/a.txt", "src/b.txt"]
    cmd count_lines()
}
step {
    out "out/h.txt"
    in ["src/a.txt", "src/a.txt", "src/e.txt"]
    cmd hash()
}
step {
    out "out/n1.txt"
    in "src/e.txt"
    cmd count_lines()
}
default ["out/n.txt", "out/h.txt", "out/n1.txt"]
''',
          "src/a.txt": "1\n2\n", "src/b.txt": "only", "src/e.txt": ""},
         "build -j 2\nbuild\n",
         expect=["  ok ran=3 hit=0 time=4", "  ok ran=0 hit=3 time=0"])

    # One step per command with no `cost` field, run on a single worker, so the
    # start and end times spell out every default cost in the table.
    cost_specs = [
        ('write("w\\n")', None),
        ("copy()", '"src/a.txt"'),
        ("concat()", '"src/a.txt"'),
        ("upper()", '"src/a.txt"'),
        ("lower()", '"src/a.txt"'),
        ('grep("a")', '"src/a.txt"'),
        ('replace("a", "A")', '"src/a.txt"'),
        ("sort_lines()", '"src/a.txt"'),
        ("reverse_lines()", '"src/a.txt"'),
        ("dedup()", '"src/a.txt"'),
        ("number()", '"src/a.txt"'),
        ("indent(2)", '"src/a.txt"'),
        ('wrap("<", ">")', '"src/a.txt"'),
        ("count_lines()", '"src/a.txt"'),
        ("hash()", '"src/a.txt"'),
        ("preprocess()", '"src/m.txt"'),
    ]
    parts = []
    for i, (cmd, inp) in enumerate(cost_specs):
        fields = ['out "out/%02d.txt"' % i]
        if inp:
            fields.append("in " + inp)
        if cmd == "preprocess()":
            fields.append('depfile "out/%02d.d"' % i)
        fields.append("cmd " + cmd)
        parts.append(step_of(fields, ""))
    parts.append('phony all = %s\n' % ("[" + ", ".join(
        '"out/%02d.txt"' % i for i in range(len(cost_specs))) + "]"))
    parts.append('default "@all"\n')
    case("cmd_default_costs",
         {"main.kiln": "".join(parts), "src/a.txt": "b\na\nb\n",
          "src/m.txt": "m1\n@need src/a.txt\n"},
         "build\nbuild\n", pub=True,
         expect=['  run 0 1 w0 out/00.txt write("w\\n")',
                 "  run 1 2 w0 out/01.txt copy()",
                 "  run 2 4 w0 out/02.txt concat()",
                 "  run 4 6 w0 out/03.txt upper()",
                 "  run 6 8 w0 out/04.txt lower()",
                 '  run 8 11 w0 out/05.txt grep("a")',
                 '  run 11 14 w0 out/06.txt replace("a", "A")',
                 "  run 14 18 w0 out/07.txt sort_lines()",
                 "  run 18 20 w0 out/08.txt reverse_lines()",
                 "  run 20 23 w0 out/09.txt dedup()",
                 "  run 23 25 w0 out/10.txt number()",
                 "  run 25 27 w0 out/11.txt indent(2)",
                 '  run 27 28 w0 out/12.txt wrap("<", ">")',
                 "  run 28 30 w0 out/13.txt count_lines()",
                 "  run 30 33 w0 out/14.txt hash()",
                 "  run 33 39 w0 out/15.txt preprocess()",
                 "  ok ran=16 hit=0 time=39",
                 "  ok ran=0 hit=16 time=0"])


# ---------------------------------------------------------------------------
# lexical and syntactic errors
# ---------------------------------------------------------------------------

def g_parse():
    variants("parse_lexical", [
        'let x = "unterminated\n',
        "let y = 'unterminated\n",
        'let b = f(\n  "unterminated\n)\n',
        "let a = 1\n)\n",
        "let a = f(\nlet b = 2\n",
        "let x = 1\nlet y = @\n",
        "let x = 1 | 2\n",
        "let x = 1 & 2\n",
        "let x = 1 ; 2\n",
    ], pub=True, expect=errs(*["E_PARSE main.kiln:%d" % n
                               for n in (1, 1, 1, 2, 1, 2, 1, 1, 1)]))

    variants("parse_reserved_words", [
        "let cost = 1\n",
        "each in in [1] {\n}\n",
        "rule r(step) {\n}\n",
        "phony when = []\n",
        "let x = 1\nset out = 2\n",
        "rule r(a) {\n}\nuse r(when = 1)\n",
        "let true = 1\n",
        "let x = default\n",
        "each i, elsewhen in [1] {\n}\n",
    ], expect=errs(*["E_PARSE main.kiln:%d" % n
                     for n in (1, 1, 1, 1, 2, 3, 1, 1, 1)]))

    variants("parse_blocks", [
        'step {\n    out "out/z.txt"\n    cmd write("x")\n',
        "}\n",
        "when true {\n} foo\n",
        "when true {\n} otherwise {\n} elsewhen false {\n}\n",
        "when true {\n} otherwise {\n} otherwise {\n}\n",
        "each x in [1] {\n} otherwise {\n}\n",
        "{\n}\n",
        "when true {\n} elsewhen false {\n",
        "each x in [1] {\n} elsewhen true {\n}\n",
        "rule r() {\n",
    ], pub=True, expect=errs(*["E_PARSE main.kiln:%d" % n
                               for n in (1, 1, 2, 3, 3, 2, 1, 2, 2, 1)]))

    variants("parse_grammar", [
        'out "out/z.txt"\n',
        'step {\n    let x = 1\n    cmd write("x")\n    out "out/z.txt"\n}\n',
        "let x = 1 2\n",
        "rule r(a, b) {\n}\nuse r(a = 1, 2)\n",
        "rule r(a, a) {\n}\n",
        "rule r(a = 1, b) {\n}\n",
        "let x = (1)(2)\n",
        "let x = 1 |> 2\n",
        "include\n",
        "let = 1\n",
        "rule r() {\n}\nuse r\n",
        'step {\n    cmd write("x")\n    out\n}\n',
        "let x = [1, 2\n",
        'depfile "out/a.d"\n',
    ], expect=errs(*["E_PARSE main.kiln:%d" % n
                     for n in (1, 2, 1, 3, 1, 1, 1, 1, 1, 1, 3, 3, 1, 1)]))

    variants("parse_strings", [
        'let x = "{}"\n',
        'let x = "{ }"\n',
        'let x = "{1"\n',
        'let x = "{1 2}"\n',
        r'let x = "\q"' + "\n",
        'let x = "a}b"\n',
        'when false {\n    let y = "{}"\n}\n',
        'rule r() {\n    let y = "{"\n}\n',
        'let x = "{foo(}"\n',
        'let x = "}}}"\n',
        'let x = "{\'a\'}" ++ 1\n',
    ], pub=False, expect=errs(*(["E_PARSE main.kiln:%d" % n
                                 for n in (1, 1, 1, 1, 1, 1, 2, 2, 1, 1)]
                                + ["E_TYPE operator ++: expected list, got str"])))

    variants("parse_line_attribution", [
        "let a = 1\nlet b = f(\n  1,\n  2 2\n)\nlet c = 3\n",
        "let a = [\n  1,\n  2,\n]\nlet b = a[\n  0\n] [\n",
        "# comment with a ( bracket\nlet a = 1\nlet b = )\n",
        'let a = "# not a comment ("\nlet b = )\n',
        "let xs = [1,\n  2,\n  3]\nlet y = 2\nlet z = ]\n",
    ], expect=errs(*["E_PARSE main.kiln:%d" % n for n in (2, 5, 3, 2, 5)]))

    case("parse_include_attribution",
         {"main.kiln": 'let a = 1\ninclude "sub/mod.kiln"\nlet b = 2\n',
          "sub/mod.kiln": "let m = 1\nlet n = 2\nlet o = )\n"},
         "build\n", pub=False,
         expect=["  error E_PARSE sub/mod.kiln:3"])

    case("parse_include_runs_in_order",
         {"main.kiln": 'let a = 1\nabort "before"\ninclude "sub/mod.kiln"\n',
          "sub/mod.kiln": "let o = )\n"},
         "build\n",
         expect=["  error E_ABORT before"])

    case("parse_strings_positive",
         {"main.kiln": r'''let n = 7
let xs = ["a", "b"]
let s = 'raw\nand{x}'
step {
    out "out/s.txt"
    cmd write("{{literal}} {n} {n * 2 + 1} {xs[0]}-{xs[1]} {len(xs) == 2} {join(xs, ", ")} {s} # not a comment\n")
}
step {
    out "out/t.txt"
    cmd write("tab:\there\0nl:\ndq:\" bs:\\ cr:\r done\n")
}
step {
    out "out/h.txt"
    in ["out/s.txt", "out/t.txt"]
    cmd hash()
}
default "out/h.txt"
'''},
         "build -j 2\nbuild\n", pub=True,
         expect=[r'  run 0 1 w0 out/s.txt write("{literal} 7 15 a-b true a, b raw\\nand{x} # not a comment\n")',
                 r'  run 0 1 w1 out/t.txt write("tab:\there\x00nl:\ndq:\" bs:\\ cr:\r done\n")',
                 "  ok ran=0 hit=3 time=0"])


# ---------------------------------------------------------------------------
# an independent glob matcher, written from SPEC.md section 11
#
# It exists so the expected `glob`, `filter` and `reject` results are computed
# from the specification rather than copied out of the reference.
# ---------------------------------------------------------------------------

class BadGlob(Exception):
    pass


def _scan_class(pat, i):
    """Parse a character class starting just after `[`; return (neg, items, j)."""
    neg = False
    if i < len(pat) and pat[i:i + 1] == b"!":
        neg = True
        i += 1
    items = []
    while True:
        if i >= len(pat):
            raise BadGlob("unterminated class")
        if pat[i:i + 1] == b"]":
            if not items:
                raise BadGlob("empty class")
            return neg, items, i + 1
        if i + 2 < len(pat) and pat[i + 1:i + 2] == b"-" and pat[i + 2:i + 3] != b"]":
            lo, hi = pat[i], pat[i + 2]
            if lo > hi:
                raise BadGlob("reversed range")
            items.append((lo, hi))
            i += 3
        else:
            items.append((pat[i], pat[i]))
            i += 1


def _match_component(pat, cand):
    """Match one pattern component against one candidate component."""
    # Positions reachable in `cand` after consuming the pattern items so far.
    reach = {0}
    i = 0
    n = len(cand)
    while i < len(pat):
        ch = pat[i:i + 1]
        if ch == b"*":
            i += 1
            lo = min(reach)
            reach = set(range(lo, n + 1))
            continue
        if ch == b"?":
            i += 1
            reach = {p + 1 for p in reach if p < n}
        elif ch == b"[":
            neg, items, j = _scan_class(pat, i + 1)
            i = j
            nxt = set()
            for p in reach:
                if p < n:
                    b = cand[p]
                    inside = any(lo <= b <= hi for lo, hi in items)
                    if inside != neg:
                        nxt.add(p + 1)
            reach = nxt
        else:
            i += 1
            reach = {p + 1 for p in reach if p < n and cand[p] == ch[0]}
        if not reach:
            return False
    return n in reach


def spec_glob_match(pattern, candidate):
    """True when `pattern` matches the whole `/`-separated `candidate`."""
    if not pattern or pattern.startswith(b"/") or pattern.endswith(b"/"):
        raise BadGlob("bad shape")
    pcomps = pattern.split(b"/")
    for p in pcomps:
        if not p:
            raise BadGlob("empty component")
        if p != b"**":
            # Validate every class now, so a malformed pattern is rejected even
            # when matching would short-circuit before reaching it.
            k = 0
            while k < len(p):
                if p[k:k + 1] == b"[":
                    _, _, k = _scan_class(p, k + 1)
                else:
                    k += 1
    ccomps = candidate.split(b"/")

    def go(pi, ci):
        if pi == len(pcomps):
            return ci == len(ccomps)
        if pcomps[pi] == b"**":
            for take in range(len(ccomps) - ci + 1):
                if go(pi + 1, ci + take):
                    return True
            return False
        if ci == len(ccomps):
            return False
        if not _match_component(pcomps[pi], ccomps[ci]):
            return False
        return go(pi + 1, ci + 1)

    return go(0, 0)


def spec_glob(pattern, paths):
    """The `glob` built-in: sorted visible workspace paths matching `pattern`."""
    out = []
    for p in sorted(as_bytes(x) for x in paths):
        if p.split(b"/")[0] == b"out" or p == b".kiln-state":
            continue
        if spec_glob_match(as_bytes(pattern), p):
            out.append(p)
    return out


def spec_filter(pattern, items, keep=True):
    return [x for x in (as_bytes(i) for i in items)
            if spec_glob_match(as_bytes(pattern), x) == keep]


# ---------------------------------------------------------------------------
# canonical rendering, used to predict log lines
# ---------------------------------------------------------------------------

def esc(text):
    """Render a byte string as the canonical command string escapes it."""
    out = []
    for b in as_bytes(text):
        if b == 0x5C:
            out.append(b"\\\\")
        elif b == 0x22:
            out.append(b'\\"')
        elif b == 0x0A:
            out.append(b"\\n")
        elif b == 0x09:
            out.append(b"\\t")
        elif b == 0x0D:
            out.append(b"\\r")
        elif b < 0x20 or b == 0x7F:
            out.append(b"\\x%02x" % b)
        else:
            out.append(bytes([b]))
    return b'"' + b"".join(out) + b'"'


def write_table(name, prelude, rows, pub=False, files=None):
    """A case of one `write` step per row, each asserting its rendered text.

    `rows` pairs a KBL interpolation body with the text it must produce. Every
    step costs 1 and the build uses one worker, so step `i` runs from `i` to
    `i + 1` and its log line pins the produced bytes exactly.
    """
    parts = [prelude]
    expect = []
    for i, (kbl, want) in enumerate(rows):
        parts.append('step {\n    out "out/l%d.txt"\n    cmd write("%s\\n")\n}\n'
                     'default "out/l%d.txt"\n' % (i, kbl, i))
        expect.append(b"  run %d %d w0 out/l%d.txt write(%s)"
                      % (i, i + 1, i, esc(as_bytes(want) + b"\n")))
    all_files = dict(files or {})
    all_files["main.kiln"] = "".join(parts)
    case(name, all_files, "build\nbuild\n", pub=pub,
         expect=expect + [b"  ok ran=%d hit=0 time=%d" % (len(rows), len(rows)),
                          b"  ok ran=0 hit=%d time=0" % len(rows)])


# ---------------------------------------------------------------------------
# expressions and operators
# ---------------------------------------------------------------------------

def g_expr():
    write_table("expr_arithmetic", "let a = 7\nlet b = -3\n", [
        ("{a + b} {a - b} {a * b} {a / b} {a % b} {b / a} {b % a} {-a} {-(a + b)}",
         "4 10 -21 -2 1 0 -3 -7 -4"),
        ("{1 + 2 * 3 - 4 / 2} {(1 + 2) * 3} {10 % 4 * 2} {2 * 3 % 4} {7 / 2} {-7 / 2} {7 / -2} {-7 % 2}",
         "5 9 4 2 3 -3 -3 -1"),
        ('{"ab" ~ "cd" ~ ""} {count([1] ++ [2, 3] ++ [])} {!false} {!!true}',
         "abcd 3 true true"),
        ('{"abcdef"[2]}{"abcdef"[-1]}{[10, 20, 30][-2]}{[10, 20, 30][0]}',
         "cf2010"),
        ("{false && undefined_name} {true || undefined_name} {false || true} {true && false}",
         "false true true false"),
    ], pub=True)

    write_table("expr_total_order",
                'let mixed = [[1], "b", 3, true, "a", [0, 2], false, -1]\n', [
                    ("{indexof(sort(mixed), false)}|{indexof(sort(mixed), -1)}|"
                     '{indexof(sort(mixed), "a")}|{indexof(sort(mixed), [0, 2])}|'
                     "{count(sort(mixed))}",
                     "0|2|4|6|8"),
                    ('{[1, 2] == [1, 2]} {[1, "2"] == [1, 2]} {1 == true} {0 == false} '
                     '{[] == []} {[[1]] == [[1]]} {"a" != "a"}',
                     "true false false false true true false"),
                    ('{"a" < "ab"} {[1] < [1, 0]} {true < 1} {3 < "x"} {"z" < [0]} '
                     "{false < true} {-2 <= -2} {3 >= 4} {[2] > [1, 9]}",
                     "true true true true true true true false true"),
                ])

    variants("expr_type_errors", [
        'let x = 1 + "a"\n',
        'let x = "a" + 1\n',
        "let x = 1 - true\n",
        "let x = true * 2\n",
        "let x = [1] / 2\n",
        'let x = 1 % "a"\n',
        'let x = 1 ~ "a"\n',
        'let x = "a" ~ 1\n',
        'let x = [1] ++ "a"\n',
        "let x = 1 && true\n",
        "let x = true && 1\n",
        "let x = 1 || true\n",
        "let x = false || [1]\n",
        "let x = !1\n",
        'let x = -"a"\n',
        'let x = [1]["a"]\n',
        "let x = 1[0]\n",
        "let x = true[0]\n",
    ], pub=True, expect=errs(
        "E_TYPE operator +: expected int, got str",
        "E_TYPE operator +: expected int, got str",
        "E_TYPE operator -: expected int, got bool",
        "E_TYPE operator *: expected int, got bool",
        "E_TYPE operator /: expected int, got list",
        "E_TYPE operator %: expected int, got str",
        "E_TYPE operator ~: expected str, got int",
        "E_TYPE operator ~: expected str, got int",
        "E_TYPE operator ++: expected list, got str",
        "E_TYPE operator &&: expected bool, got int",
        "E_TYPE operator &&: expected bool, got int",
        "E_TYPE operator ||: expected bool, got int",
        "E_TYPE operator ||: expected bool, got list",
        "E_TYPE operator !: expected bool, got int",
        "E_TYPE operator -: expected int, got str",
        "E_TYPE index: expected int, got str",
        "E_TYPE index target: expected str|list, got int",
        "E_TYPE index target: expected str|list, got bool"))

    variants("expr_value_errors", [
        "let x = 1 / 0\n",
        "let x = 1 % 0\n",
        "let x = -1 / (2 - 2)\n",
        "let x = [1, 2][5]\n",
        "let x = [1, 2][-3]\n",
        'let x = "ab"[2]\n',
        'let x = "ab"[-3]\n',
        "let x = [][0]\n",
        "let xs = [1]\n" + step_of(['out "out/z.txt"', 'cmd write("{xs}")']),
        "let xs = [1]\n" + step_of(['out "out/z.txt"', 'cmd write("{xs[0]} ok")']),
        step_of(['out "out/z.txt"', "cmd write(missing_var)"]),
        "let x = nope(1)\n",
        "let x = nope(undefined_name)\n",
        'let x = upper(undefined_name, 2)\n',
    ], expect=errs("E_DIV_ZERO", "E_DIV_ZERO", "E_DIV_ZERO",
                   "E_ARG fn index: out of range", "E_ARG fn index: out of range",
                   "E_ARG fn index: out of range", "E_ARG fn index: out of range",
                   "E_ARG fn index: out of range", "E_INTERP list")
             + [r'  run 0 1 w0 out/z.txt write("1 ok")']
             + errs("E_UNKNOWN_VAR missing_var", "E_UNKNOWN_FUNC nope",
                    "E_UNKNOWN_FUNC nope", "E_UNKNOWN_VAR undefined_name"))


# ---------------------------------------------------------------------------
# the 39 built-in functions
# ---------------------------------------------------------------------------

def g_functions():
    write_table("fn_strings", 'let s = "Hello, World"\n', [
        ("{len(s)} {upper(s)} {lower(s)} {len(\"\")}", "12 HELLO, WORLD hello, world 0"),
        ('[{trim("  x y  ")}] [{trim("\\t\\n\\r x \\r\\n\\t")}] [{trim("")}] [{trim("  ")}]',
         "[x y] [x] [] []"),
        ('{replace(s, "l", "L")} {replace("aaa", "aa", "b")} {replace("abc", "abc", "")}',
         "HeLLo, WorLd ba "),
        ('{starts_with(s, "He")} {starts_with(s, "")} {starts_with("a", "ab")} '
         '{ends_with(s, "ld")} {ends_with(s, "")} {contains(s, "o, W")} '
         '{contains(s, "")} {contains(s, "zz")}',
         "true true false true true true true false"),
        ('{substr(s, 1, 3)}|{substr(s, -2, 5)}|{substr(s, 10, 2)}|{substr(s, 2, -1)}|'
         "{substr(s, 0, 100)}|{substr(s, -100, 2)}|{substr(s, 12, 1)}",
         "ell|ld|ld||Hello, World|He|"),
    ], pub=True)

    write_table("fn_split_join_str", "", [
        ('{join(split("a,,b", ","), "|")}|{join(split("", ","), "-")}|'
         '{join(split("abc", "x"), "-")}|{join([], "x")}|{join([1, "a", -2], "+")}|'
         '{count(split("a,b,c", ","))}|{count(split(",", ","))}',
         "a||b||abc||1+a+-2|3|2"),
        ('{join(split("aXXb", "XX"), "/")} {join(split("XXaXX", "XX"), "/")} '
         '{join(["x"], "")}',
         "a/b /a/ x"),
        ('{str(42)}|{str(-1)}|{str(true)}|{str(false)}|{str("x")}|{int("0042")}|'
         '{int(-7)}|{int("-9")}|{int("0")}|{int("-0")}',
         "42|-1|true|false|x|42|-7|-9|0|0"),
    ])

    write_table("fn_paths", "", [
        ('{dirname("src/a.txt")}|{dirname("a.txt")}|{dirname("a/b/c")}|{dirname("")}',
         "src||a/b|"),
        ('{basename("src/a.txt")}|{basename("a.txt")}|{basename("a/b/")}',
         "a.txt|a.txt|"),
        ('{stem("src/a.txt")}|{stem("src/a.b.txt")}|{stem("src/a")}|'
         '{stem("src/.hidden")}|{stem("a.txt")}|{stem("src/x.")}',
         "a|a.b|a|.hidden|a|x"),
        ('{ext("src/a.txt")}|{ext("src/a.b.txt")}|{ext("src/a")}|'
         '{ext("src/.hidden")}|{ext("a.txt")}|{ext("src/x.")}',
         ".txt|.txt|||.txt|."),
        ('{pathjoin("out", "", "a.txt")}|{pathjoin("out/")}|{pathjoin("")}|'
         '{pathjoin("a", "b", "c", "d", "e", "f", "g", "h")}',
         "out/a.txt|out/||a/b/c/d/e/f/g/h"),
    ], pub=False)

    write_table("fn_lists", "let l = [3, 1, 2, 1]\n", [
        ('{count(l)}|{len(l)}|{join(sort(l), ",")}|{join(uniq(l), ",")}|'
         '{join(reverse(l), ",")}|{first(l)}|{last(l)}',
         "4|4|1,1,2,3|3,1,2|1,2,1,3|3|1"),
        ('{join(slice(l, 1, 2), ",")}|{join(slice(l, -2, 9), ",")}|'
         '{count(slice(l, 9, 1))}|{count(slice(l, 0, -1))}',
         "1,2|2,1|0|0"),
        ('{has(l, 1)}|{has(l, 9)}|{has(l, "1")}|{indexof(l, 2)}|{indexof(l, 9)}|'
         '{indexof([[1], [2]], [2])}',
         "true|false|false|2|-1|1"),
        ('{join(range(4), ",")}|{count(range(0))}|{sum(l)}|{sum([])}|'
         '{count(flatten([[1, 2], 3, [4], []]))}|{count(flatten([]))}',
         "0,1,2,3|0|7|0|4|0"),
        ('{count(zip([1, 2, 3], [4, 5]))}|{zip([1, 2], [3, 4])[1][0]}|'
         '{count(zip([], [1]))}|{count(uniq([[1], [1], 1, "1"]))}',
         "2|2|0|3"),
        ('{is_str("a")}{is_int(1)}{is_bool(true)}{is_list([])}|'
         '{is_str(1)}{is_int("a")}{is_bool(1)}{is_list(1)}',
         "truetruetruetrue|falsefalsefalsefalse"),
        ('{join(map(["a", "b"], "out/%.o"), ",")}|{join(map(["a"], "100%%-%"), ",")}|'
         '{count(map([], "%"))}|{join(map(["x"], "no-marker"), ",")}',
         "out/a.o,out/b.o|100%-a|0|no-marker"),
    ], pub=True)

    variants("fn_errors_arity_type", [
        'let x = upper("a", "b")\n',
        "let x = upper()\n",
        "let x = pathjoin()\n",
        'let x = pathjoin("a", "b", "c", "d", "e", "f", "g", "h", "i")\n',
        'let x = substr("a", 1)\n',
        "let x = upper(1)\n",
        'let x = substr("a", "b", 1)\n',
        'let x = substr("a", 1, true)\n',
        "let x = len(1)\n",
        'let x = count("a")\n',
        "let x = sort(1)\n",
        "let x = zip([1], 2)\n",
        'let x = range("3")\n',
        'let x = has("a", 1)\n',
        "let x = str([1])\n",
        "let x = int(true)\n",
        'let x = replace("a", "b", 1)\n',
        "let x = glob(1)\n",
    ], expect=errs(
        "E_ARITY fn upper: expected 1, got 2",
        "E_ARITY fn upper: expected 1, got 0",
        "E_ARITY fn pathjoin: expected 1-8, got 0",
        "E_ARITY fn pathjoin: expected 1-8, got 9",
        "E_ARITY fn substr: expected 3, got 2",
        "E_TYPE fn upper argument 1: expected str, got int",
        "E_TYPE fn substr argument 2: expected int, got str",
        "E_TYPE fn substr argument 3: expected int, got bool",
        "E_TYPE fn len argument 1: expected str|list, got int",
        "E_TYPE fn count argument 1: expected list, got str",
        "E_TYPE fn sort argument 1: expected list, got int",
        "E_TYPE fn zip argument 2: expected list, got int",
        "E_TYPE fn range argument 1: expected int, got str",
        "E_TYPE fn has argument 1: expected list, got str",
        "E_TYPE fn str argument 1: expected str|int|bool, got list",
        "E_TYPE fn int argument 1: expected str|int, got bool",
        "E_TYPE fn replace argument 3: expected str, got int",
        "E_TYPE fn glob argument 1: expected str, got int"))

    variants("fn_errors_elements_and_args", [
        'let x = join([[1]], ",")\n',
        'let x = join([1, true], ",")\n',
        'let x = map([1], "%")\n',
        'let x = map(["a", 2], "%")\n',
        'let x = sum([1, "a"])\n',
        "let x = sum([[1]])\n",
        'let x = filter(["a", 1], "*")\n',
        'let x = reject([true], "*")\n',
        'let x = replace("a", "", "b")\n',
        'let x = split("a", "")\n',
        'let x = int("12a")\n',
        'let x = int("+1")\n',
        'let x = int(" 1")\n',
        'let x = int("")\n',
        'let x = int("99999999999999999999")\n',
        "let x = first([])\n",
        "let x = last([])\n",
        "let x = range(-1)\n",
        'let x = glob("")\n',
        'let x = glob("/a")\n',
        'let x = glob("a/")\n',
        'let x = glob("a//b")\n',
        'let x = glob("a[b")\n',
        'let x = glob("a[]b")\n',
        'let x = glob("a[!]b")\n',
        'let x = glob("a[z-a]b")\n',
        'let x = filter([1], "")\n',
        'let x = reject([], "a//b")\n',
    ], pub=True, expect=errs(
        "E_TYPE fn join element 0: expected str|int, got list",
        "E_TYPE fn join element 1: expected str|int, got bool",
        "E_TYPE fn map element 0: expected str, got int",
        "E_TYPE fn map element 1: expected str, got int",
        "E_TYPE fn sum element 1: expected int, got str",
        "E_TYPE fn sum element 0: expected int, got list",
        "E_TYPE fn filter element 1: expected str, got int",
        "E_TYPE fn reject element 0: expected str, got bool",
        "E_ARG fn replace: empty pattern",
        "E_ARG fn split: empty separator",
        "E_ARG fn int: bad integer", "E_ARG fn int: bad integer",
        "E_ARG fn int: bad integer", "E_ARG fn int: bad integer",
        "E_ARG fn int: bad integer",
        "E_ARG fn first: empty list", "E_ARG fn last: empty list",
        "E_ARG fn range: negative",
        "E_ARG fn glob: bad pattern", "E_ARG fn glob: bad pattern",
        "E_ARG fn glob: bad pattern", "E_ARG fn glob: bad pattern",
        "E_ARG fn glob: bad pattern", "E_ARG fn glob: bad pattern",
        "E_ARG fn glob: bad pattern", "E_ARG fn glob: bad pattern",
        "E_ARG fn filter: bad pattern", "E_ARG fn reject: bad pattern"))


# ---------------------------------------------------------------------------
# glob, filter and reject
# ---------------------------------------------------------------------------

GLOB_FILES = {
    "a.txt": "a\n", "ab": "ab\n", "axyzb": "axyzb\n", "lib": "lib\n",
    "src/a.txt": "sa\n", "src/b.txt": "sb\n", "src/c.txt": "sc\n",
    "src/7.txt": "s7\n", "src/ab.txt": "sab\n", "src/a1.txt": "sa1\n",
    "src/.txt": "sdot\n", "src/t.txt": "st\n", "src/t_1.txt": "st1\n",
    "src/notes.md": "md\n", "src/sub/c.txt": "sub\n",
    "src/x/y/z.txt": "xyz\n", "src/a/b/t_2.txt": "t2\n",
    "out/hidden.txt": "hidden\n", ".kiln-state": "kiln-state 1\n",
}

GLOB_PATTERNS = [
    "src/*.txt", "src/**", "**/*.txt", "src/**/t_*.txt", "src/?.txt",
    "src/[ab]*.txt", "src/[!ab]*.txt", "src/[0-9].txt", "a**b", "lib/**",
    "**", "src/**/*.txt", "[-a]*", "src/[a-]*.txt", "src/[*?]*.txt",
    "src/su?/*", "*.txt", "src/a/**/t_2.txt", "**/t_*.txt", "src/*/*.txt",
    "src/[a-c].txt", "src/[!0-9a-z]*", "**/**", "src/**/**/c.txt",
    "src/?[!.]*.txt", "s*c/*.t?t", "src/a*", "no/such/**",
]

FILTER_ITEMS = [
    "src/a.txt", "a.txt", "src/sub/a.txt", "src", "srcx", "src/.txt",
    "ab", "axyzb", "a/b", "A.TXT", "src/a.text", "src/t_1.txt", "",
    "src/7.txt", "src/a.txt", "out/x.txt", ".kiln-state",
]

FILTER_PATTERNS = ["src/*.txt", "src/**", "**/*.txt", "a**b", "[!s]*", "*",
                   "**", "src", "out/**", "?"]


def g_glob():
    paths = [p for p in GLOB_FILES if p != ".kiln-state"] + ["main.kiln"]
    parts = ['let pats = [%s]\n' % ", ".join('"%s"' % p for p in GLOB_PATTERNS)]
    parts.append('each i, p in pats {\n'
                 '    step {\n'
                 '        out "out/g{i}.txt"\n'
                 '        cmd write("{join(glob(p), " ")}\\n")\n'
                 '    }\n'
                 '    default "out/g{i}.txt"\n'
                 '}\n')
    expect = []
    for i, pat in enumerate(GLOB_PATTERNS):
        want = b" ".join(spec_glob(pat, paths)) + b"\n"
        expect.append(b"  run %d %d w0 out/g%d.txt write(%s)" % (i, i + 1, i, esc(want)))
    case("glob_patterns", dict(GLOB_FILES, **{"main.kiln": "".join(parts)}),
         "build\nbuild\n", pub=True,
         expect=expect + [b"  ok ran=0 hit=%d time=0" % len(GLOB_PATTERNS)])

    parts = ['let xs = [%s]\n' % ", ".join('"%s"' % x for x in FILTER_ITEMS)]
    parts.append('each i, p in [%s] {\n' % ", ".join('"%s"' % p for p in FILTER_PATTERNS))
    parts.append('    step {\n'
                 '        out "out/f{i}.txt"\n'
                 '        cmd write("{join(filter(xs, p), "|")}/{join(reject(xs, p), "|")}\\n")\n'
                 '    }\n'
                 '    default "out/f{i}.txt"\n'
                 '}\n')
    expect = []
    for i, pat in enumerate(FILTER_PATTERNS):
        want = (b"|".join(spec_filter(pat, FILTER_ITEMS, True)) + b"/"
                + b"|".join(spec_filter(pat, FILTER_ITEMS, False)) + b"\n")
        expect.append(b"  run %d %d w0 out/f%d.txt write(%s)" % (i, i + 1, i, esc(want)))
    case("glob_filter_reject", {"main.kiln": "".join(parts)}, "build\n",
         expect=expect)

    case("glob_sees_live_workspace",
         {"main.kiln": 'let xs = sort(glob("src/*.txt"))\n' + step_of(
             ['out "out/g.txt"', 'cmd write("{count(xs)}:{join(xs, ",")}\\n")'],
             'default "out/g.txt"\n'),
          "src/a.txt": "a\n"},
         "build\ncreate src/b.txt\nb\n---\nbuild\ndelete src/a.txt\nbuild\n"
         "create out/later.txt\nx\n---\nbuild\n",
         expect=['  run 0 1 w0 out/g.txt write("1:src/a.txt\\n")',
                 '  run 0 1 w0 out/g.txt write("2:src/a.txt,src/b.txt\\n")',
                 '  run 0 1 w0 out/g.txt write("1:src/b.txt\\n")',
                 "  ok ran=0 hit=1 time=0"])


# ---------------------------------------------------------------------------
# scopes, include, rules and use
# ---------------------------------------------------------------------------

def g_scope():
    case("scope_shadowing",
         {"main.kiln": '''let x = 1
let acc = []
each i in [0, 1] {
    let x = 10 + i
    set acc = acc ++ [x]
}
when true {
    let x = 99
    set acc = acc ++ [x]
    set x = 98
}
each i, n in ["p", "q"] {
    when i == 0 {
        set acc = acc ++ [n]
    } otherwise {
        set acc = acc ++ [upper(n)]
    }
}
''' + step_of(['out "out/s.txt"', 'cmd write("{x} {join(acc, ",")}\\n")'],
              'default "out/s.txt"\n')},
         "build\n", pub=True,
         expect=['  run 0 1 w0 out/s.txt write("1 10,11,99,p,Q\\n")'])

    case("scope_rule_capture",
         {"main.kiln": '''let base = "root"
when true {
    let base = "inner"
    rule r(n, tag = base ~ "-" ~ n) {
        step {
            out "out/{n}.txt"
            cmd write("{tag}|{base}\\n")
        }
        default "out/{n}.txt"
    }
}
let tag = "shadowed"
use r("one")
use r("two", tag = "given")
use r(n = "three")
'''},
         "build -j 3\n", pub=False,
         expect=['  run 0 1 w0 out/one.txt write("inner-one|inner\\n")',
                 '  run 0 1 w1 out/two.txt write("given|inner\\n")',
                 '  run 0 1 w2 out/three.txt write("inner-three|inner\\n")'])

    case("scope_rule_nested_and_loops",
         {"main.kiln": '''rule leaf(name, n) {
    step {
        out "out/{name}.txt"
        cmd write("{name}:{n}\\n")
        cost n
    }
    default "out/{name}.txt"
}
rule group(prefix, count) {
    each i in range(count) {
        use leaf("{prefix}_{i}", i + 1)
    }
}
use group("a", 3)
use group(prefix = "b", count = 2)
'''},
         "build -j 2\n",
         expect=['  run 0 1 w0 out/a_0.txt write("a_0:1\\n")',
                 '  run 0 2 w1 out/a_1.txt write("a_1:2\\n")',
                 '  run 1 4 w0 out/a_2.txt write("a_2:3\\n")',
                 '  run 2 3 w1 out/b_0.txt write("b_0:1\\n")',
                 '  run 3 5 w1 out/b_1.txt write("b_1:2\\n")',
                 "  ok ran=5 hit=0 time=5"])

    variants("scope_errors", [
        "let x = 1\nlet x = 2\n",
        "each i in [1] {\n    let i = 2\n}\n",
        "rule r() {\n}\nrule r() {\n}\n",
        "set y = 1\n",
        "when true {\n    set z = 1\n}\n",
        "let x = 1\nwhen true {\n    let x = 2\n}\nlet x = 3\n",
        "use nosuch()\n",
        "rule r(a) {\n}\nuse r(1, 2)\n",
        "rule r(a) {\n}\nuse r()\nuse r(b = 1)\n",
        "rule r(a, b) {\n}\nuse r(1, a = 2)\n",
        "rule r(a, b) {\n}\nuse r(1)\n",
        "rule r(a = undefined_name) {\n}\nuse r()\n",
        "when 1 {\n}\n",
        'each x in "ab" {\n}\n',
        "include 1\n",
        "abort 1\n",
        "rule r(a) {\n}\nuse r(1, b = 2)\n",
        "rule r(a, b = 1) {\n}\nuse r(b = 2, a = 3)\n",
    ], pub=True, expect=errs(
        "E_REDEFINE x", "E_REDEFINE i", "E_REDEFINE r",
        "E_SET_UNDEFINED y", "E_SET_UNDEFINED z", "E_REDEFINE x",
        "E_UNKNOWN_RULE nosuch",
        "E_ARITY rule r: expected 1, got 2",
        "E_ARG rule r: missing argument a",
        "E_ARG rule r: duplicate argument a",
        "E_ARG rule r: missing argument b",
        "E_UNKNOWN_VAR undefined_name",
        "E_TYPE when condition: expected bool, got int",
        "E_TYPE each subject: expected list, got str",
        "E_TYPE include path: expected str, got int",
        "E_TYPE abort message: expected str, got int",
        "E_ARG rule r: unknown argument b",
        "E_NO_DEFAULT"))

    variants("scope_declaration_errors", [
        'include "../x"\n',
        'include "nope.kiln"\n',
        'include ""\n',
        "default 1\n",
        'default ["a", 1]\n',
        "default []\n",
        "phony p = 1\n",
        'phony p = ["a", true]\n',
        "phony p = []\nphony p = []\n",
        'phony p = ["bad path!"]\n',
        'phony p = ["@1bad"]\n',
        'phony p = ["@ok"]\n',
        'abort "msg {1 + 1}"\n',
        'let m = "x"\nabort m ~ "!"\n',
    ], expect=errs(
        "E_BAD_PATH ../x", "E_INCLUDE_MISSING nope.kiln", "E_BAD_PATH ",
        "E_TYPE default: expected strlist, got int",
        "E_TYPE default: expected strlist, got int",
        "E_NO_DEFAULT",
        "E_TYPE phony p: expected strlist, got int",
        "E_TYPE phony p: expected strlist, got bool",
        "E_DUP_PHONY p", "E_BAD_PATH bad path!", "E_BAD_PATH @1bad",
        "E_MISSING_INPUT @ok required by @p",
        "E_ABORT msg 2", "E_ABORT x!"))

    case("scope_include_chain",
         {"main.kiln": 'let mode = "fast"\nlet flags = []\ninclude "tune/a.kiln"\n'
                       'when mode == "fast" {\n    set flags = flags ++ ["F"]\n'
                       '} elsewhen extra == 2 {\n    set flags = flags ++ ["E"]\n'
                       '} otherwise {\n    set flags = flags ++ ["S"]\n}\n'
                       + step_of(['out "out/f.txt"',
                                  'cmd write("{mode}:{extra}:{join(flags, "+")}\\n")'],
                                 'default "out/f.txt"\n'),
          "tune/a.kiln": 'set mode = "slow"\nlet extra = 1\ninclude "tune/b.kiln"\n',
          "tune/b.kiln": "set extra = extra + 1\n"},
         "build\n", pub=False,
         expect=['  run 0 1 w0 out/f.txt write("slow:2:E\\n")'])

    case("scope_include_cycle",
         {"main.kiln": 'let a = 1\ninclude "mod/a.kiln"\n',
          "mod/a.kiln": 'let b = 2\ninclude "mod/b.kiln"\n',
          "mod/b.kiln": 'include "mod/a.kiln"\n'},
         "build\n",
         expect=["  error E_INCLUDE_CYCLE mod/a.kiln"])

    case("scope_include_self_cycle",
         {"main.kiln": 'include "main.kiln"\n'}, "build\n",
         expect=["  error E_INCLUDE_CYCLE main.kiln"])

    case("scope_include_twice",
         {"main.kiln": 'include "mod/a.kiln"\ninclude "mod/a.kiln"\n',
          "mod/a.kiln": "let b = 2\n"},
         "build\n", pub=False,
         expect=["  error E_REDEFINE b"])

    case("scope_include_twice_steps_only",
         {"main.kiln": 'let i = 0\ninclude "mod/s.kiln"\nset i = 1\n'
                       'include "mod/s.kiln"\nphony all = ["out/s0.txt", "out/s1.txt"]\n'
                       'default "@all"\n',
          "mod/s.kiln": 'step {\n    out "out/s{i}.txt"\n    cmd write("{i}\\n")\n}\n'},
         "build -j 2\n",
         expect=['  run 0 1 w0 out/s0.txt write("0\\n")',
                 '  run 0 1 w1 out/s1.txt write("1\\n")'])

    case("scope_include_not_relative",
         {"main.kiln": 'include "sub/mod.kiln"\n',
          "sub/mod.kiln": 'include "other.kiln"\n',
          "sub/other.kiln": "let x = 1\n"},
         "build\n",
         expect=["  error E_INCLUDE_MISSING other.kiln"])

    case("scope_include_in_loop",
         {"main.kiln": 'each n in ["a", "b", "c"] {\n    include "mod/one.kiln"\n}\n'
                       'default map(["a", "b", "c"], "out/%.txt")\n',
          "mod/one.kiln": 'step {\n    out "out/{n}.txt"\n    cmd write("{n}\\n")\n}\n'},
         "build -j 3\n",
         expect=['  run 0 1 w0 out/a.txt write("a\\n")',
                 '  run 0 1 w2 out/c.txt write("c\\n")',
                 "  ok ran=3 hit=0 time=1"])

    recurse = '''rule r(n) {
    step {
        out "out/r{n}.txt"
        cmd write("{n}\\n")
    }
    default "out/r{n}.txt"
    when n > 1 {
        use r(n - 1)
    }
}
use r(%d)
'''
    case("scope_rule_depth_64", {"main.kiln": recurse % 64}, "build -j 8\nbuild\n",
         expect=["  ok ran=64 hit=0 time=8", "  ok ran=0 hit=64 time=0"])
    case("scope_rule_depth_65", {"main.kiln": recurse % 65}, "build\n", pub=True,
         expect=["  error E_RULE_RECURSION r"])


# ---------------------------------------------------------------------------
# step fields, paths, command shapes
# ---------------------------------------------------------------------------

SRC_A = {"src/a.txt": "a\n", "src/b.txt": "b\n"}


def g_steps():
    variants("step_field_errors", [
        'step {\n    out "out/z.txt"\n}\n',
        'step {\n    cmd write("x")\n}\n',
        "step {\n}\n",
        'step {\n    out []\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt"\n    cmd write("x")\n    cmd copy()\n}\n',
        'step {\n    out "out/z.txt"\n    cost 1\n    cost undefined_name\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt"\n    depfile "out/z.d"\n    depfile "out/y.d"\n    cmd preprocess()\n}\n',
        'step {\n    out 1\n    cmd write("x")\n}\n',
        'step {\n    out ["out/z.txt", 1]\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt"\n    in 1\n    cmd copy()\n}\n',
        'step {\n    out "out/z.txt"\n    after true\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt"\n    cost "x"\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt"\n    cost 0 - 1\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt"\n    depfile 1\n    cmd preprocess()\n}\n',
        'step {\n    out "out/z.txt"\n    cmd nosuch()\n}\n',
        'step {\n    out "out/z.txt"\n    cmd nosuch(undefined_name)\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    cmd grep()\n}\n',
        'step {\n    out "out/z.txt"\n    cmd write("a", "b")\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    cmd copy(1)\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    cmd grep(1)\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    cmd indent("x")\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    cmd replace("a", 1)\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    cmd replace("", "x")\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    cmd indent(0 - 1)\n}\n',
    ], pub=True, files=SRC_A, expect=errs(
        "E_STEP_FIELD missing cmd", "E_STEP_FIELD missing out",
        "E_STEP_FIELD missing cmd", "E_STEP_FIELD missing out",
        "E_STEP_FIELD duplicate cmd", "E_STEP_FIELD duplicate cost",
        "E_STEP_FIELD duplicate depfile",
        "E_TYPE field out: expected strlist, got int",
        "E_TYPE field out: expected strlist, got int",
        "E_TYPE field in: expected strlist, got int",
        "E_TYPE field after: expected strlist, got bool",
        "E_TYPE field cost: expected int, got str",
        "E_ARG field cost: negative",
        "E_TYPE field depfile: expected str, got int",
        "E_UNKNOWN_CMD nosuch", "E_UNKNOWN_CMD nosuch",
        "E_ARITY cmd grep: expected 1, got 0",
        "E_ARITY cmd write: expected 1, got 2",
        "E_ARITY cmd copy: expected 0, got 1",
        "E_TYPE cmd grep argument 1: expected str, got int",
        "E_TYPE cmd indent argument 1: expected int, got str",
        "E_TYPE cmd replace argument 2: expected str, got int",
        "E_ARG cmd replace: empty pattern",
        "E_ARG cmd indent: negative"))

    long_comp = "n" * 256
    long_path = "out/" + "/".join(["d" * 100] * 11)
    variants("step_path_errors", [
        'step {\n    out "z.txt"\n    cmd write("x")\n}\n',
        'step {\n    out "outx/z.txt"\n    cmd write("x")\n}\n',
        'step {\n    out "../out/z.txt"\n    cmd write("x")\n}\n',
        'step {\n    out "/out/z.txt"\n    cmd write("x")\n}\n',
        'step {\n    out "out//z.txt"\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt/"\n    cmd write("x")\n}\n',
        'step {\n    out "out/z z.txt"\n    cmd write("x")\n}\n',
        'step {\n    out "out/*.txt"\n    cmd write("x")\n}\n',
        'step {\n    out ""\n    cmd write("x")\n}\n',
        'step {\n    out "out/./z.txt"\n    cmd write("x")\n}\n',
        'step {\n    out "out/%s.txt"\n    cmd write("x")\n}\n' % long_comp,
        'step {\n    out "%s"\n    cmd write("x")\n}\n' % long_path,
        'step {\n    out ["out/z.txt", "bad.txt"]\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt"\n    depfile "z.d"\n    in "src/a.txt"\n    cmd preprocess()\n}\n',
        'step {\n    out "out/z.txt"\n    depfile "out/d d"\n    in "src/a.txt"\n    cmd preprocess()\n}\n',
        'step {\n    out "out/z.txt"\n    in "bad path"\n    cmd copy()\n}\n',
        'step {\n    out "out/z.txt"\n    in "@1x"\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt"\n    after "@"\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt"\n    in ".."\n    cmd copy()\n}\n',
        'step {\n    out "bad.txt"\n    in "also bad"\n    cmd copy()\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    after "bad after"\n    cmd copy()\n}\n',
    ], files=SRC_A, expect=errs(
        "E_OUTPUT_PATH z.txt", "E_OUTPUT_PATH outx/z.txt",
        "E_BAD_PATH ../out/z.txt", "E_BAD_PATH /out/z.txt",
        "E_BAD_PATH out//z.txt", "E_BAD_PATH out/z.txt/",
        "E_BAD_PATH out/z z.txt", "E_BAD_PATH out/*.txt",
        "E_BAD_PATH ", "E_BAD_PATH out/./z.txt",
        "E_BAD_PATH out/%s.txt" % long_comp, "E_BAD_PATH %s" % long_path,
        "E_OUTPUT_PATH bad.txt", "E_OUTPUT_PATH z.d",
        "E_BAD_PATH out/d d", "E_BAD_PATH bad path",
        "E_BAD_PATH @1x", "E_BAD_PATH @",
        "E_BAD_PATH ..", "E_OUTPUT_PATH bad.txt",
        "E_BAD_PATH bad after"))

    variants("step_cmd_shapes", [
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    cmd write("x")\n}\n',
        'step {\n    out "out/z.txt"\n    cmd copy()\n}\n',
        'step {\n    out "out/z.txt"\n    in ["src/a.txt", "src/b.txt"]\n    cmd copy()\n}\n',
        'step {\n    out "out/z.txt"\n    cmd concat()\n}\n',
        'step {\n    out "out/z.txt"\n    cmd count_lines()\n}\n',
        'step {\n    out "out/z.txt"\n    cmd hash()\n}\n',
        'step {\n    out ["out/z.txt", "out/y.txt"]\n    in "src/a.txt"\n    cmd copy()\n}\n',
        'step {\n    out "out/z.txt"\n    out "out/y.txt"\n    in "src/a.txt"\n    cmd copy()\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    depfile "out/z.d"\n    cmd copy()\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    cmd preprocess()\n}\n',
        'step {\n    out ["out/z.txt", "out/y.txt"]\n    cmd copy()\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    depfile "out/z.d"\n    cmd preprocess()\n    cost 0\n}\ndefault "out/z.txt"\n',
    ], pub=True, files=SRC_A, expect=errs(
        "E_CMD_SHAPE write: expected inputs 0-0, got 1",
        "E_CMD_SHAPE copy: expected inputs 1-1, got 0",
        "E_CMD_SHAPE copy: expected inputs 1-1, got 2",
        "E_CMD_SHAPE concat: expected inputs 1-N, got 0",
        "E_CMD_SHAPE count_lines: expected inputs 1-N, got 0",
        "E_CMD_SHAPE hash: expected inputs 1-N, got 0",
        "E_CMD_SHAPE copy: expected outputs 1, got 2",
        "E_CMD_SHAPE copy: expected outputs 1, got 2",
        "E_CMD_SHAPE copy: depfile not allowed",
        "E_CMD_SHAPE preprocess: depfile required",
        "E_CMD_SHAPE copy: expected inputs 1-1, got 0")
        + ["  run 0 0 w0 out/z.txt preprocess()"])

    case("step_phony_inputs_not_counted",
         {"main.kiln": '''phony gate = []
step {
    out "out/w.txt"
    in "@gate"
    cmd write("w\\n")
}
step {
    out "out/c.txt"
    in ["@gate", "src/a.txt"]
    cmd copy()
}
step {
    out "out/m.txt"
    out "out/m.txt"
    in ["src/a.txt", "@gate", "src/b.txt"]
    cmd concat()
}
phony all = ["out/w.txt", "out/c.txt"]
default "@all"
''', "src/a.txt": "a\n", "src/b.txt": "b\n"},
         "build -j 2\n", pub=False,
         expect=["  error E_CMD_SHAPE concat: expected outputs 1, got 2"])

    case("step_multiple_field_lines",
         {"main.kiln": '''let extra = ["src/b.txt"]
step {
    out "out/j.txt"
    in "src/a.txt"
    in extra
    in []
    after "src/c.txt"
    after []
    cmd concat()
    cost 3
}
default "out/j.txt"
''', "src/a.txt": "a\n", "src/b.txt": "b\n", "src/c.txt": "c\n"},
         "build\nbuild\n", pub=False,
         expect=["  run 0 3 w0 out/j.txt concat()", "  ok ran=0 hit=1 time=0"])

    case("step_out_tree_root_path",
         {"main.kiln": '''step {
    out "out"
    cmd write("root\\n")
}
step {
    out "out.txt.generated/x"
    cmd write("nope\\n")
}
default "out"
'''},
         "build\n",
         expect=["  error E_OUTPUT_PATH out.txt.generated/x"])


# ---------------------------------------------------------------------------
# the graph: duplicates, resolution, reachability, cycles
# ---------------------------------------------------------------------------

def g_graph():
    variants("graph_resolution_errors", [
        'step {\n    out "out/z.txt"\n    cmd write("1\\n")\n}\n'
        'step {\n    out "out/z.txt"\n    cmd write("2\\n")\n}\ndefault "out/z.txt"\n',
        'step {\n    out "out/z.txt"\n    depfile "out/z.txt"\n    in "src/a.txt"\n'
        '    cmd preprocess()\n}\ndefault "out/z.txt"\n',
        'step {\n    out "out/z.txt"\n    cmd write("1\\n")\n}\n'
        'step {\n    out "out/u.txt"\n    depfile "out/z.txt"\n    in "src/a.txt"\n'
        '    cmd preprocess()\n}\ndefault "out/z.txt"\n',
        'step {\n    out "out/z.txt"\n    in ["src/a.txt", "src/missing.txt"]\n'
        '    cmd concat()\n}\ndefault "out/z.txt"\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    after "src/gone.txt"\n'
        '    cmd copy()\n}\ndefault "out/z.txt"\n',
        'step {\n    out "out/z.txt"\n    in "@nophony"\n    cmd write("x\\n")\n}\n'
        'default "out/z.txt"\n',
        'phony p = ["src/a.txt", "@q"]\nstep {\n    out "out/z.txt"\n'
        '    cmd write("x\\n")\n}\ndefault "out/z.txt"\n',
        'step {\n    out "out/z.txt"\n    cmd write("x\\n")\n}\ndefault "out/other.txt"\n',
        'step {\n    out "out/z.txt"\n    cmd write("x\\n")\n}\ndefault "@nope"\n',
        'step {\n    out "out/z.txt"\n    cmd write("x\\n")\n}\ndefault "not a path"\n',
        'step {\n    out "out/z.txt"\n    cmd write("x\\n")\n}\n',
        'step {\n    out "out/z.txt"\n    in "src/a.txt"\n    in "src/missing.txt"\n'
        '    after "src/other.txt"\n    cmd concat()\n}\n'
        'phony p = ["src/nope.txt"]\ndefault "out/z.txt"\n',
    ], pub=True, files=SRC_A, expect=errs(
        "E_DUP_OUTPUT out/z.txt", "E_DUP_OUTPUT out/z.txt", "E_DUP_OUTPUT out/z.txt",
        "E_MISSING_INPUT src/missing.txt required by out/z.txt",
        "E_MISSING_INPUT src/gone.txt required by out/z.txt",
        "E_MISSING_INPUT @nophony required by out/z.txt",
        "E_MISSING_INPUT @q required by @p",
        "E_UNKNOWN_TARGET out/other.txt", "E_UNKNOWN_TARGET @nope",
        "E_UNKNOWN_TARGET not a path", "E_NO_DEFAULT",
        "E_MISSING_INPUT src/missing.txt required by out/z.txt"))

    case("graph_build_line_targets",
         {"main.kiln": two_steps(), "src/a.txt": "a\n"},
         "build out/nope.txt\nbuild @nope\nbuild not/a*path\nbuild src/a.txt\n"
         "build out/a.txt\n", pub=False,
         expect=["  error E_UNKNOWN_TARGET out/nope.txt",
                 "  error E_UNKNOWN_TARGET @nope",
                 "  error E_UNKNOWN_TARGET not/a*path",
                 "step 4: build src/a.txt -j 1", "  ok ran=0 hit=0 time=0",
                 '  run 0 1 w0 out/a.txt write("A\\n")'])

    case("graph_default_checked_with_explicit_targets",
         {"main.kiln": 'step {\n    out "out/a.txt"\n    cmd write("A\\n")\n}\n'
                       'default ["out/a.txt", "out/missing.txt"]\n'},
         "build out/a.txt\n",
         expect=["  error E_UNKNOWN_TARGET out/missing.txt"])

    case("graph_unreachable_steps_validated",
         {"main.kiln": '''step {
    out "out/reach.txt"
    cmd write("r\\n")
}
step {
    out "out/dup.txt"
    cmd write("1\\n")
}
step {
    out "out/dup.txt"
    cmd write("2\\n")
}
default "out/reach.txt"
'''},
         "build\n",
         expect=["  error E_DUP_OUTPUT out/dup.txt"])

    case("graph_unreachable_steps_not_run",
         {"main.kiln": '''step {
    out "out/a.txt"
    cmd write("A\\n")
}
step {
    out "out/b.txt"
    in "out/a.txt"
    cmd copy()
}
step {
    out "out/idle.txt"
    cmd write("idle\\n")
    cost 9
}
default "out/b.txt"
'''},
         "build\nbuild out/idle.txt\nbuild out/b.txt out/idle.txt\n", pub=True,
         expect=["  run 0 1 w0 out/a.txt write(\"A\\n\")",
                 "  run 1 2 w0 out/b.txt copy()",
                 "  ok ran=2 hit=0 time=2",
                 "  run 0 9 w0 out/idle.txt write(\"idle\\n\")",
                 "  ok ran=1 hit=0 time=9",
                 "  ok ran=0 hit=3 time=0"])

    case("graph_step_output_shadows_source",
         {"main.kiln": '''step {
    out "out/gen.txt"
    in "src/a.txt"
    cmd upper()
    cost 4
}
step {
    out "out/use.txt"
    in "out/gen.txt"
    cmd copy()
}
default "out/use.txt"
''', "src/a.txt": "a\n", "out/gen.txt": "pre-existing\n"},
         "build -j 4\n", pub=False,
         expect=["  run 0 4 w0 out/gen.txt upper()",
                 "  run 4 5 w0 out/use.txt copy()"])

    case("graph_source_node_and_phony_timing",
         {"main.kiln": '''phony empty = []
phony gate = ["out/slow.txt"]
step {
    out "out/slow.txt"
    in "src/a.txt"
    cmd copy()
    cost 5
}
step {
    out "out/after_gate.txt"
    in "@gate"
    cmd write("g\\n")
}
step {
    out "out/after_empty.txt"
    in "@empty"
    cmd write("e\\n")
}
phony all = ["out/after_gate.txt", "out/after_empty.txt"]
default "@all"
''', "src/a.txt": "a\n"},
         "build -j 4\n",
         expect=["  run 0 5 w0 out/slow.txt copy()",
                 '  run 0 1 w1 out/after_empty.txt write("e\\n")',
                 '  run 5 6 w0 out/after_gate.txt write("g\\n")',
                 "  ok ran=3 hit=0 time=6"])

    case("graph_diamond",
         {"main.kiln": '''step {
    out "out/top.txt"
    in "src/a.txt"
    cmd copy()
}
each i, n in ["left", "right"] {
    step {
        out "out/{n}.txt"
        in "out/top.txt"
        cmd wrap("{n}:", "\\n")
        cost i + 2
    }
}
step {
    out "out/join.txt"
    in ["out/left.txt", "out/right.txt"]
    after "@both"
    cmd concat()
}
phony both = ["out/left.txt", "out/right.txt"]
default "out/join.txt"
''', "src/a.txt": "a\n"},
         "build -j 2\nbuild -j 2\n", pub=True,
         expect=["  run 0 1 w0 out/top.txt copy()",
                 '  run 1 3 w0 out/left.txt wrap("left:", "\\n")',
                 '  run 1 4 w1 out/right.txt wrap("right:", "\\n")',
                 "  run 4 6 w0 out/join.txt concat()",
                 "  ok ran=4 hit=0 time=6", "  ok ran=0 hit=4 time=0"])

    variants("graph_cycles", [
        'step {\n    out "out/a.txt"\n    in "out/a.txt"\n    cmd copy()\n}\n'
        'default "out/a.txt"\n',
        'step {\n    out "out/x.txt"\n    in "out/y.txt"\n    cmd copy()\n}\n'
        'step {\n    out "out/y.txt"\n    in "out/x.txt"\n    cmd copy()\n}\n'
        'default "out/x.txt"\n',
        'phony a = ["@b"]\nphony b = ["@a"]\ndefault "@a"\n',
        'step {\n    out "out/top.txt"\n    in "@p"\n    cmd write("t\\n")\n}\n'
        'step {\n    out "out/mid.txt"\n    in "out/top.txt"\n    cmd copy()\n}\n'
        'phony p = ["out/mid.txt"]\ndefault "out/top.txt"\n',
        'step {\n    out "out/r.txt"\n    in "out/a.txt"\n    cmd copy()\n}\n'
        'step {\n    out "out/a.txt"\n    in "out/b.txt"\n    cmd copy()\n}\n'
        'step {\n    out "out/b.txt"\n    in "out/a.txt"\n    cmd copy()\n}\n'
        'default "out/r.txt"\n',
        'step {\n    out "out/a.txt"\n    after "out/b.txt"\n    cmd write("a\\n")\n}\n'
        'step {\n    out "out/b.txt"\n    after "out/a.txt"\n    cmd write("b\\n")\n}\n'
        'default ["out/b.txt", "out/a.txt"]\n',
        'step {\n    out "out/ok.txt"\n    cmd write("ok\\n")\n}\n'
        'step {\n    out "out/c1.txt"\n    in "out/c2.txt"\n    cmd copy()\n}\n'
        'step {\n    out "out/c2.txt"\n    in "out/c1.txt"\n    cmd copy()\n}\n'
        'default "out/ok.txt"\n',
        'step {\n    out "out/a.txt"\n    in ["src/a.txt", "out/b.txt"]\n    cmd concat()\n}\n'
        'step {\n    out "out/b.txt"\n    in ["src/b.txt", "out/c.txt"]\n    cmd concat()\n}\n'
        'step {\n    out "out/c.txt"\n    in ["src/a.txt", "out/a.txt"]\n    cmd concat()\n}\n'
        'phony all = ["out/a.txt", "out/b.txt", "out/c.txt"]\ndefault "@all"\n',
    ], pub=True, files=SRC_A, expect=errs(
        "E_CYCLE out/a.txt -> out/a.txt",
        "E_CYCLE out/x.txt -> out/y.txt -> out/x.txt",
        "E_CYCLE @a -> @b -> @a",
        "E_CYCLE out/top.txt -> @p -> out/mid.txt -> out/top.txt",
        "E_CYCLE out/a.txt -> out/b.txt -> out/a.txt",
        "E_CYCLE out/b.txt -> out/a.txt -> out/b.txt")
        + ['  run 0 1 w0 out/ok.txt write("ok\\n")']
        + errs("E_CYCLE out/a.txt -> out/b.txt -> out/c.txt -> out/a.txt"))

    case("graph_serial_order_tie_break",
         {"main.kiln": '''each i in range(6) {
    step {
        out "out/s{i}.txt"
        cmd write("{i}\\n")
        cost 7 - i
    }
    default "out/s{i}.txt"
}
'''},
         "build -j 3\n", pub=False,
         expect=['  run 0 7 w0 out/s0.txt write("0\\n")',
                 '  run 0 6 w1 out/s1.txt write("1\\n")',
                 '  run 0 5 w2 out/s2.txt write("2\\n")',
                 '  run 5 9 w2 out/s3.txt write("3\\n")',
                 '  run 6 9 w1 out/s4.txt write("4\\n")',
                 '  run 7 9 w0 out/s5.txt write("5\\n")',
                 "  ok ran=6 hit=0 time=9"])

    case("graph_phony_chain",
         {"main.kiln": '''phony a = ["@b", "@c"]
phony b = ["out/b.txt"]
phony c = ["@b", "out/c.txt"]
step {
    out "out/b.txt"
    cmd write("b\\n")
    cost 2
}
step {
    out "out/c.txt"
    in "@b"
    cmd write("c\\n")
}
default "@a"
'''},
         "build -j 4\nbuild\n",
         expect=['  run 0 2 w0 out/b.txt write("b\\n")',
                 '  run 2 3 w0 out/c.txt write("c\\n")',
                 "  ok ran=2 hit=0 time=3", "  ok ran=0 hit=2 time=0"])


# ---------------------------------------------------------------------------
# the worked examples from SPEC.md, transcribed with their published logs
# ---------------------------------------------------------------------------

EX3 = '''step {
    out "out/a.txt"
    cmd write("A\\n")
    cost 3
}
step {
    out "out/b.txt"
    cmd write("B\\n")
    cost 1
}
step {
    out "out/c.txt"
    cmd write("C\\n")
    cost 4
}
step {
    out "out/d.txt"
    cmd write("D\\n")
    cost 2
}
step {
    out "out/all.txt"
    in ["out/a.txt", "out/b.txt", "out/c.txt", "out/d.txt"]
    cmd concat()
    cost 2
}
default "out/all.txt"
'''

EX7 = '''step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/main.txt"
    cmd preprocess()
}
default "out/doc.txt"
'''

EX12 = '''step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/main.txt"
    cmd preprocess()
}
step {
    out "out/slow.txt"
    cmd write("slow\\n")
    cost 10
}
step {
    out "out/after.txt"
    in "out/doc.txt"
    cmd copy()
}
phony all = ["out/doc.txt", "out/slow.txt", "out/after.txt"]
default "@all"
'''

EX14 = '''step {
    out "out/j.txt"
    in [%s]
    cmd concat()%s
}
default "out/j.txt"
'''


def g_examples():
    case("ex01_one_step", {"main.kiln": HELLO}, "build\n", pub=True,
         expect=['step 1: build (default) -j 1',
                 '  run 0 1 w0 out/hello.txt write("hello\\n")',
                 "  ok ran=1 hit=0 time=1"])

    case("ex02_hit_and_touch", {"main.kiln": HELLO},
         "build\nbuild\ntouch main.kiln\nbuild\n", pub=False,
         expect=['  run 0 1 w0 out/hello.txt write("hello\\n")',
                 "  ok ran=1 hit=0 time=1", "  hit 0 out/hello.txt",
                 "  ok ran=0 hit=1 time=0", "step 3: touch main.kiln", "  ok",
                 "  hit 0 out/hello.txt", "  ok ran=0 hit=1 time=0"])

    case("ex03_parallel_tie_break", {"main.kiln": EX3}, "build -j 2\n", pub=True,
         expect=['  run 0 3 w0 out/a.txt write("A\\n")',
                 '  run 0 1 w1 out/b.txt write("B\\n")',
                 '  run 1 5 w1 out/c.txt write("C\\n")',
                 '  run 3 5 w0 out/d.txt write("D\\n")',
                 "  run 5 7 w0 out/all.txt concat()",
                 "  ok ran=5 hit=0 time=7"])

    case("ex04_each_map_phony",
         {"main.kiln": '''let names = ["alpha", "beta", "gamma"]
let outs = map(names, "out/%.txt")
each i, n in names {
    step {
        out "out/{n}.txt"
        cmd write("{i}:{n}\\n")
        cost 1
    }
}
step {
    out "out/index.txt"
    in outs
    cmd concat()
}
phony all = ["out/index.txt"]
default "@all"
'''},
         "build @all -j 3\n", pub=False,
         expect=["step 1: build @all -j 3",
                 '  run 0 1 w0 out/alpha.txt write("0:alpha\\n")',
                 '  run 0 1 w1 out/beta.txt write("1:beta\\n")',
                 '  run 0 1 w2 out/gamma.txt write("2:gamma\\n")',
                 "  run 1 3 w0 out/index.txt concat()",
                 "  ok ran=4 hit=0 time=3"])

    case("ex05_rules_and_chain",
         {"main.kiln": '''rule bundle(name, parts, weight = 2) {
    step {
        out "out/{name}.txt"
        in parts
        cmd concat()
        cost weight
    }
}

let base = ["src/a.txt", "src/b.txt"]
use bundle("one", base)
use bundle(name = "two", parts = base ++ ["out/one.txt"], weight = 5)
phony all = ["out/one.txt", "out/two.txt"]
default "@all"
''', "src/a.txt": "AAA\n", "src/b.txt": "BBB\n"},
         "build -j 2\n", pub=True,
         expect=["  run 0 2 w0 out/one.txt concat()",
                 "  run 2 7 w0 out/two.txt concat()",
                 "  ok ran=2 hit=0 time=7"])

    case("ex06_glob_include_set_when",
         {"main.kiln": '''let mode = "fast"
let flags = []
include "tune.kiln"
when mode == "fast" {
    set flags = flags ++ ["F"]
} otherwise {
    set flags = flags ++ ["S"]
}
let srcs = glob("src/**/*.txt")
step {
    out "out/list.txt"
    in srcs
    cmd count_lines()
}
step {
    out "out/flags.txt"
    cmd write("{join(flags, ",")}\\n")
}
default ["out/list.txt", "out/flags.txt"]
''',
          "tune.kiln": 'set mode = "slow"\nlet extra = 1\n',
          "src/a.txt": "a1\n", "src/b.txt": "b1\n", "src/sub/c.txt": "c1\n",
          "src/notes.md": "note\n"},
         "build -j 2\n", pub=False,
         expect=["  run 0 2 w0 out/list.txt count_lines()",
                 '  run 0 1 w1 out/flags.txt write("S\\n")',
                 "  ok ran=2 hit=0 time=2"])

    case("ex07_preprocess_depfile",
         {"main.kiln": EX7,
          "src/main.txt": "title\n@need src/part.txt\nend\n",
          "src/part.txt": "PART-A\n@need src/deep.txt\n",
          "src/deep.txt": "DEEP\n"},
         "build\nbuild\nedit src/deep.txt\nDEEP2\n---\nbuild\n", pub=True,
         expect=["  run 0 6 w0 out/doc.txt preprocess()",
                 "  ok ran=1 hit=0 time=6", "  hit 0 out/doc.txt",
                 "  ok ran=0 hit=1 time=0", "step 3: edit src/deep.txt",
                 "  ok size=6", "  run 0 6 w0 out/doc.txt preprocess()",
                 "  ok ran=1 hit=0 time=6"])

    case("ex08_early_cutoff",
         {"main.kiln": '''step {
    out "out/mid.txt"
    in "src/a.txt"
    cmd upper()
}
step {
    out "out/final.txt"
    in "out/mid.txt"
    cmd number()
}
default "out/final.txt"
''', "src/a.txt": "abc\n"},
         "build\nedit src/a.txt\nABC\n---\nbuild\n", pub=True,
         expect=["  run 0 2 w0 out/mid.txt upper()",
                 "  run 2 4 w0 out/final.txt number()",
                 "  ok ran=2 hit=0 time=4", "  ok size=4",
                 "  run 0 2 w0 out/mid.txt upper()",
                 "  hit 2 out/final.txt", "  ok ran=1 hit=1 time=2"])

    case("ex09_cycle",
         {"main.kiln": '''step {
    out "out/x.txt"
    in "out/y.txt"
    cmd copy()
}
step {
    out "out/y.txt"
    in "out/x.txt"
    cmd copy()
}
default "out/x.txt"
'''},
         "build\n", pub=False,
         expect=["  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt"])

    case("ex10a_dup_output",
         {"main.kiln": '''step {
    out "out/z.txt"
    cmd write("1\\n")
}
step {
    out "out/z.txt"
    cmd write("2\\n")
}
default "out/z.txt"
'''}, "build\n", expect=["  error E_DUP_OUTPUT out/z.txt"])

    case("ex10b_missing_input",
         {"main.kiln": '''step {
    out "out/z.txt"
    in ["src/a.txt", "src/missing.txt"]
    cmd concat()
}
default "out/z.txt"
''', "src/a.txt": "a\n"}, "build\n",
         expect=["  error E_MISSING_INPUT src/missing.txt required by out/z.txt"])

    case("ex10c_unknown_var",
         {"main.kiln": '''step {
    out "out/z.txt"
    cmd write(greeting)
}
default "out/z.txt"
'''}, "build\n", expect=["  error E_UNKNOWN_VAR greeting"])

    case("ex10d_abort",
         {"main.kiln": 'let n = 3\nwhen n > 2 {\n    abort "n too large: {n}"\n}\n'},
         "build\n", expect=["  error E_ABORT n too large: 3"])

    case("ex10e_no_default",
         {"main.kiln": 'step {\n    out "out/z.txt"\n    cmd write("ok\\n")\n}\n'},
         "build\n", expect=["  error E_NO_DEFAULT"])

    case("ex11_clean", {"main.kiln": HELLO}, "build\nclean\nbuild\n",
         expect=['  run 0 1 w0 out/hello.txt write("hello\\n")',
                 "  ok ran=1 hit=0 time=1", "step 2: clean",
                 "  remove .kiln-state", "  remove out/hello.txt",
                 "  ok removed=2", '  run 0 1 w0 out/hello.txt write("hello\\n")',
                 "  ok ran=1 hit=0 time=1"])

    case("ex12_fail_and_cancel",
         {"main.kiln": EX12, "src/main.txt": "@need src/gone.txt\n"},
         "build -j 2\n", pub=True,
         expect=["  fail 0 6 w0 out/doc.txt preprocess()",
                 '  cancel 0 10 w1 out/slow.txt write("slow\\n")',
                 "  error E_NEED_MISSING src/gone.txt needed by src/main.txt"])

    case("ex13_after_is_order_only",
         {"main.kiln": '''step {
    out "out/gen.txt"
    in "src/a.txt"
    cmd copy()
}
step {
    out "out/rep.txt"
    after "out/gen.txt"
    cmd write("report\\n")
}
phony all = ["out/rep.txt"]
default "@all"
''', "src/a.txt": "a\n"},
         "build\nedit src/a.txt\nb\n---\nbuild\n",
         expect=["  run 0 1 w0 out/gen.txt copy()",
                 '  run 1 2 w0 out/rep.txt write("report\\n")',
                 "  ok ran=2 hit=0 time=2", "  ok size=2",
                 "  run 0 1 w0 out/gen.txt copy()",
                 "  hit 1 out/rep.txt", "  ok ran=1 hit=1 time=1"])

    ex14_first = EX14 % ('"src/a.txt", "src/b.txt"', "")
    ex14_second = EX14 % ('"src/a.txt", "src/b.txt"', "\n    cost 5")
    ex14_third = EX14 % ('"src/b.txt", "src/a.txt"', "\n    cost 5")
    case("ex14_cost_and_dep_set",
         {"main.kiln": ex14_first, "src/a.txt": "a\n", "src/b.txt": "a\n"},
         "build\nedit main.kiln\n" + ex14_second.rstrip("\n") + "\n---\nbuild\n"
         "edit main.kiln\n" + ex14_third.rstrip("\n") + "\n---\nbuild\n",
         pub=True,
         expect=["  run 0 2 w0 out/j.txt concat()", "  ok ran=1 hit=0 time=2",
                 "  ok size=111", "  hit 0 out/j.txt", "  ok ran=0 hit=1 time=0",
                 "  ok size=111", "  run 0 5 w0 out/j.txt concat()",
                 "  ok ran=1 hit=0 time=5"])

    case("ex15_output_tampering", {"main.kiln": HELLO},
         "build\nedit out/hello.txt\ntampered\n---\nbuild\n"
         "delete out/hello.txt\nbuild\n",
         expect=['  run 0 1 w0 out/hello.txt write("hello\\n")',
                 "  ok size=9", '  run 0 1 w0 out/hello.txt write("hello\\n")',
                 "step 4: delete out/hello.txt", "  ok",
                 '  run 0 1 w0 out/hello.txt write("hello\\n")',
                 "  ok ran=1 hit=0 time=1"])


# ---------------------------------------------------------------------------
# the scheduler
# ---------------------------------------------------------------------------

def g_scheduler():
    case("sched_cost_zero",
         {"main.kiln": '''step {
    out "out/z0.txt"
    cmd write("0\\n")
    cost 0
}
step {
    out "out/z1.txt"
    in "out/z0.txt"
    cmd copy()
    cost 0
}
step {
    out "out/z2.txt"
    in "out/z1.txt"
    cmd copy()
    cost 1
}
step {
    out "out/z3.txt"
    cmd write("3\\n")
    cost 0
}
phony all = ["out/z2.txt", "out/z3.txt"]
default "@all"
'''},
         "build\nbuild -j 2\nbuild\n", pub=True,
         expect=['  run 0 0 w0 out/z0.txt write("0\\n")',
                 "  run 0 0 w0 out/z1.txt copy()",
                 "  run 0 1 w0 out/z2.txt copy()",
                 '  run 1 1 w0 out/z3.txt write("3\\n")',
                 "  ok ran=4 hit=0 time=1",
                 "  ok ran=0 hit=4 time=0"])

    case("sched_two_failures_one_instant",
         {"main.kiln": '''each i in range(2) {
    step {
        out "out/d{i}.txt"
        depfile "out/d{i}.d"
        in "src/m{i}.txt"
        cmd preprocess()
    }
}
step {
    out "out/slow.txt"
    cmd write("slow\\n")
    cost 20
}
step {
    out "out/quick.txt"
    cmd write("quick\\n")
    cost 1
}
phony all = ["out/d0.txt", "out/d1.txt", "out/slow.txt", "out/quick.txt"]
default "@all"
''',
          "src/m0.txt": "@need src/gone0.txt\n",
          "src/m1.txt": "@need src/gone1.txt\n"},
         "build -j 4\n", pub=True,
         expect=["  fail 0 6 w0 out/d0.txt preprocess()",
                 "  fail 0 6 w1 out/d1.txt preprocess()",
                 '  cancel 0 20 w2 out/slow.txt write("slow\\n")',
                 '  run 0 1 w3 out/quick.txt write("quick\\n")',
                 "  error E_NEED_MISSING src/gone0.txt needed by src/m0.txt"])

    case("sched_failure_after_success",
         {"main.kiln": '''step {
    out "out/ok.txt"
    cmd write("ok\\n")
    cost 2
}
step {
    out "out/bad.txt"
    depfile "out/bad.d"
    in "src/m.txt"
    cmd preprocess()
}
step {
    out "out/never.txt"
    in "out/bad.txt"
    cmd copy()
}
phony all = ["out/ok.txt", "out/bad.txt", "out/never.txt"]
default "@all"
''', "src/m.txt": "@need src/../x\n"},
         "build -j 2\nbuild -j 2\n",
         expect=['  run 0 2 w0 out/ok.txt write("ok\\n")',
                 "  fail 0 6 w1 out/bad.txt preprocess()",
                 "  error E_NEED_PATH src/../x",
                 "  hit 0 out/ok.txt",
                 "  fail 0 6 w0 out/bad.txt preprocess()"])

    case("sched_hit_cascade_mid_build",
         {"main.kiln": '''step {
    out "out/a.txt"
    in "src/a.txt"
    cmd upper()
    cost 3
}
step {
    out "out/b.txt"
    in "out/a.txt"
    cmd copy()
}
step {
    out "out/c.txt"
    in "out/b.txt"
    cmd copy()
}
step {
    out "out/d.txt"
    in "out/c.txt"
    cmd number()
}
default "out/d.txt"
''', "src/a.txt": "abc\n"},
         "build\nedit src/a.txt\nABC\n---\nbuild\nedit src/a.txt\nxyz\n---\nbuild\n",
         pub=True,
         expect=["  run 0 3 w0 out/a.txt upper()",
                 "  run 3 4 w0 out/b.txt copy()",
                 "  ok ran=4 hit=0 time=7",
                 "  run 0 3 w0 out/a.txt upper()",
                 "  hit 3 out/b.txt", "  hit 3 out/c.txt", "  hit 3 out/d.txt",
                 "  ok ran=1 hit=3 time=3",
                 "  ok ran=4 hit=0 time=7"])

    # Twenty-four steps of varied cost on eight workers: the whole dispatch,
    # clock-advance and worker-allocation loop in one trace.
    case("sched_many_workers",
         {"main.kiln": '''let outs = []
each i in range(24) {
    step {
        out "out/w{i}.txt"
        cmd write("{i}\\n")
        cost 1 + (i * 7) % 11
    }
    default "out/w{i}.txt"
    set outs = outs ++ ["out/w{i}.txt"]
}
step {
    out "out/join.txt"
    in outs
    cmd count_lines()
    cost 3
}
default "out/join.txt"
'''},
         "build -j 8\nbuild -j 8\nbuild -j 1\n",
         expect=['  run 0 1 w0 out/w0.txt write("0\\n")',
                 '  run 0 8 w1 out/w1.txt write("1\\n")',
                 "  ok ran=0 hit=25 time=0"])

    case("sched_large_costs",
         {"main.kiln": '''step {
    out "out/big.txt"
    cmd write("big\\n")
    cost 1000000
}
step {
    out "out/small.txt"
    in "out/big.txt"
    cmd copy()
    cost 999999
}
default "out/small.txt"
'''},
         "build -j 4\n",
         expect=['  run 0 1000000 w0 out/big.txt write("big\\n")',
                 "  run 1000000 1999999 w0 out/small.txt copy()",
                 "  ok ran=2 hit=0 time=1999999"])

    case("sched_mixed_hits_and_runs",
         {"main.kiln": '''let outs = []
each i in range(6) {
    step {
        out "out/m{i}.txt"
        in "src/s{i}.txt"
        cmd copy()
        cost 2
    }
    set outs = outs ++ ["out/m{i}.txt"]
}
step {
    out "out/all.txt"
    in outs
    cmd concat()
    cost 1
}
default "out/all.txt"
''', **{"src/s%d.txt" % i: "s%d\n" % i for i in range(6)}},
         "build -j 3\nedit src/s2.txt\nS2\n---\nbuild -j 3\n"
         "edit src/s0.txt\nS0\n---\nedit src/s5.txt\nS5\n---\nbuild -j 2\n",
         expect=["  ok ran=7 hit=0 time=5",
                 "  hit 0 out/m0.txt", "  hit 0 out/m1.txt",
                 "  run 0 2 w0 out/m2.txt copy()",
                 "  hit 0 out/m3.txt", "  hit 0 out/m4.txt", "  hit 0 out/m5.txt",
                 "  run 2 3 w0 out/all.txt concat()",
                 "  ok ran=2 hit=5 time=3",
                 "  run 0 2 w0 out/m0.txt copy()",
                 "  run 0 2 w1 out/m5.txt copy()",
                 "  run 2 3 w0 out/all.txt concat()",
                 "  ok ran=3 hit=4 time=3"])


# ---------------------------------------------------------------------------
# the state file
# ---------------------------------------------------------------------------

def fnv_hex(data):
    """FNV-1a-64 of `data`, as 16 lowercase hex digits (SPEC.md section 4)."""
    h = 0xCBF29CE484222325
    for b in as_bytes(data):
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


STATE_MAIN = '''step {
    out "out/z.txt"
    in "src/a.txt"
    cmd copy()
}
default "out/z.txt"
'''

HA = fnv_hex("a\n")

GOOD_STATE = ("kiln-state 1\nstep out/z.txt\ncmd copy()\n"
              "in src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA))


def g_state():
    base = {"main.kiln": STATE_MAIN, "src/a.txt": "a\n", "out/z.txt": "a\n",
            ".kiln-state": GOOD_STATE}

    case("state_valid_handwritten", base, "build\nbuild\n", pub=True,
         expect=["  hit 0 out/z.txt", "  ok ran=0 hit=1 time=0",
                 "  ok ran=0 hit=1 time=0"])

    corruptions = [
        "kiln-state 2\nstep out/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "step out/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\n" % (HA, HA),
        "kiln-state 1\njunk\nstep out/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nout out/z.txt %s\nin src/a.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstep out/z.txt\ncmd copy()\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nin src/a.txt %s\nend\n" % HA,
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA.upper()),
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA[:15]),
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nin bad path %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstep out/y.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        ("kiln-state 1\nstep out/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA)) * 2,
        "kiln-state 1\nstep out/z.txt\ncmd \nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend \n" % (HA, HA),
        "kiln-state 1\nsteps out/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstepout/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstep  out/z.txt\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nin src/a.txt\nout out/z.txt %s\nend\n" % HA,
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nin src/a.txt %s0\nout out/z.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nin src/a.txt zzzzzzzzzzzzzzzz\nout out/z.txt %s\nend\n" % HA,
        "kiln-state 1\nstep out/z.txt\ncmd copy()\nout out/z.txt %s\ndep src/a.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nstep ../x\ncmd copy()\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "kiln-state 1\nend\n",
        "kiln-state 1\nstep out/z.txt\nin src/a.txt %s\nout out/z.txt %s\nend\n" % (HA, HA),
        "",
    ]
    half = len(corruptions) // 2
    for part, group in (("a", corruptions[:half]), ("b", corruptions[half:])):
        lines = ["build"]
        expect = ["  ok ran=0 hit=1 time=0"]
        for text in group:
            lines.append("edit .kiln-state")
            lines.extend(text.split("\n")[:-1] if text else [])
            lines.append("---")
            lines.append("build")
            expect.append("  run 0 1 w0 out/z.txt copy()")
        case("state_corrupt_" + part, base, "\n".join(lines) + "\n",
             pub=(part == "a"), expect=expect)

    case("state_unterminated_last_line",
         dict(base, **{".kiln-state": GOOD_STATE.rstrip("\n")}),
         "build\nbuild\n",
         expect=["  run 0 1 w0 out/z.txt copy()", "  ok ran=0 hit=1 time=0"])

    two_main = '''step {
    out "out/one.txt"
    in ["src/a.txt", "src/a.txt"]
    cmd concat()
}
step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/m.txt"
    cmd preprocess()
}
phony all = ["out/one.txt", "out/doc.txt"]
default "@all"
'''
    doc_out = "head\nP\nQ\n"
    doc_dep = "kiln-deps 1\nneed src/p.txt\nneed src/q.txt\n"
    odd_state = (
        "kiln-state 1\n"
        "step out/doc.txt\ncmd preprocess()\nin src/m.txt %s\n"
        "dep src/q.txt %s\ndep src/p.txt %s\n"
        "out out/doc.txt %s\nout out/doc.d %s\nend\n"
        "step out/gone.txt\ncmd write(\"gone\")\nout out/gone.txt %s\nend\n"
        "step out/one.txt\ncmd concat()\nin src/a.txt %s\nin src/a.txt %s\n"
        "out out/one.txt %s\nend\n"
        % (fnv_hex("head\n@need src/p.txt\n@need src/q.txt\n"),
           fnv_hex("Q\n"), fnv_hex("P\n"), fnv_hex(doc_out), fnv_hex(doc_dep),
           fnv_hex("gone"), HA, HA, fnv_hex("a\na\n")))
    case("state_accepted_oddities",
         {"main.kiln": two_main, "src/a.txt": "a\n", "src/p.txt": "P\n",
          "src/q.txt": "Q\n",
          "src/m.txt": "head\n@need src/p.txt\n@need src/q.txt\n",
          "out/one.txt": "a\na\n", "out/doc.txt": doc_out, "out/doc.d": doc_dep,
          ".kiln-state": odd_state},
         "build -j 2\nbuild\n", pub=False,
         expect=["  hit 0 out/one.txt", "  hit 0 out/doc.txt",
                 "  ok ran=0 hit=2 time=0", "  ok ran=0 hit=2 time=0"])

    case("state_carry_over_unreachable",
         {"main.kiln": '''step {
    out "out/a.txt"
    in "src/a.txt"
    cmd copy()
}
step {
    out "out/idle.txt"
    cmd write("idle\\n")
}
default "out/a.txt"
''', "src/a.txt": "a\n",
          ".kiln-state": ("kiln-state 1\nstep out/ancient.txt\ncmd write(\"old\")\n"
                          "out out/ancient.txt %s\nend\n" % fnv_hex("old")),
          "out/ancient.txt": "old"},
         "build\nbuild out/idle.txt\nbuild\n",
         expect=["  run 0 1 w0 out/a.txt copy()",
                 '  run 0 1 w0 out/idle.txt write("idle\\n")',
                 "  ok ran=0 hit=1 time=0"])

    case("state_entries_removed_on_failure",
         {"main.kiln": '''step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/m.txt"
    cmd preprocess()
}
step {
    out "out/ok.txt"
    cmd write("ok\\n")
    cost 1
}
step {
    out "out/late.txt"
    cmd write("late\\n")
    cost 30
}
phony all = ["out/doc.txt", "out/ok.txt", "out/late.txt"]
default "@all"
''', "src/m.txt": "@need src/p.txt\n", "src/p.txt": "P\n"},
         "build -j 3\ndelete src/p.txt\nbuild -j 3\nbuild -j 3\n", pub=True,
         expect=["  run 0 6 w0 out/doc.txt preprocess()",
                 '  run 0 1 w1 out/ok.txt write("ok\\n")',
                 '  run 0 30 w2 out/late.txt write("late\\n")',
                 "  ok ran=3 hit=0 time=30",
                 "  fail 0 6 w0 out/doc.txt preprocess()",
                 "  hit 0 out/ok.txt", "  hit 0 out/late.txt",
                 "  error E_NEED_MISSING src/p.txt needed by src/m.txt",
                 "  fail 0 6 w0 out/doc.txt preprocess()"])


# ---------------------------------------------------------------------------
# change detection, rule by rule
# ---------------------------------------------------------------------------

def g_freshness():
    one_in = 'step {\n    out "out/z.txt"\n    in %s\n    cmd %s\n}\n%sdefault "out/z.txt"\n'

    variants("fresh_cmd_string", [
        one_in % ('"src/a.txt"', "upper()", ""),
        one_in % ('"src/a.txt"', "copy()", ""),
        one_in % ('"src/a.txt"', "copy()", ""),
        one_in % ('"src/a.txt"', 'grep("A")', ""),
        one_in % ('"src/a.txt"', 'grep("B")', ""),
        one_in % ('"src/a.txt"', 'grep("B")', "# a comment changes nothing\n"),
        (one_in % ('"src/a.txt"', "copy()", "")).replace(
            "cmd copy()", "cmd copy()\n    cost 7"),
    ], pub=True, files={"src/a.txt": "ABC\n"}, expect=[
        "  run 0 2 w0 out/z.txt upper()",
        "  run 0 1 w0 out/z.txt copy()",
        "  hit 0 out/z.txt",
        '  run 0 3 w0 out/z.txt grep("A")',
        '  run 0 3 w0 out/z.txt grep("B")',
        '  hit 0 out/z.txt',
        "  run 0 7 w0 out/z.txt copy()"])

    variants("fresh_input_list", [
        one_in % ('["src/a.txt"]', "concat()", ""),
        one_in % ('["src/a.txt", "src/b.txt"]', "concat()", ""),
        one_in % ('["src/a.txt", "src/b.txt"]', "concat()", ""),
        one_in % ('["src/b.txt", "src/a.txt"]', "concat()", ""),
        one_in % ('["src/a.txt", "src/b.txt", "src/b.txt"]', "concat()", ""),
        one_in % ('["src/a.txt", "src/b.txt"]', "concat()", ""),
        (one_in % ('["src/a.txt", "src/b.txt"]', "concat()", 'phony p = []\n')
         ).replace('in ["src/a.txt", "src/b.txt"]',
                   'in ["src/a.txt", "@p", "src/b.txt"]'),
        (one_in % ('["src/a.txt", "src/b.txt"]', "concat()", "")).replace(
            "cmd concat()", 'after "src/c.txt"\n    cmd concat()'),
    ], pub=True, files={"src/a.txt": "a\n", "src/b.txt": "a\n", "src/c.txt": "c\n"},
        expect=["  run 0 2 w0 out/z.txt concat()",
                "  run 0 2 w0 out/z.txt concat()",
                "  hit 0 out/z.txt",
                "  run 0 2 w0 out/z.txt concat()",
                "  run 0 2 w0 out/z.txt concat()",
                "  run 0 2 w0 out/z.txt concat()",
                "  hit 0 out/z.txt",
                "  hit 0 out/z.txt"])

    case("fresh_input_content",
         {"main.kiln": one_in % ('"src/a.txt"', "copy()", ""), "src/a.txt": "a\n"},
         "build\nedit src/a.txt\na\n---\nbuild\nedit src/a.txt\nb\n---\nbuild\n"
         "touch src/a.txt\nbuild\n", pub=False,
         expect=["  run 0 1 w0 out/z.txt copy()", "  hit 0 out/z.txt",
                 "  run 0 1 w0 out/z.txt copy()", "  hit 0 out/z.txt"])

    case("fresh_output_and_depfile",
         {"main.kiln": '''step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/m.txt"
    cmd preprocess()
}
default "out/doc.txt"
''', "src/m.txt": "head\n@need src/p.txt\n", "src/p.txt": "P\n"},
         "build\nbuild\ndelete out/doc.d\nbuild\nedit out/doc.d\nkiln-deps 1\n---\n"
         "build\ndelete out/doc.txt\nbuild\nedit out/doc.txt\nx\n---\nbuild\n",
         expect=["  run 0 6 w0 out/doc.txt preprocess()", "  hit 0 out/doc.txt",
                 "  run 0 6 w0 out/doc.txt preprocess()",
                 "  run 0 6 w0 out/doc.txt preprocess()",
                 "  run 0 6 w0 out/doc.txt preprocess()",
                 "  run 0 6 w0 out/doc.txt preprocess()"])

    pre_main = '''step {
    out "out/doc.txt"
    depfile "%s"
    in "src/m.txt"
    cmd preprocess()
}
default "out/doc.txt"
'''
    variants("fresh_output_list", [
        pre_main % "out/d1.d",
        pre_main % "out/d1.d",
        pre_main % "out/d2.d",
        pre_main % "out/d2.d",
    ], files={"src/m.txt": "head\n@need src/p.txt\n", "src/p.txt": "P\n"},
        expect=["  run 0 6 w0 out/doc.txt preprocess()", "  hit 0 out/doc.txt",
                "  run 0 6 w0 out/doc.txt preprocess()", "  hit 0 out/doc.txt"])

    case("fresh_discovered_dependency",
         {"main.kiln": '''step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/m.txt"
    cmd preprocess()
}
default "out/doc.txt"
''', "src/m.txt": "head\n@need src/p.txt\ntail\n", "src/p.txt": "P\n",
          "src/q.txt": "Q\n"},
         "build\nbuild\nedit src/p.txt\nP2\n---\nbuild\nbuild\n"
         "edit src/q.txt\nQ2\n---\nbuild\n"
         "edit src/m.txt\nhead\n@need src/q.txt\ntail\n---\nbuild\nbuild\n",
         pub=True,
         expect=["  run 0 6 w0 out/doc.txt preprocess()", "  hit 0 out/doc.txt",
                 "  run 0 6 w0 out/doc.txt preprocess()", "  hit 0 out/doc.txt",
                 "  hit 0 out/doc.txt",
                 "  run 0 6 w0 out/doc.txt preprocess()", "  hit 0 out/doc.txt"])

    case("fresh_needed_build_file",
         {"main.kiln": '''step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/m.txt"
    cmd preprocess()
}
default "out/doc.txt"
''', "src/m.txt": "@need tune/v.kiln\n", "tune/v.kiln": "let v = 1\n"},
         "build\nbuild\nedit tune/v.kiln\nlet v = 2\n---\nbuild\nbuild\n",
         expect=["  run 0 6 w0 out/doc.txt preprocess()", "  hit 0 out/doc.txt",
                 "  run 0 6 w0 out/doc.txt preprocess()", "  hit 0 out/doc.txt"])

    case("fresh_whole_chain",
         {"main.kiln": '''let stages = ["one", "two", "three"]
let prev = "src/a.txt"
each i, s in stages {
    step {
        out "out/{s}.txt"
        in prev
        cmd wrap("[{i}", "]\\n")
        cost 2
    }
    set prev = "out/{s}.txt"
}
default prev
''', "src/a.txt": "a\n"},
         "build\nbuild\nedit src/a.txt\nb\n---\nbuild\nclean\nbuild -j 2\n",
         expect=["  run 0 2 w0 out/one.txt wrap(\"[0\", \"]\\n\")",
                 "  run 2 4 w0 out/two.txt wrap(\"[1\", \"]\\n\")",
                 "  run 4 6 w0 out/three.txt wrap(\"[2\", \"]\\n\")",
                 "  ok ran=3 hit=0 time=6", "  ok ran=0 hit=3 time=0",
                 "  ok ran=3 hit=0 time=6", "  ok removed=4",
                 "  ok ran=3 hit=0 time=6"])


# ---------------------------------------------------------------------------
# preprocess, @need directives and depfiles
# ---------------------------------------------------------------------------

PRE_MAIN = '''step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/root.txt"
    cmd preprocess()
}
step {
    out "out/h.txt"
    in ["out/doc.txt", "out/doc.d"]
    cmd hash()
}
default "out/h.txt"
'''


def g_preprocess():
    case("pre_nesting_and_dedup",
         {"main.kiln": PRE_MAIN,
          "src/root.txt": "A\n@need src/mid1.txt\nB\n@need src/mid2.txt\nC\n",
          "src/mid1.txt": "M1\n@need src/leaf.txt\n",
          "src/mid2.txt": "M2\n@need src/leaf.txt\n",
          "src/leaf.txt": "L\n"},
         "build\nbuild\n", pub=True,
         expect=["  run 0 6 w0 out/doc.txt preprocess()",
                 "  run 6 9 w0 out/h.txt hash()", "  ok ran=0 hit=2 time=0"])

    case("pre_directive_edges",
         {"main.kiln": PRE_MAIN,
          "src/root.txt": ("@needx y\n@need\n@need \n @need src/ok.txt\n"
                           "@needsrc/ok.txt\nplain\n@need src/ok.txt\n"
                           "@need src/empty.txt\n"),
          "src/ok.txt": "OK\n", "src/empty.txt": ""},
         "build\nbuild\n", pub=False,
         expect=["  run 0 6 w0 out/doc.txt preprocess()",
                 "  ok ran=0 hit=2 time=0"])

    case("pre_no_needs",
         {"main.kiln": PRE_MAIN, "src/root.txt": "just text\nno needs\n"},
         "build\nbuild\n",
         expect=["  run 0 6 w0 out/doc.txt preprocess()",
                 "  ok ran=0 hit=2 time=0"])

    case("pre_empty_input",
         {"main.kiln": PRE_MAIN, "src/root.txt": ""},
         "build\n",
         expect=["  run 0 6 w0 out/doc.txt preprocess()"])

    pre_err_main = '''step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/root.txt"
    cmd preprocess()
}
default "out/doc.txt"
'''
    roots = [
        "@need ../x\n",
        "@need /abs/x\n",
        "@need src/a b.txt\n",
        "@need src/missing.txt\n",
        "ok\n@need src/mid.txt\n",
        "@need src/root.txt\n",
        "@need src/selfloop.txt\n",
        "@need src/cyc1.txt\n",
        "@need src/missing.txt\n@need ../later\n",
        "@need src/ok.txt\n@need src/missing.txt\n",
    ]
    lines = []
    expect = []
    kinds = [
        "E_NEED_PATH ../x",
        "E_NEED_PATH /abs/x",
        "E_NEED_PATH src/a b.txt",
        "E_NEED_MISSING src/missing.txt needed by src/root.txt",
        "E_NEED_MISSING src/gone.txt needed by src/mid.txt",
        "E_NEED_CYCLE src/root.txt",
        "E_NEED_CYCLE src/selfloop.txt",
        "E_NEED_CYCLE src/cyc1.txt",
        "E_NEED_MISSING src/missing.txt needed by src/root.txt",
        "E_NEED_MISSING src/missing.txt needed by src/root.txt",
    ]
    for text, kind in zip(roots, kinds):
        lines.append("edit src/root.txt")
        lines.extend(text.rstrip("\n").split("\n"))
        lines.append("---")
        lines.append("build")
        expect.append("  error " + kind)
    case("pre_need_errors",
         {"main.kiln": pre_err_main, "src/root.txt": "placeholder\n",
          "src/ok.txt": "OK\n", "src/mid.txt": "m\n@need src/gone.txt\n",
          "src/selfloop.txt": "@need src/selfloop.txt\n",
          "src/cyc1.txt": "@need src/cyc2.txt\n",
          "src/cyc2.txt": "@need src/cyc1.txt\n"},
         "\n".join(lines) + "\n", pub=True, expect=expect)

    case("pre_depfile_consumed_by_another_step",
         {"main.kiln": '''step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/root.txt"
    cmd preprocess()
}
step {
    out "out/deps.txt"
    in "out/doc.d"
    cmd number()
}
step {
    out "out/both.txt"
    in ["out/doc.txt", "out/deps.txt"]
    cmd concat()
}
default "out/both.txt"
''', "src/root.txt": "head\n@need src/p.txt\n@need src/q.txt\n",
          "src/p.txt": "P\n", "src/q.txt": "Q\n"},
         "build -j 2\nbuild\nedit src/q.txt\nQ2\n---\nbuild\n",
         expect=["  run 0 6 w0 out/doc.txt preprocess()",
                 "  run 6 8 w0 out/deps.txt number()",
                 "  run 8 10 w0 out/both.txt concat()",
                 "  ok ran=3 hit=0 time=10", "  ok ran=0 hit=3 time=0",
                 "  run 0 6 w0 out/doc.txt preprocess()",
                 "  hit 6 out/deps.txt",
                 "  run 6 8 w0 out/both.txt concat()"])

    case("pre_two_steps_shared_deps",
         {"main.kiln": '''each i, root in ["src/r0.txt", "src/r1.txt"] {
    step {
        out "out/d{i}.txt"
        depfile "out/d{i}.d"
        in root
        cmd preprocess()
        cost 2
    }
    default "out/d{i}.txt"
}
''', "src/r0.txt": "r0\n@need src/shared.txt\n",
          "src/r1.txt": "r1\n@need src/shared.txt\n@need src/extra.txt\n",
          "src/shared.txt": "S\n", "src/extra.txt": "E\n"},
         "build -j 2\nbuild\nedit src/shared.txt\nS2\n---\nbuild -j 2\n"
         "edit src/extra.txt\nE2\n---\nbuild -j 2\n",
         expect=["  run 0 2 w0 out/d0.txt preprocess()",
                 "  run 0 2 w1 out/d1.txt preprocess()",
                 "  ok ran=2 hit=0 time=2", "  ok ran=0 hit=2 time=0",
                 "  run 0 2 w0 out/d0.txt preprocess()",
                 "  run 0 2 w1 out/d1.txt preprocess()",
                 "  hit 0 out/d0.txt",
                 "  run 0 2 w0 out/d1.txt preprocess()",
                 "  ok ran=1 hit=1 time=2"])

    case("pre_deep_chain",
         {"main.kiln": PRE_MAIN,
          "src/root.txt": "@need src/n0.txt\n",
          **{"src/n%d.txt" % i: "L%d\n@need src/n%d.txt\n" % (i, i + 1)
             for i in range(40)},
          "src/n40.txt": "bottom\n"},
         "build\nbuild\nedit src/n40.txt\nBOTTOM\n---\nbuild\n",
         expect=["  run 0 6 w0 out/doc.txt preprocess()",
                 "  ok ran=0 hit=2 time=0",
                 "  run 0 6 w0 out/doc.txt preprocess()",
                 "  run 6 9 w0 out/h.txt hash()"])


# ---------------------------------------------------------------------------
# generated projects
#
# Each case is a deterministic pseudo-random Kiln project: modules of globbed
# sources compiled by per-element commands chosen through when/elsewhen chains,
# bundled, wrapped through a rule, optionally preprocessed, and driven by a
# session of builds, edits, touches, deletes, creates and cleans.
# ---------------------------------------------------------------------------

WORDS = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
         "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi",
         "ash", "birch", "cedar", "elm", "fir", "hazel", "ilex", "juniper",
         "Ünicode", "0123", "a-b+c", "the end", "", "   spaced   "]

ELEMENT_COMMANDS = [
    ("upper()", 2), ("lower()", 2), ("number()", 2), ("dedup()", 3),
    ("sort_lines()", 4), ("reverse_lines()", 2), ('grep("e")', 3),
    ('replace("a", "A")', 3), ("indent(2)", 2), ("copy()", 1),
    ('wrap("[", "]\\n")', 1),
]

BUNDLE_COMMANDS = [("concat()", 4), ("count_lines()", 2), ("hash()", 3)]


def rand_text(rng, nlines):
    return "".join(rng.choice(WORDS) + "\n" for _ in range(nlines))


def gen_project(seed, mods, per_mod, with_preprocess=True, noise=0):
    """Build one pseudo-random project; return (files, module names)."""
    rng = random.Random(seed)
    files = {}
    names = []
    for k in range(mods):
        name = "m%d" % k
        names.append(name)
        for j in range(per_mod):
            # A quarter of each module's sources live one level down, and the
            # skipped ones are there to be rejected, so the module's source
            # list exercises `**`, `filter` and `reject`.
            if j % 4 == 3:
                files["src/%s/sub/g%d.txt" % (name, j)] = rand_text(rng, rng.randint(0, 6))
            else:
                files["src/%s/f%d.txt" % (name, j)] = rand_text(rng, rng.randint(0, 6))
        files["src/%s/skip_me.txt" % name] = "skipped\n"
        files["src/%s/sub/skip_too.txt" % name] = "skipped\n"
        body = ['let all_%s = glob("src/%s/**/*.txt")' % (name, name),
                'let s_%s = sort(reject(all_%s, "**/skip_*.txt"))' % (name, name),
                "let o_%s = []" % name,
                "each i, f in s_%s {" % name]
        picks = [ELEMENT_COMMANDS[rng.randrange(len(ELEMENT_COMMANDS))]
                 for _ in range(3)]
        for b, (cmd, cost) in enumerate(picks):
            head = ("    when i %% %d == %d {" % (len(picks), b) if b == 0 else
                    ("    } elsewhen i %% %d == %d {" % (len(picks), b)
                     if b < len(picks) - 1 else "    } otherwise {"))
            body.append(head)
            body.append("        step {")
            body.append('            out "out/%s/{stem(f)}.txt"' % name)
            body.append("            in f")
            body.append("            cmd %s" % cmd)
            body.append("            cost %d" % cost)
            body.append("        }")
        body.append("    }")
        body.append('    set o_%s = o_%s ++ ["out/%s/{stem(f)}.txt"]'
                    % (name, name, name))
        body.append("}")
        bcmd, bcost = BUNDLE_COMMANDS[rng.randrange(len(BUNDLE_COMMANDS))]
        body.append("step {")
        body.append('    out "out/%s/bundle.txt"' % name)
        body.append("    in o_%s" % name)
        body.append("    cmd %s" % bcmd)
        body.append("    cost %d" % bcost)
        body.append("}")
        body.append('use wrapper("%s/wrapped", "out/%s/bundle.txt", "<%s|", "|>\\n", %d)'
                    % (name, name, name, rng.randint(0, 4)))
        deps = ['"out/%s/wrapped.txt"' % name]
        if with_preprocess and k % 3 == 1:
            doc = ["head of %s" % name]
            for j in range(min(per_mod, 3)):
                doc.append("@need src/%s/f%d.txt" % (name, j))
            doc.append("tail")
            files["src/%s/doc.src" % name] = "\n".join(doc) + "\n"
            body.append("step {")
            body.append('    out "out/%s/doc.txt"' % name)
            body.append('    depfile "out/%s/doc.d"' % name)
            body.append('    in "src/%s/doc.src"' % name)
            body.append("    cmd preprocess()")
            body.append("    cost %d" % rng.randint(1, 8))
            body.append("}")
            deps.append('"out/%s/doc.txt"' % name)
        body.append("phony %s = [%s]" % (name, ", ".join(deps)))
        files["build/%s.kiln" % name] = "\n".join(body) + "\n"

    main = ['rule wrapper(name, src, pre, post, w) {',
            "    step {",
            '        out "out/{name}.txt"',
            "        in src",
            "        cmd wrap(pre, post)",
            "        cost w",
            "    }",
            "}"]
    for name in names:
        main.append('include "build/%s.kiln"' % name)
    main.append("step {")
    main.append('    out "out/all.txt"')
    main.append("    in [%s]" % ", ".join('"out/%s/bundle.txt"' % n for n in names))
    main.append("    after [%s]" % ", ".join('"@%s"' % n for n in names))
    main.append("    cmd count_lines()")
    main.append("    cost 3")
    main.append("}")
    main.append('phony all = ["out/all.txt", %s]'
                % ", ".join('"@%s"' % n for n in names))
    main.append('default "@all"')
    files["main.kiln"] = "\n".join(main) + "\n"

    for i in range(noise):
        files["noise/d%d/n%d.dat" % (i % 40, i)] = "noise %d\n" % i
    if noise:
        # A glob over the whole noise tree, so the match loop meets every file.
        files["main.kiln"] += (
            'step {\n'
            '    out "out/noise.txt"\n'
            '    cmd write("{count(glob("noise/**"))}:{count(glob("noise/**/n1*.dat"))}'
            ':{count(glob("**"))}\\n")\n'
            '}\n'
            'default "out/noise.txt"\n')
    return files, names


def gen_session(seed, files, names, builds):
    """A session of builds interleaved with workspace mutations."""
    rng = random.Random(seed ^ 0x5F5F)
    live = set(p for p in files if p.startswith("src/")
               and p.endswith(".txt") and "skip_" not in p)
    created = 0
    lines = []
    for b in range(builds):
        jobs = rng.choice([1, 1, 2, 3, 4, 8, 16, 64])
        target = "" if b == 0 else rng.choice(
            ["", ""] + ["@" + n for n in names] + ["out/all.txt"])
        lines.append(("build " + target).strip() + (" -j %d" % jobs if jobs > 1 else ""))
        if b == builds - 1:
            break
        action = rng.randrange(10)
        if action < 4 and live:
            path = sorted(live)[rng.randrange(len(live))]
            lines.append("edit " + path)
            lines.extend(rand_text(rng, rng.randint(0, 4)).split("\n")[:-1])
            lines.append("---")
        elif action < 6 and live:
            lines.append("touch " + sorted(live)[rng.randrange(len(live))])
        elif action < 7:
            name = names[rng.randrange(len(names))]
            path = "src/%s/new%d.txt" % (name, created)
            created += 1
            lines.append("create " + path)
            lines.extend(rand_text(rng, rng.randint(1, 3)).split("\n")[:-1])
            lines.append("---")
            live.add(path)
        elif action < 8 and len(live) > 2:
            # Only files no `@need` directive names are deletable, so a
            # generated session never turns into an execution error.
            spare = sorted(p for p in live
                           if "/new" in p or "/sub/" in p
                           or not p.rsplit("/", 1)[1][1:-4].isdigit()
                           or int(p.rsplit("/", 1)[1][1:-4]) >= 3)
            if spare:
                path = spare[rng.randrange(len(spare))]
                lines.append("delete " + path)
                live.discard(path)
        elif action < 9:
            lines.append("clean")
        else:
            lines.append("touch main.kiln")
    return "\n".join(lines) + "\n"


GEN_SPECS = [
    # name,                  seed, mods, per_mod, builds, preproc, noise, pub
    ("gen_tiny_1", 101, 1, 1, 2, False, 0, True),
    ("gen_tiny_2", 102, 1, 2, 3, False, 0, False),
    ("gen_tiny_3", 103, 2, 1, 3, True, 0, False),
    ("gen_tiny_4", 104, 2, 2, 4, False, 0, False),
    ("gen_tiny_5", 105, 2, 2, 4, True, 0, True),
    ("gen_tiny_6", 106, 3, 1, 5, True, 0, False),
    ("gen_small_1", 201, 3, 3, 4, True, 0, False),
    ("gen_small_2", 202, 3, 4, 5, False, 0, False),
    ("gen_small_3", 203, 4, 3, 6, True, 0, False),
    ("gen_small_4", 204, 4, 4, 5, True, 0, False),
    ("gen_small_5", 205, 4, 5, 7, False, 0, False),
    ("gen_small_6", 206, 5, 4, 6, True, 0, False),
    ("gen_small_7", 207, 5, 5, 8, True, 0, True),
    ("gen_small_8", 208, 5, 6, 6, False, 0, False),
    ("gen_small_9", 209, 6, 4, 7, True, 0, False),
    ("gen_small_10", 210, 6, 5, 9, True, 0, False),
    ("gen_small_11", 211, 6, 6, 6, False, 0, False),
    ("gen_small_12", 212, 7, 5, 8, True, 0, False),
    ("gen_medium_1", 301, 7, 8, 6, True, 0, False),
    ("gen_medium_2", 302, 8, 8, 8, True, 0, False),
    ("gen_medium_3", 303, 8, 10, 6, False, 0, False),
    ("gen_medium_4", 304, 9, 9, 7, True, 0, False),
    ("gen_medium_5", 305, 9, 12, 5, True, 0, False),
    ("gen_medium_6", 306, 10, 10, 8, True, 0, False),
    ("gen_medium_7", 307, 10, 12, 6, False, 0, False),
    ("gen_medium_8", 308, 11, 10, 7, True, 0, True),
    ("gen_medium_9", 309, 11, 14, 5, True, 0, False),
    ("gen_medium_10", 310, 12, 12, 6, True, 0, False),
    ("gen_medium_11", 311, 12, 15, 5, False, 0, False),
    ("gen_medium_12", 312, 12, 16, 7, True, 0, False),
    ("gen_large_1", 401, 14, 16, 5, True, 0, True),
    ("gen_large_2", 402, 14, 20, 4, True, 0, False),
    ("gen_large_3", 403, 16, 18, 4, False, 0, False),
    ("gen_large_4", 404, 16, 24, 4, True, 0, False),
    ("gen_large_5", 405, 18, 24, 3, True, 0, False),
    ("gen_large_6", 406, 20, 24, 3, True, 0, False),
    ("gen_large_7", 407, 20, 30, 3, False, 0, False),
    ("gen_large_8", 408, 22, 30, 3, True, 0, False),
    ("gen_glob_noise_1", 501, 4, 6, 5, True, 1200, False),
    ("gen_glob_noise_2", 502, 6, 8, 4, True, 2400, True),
    ("gen_glob_noise_3", 503, 3, 4, 6, False, 2950, False),
    ("gen_huge_1", 601, 24, 60, 3, True, 0, False),
    ("gen_huge_2", 602, 24, 100, 3, True, 0, False),
    ("gen_mix_1", 901, 2, 5, 6, True, 0, False),
    ("gen_mix_2", 902, 3, 7, 7, False, 0, False),
    ("gen_mix_3", 903, 4, 9, 8, True, 0, False),
    ("gen_mix_4", 904, 5, 11, 6, True, 0, False),
    ("gen_mix_5", 905, 6, 13, 5, False, 0, False),
    ("gen_mix_6", 906, 7, 3, 9, True, 0, False),
    ("gen_mix_7", 907, 8, 5, 7, True, 0, False),
    ("gen_mix_8", 908, 9, 7, 6, False, 0, False),
    ("gen_mix_9", 909, 10, 9, 5, True, 0, False),
    ("gen_mix_10", 910, 11, 11, 4, True, 0, False),
    ("gen_mix_11", 911, 13, 7, 5, False, 0, False),
    ("gen_mix_12", 912, 15, 9, 4, True, 0, False),
    ("gen_mix_13", 913, 17, 5, 6, True, 0, False),
    ("gen_mix_14", 914, 19, 7, 4, False, 0, False),
    ("gen_mix_15", 915, 21, 9, 3, True, 0, False),
    ("gen_mix_16", 916, 23, 11, 3, True, 0, False),
    ("gen_mix_17", 917, 6, 6, 12, True, 0, False),
    ("gen_mix_18", 918, 4, 4, 16, True, 0, False),
    ("gen_mix_19", 919, 8, 8, 10, False, 0, False),
    ("gen_mix_20", 920, 12, 4, 11, True, 0, False),
    ("gen_noise_small", 921, 2, 3, 5, True, 600, False),
    ("gen_noise_mid", 922, 5, 5, 4, False, 1800, False),
]


def g_generated():
    for name, seed, mods, per_mod, builds, preproc, noise, pub in GEN_SPECS:
        files, names = gen_project(seed, mods, per_mod, preproc, noise)
        session = gen_session(seed, files, names, builds)
        case(name, files, session, pub=pub, forbid=["  error "])

    # A 400-step session over a small project: the session driver at scale.
    files, names = gen_project(701, 3, 3, True, 0)
    session = gen_session(701, files, names, 400)
    case("gen_long_session", files, session, forbid=["  error "])

    # One generated project where a `@need`-ed source is deleted on purpose, so
    # the session walks through failure, cancellation and recovery at scale.
    files, names = gen_project(801, 5, 4, True, 0)
    session = ("build -j 4\n"
               "delete src/m1/f2.txt\n"
               "build -j 4\n"
               "build -j 1\n"
               "create src/m1/f2.txt\nrestored\n---\n"
               "build -j 4\n"
               "clean\n"
               "build -j 8\n")
    case("gen_failure_recovery", files, session, pub=True,
         expect=["  error E_NEED_MISSING src/m1/f2.txt needed by src/m1/doc.src"])


# ---------------------------------------------------------------------------
# the pipe operator, namespaces and a few remaining corners
# ---------------------------------------------------------------------------

def g_misc():
    write_table("misc_pipe_operator", "", [
        ("{[3, 1, 2] |> sort |> first}|{[3, 1, 2] |> sort |> join(\",\")}",
         "1|1,2,3"),
        ('{"abc" |> upper}|{"abc" |> upper |> lower |> len}', "ABC|3"),
        ('{"x" |> pathjoin("y", "z")}|{[1, 2, 3] |> slice(1, 2) |> last}',
         "x/y/z|3"),
        ('{5 |> range |> reverse |> join("-")}|{[[1], [2]] |> flatten |> sum}',
         "4-3-2-1-0|3"),
        ('{"a,b,c" |> split(",") |> count}|{"  pad  " |> trim |> upper}',
         "3|PAD"),
    ], pub=True)

    variants("misc_pipe_errors", [
        "let x = 1 |> nope\n",
        "let x = 1 |> cost\n",
        'let x = "a" |> upper(1)\n',
        "let x = [1] |> first |> upper\n",
    ], expect=errs(
        "E_UNKNOWN_FUNC nope", "E_UNKNOWN_FUNC cost",
        "E_ARITY fn upper: expected 1, got 2",
        "E_TYPE fn upper argument 1: expected str, got int"))

    case("misc_namespaces",
         {"main.kiln": '''let upper = "variable named like a function"
let wrapper = 3
rule wrapper(n) {
    step {
        out "out/{n}.txt"
        cmd write("{upper(n)}|{len(upper)}|{wrapper}\\n")
    }
    default "out/{n}.txt"
}
let all = "variable named like a phony"
phony all = ["out/w.txt"]
use wrapper("w")
'''},
         "build\n", pub=True,
         expect=['  run 0 1 w0 out/w.txt write("W|30|3\\n")'])

    case("misc_include_inside_rule",
         {"main.kiln": '''rule emit(n, body) {
    include "build/emit.kiln"
}
use emit("one", "A")
use emit("two", "B")
phony all = ["out/one.txt", "out/two.txt"]
default "@all"
''',
          "build/emit.kiln": 'let text = body ~ "-" ~ n\n'
                             'step {\n    out "out/{n}.txt"\n'
                             '    cmd write("{text}\\n")\n}\n'},
         "build -j 2\n",
         expect=['  run 0 1 w0 out/one.txt write("A-one\\n")',
                 '  run 0 1 w1 out/two.txt write("B-two\\n")'])

    case("misc_after_phony_and_defaults",
         {"main.kiln": '''phony stage1 = ["out/a.txt"]
step {
    out "out/a.txt"
    cmd write("a\\n")
    cost 4
}
step {
    out "out/b.txt"
    after "@stage1"
    cmd write("b\\n")
}
default "out/a.txt"
default ["out/b.txt", "out/a.txt"]
default "@stage1"
'''},
         "build -j 4\nbuild\n", pub=False,
         expect=['  run 0 4 w0 out/a.txt write("a\\n")',
                 '  run 4 5 w0 out/b.txt write("b\\n")',
                 "  ok ran=2 hit=0 time=5", "  ok ran=0 hit=2 time=0"])

    case("misc_build_target_variety",
         {"main.kiln": '''step {
    out "out/a.txt"
    in "src/s.txt"
    cmd copy()
}
step {
    out "out/b.txt"
    in "out/a.txt"
    cmd upper()
}
phony both = ["out/a.txt", "out/b.txt"]
default "out/b.txt"
''', "src/s.txt": "s\n"},
         "build src/s.txt\nbuild out/a.txt\nbuild @both out/a.txt out/b.txt\n"
         "build\nbuild out/b.txt out/b.txt -j 2\n",
         expect=["  ok ran=0 hit=0 time=0",
                 "  run 0 1 w0 out/a.txt copy()",
                 "  ok ran=1 hit=0 time=1",
                 "  hit 0 out/a.txt", "  run 0 2 w0 out/b.txt upper()",
                 "  ok ran=1 hit=1 time=2",
                 "  ok ran=0 hit=2 time=0",
                 "step 5: build out/b.txt out/b.txt -j 2",
                 "  ok ran=0 hit=2 time=0"])




# ---------------------------------------------------------------------------
# one case per command, over a fixed set of awkward sources
# ---------------------------------------------------------------------------

MATRIX_SOURCES = [
    ("src/e.txt", b""),
    ("src/n.txt", b"mixed\nLines\nmixed\n"),
    ("src/x.txt", b"no trailing newline"),
    ("src/c.txt", b"cr\r\nlines\r\n"),
    ("src/u.txt", "Ünïcödé ÄÖÜ\nß\n".encode("utf-8")),
    ("src/b.txt", bytes(range(1, 256)) + b"\n"),
]

MATRIX_COMMANDS = [
    ("copy", "copy()", 1, 1),
    ("upper", "upper()", 1, 2),
    ("lower", "lower()", 1, 2),
    ("grep", 'grep("i")', 1, 3),
    ("grep_empty", 'grep("")', 1, 3),
    ("replace", 'replace("i", "<I>")', 1, 3),
    ("replace_nl", 'replace("\\n", ";")', 1, 3),
    ("sort_lines", "sort_lines()", 1, 4),
    ("reverse_lines", "reverse_lines()", 1, 2),
    ("dedup", "dedup()", 1, 3),
    ("number", "number()", 1, 2),
    ("indent", "indent(4)", 1, 2),
    ("indent_zero", "indent(0)", 1, 2),
    ("wrap", 'wrap("<<", ">>")', 1, 1),
    ("wrap_empty", 'wrap("", "")', 1, 1),
    ("concat_all", "concat()", 6, 2),
    ("count_lines_all", "count_lines()", 6, 2),
    ("hash_all", "hash()", 6, 3),
]


def g_command_matrix():
    for name, cmd, arity, cost in MATRIX_COMMANDS:
        parts = []
        expect = []
        outs = []
        if arity == 1:
            for i, (path, _) in enumerate(MATRIX_SOURCES):
                out = "out/%s_%d.txt" % (name, i)
                outs.append(out)
                parts.append('step {\n    out "%s"\n    in "%s"\n    cmd %s\n}\n'
                             % (out, path, cmd))
                expect.append(b"  run %d %d w0 %s %s"
                              % (i * cost, (i + 1) * cost, as_bytes(out),
                                 as_bytes(cmd.replace("\\\\", "\\"))))
        else:
            out = "out/%s.txt" % name
            outs.append(out)
            parts.append('step {\n    out "%s"\n    in [%s]\n    cmd %s\n}\n'
                         % (out, ", ".join('"%s"' % p for p, _ in MATRIX_SOURCES),
                            cmd))
            expect.append(b"  run 0 %d w0 %s %s"
                          % (cost, as_bytes(out), as_bytes(cmd)))
        pin = "out/%s_pin.txt" % name
        parts.append('step {\n    out "%s"\n    in [%s]\n    cmd hash()\n}\n'
                     % (pin, ", ".join('"%s"' % o for o in outs)))
        parts.append('default "%s"\n' % pin)
        case("mx_" + name, dict(MATRIX_SOURCES, **{"main.kiln": "".join(parts)}),
             "build\nbuild\n", pub=(name == "number"),
             expect=expect + [b"  ok ran=0 hit=%d time=0" % (len(outs) + 1)])

    # `write` takes no input, so it gets its own case with awkward literals.
    texts = [r'""', r'"\n"', r'"\0\0"', r'"no newline"', r'"tab\there"',
             r'"cr\rhere"', r'"quote\" and backslash\\"', r'"Ünïcödé"',
             r'"{1 + 1}x{{brace}}"', r'"\x"'[:-1] + r'7f"']
    parts = []
    expect = []
    outs = []
    for i, text in enumerate(texts[:-1]):
        out = "out/w%d.txt" % i
        outs.append(out)
        parts.append('step {\n    out "%s"\n    cmd write(%s)\n}\n' % (out, text))
    parts.append('step {\n    out "out/w_pin.txt"\n    in [%s]\n    cmd hash()\n}\n'
                 % ", ".join('"%s"' % o for o in outs))
    parts.append('default "out/w_pin.txt"\n')
    case("mx_write", {"main.kiln": "".join(parts)}, "build\nbuild\n",
         expect=[r'  run 2 3 w0 out/w2.txt write("\x00\x00")',
                 r'  run 6 7 w0 out/w6.txt write("quote\" and backslash\\")',
                 r'  run 8 9 w0 out/w8.txt write("2x{brace}")',
                 "  ok ran=0 hit=%d time=0" % (len(outs) + 1)])

    # `preprocess` over the same sources, each needing the next one.
    files = dict(MATRIX_SOURCES)
    files["src/doc.src"] = "".join(
        "@need %s\n" % p for p, _ in MATRIX_SOURCES) + "tail\n"
    files["main.kiln"] = ('step {\n    out "out/doc.txt"\n'
                          '    depfile "out/doc.d"\n    in "src/doc.src"\n'
                          '    cmd preprocess()\n}\n'
                          'step {\n    out "out/pin.txt"\n'
                          '    in ["out/doc.txt", "out/doc.d"]\n    cmd hash()\n}\n'
                          'default "out/pin.txt"\n')
    case("mx_preprocess", files, "build\nbuild\nedit src/n.txt\nchanged\n---\nbuild\n",
         pub=True,
         expect=["  run 0 6 w0 out/doc.txt preprocess()",
                 "  run 6 9 w0 out/pin.txt hash()", "  ok ran=0 hit=2 time=0",
                 "  run 0 6 w0 out/doc.txt preprocess()",
                 "  run 6 9 w0 out/pin.txt hash()"])


# ---------------------------------------------------------------------------
# a worker-count sweep, with the schedule predicted independently
# ---------------------------------------------------------------------------

def simulate(costs, deps, workers):
    """Replay SPEC.md's scheduler for an all-stale build.

    `costs[i]` is step i's cost and `deps[i]` the step indices it waits for.
    Returns the dispatch events as (start, serial, worker, end) tuples sorted
    the way the log sorts them: by start time, then by serial.
    """
    pending = [len(set(d)) for d in deps]
    waiters = {}
    for i, ds in enumerate(deps):
        for d in set(ds):
            waiters.setdefault(d, []).append(i)
    ready = sorted(i for i in range(len(costs)) if pending[i] == 0)
    running = {}
    time = 0
    events = []
    while True:
        while ready and len(running) < workers:
            n = ready.pop(0)
            w = min(w for w in range(workers) if w not in running)
            running[w] = (n, time, time + costs[n])
            events.append((time, n, w, time + costs[n]))
        if not running:
            break
        time = min(end for (_, _, end) in running.values())
        for w in [w for w in sorted(running) if running[w][2] == time]:
            n = running.pop(w)[0]
            for m in waiters.get(n, []):
                pending[m] -= 1
                if pending[m] == 0:
                    ready.append(m)
        ready.sort()
    events.sort(key=lambda e: (e[0], e[1]))
    return events


SWEEP_COSTS = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8]


def g_sched_sweep():
    body = []
    for i, c in enumerate(SWEEP_COSTS):
        body.append('step {\n    out "out/s%d.txt"\n    cmd write("%d\\n")\n'
                    '    cost %d\n}\n' % (i, i, c))
    body.append('step {\n    out "out/join.txt"\n    in [%s]\n    cmd count_lines()\n'
                '    cost 2\n}\ndefault "out/join.txt"\n'
                % ", ".join('"out/s%d.txt"' % i for i in range(len(SWEEP_COSTS))))
    main = "".join(body)
    costs = SWEEP_COSTS + [2]
    deps = [[] for _ in SWEEP_COSTS] + [list(range(len(SWEEP_COSTS)))]
    rendered = ['out/s%d.txt write("%d\\n")' % (i, i)
                for i in range(len(SWEEP_COSTS))] + ["out/join.txt count_lines()"]
    for workers in range(1, 12):
        expect = ["  run %d %d w%d %s" % (start, end, w, rendered[n])
                  for (start, n, w, end) in simulate(costs, deps, workers)]
        case("sweep_j%02d" % workers, {"main.kiln": main},
             "build -j %d\nbuild -j %d\n" % (workers, workers),
             pub=(workers == 3),
             expect=expect + ["  ok ran=0 hit=%d time=0" % len(costs)])




# ---------------------------------------------------------------------------
# a second, deeper glob corpus
# ---------------------------------------------------------------------------

GLOB_FILES2 = {
    "p": "p\n", "p.q": "pq\n", "q/r": "qr\n", "q/r.s/t.u": "rst\n",
    "deep/1/2/3/4/leaf.txt": "leaf\n", "deep/1/2/x.txt": "x\n",
    "deep/1/y.txt": "y\n", "deep/z.txt": "z\n",
    "deep/1/2/3/4/5/6/7/8/9/bottom.dat": "bottom\n",
    "A/b/C.txt": "ABC\n",
    "mix/a-b.txt": "dash\n", "mix/a_b.txt": "under\n", "mix/a+b.txt": "plus\n",
    "mix/a.b.c.txt": "dots\n", "mix/.leading.txt": "lead\n",
    "mix/UPPER.TXT": "upper\n", "mix/9.txt": "nine\n",
}

GLOB_PATTERNS2 = [
    "**", "**/**", "**/**/**", "deep/**", "deep/**/*.txt", "**/*.txt",
    "**/leaf.txt", "deep/1/2/**/*.txt", "deep/*/*/*.txt", "?",
    "?.?", "q/**", "q/r.s/*", "mix/*", "mix/[a-z]*", "mix/[A-Z]*",
    "mix/[!a-z]*", "mix/a[-_+]b.txt", "mix/*.*.*", "[Aa]/**/[Cc].txt", "a/**",
    "**/[0-9].txt", "mix/.*", "**/*.dat", "deep/1/2/3/4/5/6/7/8/9/*",
    "*/*", "*/*/*", "**/?.txt", "mix/a?b.txt",
]


def g_glob2():
    paths = list(GLOB_FILES2) + ["main.kiln"]
    parts = ['let pats = [%s]\n'
             % ", ".join('"%s"' % p for p in GLOB_PATTERNS2)]
    parts.append('each i, p in pats {\n'
                 '    step {\n'
                 '        out "out/g{i}.txt"\n'
                 '        cmd write("{join(glob(p), " ")}\\n")\n'
                 '    }\n'
                 '    default "out/g{i}.txt"\n'
                 '}\n')
    expect = []
    for i, pat in enumerate(GLOB_PATTERNS2):
        want = b" ".join(spec_glob(pat, paths)) + b"\n"
        expect.append(b"  run %d %d w0 out/g%d.txt write(%s)" % (i, i + 1, i, esc(want)))
    case("glob_patterns_deep",
         dict(GLOB_FILES2, **{"main.kiln": "".join(parts)}), "build\nbuild\n",
         expect=expect + [b"  ok ran=0 hit=%d time=0" % len(GLOB_PATTERNS2)])

    # The same patterns through filter and reject, over candidates that are not
    # workspace paths at all.
    items = sorted(GLOB_FILES2) + ["", "x", "x/", "/x", "a//b", "deep",
                                   "deep/1", "MIX/a-b.txt"]
    parts = ['let xs = [%s]\n' % ", ".join('"%s"' % x for x in items)]
    parts.append('each i, p in [%s] {\n'
                 % ", ".join('"%s"' % p for p in GLOB_PATTERNS2[:14]))
    parts.append('    step {\n'
                 '        out "out/f{i}.txt"\n'
                 '        cmd write("{count(filter(xs, p))}/{count(reject(xs, p))}'
                 ':{join(filter(xs, p), "|")}\\n")\n'
                 '    }\n'
                 '    default "out/f{i}.txt"\n'
                 '}\n')
    expect = []
    for i, pat in enumerate(GLOB_PATTERNS2[:14]):
        keep = spec_filter(pat, items, True)
        drop = spec_filter(pat, items, False)
        want = (b"%d/%d:" % (len(keep), len(drop))) + b"|".join(keep) + b"\n"
        expect.append(b"  run %d %d w0 out/f%d.txt write(%s)" % (i, i + 1, i, esc(want)))
    case("glob_filter_reject_deep", {"main.kiln": "".join(parts)}, "build\n",
         pub=True, expect=expect)


# ---------------------------------------------------------------------------
# error precedence and evaluation-order pins
# ---------------------------------------------------------------------------

def g_precedence():
    # Lexical errors anywhere in a file beat grammar errors; grammar errors are
    # reported in file order; an unterminated block comes last and names the
    # innermost open header.
    variants("prec_parse_lexical_first", [
        'let = 1\nlet x = "abc\n',
        "let x = 1 2\nlet y = 1 $\n",
        "let x = 1 2\nlet y = \"{a $ b}\"\n",
        'let x = "\\q"\nlet y = (\n',
        "}\nlet x = 1 | 2\n",
    ], pub=True, expect=errs(*["E_PARSE main.kiln:%d" % n
                               for n in (2, 2, 1, 2, 2)]))

    variants("prec_parse_blocks_last", [
        "when true {\n  when true {\nlet x = 1\n",
        "when true {\nlet x = = 1\n",
        "rule r() {\n  each x in [1] {\n    step {\n",
        "each x in [1] {\n}\n}\nlet y = (1 2)\n",
        "when true {\n} elsewhen true {\nlet a = 1 2\n",
        "step {\n    cost 1 2\n",
        "let x = (1 2)\nlet y = 1 & 2\n",
        "when true {\n    let a = = 1\n}\nlet b = 'open\n",
    ], expect=errs(*["E_PARSE main.kiln:%d" % n
                     for n in (2, 2, 3, 3, 3, 2, 2, 4)]))

    variants("prec_eval_order", [
        'let x = 1\nphony a = []\nphony a = [x]\n',
        'phony a = []\nphony a = ["bad path"]\n',
        'phony a = []\nphony a = ["ok.txt"]\n',
        'let x = 5["a"]\n',
        'let x = "a" + [1]\n',
        'let x = [1] ++ "a"\n',
        'let x = 1\nlet x = y\n',
        'step {\n    out ["out/a.txt", 1, [2]]\n    cmd write("x")\n}\n',
        'let x = [1][true]\n',
        'let x = -"a" ~ 1\n',
    ], pub=True, expect=errs(
        "E_TYPE phony a: expected strlist, got int",
        "E_BAD_PATH bad path",
        "E_DUP_PHONY a",
        "E_TYPE index: expected int, got str",
        "E_TYPE operator +: expected int, got str",
        "E_TYPE operator ++: expected list, got str",
        "E_UNKNOWN_VAR y",
        "E_TYPE field out: expected strlist, got int",
        "E_TYPE index: expected int, got bool",
        "E_TYPE operator -: expected int, got str"))

    variants("prec_eval_order_more", [
        'phony a = []\nphony a = undefined\n',
        'phony a = []\nphony a = ["@bad-name"]\n',
        'let x = "abc"[undefined]\n',
        'let x = undefined[1 / 0]\n',
        'let x = true < 1 / 0\n',
        'let x = [1] ++ 2 + "b"\n',
        'default ["out/a.txt", 2, true]\n',
        'let xs = [1]\nlet y = xs["0"] + xs[5]\n',
        'let x = true["x"]\n',
    ], expect=errs(
        "E_UNKNOWN_VAR undefined",
        "E_BAD_PATH @bad-name",
        "E_UNKNOWN_VAR undefined",
        "E_UNKNOWN_VAR undefined",
        "E_DIV_ZERO",
        "E_TYPE operator +: expected int, got str",
        "E_TYPE default: expected strlist, got int",
        "E_TYPE index: expected int, got str",
        "E_TYPE index: expected int, got str"))

    # A rule keeps its defining scope by reference, so later `let`s and `set`s
    # there are visible to later instantiations.
    rule_src = (
        'rule r(n) {\n'
        '    step {\n'
        '        out "out/{n}.txt"\n'
        '        cmd write("{n}={late}\\n")\n'
        '    }\n'
        '}\n'
        'let late = "L1"\n'
        'use r("a")\n'
        'set late = "L2"\n'
        'use r("b")\n'
        'when true {\n'
        '    rule inner(n) {\n'
        '        step {\n'
        '            out "out/{n}.txt"\n'
        '            cmd write("{n}={tag}\\n")\n'
        '        }\n'
        '    }\n'
        '    let tag = "T1"\n'
        '}\n'
        'use inner("c")\n'
        'default ["out/a.txt", "out/b.txt", "out/c.txt"]\n')
    case("prec_rule_scope_by_reference", {"main.kiln": rule_src}, "build -j 3\n",
         pub=True,
         expect=['  run 0 1 w0 out/a.txt write("a=L1\\n")',
                 '  run 0 1 w1 out/b.txt write("b=L2\\n")',
                 '  run 0 1 w2 out/c.txt write("c=T1\\n")'])
    case("prec_rule_scope_by_reference_more",
         {"main.kiln": rule_src.replace("L1", "first").replace("L2", "second")
                               .replace("T1", "branch")},
         "build\n",
         expect=['  run 0 1 w0 out/a.txt write("a=first\\n")',
                 '  run 1 2 w0 out/b.txt write("b=second\\n")',
                 '  run 2 3 w0 out/c.txt write("c=branch\\n")'])

    # Content lines are verbatim: surrounding spaces and tabs are content.
    case("prec_content_lines_verbatim",
         {"main.kiln": step_of(['out "out/n.txt"', 'in "src/x.txt"',
                                'cmd hash()'], 'default "out/n.txt"\n')},
         "create src/x.txt\n  lead\ntrail  \n\ttab\t\n \n---\nbuild\n",
         expect=["  ok size=23", "  run 0 3 w0 out/n.txt hash()"])

    # Candidates with empty components, matched by filter and reject.
    items = ["", "x/", "/x", "a//b", "a/b", "/", "//", "a/", "/a/"]
    pats = ["*", "**", "?", "*/*", "**/b", "a/*/b", "*/x", "**/*", "*/*/*",
            "a/**", "**/a/**", "[!a]*"]
    parts = ['let xs = [%s]\n' % ", ".join('"%s"' % x for x in items)]
    parts.append('each i, p in [%s] {\n' % ", ".join('"%s"' % p for p in pats))
    parts.append('    step {\n'
                 '        out "out/e{i}.txt"\n'
                 '        cmd write("{count(filter(xs, p))}:{join(filter(xs, p), "|")}'
                 '/{join(reject(xs, p), "|")}\\n")\n'
                 '    }\n'
                 '    default "out/e{i}.txt"\n'
                 '}\n')
    expect = []
    for i, pat in enumerate(pats):
        keep = spec_filter(pat, items, True)
        drop = spec_filter(pat, items, False)
        want = (b"%d:" % len(keep)) + b"|".join(keep) + b"/" + b"|".join(drop) + b"\n"
        expect.append(b"  run %d %d w0 out/e%d.txt write(%s)" % (i, i + 1, i, esc(want)))
    case("prec_glob_empty_components", {"main.kiln": "".join(parts)}, "build\n",
         expect=expect)


def g_mutation_pins():
    # Mutual recursion: the use that would run at depth 65 names the rule it
    # is entering (`pong`, since `ping` runs at odd depths).
    mutual = ('rule ping(n) {\n    use pong(n + 1)\n}\n'
              'rule pong(n) {\n    when n < 1000 {\n        use ping(n + 1)\n    }\n}\n'
              'use ping(1)\n')
    case("mut_rule_depth_mutual", {"main.kiln": mutual}, "build\n",
         expect=["  error E_RULE_RECURSION ping"])

    # Reordering two byte-identical declared inputs makes the step stale.
    order = ('step {\n    out "out/j.txt"\n    in %s\n    cmd hash()\n}\n'
             'default "out/j.txt"\n')
    case("mut_input_order_counts",
         {"main.kiln": order % '["src/a.txt", "src/b.txt", "src/a.txt"]',
          "src/a.txt": "same\n", "src/b.txt": "same\n"},
         "build\nedit main.kiln\n" + (order % '["src/a.txt", "src/a.txt", "src/b.txt"]')
         + "---\nbuild\nbuild\n",
         expect=["  run 0 3 w0 out/j.txt hash()", "  ok ran=1 hit=0 time=3",
                 "  run 0 3 w0 out/j.txt hash()", "  ok ran=1 hit=0 time=3",
                 "  hit 0 out/j.txt"])

    # A cancelled step loses the state entry it had from an earlier build.
    cancel_main = ('step {\n    out "out/doc.txt"\n    depfile "out/doc.d"\n'
                   '    in "src/main.txt"\n    cmd preprocess()\n}\n'
                   'step {\n    out "out/slow.txt"\n    in "src/s.txt"\n'
                   '    cmd upper()\n    cost 20\n}\n'
                   'phony all = ["out/doc.txt", "out/slow.txt"]\ndefault "@all"\n')
    for suffix, pub in (("", True), ("_more", False)):
        case("mut_cancel_drops_entry" + suffix,
             {"main.kiln": cancel_main, "src/main.txt": "top\n@need src/p.txt\n",
              "src/p.txt": "part\n", "src/s.txt": "slow%s\n" % suffix},
             "build -j 2\nedit src/s.txt\nslow two\n---\ndelete src/p.txt\n"
             "build -j 2\nbuild -j 2\n" if not suffix else
             "build -j 2\nedit src/s.txt\nchanged\n---\ndelete src/p.txt\n"
             "build -j 2\n",
             pub=pub,
             expect=["  ok ran=2 hit=0 time=20",
                     "  fail 0 6 w0 out/doc.txt preprocess()",
                     "  cancel 0 20 w1 out/slow.txt upper()",
                     "  error E_NEED_MISSING src/p.txt needed by src/main.txt"])

    rows_pub = [
        ('{stem(".hidden")}|{ext(".hidden")}|{stem("d/.x.y")}|{ext("d/.x.y")}',
         ".hidden||.x|.y"),
        ('{stem("..")}|{ext("..")}|{stem("a/.")}|{ext("a/.")}', ".|.|.|"),
    ]
    write_table("mut_stem_leading_dot", "", rows_pub, pub=True)
    rows_hidden = [
        ('[{trim("\\r\\r x\\r")}] [{trim("\\rq")}]', "[x] [q]"),
        ('{substr("abcdef", -3, 2)}|{substr("abcdef", -6, 1)}|{substr("abcdef", -7, 3)}',
         "de|a|abc"),
        ('{join(slice([1, 2, 3, 4], -2, 9), ",")}|{join(slice([1, 2, 3], -1, -1), ",")}',
         "3,4|"),
    ]
    write_table("mut_trim_substr_negative", "", rows_hidden)


def register_all():
    g_session()
    g_workspace()
    g_commands()
    g_parse()
    g_expr()
    g_functions()
    g_glob()
    g_scope()
    g_steps()
    g_graph()
    g_examples()
    g_scheduler()
    g_state()
    g_freshness()
    g_preprocess()
    g_misc()
    g_glob2()
    g_command_matrix()
    g_sched_sweep()
    g_precedence()
    g_mutation_pins()
    g_generated()


if __name__ == "__main__":
    sys.exit(main())
