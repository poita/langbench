#!/usr/bin/env python3
"""Audit a run: what its agents touched and what their implementations depend on.

    tools/audit.py TRANSCRIPTS IMPLS [--forbidden PATH ...] [--json OUT]

TRANSCRIPTS is a run directory (manifest.jsonl and sessions/, as `impl_run.py` writes), an older workflow run's
transcript directory, or an archive of either (.tar.gz);
IMPLS is the directory of <rep>/<lang>/<slug> implementations. Reported:

- forbidden-path: a tool call that was not refused naming a forbidden path (the repository, the held-out tests, transcripts, the
  sandbox outside the task's own workspace) or a reference implementation or test generator anywhere;
- other-implementation: a tool call naming a file inside another agent's project;
- blocked-attempt: a tool call naming forbidden paths, every one of which was refused (the sandbox's
  "Operation not permitted" or a file tool's permission denial); reported, but nothing was read;
- environment: instruction files (CLAUDE.md, memory) injected into an agent's context;
- harness-modified (from impl_run.py finish): a test, spec or runner file changed in the sandbox;
- dependency: a third-party dependency in an implementation's manifest or imports;
- banned-facility: a standard-library facility that the problem's SPEC.md rules out (a regex engine for
  regex, a JSON parser for json, an ordered map for ordered-map, ...);
- build-flags: non-default optimisation settings in the build files.

forbidden-path, other-implementation, environment and harness-modified are integrity findings: the run itself
is suspect, `impl_run.py finish` will not record it, and the exit status is nonzero. The rest (blocked attempts
and rule violations by individual agents) are reported as results.
"""
import argparse
import glob
import json
import os
import re
import sys
import tarfile
import tempfile

INTEGRITY = {"forbidden-path", "other-implementation", "environment", "harness-modified"}
IMPORTS = {
    "python": re.compile(r"^\s*(?:import\s+([\w.]+(?:\s*,\s*[\w.]+)*)|from\s+([\w.]+)\s+import)", re.M),
    "go": re.compile(r'^\s*(?:import\s+)?(?:[\w.]+\s+)?"([\w/]+)"\s*$', re.M),
    "d": re.compile(r"^\s*(?:public\s+|static\s+)*import\s+([\w.]+)", re.M),
    "cpp": re.compile(r"^\s*#\s*include\s*(<\w+>)", re.M),
    "rust": re.compile(r"\b(BTreeMap|BTreeSet)\b"),
    "haskell": re.compile(r"^\s*import\s+(?:safe\s+)?(?:qualified\s+)?([\w.]+)", re.M),
    # Clojure reaches the JDK through :import forms and fully qualified names alike, so any mention counts.
    "clojure": re.compile(r"\b((?:java|javax|clojure)\.[\w.\-]*\w)"),
}
# Standard-library facilities by category, as each language names the module, package or header.
FACILITIES = {
    "regex": {"python": r"re", "go": r"regexp(/syntax)?", "d": r"std\.regex(\.\w+)*", "cpp": r"<regex>",
              "haskell": r"Text\.Regex(\.\w+)*", "clojure": r"java\.util\.regex(\.\w+)*"},
    "json": {"python": r"json", "go": r"encoding/json", "d": r"std\.json", "clojure": r"clojure\.data\.json"},
    "zlib": {"python": r"zlib|gzip", "go": r"compress/\w+", "d": r"std\.zlib", "clojure": r"java\.util\.zip(\.\w+)*"},
    "hash": {"python": r"hashlib|hmac", "go": r"crypto/\w+", "d": r"std\.digest(\.\w+)*",
             "clojure": r"java\.security(\.\w+)*|javax\.crypto(\.\w+)*"},
    "base64": {"python": r"base64|binascii", "go": r"encoding/base64", "d": r"std\.base64",
               "clojure": r"java\.util\.Base64"},
    "bigint": {"python": r"decimal|fractions", "go": r"math/big", "d": r"std\.bigint", "clojure": r"java\.math(\.\w+)*"},
    "sql": {"python": r"sqlite3", "go": r"database/sql", "clojure": r"java\.sql(\.\w+)*"},
    "email": {"python": r"email(\.\w+)*|quopri", "go": r"net/mail|mime(/\w+)?",
              "clojure": r"javax\.mail(\.\w+)*|jakarta\.mail(\.\w+)*"},
    "toml": {"python": r"tomllib"},
    "diff": {"python": r"difflib"},
    "date": {"python": r"datetime|calendar|zoneinfo", "go": r"time", "d": r"std\.datetime(\.\w+)*",
             "haskell": r"Data\.Time(\.\w+)*", "clojure": r"java\.time(\.\w+)*|java\.util\.(Date|Calendar)"},
    "xml": {"python": r"xml(\.\w+)*", "go": r"encoding/xml", "d": r"std\.xml", "haskell": r"Text\.XML(\.\w+)*",
            "clojure": r"javax\.xml(\.\w+)*|clojure\.(data\.)?xml|org\.w3c\.dom(\.\w+)*"},
    "ordered": {"cpp": r"<map>|<set>", "rust": r"BTreeMap|BTreeSet", "d": r"std\.container\.rbtree",
                "haskell": r"Data\.(Map|Set|IntMap|IntSet)(\.\w+)*",
                "clojure": r"java\.util\.(TreeMap|TreeSet|concurrent\.ConcurrentSkipList\w+)"},
}
# The facilities each problem's SPEC.md rules out.
PROBLEM_FACILITIES = {
    "regex": ["regex"], "json": ["json"], "jq": ["json"], "jsonschema": ["json", "regex"], "inflate": ["zlib"],
    "gitrepo": ["zlib", "hash"], "webhooks": ["hash", "base64"], "bigint": ["bigint"], "scheme": ["bigint"],
    "minisql": ["sql"], "sqlitefile": ["sql"], "mime": ["email", "base64"], "toml": ["toml"], "sitegen": ["toml"],
    "diff": ["diff"], "rrule": ["date"], "svgraster": ["xml"], "ordered-map": ["ordered"],
}
SOURCE_EXT = {"python": (".py",), "go": (".go",), "d": (".d",), "cpp": (".cpp", ".cc", ".cxx", ".hpp", ".h", ".hh"),
              "rust": (".rs",), "haskell": (".hs",), "clojure": (".clj", ".cljc")}
