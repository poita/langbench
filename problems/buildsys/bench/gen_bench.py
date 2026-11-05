#!/usr/bin/env python3
"""Generate the buildsys performance benchmark deterministically.

Writes three directory-mode cases into bench/ in the same layout as tests/:
bench/NNN_name/input/ (session.txt plus the initial workspace) and
bench/NNN_name/expected/ (the tree reference/main.py produces from it).

Every case stays inside the limits SPEC.md states: at most 400 session steps,
at most 2,400 steps, 120 phony targets and 11,000 declared inputs per build,
at most 24 included files, no build file over 180 KB, globs over at most
3,000 files, no file over 256 KB, no workspace over 6 MB and an output tree of
about 3,600 files at most. The generator checks the stated limits it can see
directly and refuses to write a case whose log contains an error line.

    python3 gen_bench.py [--only SUBSTRING] [--no-expected]
"""
import argparse
import os
import random
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)
sys.dont_write_bytecode = True
from gen_tests import check_paths  # noqa: E402

REF = os.path.join(PROBLEM, "reference", "main.py")

MAX_SESSION_STEPS = 400
MAX_FILE = 256 * 1024
MAX_BUILD_FILE = 180 * 1024
MAX_WORKSPACE = 6 * 1024 * 1024
MAX_GLOB_FILES = 3000
MAX_OUTPUT_FILES = 3600
# The state file of a 2,000-step build cannot fit in 256 KB; the official
# suite's own largest case (gen_huge_2) writes a 363,440-byte .kiln-state, so
# that size is the bound used for it here.
MAX_STATE = 363440

WORDS = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
         "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi", "rho",
         "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega",
         "ash", "birch", "cedar", "elm", "fir", "hazel", "ilex", "juniper",
         "larch", "maple", "oak", "pine", "rowan", "spruce", "willow", "yew",
         "Ünicode", "naïve", "0123", "a-b+c", "TODO", "assert", "return",
         "init", "free", "load", "store", "parse", "emit", "flush"]


def words_line(rng, lo, hi, words=WORDS):
    return " ".join(rng.choice(words) for _ in range(rng.randint(lo, hi)))


def text_lines(rng, n, lo=2, hi=8):
    return [words_line(rng, lo, hi) for _ in range(n)]


def as_text(lines):
    return "".join(l + "\n" for l in lines)


def content_block(lines):
    """Session `create`/`edit` body lines; never a bare `---`."""
    return [l if l != "---" else "- - -" for l in lines]


# ---------------------------------------------------------------------------
# 001 — a large monorepo driven through a long incremental session
# ---------------------------------------------------------------------------

M1_MODULES = 24
M1_SOURCES = 960             # two steps each, plus three per module and one
M1_STAGE2 = [("upper()", 2), ("lower()", 2), ("number()", 2), ("dedup()", 3),
             ("sort_lines()", 4), ("reverse_lines()", 2), ('grep("e")', 3),
             ('replace("a", "A")', 3), ("indent(4)", 2), ("copy()", 1),
             ('wrap("/* ", " */\\n")', 1)]
M1_BUNDLE = ["concat()", "count_lines()", "hash()"]


def m1_module_file(name, picks, bundle, deps, wrap_cost):
    lines = [
        "# module %s" % name,
        'let srcs_%s = glob("src/%s/**") |> filter("**/*.txt") |> sort' % (name, name),
        "let objs_%s = []" % name,
        "each i, f in srcs_%s {" % name,
        '    let pp = "out/%s/pp/{stem(f)}.txt"' % name,
        '    let obj = "out/%s/obj/{stem(f)}.txt"' % name,
        "    step {",
        "        out pp",
        '        in [prelude, "src/%s/api.h", f]' % name,
        "        cmd concat()",
        "        cost 1 + len(f) % 3",
        "    }",
    ]
    for b, (cmd, cost) in enumerate(picks):
        if b == 0:
            head = "    when i %% %d == 0 {" % len(picks)
        elif b < len(picks) - 1:
            head = "    } elsewhen i %% %d == %d {" % (len(picks), b)
        else:
            head = "    } otherwise {"
        lines += [head,
                  "        step {",
                  "            out obj",
                  "            in pp",
                  "            cmd %s" % cmd,
                  "            cost %d" % cost,
                  "        }"]
    lines += ["    }",
              "    set objs_%s = objs_%s ++ [obj]" % (name, name),
              "}",
              "step {",
              '    out "out/%s/bundle.txt"' % name,
              "    in objs_%s" % name,
              "    cmd %s" % bundle,
              "    cost 4",
              "}",
              "step {",
              '    out "out/%s/lib.txt"' % name,
              '    in ["out/%s/bundle.txt"%s]'
              % (name, "".join(', "out/%s/lib.txt"' % d for d in deps)),
              "    cmd hash()",
              "    cost 3",
              "}",
              'use wrapper("%s/wrapped", "out/%s/lib.txt", "<%s|", "|>\\n", %d)'
              % (name, name, name, wrap_cost),
              'phony %s = ["out/%s/wrapped.txt"]' % (name, name)]
    return "\n".join(lines) + "\n"