ALWAYS_FORBIDDEN = re.compile(r"/reference/|/gen_tests\.py\b|/gen_bench\.py\b|/bench(-long)?/|/heldout\b")
SCRATCH_FILE = re.compile(r"\b(scratch/(rep\d+-[a-z]+-[A-Za-z0-9_-]+)/[^\s\"'*;|&]*)")
PROJECT_FILE = re.compile(r"\b(out/(rep\d+)/([a-z]+)/([A-Za-z0-9_-]+)/[^\s\"'*;|&]+)")


def tool_inputs(path):
    """(tool name, input as text) for every tool call in a transcript."""
    for line in open(path):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") != "assistant":
            continue
        for c in (e.get("message") or {}).get("content") or []:
            if isinstance(c, dict) and c.get("type") == "tool_use":
                yield c.get("name"), json.dumps(c.get("input"))


def tool_calls(path):
    """(tool name, input as text, result as text) for every tool call in a transcript."""
    calls, results = [], {}
    for line in open(path):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        for c in (e.get("message") or {}).get("content") or [] if isinstance(e, dict) else []:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use" and e.get("type") == "assistant":
                calls.append((c.get("id"), c.get("name"), json.dumps(c.get("input"))))
            elif c.get("type") == "tool_result":
                r = c.get("content")
                results[c.get("tool_use_id")] = r if isinstance(r, str) else " ".join(
                    x.get("text", "") for x in r or [] if isinstance(x, dict))
    return [(name, text, results.get(tid, "")) for tid, name, text in calls]


PATH_TOKEN = re.compile(r"/[^\s\"';|&<>()]+")
REFUSED = re.compile(r"haven't granted it|denied by your permission|Permission to use \w+ has been denied")


def refused(name, text, result, forbidden):
    """Whether every forbidden path a tool call names was refused: the file tools' permission denial, or
    the OS sandbox's "Operation not permitted" for each such path in a shell command."""
    if name != "Bash":
        return bool(REFUSED.search(result))
    tokens = {t.rstrip("/\\") for t in PATH_TOKEN.findall(text) if any(t.startswith(p) for p in forbidden)}
    # A shell echoes the path as it was typed, with or without a trailing slash.
    return bool(tokens) and all(f"{t}: Operation not permitted" in result or f"{t}/: Operation not permitted" in result
                                for t in tokens)


def injected_files(path):
    for line in open(path):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        a = e.get("attachment") or {}
        if a.get("type") == "instructions":
            for f in a.get("files") or []:
                yield f.get("path")


CLAUDE_TEMP = re.compile(r"/tmp/claude-\d+/(-[A-Za-z0-9-]+)/")


def scan_agent(label, transcripts, forbidden, allowed=(), own_slug=None):
    """Findings for one implementation task (label rep:lang:slug) from its transcripts. Text matching an
    allowed pattern (such as the task's own spilled tool outputs) is not checked. With own_slug (the task's
    transcript directory name), naming another project's directory under Claude Code's temporary directory,
    where sessions keep their background-task outputs, is forbidden."""
    rep, lang, slug = label.split(":")
    findings = []
    for transcript in transcripts:
        for name, text, result in tool_calls(transcript):
            for pattern in allowed:
                text = re.sub(pattern, "<allowed>/", text)
            foreign_temp = own_slug and any(m.group(1) != own_slug for m in CLAUDE_TEMP.finditer(text))
            named = [p for p in forbidden if p in text]
            if named or ALWAYS_FORBIDDEN.search(text) or foreign_temp:
                blocked = named and not ALWAYS_FORBIDDEN.search(text) and not foreign_temp \
                    and refused(name, text, result, named)
                findings.append({"agent": label, "kind": "blocked-attempt" if blocked else "forbidden-path",
                                 "detail": f"{name}: {text[:300]}"})
            for m in PROJECT_FILE.finditer(text):
                if (m.group(2), m.group(3), m.group(4)) != (rep, lang, slug):
                    findings.append({"agent": label, "kind": "other-implementation", "detail": m.group(1)})
            for m in SCRATCH_FILE.finditer(text):
                if m.group(2) != f"{rep}-{lang}-{slug}":
                    findings.append({"agent": label, "kind": "other-implementation", "detail": m.group(1)})
        for p in sorted(set(injected_files(transcript))):
            findings.append({"agent": label, "kind": "environment", "detail": f"instructions injected: {p}"})
    return findings


def scan_transcripts(wfdir, forbidden, allowed=()):
    """Findings for every implementation agent of a workflow run (older runs: agent-*.jsonl with labels in
    agent-*.meta.json)."""
    findings = []
    for meta in sorted(glob.glob(os.path.join(wfdir, "agent-*.meta.json"))):
        label = json.load(open(meta)).get("description", "")
        if len(label.split(":")) == 3:
            findings += scan_agent(label, [meta[:-len(".meta.json")] + ".jsonl"], forbidden, allowed)
    return findings


def session_transcripts(rdir, sid):
    """A session's main transcript and its subagents' transcripts, in a run directory's sessions/."""
    main = os.path.join(rdir, "sessions", sid + ".jsonl")
    subs = sorted(glob.glob(os.path.join(rdir, "sessions", sid, "subagents", "**", "*.jsonl"), recursive=True))
    return ([main] if os.path.isfile(main) else []) + subs


def scan_run(rdir, forbidden, own_project=None, workspaces=None, projects=None, shared=()):
    """Findings for every attempt of a run made by impl_run.py launch (manifest.jsonl plus sessions/).

    With workspaces ({label: workspace path}) and projects (Claude Code's transcript root), a session may name
    its own workspace and its own spilled tool outputs (<projects>/<workspace>/<session>/tool-results/);
    otherwise own_project gives the transcript directory whose tool-results it may name. Every session may name
    the shared paths (read-only toolchain material inside the sandbox, such as the Haskell package store)."""
    findings = []
    for e in (json.loads(line) for line in open(os.path.join(rdir, "manifest.jsonl"))):
        sid = e["session_id"]
        allowed, own_slug = [re.escape(p) + r"(?![\w.-])" for p in shared], None
        if workspaces:
            ws = workspaces[e["label"]]
            own_slug = re.sub(r"[^A-Za-z0-9]", "-", ws)
            own_project = os.path.join(projects, re.sub(r"[^A-Za-z0-9]", "-", ws))
            allowed.append(re.escape(ws) + r"(?![\w.-])")
        if own_project:
            allowed.insert(0, re.escape(os.path.join(own_project, sid, "tool-results")) + "/")
        findings += scan_agent(e["label"], session_transcripts(rdir, sid), forbidden, allowed, own_slug)
    return findings