def gen_monorepo(max_steps=200):
    rng = random.Random(1001)
    names = ["m%02d" % k for k in range(M1_MODULES)]
    files = {"lib/prelude.txt": as_text(["// prelude"] + text_lines(rng, 4))}
    live = {n: [] for n in names}
    counter = {n: 0 for n in names}
    subdirs = ["core", "util", "io", "net", "fmt"]
    for i in range(M1_SOURCES):
        n = names[i % M1_MODULES]
        path = "src/%s/%s/f%03d.txt" % (n, rng.choice(subdirs), counter[n])
        counter[n] += 1
        files[path] = as_text(text_lines(rng, rng.randint(6, 14)))
        live[n].append(path)
    module_text = {}
    module_cfg = {}
    for k, n in enumerate(names):
        files["src/%s/api.h" % n] = as_text(
            ["// api of %s" % n] + text_lines(rng, 3))
        picks = [M1_STAGE2[j] for j in rng.sample(range(len(M1_STAGE2)), 4)]
        bundle = M1_BUNDLE[rng.randrange(len(M1_BUNDLE))]
        deps = sorted(rng.sample(names[:k], min(k, rng.randint(1, 3)))) if k else []
        cfg = [picks, bundle, deps, rng.randint(1, 3)]
        module_cfg[n] = cfg
        module_text[n] = m1_module_file(n, *cfg)
        files["build/%s.kiln" % n] = module_text[n]
    main = ['let prelude = "lib/prelude.txt"',
            "rule wrapper(name, src, pre, post, w = 1) {",
            "    step {",
            '        out "out/{name}.txt"',
            "        in src",
            "        cmd wrap(pre, post)",
            "        cost w",
            "    }",
            "}"]
    main += ['include "build/%s.kiln"' % n for n in names]
    main += ["step {",
             '    out "out/all.txt"',
             "    in [%s]" % ", ".join('"out/%s/lib.txt"' % n for n in names),
             "    after [%s]" % ", ".join('"@%s"' % n for n in names),
             "    cmd count_lines()",
             "    cost 2",
             "}",
             'phony all = ["out/all.txt"]',
             'default "@all"']
    files["main.kiln"] = "\n".join(main) + "\n"

    # The session: a day of incremental work on the repository.
    s = []
    steps = 0
    created = 0
    jobs_choices = [1, 2, 4, 8, 8, 16, 16, 32, 64]
    s.append("build -j 16")
    steps += 1
    while steps < max_steps:
        r = rng.random()
        if r < 0.36:
            n = rng.choice(names)
            p = rng.choice(live[n])
            s.append("edit " + p)
            s += content_block(text_lines(rng, rng.randint(6, 14)))
            s.append("---")
        elif r < 0.46:
            n = rng.choice(names)
            s.append("touch " + rng.choice(live[n]))
        elif r < 0.52 and sum(map(len, live.values())) < M1_SOURCES + 20:
            n = rng.choice(names)
            p = "src/%s/new/n%03d.txt" % (n, created)
            created += 1
            s.append("create " + p)
            s += content_block(text_lines(rng, rng.randint(6, 14)))
            s.append("---")
            live[n].append(p)
        elif r < 0.57:
            n = rng.choice([m for m in names if len(live[m]) > 30])
            p = live[n].pop(rng.randrange(len(live[n])))
            s.append("delete " + p)
        elif r < 0.62:
            n = rng.choice(names)
            s.append("edit src/%s/api.h" % n)
            s += content_block(["// api of %s" % n] + text_lines(rng, 3))
            s.append("---")
        elif r < 0.68:
            # A build-file edit: a new cost (no rebuild) or a new command for
            # one branch (the module's objects in that branch go stale).
            n = rng.choice(names)
            cfg = module_cfg[n]
            if rng.random() < 0.5:
                cfg[3] = rng.randint(1, 5)
            else:
                b = rng.randrange(len(cfg[0]))
                cfg[0][b] = M1_STAGE2[rng.randrange(len(M1_STAGE2))]
            s.append("edit build/%s.kiln" % n)
            s += m1_module_file(n, *cfg).rstrip("\n").split("\n")
            s.append("---")
        elif r < 0.695:
            s.append("edit lib/prelude.txt")
            s += content_block(["// prelude"] + text_lines(rng, 4))
            s.append("---")
        elif r < 0.705:
            s.append("clean")
        else:
            s.append("touch main.kiln")
        steps += 1
        jobs = rng.choice(jobs_choices)
        tr = rng.random()
        if tr < 0.7:
            target = ""
        elif tr < 0.85:
            target = "@" + rng.choice(names)
        else:
            target = "out/%s/lib.txt" % rng.choice(names)
        s.append(("build " + target).strip() + " -j %d" % jobs)
        steps += 1
    return files, "\n".join(s) + "\n"