def scan_any(path, forbidden, allowed=(), own_project=None):
    if os.path.isfile(os.path.join(path, "manifest.jsonl")):
        return scan_run(path, forbidden, own_project)
    return scan_transcripts(path, forbidden, allowed)


# The packages that ship with GHC: a cabal project can depend on these without any download.
GHC_PACKAGES = {
    "Cabal", "Cabal-syntax", "array", "base", "binary", "bytestring", "containers", "deepseq", "directory",
    "exceptions", "file-io", "filepath", "ghc", "ghc-bignum", "ghc-boot", "ghc-boot-th", "ghc-compact",
    "ghc-experimental", "ghc-heap", "ghc-internal", "ghc-platform", "ghc-prim", "ghc-toolchain", "ghci",
    "haddock-api", "haddock-library", "haskeline", "hpc", "integer-gmp", "mtl", "os-string", "parsec", "pretty",
    "process", "rts", "semaphore-compat", "stm", "system-cxx-std-lib", "template-haskell", "template-haskell-lift",
    "template-haskell-quasiquoter", "terminfo", "text", "time", "transformers", "unix", "xhtml"}


# The test frameworks the sandbox provides, which tests (and only tests) may use.
HASKELL_TEST_PACKAGES = {"hspec", "hspec-core", "hspec-discover", "hspec-expectations", "tasty", "tasty-hunit",
                         "tasty-quickcheck", "QuickCheck", "HUnit"}
CLOJURE_TEST_LIBS = {"io.github.cognitect-labs/test-runner", "com.cognitect/test-runner"}
PYTHON_TEST_MODULES = {"pytest", "_pytest"}


def is_python_test_file(rel):
    parts = rel.split(os.sep)
    name = parts[-1]
    return (any(p in ("test", "tests") for p in parts[:-1]) or name.startswith("test_") or name.endswith("_test.py")
            or name == "conftest.py")


def cabal_deps(text):
    """Packages named in a .cabal file's build-depends fields, other than GHC's own, the package's own libraries
    and (in test-suite and benchmark stanzas) the test frameworks the sandbox provides."""
    own = set(re.findall(r"^name\s*:\s*([\w-]+)", text, re.M | re.I))
    own |= set(re.findall(r"^\s*library\s+([\w-]+)", text, re.M | re.I))
    stanzas = [(m.start(), m.group(1).lower()) for m in re.finditer(r"^([A-Za-z][\w-]*)\b", text, re.M)]
    out = []
    for field in re.finditer(r"build-depends\s*:((?:[^\n]*)(?:\n[ \t]+(?![\w-]+\s*:)[^\n]*)*)", text, re.I):
        stanza = max((s for s in stanzas if s[0] < field.start()), default=(0, ""))[1]
        allowed = HASKELL_TEST_PACKAGES if stanza in ("test-suite", "benchmark") else set()
        for item in field.group(1).split(","):
            name = re.match(r"\s*([A-Za-z][\w-]*)", item)
            if name:
                pkg = name.group(1).split(":")[0]
                if pkg not in GHC_PACKAGES and pkg not in own and pkg not in allowed and pkg not in out:
                    out.append(pkg)
    return out


def deps_edn_deps(text):
    """Libraries a deps.edn names under :deps or an alias's :extra-deps, other than Clojure itself."""
    out = []
    for block in re.finditer(r":(?:extra-)?deps\s*\{", text):
        depth, i = 1, block.end()
        while i < len(text) and depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        body = text[block.end():i - 1]
        level = 0
        for m in re.finditer(r"[{}]|([\w.\-]+/[\w.\-]+)", body):
            if m.group(0) in "{}":
                level += 1 if m.group(0) == "{" else -1
            elif level == 0 and m.group(1) != "org.clojure/clojure" and m.group(1) not in CLOJURE_TEST_LIBS \
                    and m.group(1) not in out:
                out.append(m.group(1))
    return out