# ---------------------------------------------------------------------------
# 002 — an evaluation-heavy configuration over a 2,700-file tree
# ---------------------------------------------------------------------------

M2_PKGS = 24
M2_FEATURES = ["simd", "threads", "tls", "zstd", "lz4", "trace", "debug", "ipv6",
               "unicode", "fastmath"]
M2_STEMS = ["alloc", "arena", "codec", "cursor", "deque", "event", "frame",
            "graph", "hash", "heap", "index", "lexer", "match", "parse", "pool",
            "queue", "radix", "ring", "scan", "sched", "slab", "sort", "span",
            "table", "timer", "token", "trie", "vector", "walk", "zone"]


def m2_config(version, features, opt):
    return "\n".join([
        "# project configuration, included before every package",
        'let version = "%s"' % version,
        "let features = [%s]" % ", ".join('"%s"' % f for f in features),
        "let opt_level = %d" % opt,
        'let vparts = split(version, ".")',
        "let vnum = int(vparts[0]) * 10000 + int(vparts[1]) * 100 + int(vparts[2])",
        'let banner = "kiln {version} ({join(sort(features), "+")}) O{opt_level} #{vnum}"',
    ]) + "\n"


M2_MAIN_HEAD = r'''# generated-configuration build: every package is described by macros
include "config.kiln"
let all_tests = []
let all_manifests = []
let all_links = []
let everything = glob("**")

rule obj(pkg, f, i, flags = [], weight = 1 + (len(f) * 7 + i) % 5) {
    let o = "out/{pkg}/obj/" ~ replace(substr(f, len(pkg) + 5, 1000), "/", "__")
    step {
        out o
        in f
        cmd replace("TODO", "DONE[{join(flags, ",")}]")
        cost weight
    }
}

rule compile_group(pkg, group, flags) {
    let objs = []
    each pair in zip(group, range(count(group))) {
        let f = pair[0]
        let i = pair[1]
        when starts_with(basename(f), "fast_") && has(features, "simd") {
            use obj(pkg, f, i, flags ++ ["simd-path"], 1)
        } elsewhen ends_with(stem(stem(f)), "_impl") {
            use obj(pkg, f, i, slice(flags, 0, 3))
        } elsewhen contains(f, "/legacy/") {
            use obj(pkg, f, i, ["legacy"], weight = 6)
        } otherwise {
            use obj(pkg, f, i, flags)
        }
        set objs = objs ++ ["out/{pkg}/obj/" ~ replace(substr(f, len(pkg) + 5, 1000), "/", "__")]
    }
    set pending_objs = pending_objs ++ objs
}

rule test_log(pkg, f, needle = "assert") {
    let o = "out/{pkg}/test/{stem(stem(f))}.log"
    step {
        out o
        in f
        cmd grep(needle)
        cost 2
    }
    set all_tests = all_tests ++ [o]
}

rule manifest(pkg, dir, listing, kind = "dir", label = upper(pkg) ~ ":" ~ kind) {
    let body = listing |> map("  - %") |> join("\n")
    let total = 0
    let longest = ""
    each p in listing {
        set total = total + len(basename(p))
        when len(p) > len(longest) || (len(p) == len(longest) && p < longest) {
            set longest = p
        }
    }
    let o = "out/{pkg}/manifest/{replace(dir, "/", "_")}.txt"
    step {
        out o
        cmd write("# {label} {dir}\n{body}\n# {count(listing)} entries, {total} name bytes, longest {trim(longest)}\n")
    }
    set all_manifests = all_manifests ++ [o]
}

let pending_objs = []

rule package(pkg, deps, extra_flags = []) {
    let all = glob("pkg/{pkg}/**")
    let csrc = all |> filter("**/*.c.txt") |> reject("**/test_*") |> sort
    let hdrs = all |> filter("**/*.h.txt") |> sort
    let tests = filter(all, "**/test_[a-m]*.c.txt") ++ filter(all, "**/test_[!a-m]*.c.txt")
    let docs = all |> filter("**/*.md") |> sort
    let data = all |> reject("**/*.[ch].txt") |> reject("**/*.md") |> sort
    let flags = uniq(sort(extra_flags ++ features ++ [pkg, "O" ~ str(opt_level)]))
    let dirs = []
    each f in all {
        let d = dirname(f)
        when !has(dirs, d) {
            set dirs = dirs ++ [d]
        }
    }
    set dirs = sort(dirs)
    set pending_objs = []
    each g in ["core", "util", "legacy"] {
        use compile_group(pkg, filter(csrc, "pkg/{pkg}/src/{g}/*"), flags)
    }
    let objs = pending_objs
    each t in tests {
        when indexof(tests, t) % 2 == 0 {
            use test_log(pkg, t)
        } otherwise {
            use test_log(pkg, t, needle = lower("ASSERT"))
        }
    }
    each k, d in dirs {
        let here = filter(all, d ~ "/*")
        when count(here) > 0 && !contains(d, "/data/") {
            use manifest(pkg, d, here, kind = str(k) ~ "/" ~ str(count(dirs)))
        }
    }
    use manifest(pkg, "docs", docs, "docs", label = "{pkg} docs ({count(docs)})")
    step {
        out "out/{pkg}/data.idx"
        in data
        cmd count_lines()
        cost 1 + count(data) / 10
    }
    step {
        out "out/{pkg}/lib.a"
        in objs ++ hdrs
        cmd hash()
        cost 2 + count(objs) / 8
    }
    step {
        out "out/{pkg}/link.txt"
        in ["out/{pkg}/lib.a"] ++ map(deps, "out/%/link.txt")
        cmd hash()
        cost 3
    }
    set all_links = all_links ++ ["out/{pkg}/link.txt", "out/{pkg}/data.idx"]
}
'''

M2_MAIN_TAIL = r'''
let exts = [".c.txt", ".h.txt", ".md", ".dat", ".cfg"]
let ext_counts = []
each e in exts {
    set ext_counts = ext_counts ++ ["{e}={count(filter(everything, "**/*" ~ e))}"]
}
let newest = everything |> filter("**/new_*") |> sort |> reverse |> slice(0, 5)
step {
    out "out/summary.txt"
    cmd write("{banner}\n{join(ext_counts, " ")}\nfiles={count(everything)}\nnew={join(newest, ",")}\n")
}
step {
    out "out/tests.txt"
    in all_tests
    cmd count_lines()
    cost 2
}
step {
    out "out/release.txt"
    in all_links ++ ["out/summary.txt", "out/tests.txt"]
    after all_manifests
    cmd hash()
    cost 4
}
phony all = ["out/release.txt"]
default "@all"
'''


def m2_pkg_file(pkg, deps, extra):
    return ("# package %s\n" % pkg
            + 'use package("%s", [%s], extra_flags = [%s])\n'
            % (pkg, ", ".join('"%s"' % d for d in deps),
               ", ".join('"%s"' % x for x in extra))
            + 'phony %s = ["out/%s/link.txt", "out/%s/manifest/docs.txt"]\n'
            % (pkg, pkg, pkg))