def cargo_deps(text):
    out, section = [], None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            section = s.strip("[]").strip()
        elif s and not s.startswith("#") and section and re.fullmatch(r"(dev-|build-)?dependencies", section):
            out.append(s.split("=")[0].strip())
    return out


def go_requires(text):
    out, block = [], False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("require ("):
            block = True
        elif block and s == ")":
            block = False
        elif block and s:
            out.append(s.split()[0])
        elif s.startswith("require "):
            out.append(s.split()[1])
    return out


def python_imports(root):
    """{module: first file importing it} for absolute imports in the project's Python files."""
    found = {}
    for path in sorted(glob.glob(os.path.join(root, "**", "*.py"), recursive=True)):
        for line in open(path, errors="replace"):
            m = re.match(r"\s*(?:import\s+([\w.]+(?:\s*,\s*[\w.]+)*)|from\s+([\w.]+)\s+import)", line)
            if not m:
                continue
            names = [n.strip().split(" ")[0] for n in m.group(1).split(",")] if m.group(1) else [m.group(2)]
            for n in names:
                if n and not n.startswith("."):
                    found.setdefault(n.split(".")[0], os.path.relpath(path, root))
    return found


def local_python_modules(root):
    names = set()
    for path in glob.glob(os.path.join(root, "**", "*.py"), recursive=True):
        names.add(os.path.splitext(os.path.basename(path))[0])
        names.update(os.path.relpath(path, root).split(os.sep)[:-1])
    return names


def scan_dependencies(project, lang):
    """Third-party dependencies of one implementation project."""
    deps = []

    def read(rel):
        p = os.path.join(project, rel)
        return open(p, errors="replace").read() if os.path.isfile(p) else ""

    if lang == "rust":
        deps = [f"cargo: {d}" for d in cargo_deps(read("Cargo.toml"))]
    elif lang == "go":
        deps = [f"go.mod: {d}" for d in go_requires(read("go.mod"))]
    elif lang == "d":
        if read("dub.json"):
            deps = [f"dub: {d}" for d in json.loads(read("dub.json")).get("dependencies", {})]
        deps += [f"dub: {m}" for m in re.findall(r'^\s*dependency\s+"([^"]+)"', read("dub.sdl"), re.M)]
    elif lang == "cpp":
        text = "\n".join(open(p, errors="replace").read()
                         for p in glob.glob(os.path.join(project, "**", "CMakeLists.txt"), recursive=True))
        deps = [f"cmake: {m}" for m in sorted(set(re.findall(r"\b(FetchContent_Declare|ExternalProject_Add)\b", text)))]
        deps += [f"cmake: find_package({m})" for m in re.findall(r"find_package\(\s*(\w+)", text)
                 if m not in ("Threads", "GTest")]
    elif lang == "haskell":
        for path in sorted(glob.glob(os.path.join(project, "**", "*.cabal"), recursive=True)):
            if "/dist-newstyle/" not in path:
                deps += [f"cabal: {d}" for d in cabal_deps(open(path, errors="replace").read()) if f"cabal: {d}" not in deps]
    elif lang == "clojure":
        deps = [f"deps.edn: {d}" for d in deps_edn_deps(read("deps.edn"))]
    elif lang == "python":
        local = local_python_modules(project)
        deps = [f"{m} ({f})" for m, f in python_imports(project).items()
                if m not in sys.stdlib_module_names and m not in local and m != "__future__"
                and not (m in PYTHON_TEST_MODULES and is_python_test_file(f))]
    return [{"kind": "dependency", "detail": d} for d in deps]


def scan_banned_facilities_text(lang, text, slug):
    """Names of the standard-library facilities a source file imports that this problem's SPEC.md rules out,
    in order."""
    pattern = "|".join(FACILITIES[c][lang] for c in PROBLEM_FACILITIES.get(slug, []) if lang in FACILITIES[c])
    if not pattern or lang not in IMPORTS:
        return []
    banned = re.compile(rf"(?:{pattern})$")
    names = []
    for m in IMPORTS[lang].finditer(text):
        groups = [g for g in m.groups() if g]
        for n in (x.strip().split(" ")[0] for g in groups for x in g.split(",")):
            if n and banned.match(n) and n not in names:
                names.append(n)
    return names