def m2_c_source(rng, test=False):
    lines = []
    for _ in range(rng.randint(5, 12)):
        r = rng.random()
        if test and r < 0.35:
            lines.append("assert %s == %s" % (rng.choice(M2_STEMS), rng.choice(WORDS)))
        elif r < 0.15:
            lines.append("// TODO %s" % words_line(rng, 1, 4))
        else:
            lines.append(words_line(rng, 2, 7))
    return lines


def gen_eval_heavy(max_steps=90):
    rng = random.Random(2002)
    names = ["p%02d" % k for k in range(M2_PKGS)]
    files = {}
    live = {n: [] for n in names}
    for n in names:
        used = set()

        def fresh(prefix="", suffix=""):
            while True:
                s = prefix + rng.choice(M2_STEMS) + "%d" % rng.randrange(100) + suffix
                if s not in used:
                    used.add(s)
                    return s
        for g, k in (("core", 8), ("util", 5), ("legacy", 3)):
            for _ in range(k):
                r = rng.random()
                stem = fresh("fast_" if r < 0.25 else "", "_impl" if 0.25 <= r < 0.5 else "")
                files["pkg/%s/src/%s/%s.c.txt" % (n, g, stem)] = as_text(m2_c_source(rng))
        for _ in range(10):
            files["pkg/%s/include/%s.h.txt" % (n, fresh())] = as_text(text_lines(rng, 4))
        for _ in range(6):
            files["pkg/%s/test/test_%s.c.txt" % (n, fresh())] = as_text(m2_c_source(rng, True))
        for _ in range(6):
            files["pkg/%s/docs/%s.md" % (n, fresh())] = as_text(
                ["# " + words_line(rng, 1, 3)] + text_lines(rng, 4))
        for j in range(74):
            d = "pkg/%s/data/%s/%s" % (n, "abcdef"[j % 6], "xy"[j % 2])
            files["%s/%s.%s" % (d, fresh(), "dat" if j % 3 else "cfg")] = as_text(
                text_lines(rng, rng.randint(2, 8), 1, 4))
        live[n] = [p for p in files if p.startswith("pkg/%s/" % n)]
    feats = ["simd", "threads", "unicode"]
    version = [3, 14, 159]
    opt = 2
    files["config.kiln"] = m2_config("%d.%d.%d" % tuple(version), feats, opt)
    pkg_cfg = {}
    for k, n in enumerate(names):
        deps = sorted(rng.sample(names[:k], min(k, rng.randint(1, 4)))) if k else []
        extra = rng.sample(["pic", "lto", "strict", "asan", "ubsan", "pgo"], rng.randint(0, 3))
        pkg_cfg[n] = (deps, extra)
        files["build/%s.kiln" % n] = m2_pkg_file(n, deps, extra)
    files["main.kiln"] = (M2_MAIN_HEAD
                          + "".join('include "build/%s.kiln"\n' % n for n in names)
                          + M2_MAIN_TAIL)

    s = ["build -j 8"]
    steps = 1
    created = 0
    total_files = len(files)
    while steps < max_steps:
        r = rng.random()
        n = rng.choice(names)
        if r < 0.22 and total_files < 2760:
            kind = rng.random()
            if kind < 0.4:
                d = "pkg/%s/data/%s/%s" % (n, rng.choice("abcdef"), rng.choice("xy"))
                p = "%s/new_%03d.dat" % (d, created)
                body = text_lines(rng, rng.randint(2, 6), 1, 4)
            elif kind < 0.7:
                p = "pkg/%s/src/%s/new_%03d.c.txt" % (n, rng.choice(["core", "util"]), created)
                body = m2_c_source(rng)
            elif kind < 0.85:
                p = "pkg/%s/docs/new_%03d.md" % (n, created)
                body = ["# new"] + text_lines(rng, 3)
            else:
                p = "pkg/%s/test/test_new%03d.c.txt" % (n, created)
                body = m2_c_source(rng, True)
            created += 1
            total_files += 1
            live[n].append(p)
            s.append("create " + p)
            s += content_block(body)
            s.append("---")
        elif r < 0.34:
            cands = [p for p in live[n] if "/data/" in p or "/docs/" in p
                     or "/test/" in p or "/util/" in p]
            p = cands[rng.randrange(len(cands))]
            live[n].remove(p)
            total_files -= 1
            s.append("delete " + p)
        elif r < 0.56:
            cands = [p for p in live[n] if p.endswith(".c.txt")]
            p = cands[rng.randrange(len(cands))]
            s.append("edit " + p)
            s += content_block(m2_c_source(rng, "/test/" in p))
            s.append("---")
        elif r < 0.64:
            f = rng.random()
            if f < 0.4:
                feat = rng.choice(M2_FEATURES)
                if feat in feats and len(feats) > 1:
                    feats.remove(feat)
                elif feat not in feats:
                    feats.append(feat)
            elif f < 0.7:
                version[2] += 1
            else:
                opt = rng.randint(0, 3)
            s.append("edit config.kiln")
            s += m2_config("%d.%d.%d" % tuple(version), feats, opt).rstrip("\n").split("\n")
            s.append("---")
        elif r < 0.70:
            deps, extra = pkg_cfg[n]
            extra = rng.sample(["pic", "lto", "strict", "asan", "ubsan", "pgo"], rng.randint(0, 3))
            pkg_cfg[n] = (deps, extra)
            s.append("edit build/%s.kiln" % n)
            s += m2_pkg_file(n, deps, extra).rstrip("\n").split("\n")
            s.append("---")
        elif r < 0.85:
            s.append("touch " + rng.choice(live[n]))
        else:
            s.append("touch main.kiln")
        steps += 1
        tr = rng.random()
        target = "" if tr < 0.75 else ("@" + rng.choice(names) if tr < 0.9 else "out/summary.txt")
        s.append(("build " + target).strip() + " -j %d" % rng.choice([1, 4, 8, 16, 64]))
        steps += 1
    return files, "\n".join(s) + "\n"

# ---------------------------------------------------------------------------
# 003 — a documentation pipeline: preprocess, depfiles and line commands
# ---------------------------------------------------------------------------

M3_CHAPTERS = 12
M3_SECTIONS = 8
M3_FRAGS_PER_SECTION = 12
M3_SNIPPETS = 60

M3_MAIN = r'''# book pipeline: every chapter is assembled from sections and fragments
let chapters = glob("docs/chapter_*.src") |> sort
let todos = []
let htmls = []
let books = []

rule chapter(src, n, w = 6) {
    let name = stem(src)
    let book = "out/book/{name}.txt"
    step {
        out book
        depfile "out/book/{name}.d"
        in src
        cmd preprocess()
        cost w + n % 3
    }
    step {
        out "out/idx/{name}.uniq"
        in book
        cmd dedup()
    }
    step {
        out "out/idx/{name}.sorted"
        in "out/idx/{name}.uniq"
        cmd sort_lines()
    }
    step {
        out "out/todo/{name}.txt"
        in book
        cmd grep("TODO")
    }
    step {
        out "out/todo/{name}.numbered"
        in "out/todo/{name}.txt"
        cmd number()
    }
    step {
        out "out/html/{name}.html"
        in book
        cmd replace("kiln", "<b>kiln</b>")
        cost 4
    }
    set todos = todos ++ ["out/todo/{name}.numbered"]
    set htmls = htmls ++ ["out/html/{name}.html"]
    set books = books ++ [book, "out/idx/{name}.sorted"]
}

each i, c in chapters {
    use chapter(c, i)
}
step {
    out "out/book/todo_all.txt"
    in todos
    cmd concat()
}
step {
    out "out/book/todo_sorted.txt"
    in "out/book/todo_all.txt"
    cmd sort_lines()
}
step {
    out "out/book/stats.txt"
    in books
    cmd count_lines()
}
step {
    out "out/book/hashes.txt"
    in htmls
    cmd hash()
}
step {
    out "out/book/release.txt"
    in ["out/book/stats.txt", "out/book/hashes.txt"]
    cmd concat()
    cost 1
}
phony all = ["out/book/release.txt", "out/book/todo_sorted.txt"]
default "@all"
'''