def scan_banned_facilities(project, lang, slug):
    found = []
    for path in sorted(glob.glob(os.path.join(project, "**", "*"), recursive=True)):
        if os.path.isfile(path) and path.endswith(SOURCE_EXT.get(lang, ())):
            for n in scan_banned_facilities_text(lang, open(path, errors="replace").read(), slug):
                found.append({"kind": "banned-facility", "detail": f"{n} ({os.path.relpath(path, project)})"})
    return found


BUILD_FILES = ("CMakeLists.txt", "*.cmake", "Cargo.toml", ".cargo/config.toml", ".cargo/config", "dub.json",
               "dub.sdl", "build.sh", "run.sh", "go.mod", "Makefile", "pyproject.toml", "*.cabal", "cabal.project",
               "deps.edn")
OPT_FLAGS = re.compile(r"-march=\S+|-mcpu=\S+|-mtune=\S+|-flto\S*|-fprofile-\S+|-ffast-math|-Ofast|"
                       r"target-cpu=\S+|\blto\s*=\s*\S+|codegen-units\s*=\s*\d+|-gcflags\S*|-pgo=\S+|"
                       r"--enable-cross-module-inlining|-fsave-optimization-record|"
                       r"-fllvm|direct-linking=true")


def scan_build_flags(project, lang):
    """Non-default optimisation settings in an implementation's build files: target-specific code generation,
    link-time or profile-guided optimisation, fast-math, or compiler flags beyond the build tool's release
    defaults. GHC's -O2 (or cabal's optimization: 2) counts as Haskell's usual optimised build, as -O3 does
    for a CMake Release build, so it is not reported."""
    found = []
    for pattern in BUILD_FILES:
        for path in sorted(glob.glob(os.path.join(project, "**", pattern), recursive=True)):
            rel = os.path.relpath(path, project)
            if any(f"/{d}/" in f"/{rel}" for d in ("target", "build", "dist-newstyle", ".cpcache")):
                continue
            text = open(path, errors="replace").read()
            for m in OPT_FLAGS.finditer(text):
                found.append({"kind": "build-flags", "detail": f"{m.group(0)} ({rel})"})
    if lang == "go" and glob.glob(os.path.join(project, "**", "default.pgo"), recursive=True):
        found.append({"kind": "build-flags", "detail": "default.pgo (profile-guided optimisation)"})
    return found


def scan_impls(impls):
    findings = []
    for project in sorted(glob.glob(os.path.join(impls, "rep*", "*", "*"))):
        rep, lang, slug = project.split(os.sep)[-3:]
        for f in scan_dependencies(project, lang) + scan_banned_facilities(project, lang, slug) + scan_build_flags(project, lang):
            findings.append({"agent": f"{rep}:{lang}:{slug}", **f})
    return findings


def audit(transcripts, impls, forbidden, allowed=(), own_project=None):
    """Findings for a run's transcripts (a run directory, workflow directory or .tar.gz of either) and its
    implementations."""
    if transcripts.endswith(".tar.gz"):
        with tempfile.TemporaryDirectory() as d:
            with tarfile.open(transcripts) as t:
                t.extractall(d, filter="data")
            (wf,) = [os.path.join(d, n) for n in os.listdir(d)]
            findings = scan_any(wf, forbidden, allowed, own_project)
    else:
        findings = scan_any(transcripts, forbidden, allowed, own_project)
    return findings + scan_impls(impls)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("transcripts")
    ap.add_argument("impls")
    ap.add_argument("--forbidden", nargs="*", default=[], help="absolute paths agents must not name")
    ap.add_argument("--json", help="also write the findings here")
    a = ap.parse_args()
    findings = audit(a.transcripts, a.impls, a.forbidden)
    for f in findings:
        print(f"{f['kind']:20s} {f['agent']:28s} {f['detail'][:160]}")
    print(f"{len(findings)} findings")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(findings, f, indent=1)
    sys.exit(1 if any(f["kind"] in INTEGRITY for f in findings) else 0)


if __name__ == "__main__":
    main()