def gen_doc_pipeline(max_steps=300):
    rng = random.Random(3003)
    plain = [w for w in WORDS if w != "TODO"]

    def words_line(rng, lo, hi):
        return " ".join(rng.choice(plain) for _ in range(rng.randint(lo, hi)))
    boiler = [words_line(rng, 3, 9) for _ in range(400)]
    boiler += ["the kiln %s is %s" % (rng.choice(WORDS), rng.choice(WORDS)) for _ in range(80)]

    def frag_lines(n):
        out = []
        for _ in range(n):
            r = rng.random()
            if r < 0.45:
                out.append(rng.choice(boiler))
            elif r < 0.52:
                out.append("TODO %s" % words_line(rng, 2, 6))
            elif r < 0.6:
                out.append("")
            else:
                out.append(words_line(rng, 3, 10))
        return out

    files = {}
    files["docs/glossary.txt"] = as_text(["== glossary =="] + [
        "%s: %s" % (w, words_line(rng, 3, 8)) for w in WORDS])
    snippets = []
    for k in range(M3_SNIPPETS):
        p = "docs/snip/s%02d.txt" % k
        files[p] = as_text(frag_lines(rng.randint(3, 8)))
        snippets.append(p)
    frags = []
    sections = []
    for c in range(M3_CHAPTERS):
        ch = ["= Chapter %d =" % (c + 1), "", "kiln documentation, chapter %d" % (c + 1)]
        for s in range(M3_SECTIONS):
            sec = "docs/sec/c%02d_s%d.txt" % (c, s)
            body = ["== %d.%d %s ==" % (c + 1, s + 1, words_line(rng, 1, 3))]
            for f in range(M3_FRAGS_PER_SECTION):
                fp = "docs/frag/c%02d/s%d_f%02d.txt" % (c, s, f)
                lines = frag_lines(rng.randint(14, 26))
                if rng.random() < 0.3:
                    lines.insert(rng.randrange(len(lines) + 1),
                                 "@need " + rng.choice(snippets))
                files[fp] = as_text(lines)
                frags.append(fp)
                body.append("@need " + fp)
                if rng.random() < 0.15:
                    body.append("@need " + rng.choice(snippets))
            files[sec] = as_text(body)
            sections.append(sec)
            ch.append("@need " + sec)
        ch += ["", "@need docs/glossary.txt", "-- end of chapter %d --" % (c + 1)]
        files["docs/chapter_%02d.src" % c] = as_text(ch)
    files["main.kiln"] = M3_MAIN

    s = ["build -j 8"]
    steps = 1
    while steps < max_steps:
        r = rng.random()
        if r < 0.55:
            p = rng.choice(frags)
            lines = frag_lines(rng.randint(14, 26))
            if rng.random() < 0.3:
                lines.insert(rng.randrange(len(lines) + 1), "@need " + rng.choice(snippets))
            s.append("edit " + p)
            s += content_block(lines)
            s.append("---")
        elif r < 0.67:
            p = rng.choice(snippets)
            s.append("edit " + p)
            s += content_block(frag_lines(rng.randint(3, 8)))
            s.append("---")
        elif r < 0.75:
            # A section gains or loses a fragment reference.
            sec = rng.choice(sections)
            c, sn = sec[10:12], sec[14]
            body = files[sec].rstrip("\n").split("\n")
            pool = [f for f in frags if f.startswith("docs/frag/c%s/" % c)]
            if rng.random() < 0.5 and len(body) > 4:
                body.pop(rng.randrange(1, len(body)))
            else:
                body.insert(rng.randrange(1, len(body) + 1), "@need " + rng.choice(pool))
            files[sec] = as_text(body)
            s.append("edit " + sec)
            s += content_block(body)
            s.append("---")
        elif r < 0.78:
            s.append("edit docs/glossary.txt")
            s += content_block(["== glossary =="] + [
                "%s: %s" % (w, words_line(rng, 3, 8)) for w in WORDS])
            s.append("---")
        elif r < 0.79:
            s.append("clean")
        else:
            s.append("touch " + rng.choice(frags))
        steps += 1
        target = "" if rng.random() < 0.85 else "out/book/%s.txt" % (
            "chapter_%02d" % rng.randrange(M3_CHAPTERS))
        s.append(("build " + target).strip() + " -j %d" % rng.choice([2, 4, 8, 12]))
        steps += 1
    return files, "\n".join(s) + "\n"


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------

CASES = [
    ("001_monorepo_incremental", gen_monorepo),
    ("002_config_eval_heavy", gen_eval_heavy),
    ("003_doc_pipeline_preprocess", gen_doc_pipeline),
]

# Long tier (../bench-long): the same three sessions continued for many more
# edit/build rounds from the same seeds; the workspaces and build files are
# unchanged. Only the session length exceeds the SPEC limit (400 steps).
LONG_DIR = os.path.join(PROBLEM, "bench-long")
LONG_MAX_SESSION_STEPS = 5000
# Files created during the longer 001 session add a few entries to its state
# file, which ends up slightly above the short tier's bound.
LONG_MAX_STATE = 400_000
LONG_CASES = [
    ("001_monorepo_incremental", lambda: gen_monorepo(LONG_STEPS[0])),
    ("002_config_eval_heavy", lambda: gen_eval_heavy(LONG_STEPS[1])),
    ("003_doc_pipeline_preprocess", lambda: gen_doc_pipeline(LONG_STEPS[2])),
]
LONG_STEPS = (2000, 780, 4400)


def materialize(files, session, inp):
    os.makedirs(inp)
    with open(os.path.join(inp, "session.txt"), "wb") as f:
        f.write(session.encode("utf-8"))
    for path, content in sorted(files.items()):
        full = os.path.join(inp, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(content if isinstance(content, bytes) else content.encode("utf-8"))


def check_limits(name, files, session, expected, max_steps=MAX_SESSION_STEPS, max_state=MAX_STATE):
    check_paths(name, files)
    nsteps = sum(1 for l in session.split("\n")
                 if l.split(" ", 1)[0] in ("build", "create", "edit", "delete",
                                           "touch", "clean"))
    problems = []
    if nsteps > max_steps:
        problems.append("session has %d steps" % nsteps)
    for p, c in files.items():
        if len(c.encode("utf-8") if isinstance(c, str) else c) > MAX_FILE:
            problems.append("%s exceeds 256 KB" % p)
        if p.endswith(".kiln") and len(c.encode("utf-8")) > MAX_BUILD_FILE:
            problems.append("%s exceeds 180 KB" % p)
    if len(files) > MAX_GLOB_FILES + 60:
        problems.append("initial workspace has %d files" % len(files))
    if expected:
        ws = os.path.join(expected, "workspace")
        total = 0
        count = 0
        for dp, _, fns in os.walk(ws):
            for fn in fns:
                size = os.path.getsize(os.path.join(dp, fn))
                total += size
                count += 1
                limit = max_state if fn == ".kiln-state" else MAX_FILE
                if size > limit:
                    problems.append("output %s exceeds its size limit"
                                    % os.path.relpath(os.path.join(dp, fn), ws))
        if total > MAX_WORKSPACE:
            problems.append("final workspace is %d bytes" % total)
        if count > MAX_OUTPUT_FILES:
            problems.append("final workspace has %d files" % count)
        with open(os.path.join(expected, "log.txt"), "rb") as f:
            log = f.read()
        if b"  error " in log:
            line = [l for l in log.split(b"\n") if l.startswith(b"  error ")][0]
            problems.append("log has an error: %r" % line)
    if problems:
        raise SystemExit("%s: %s" % (name, "; ".join(problems[:10])))
    return nsteps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--no-expected", action="store_true",
                    help="write inputs only (for quick calibration)")
    ap.add_argument("--long", action="store_true", help="write the long tier to ../bench-long")
    args = ap.parse_args()
    base = LONG_DIR if args.long else HERE
    for name, fn in (LONG_CASES if args.long else CASES):
        if args.only and args.only not in name:
            continue
        files, session = fn()
        root = os.path.join(base, name)
        shutil.rmtree(root, ignore_errors=True)
        inp = os.path.join(root, "input")
        materialize(files, session, inp)
        expected = None
        elapsed = 0.0
        if not args.no_expected:
            expected = os.path.join(root, "expected")
            os.makedirs(expected)
            t0 = time.time()
            proc = subprocess.run([sys.executable, REF, inp, expected],
                                  capture_output=True)
            elapsed = time.time() - t0
            if proc.returncode != 0:
                raise SystemExit("%s: reference exited %d: %s"
                                 % (name, proc.returncode,
                                    proc.stderr.decode("utf-8", "replace")[-2000:]))
        if args.long:
            nsteps = check_limits(name, files, session, expected, LONG_MAX_SESSION_STEPS, LONG_MAX_STATE)
        else:
            nsteps = check_limits(name, files, session, expected)
        print("%-32s %5d files  %3d session steps  reference %.1fs"
              % (name, len(files), nsteps, elapsed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
