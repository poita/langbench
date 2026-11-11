#!/usr/bin/env python3
"""Generate implementations reproducibly: each task is a headless Claude Code session in a sandbox.

    tools/impl_run.py sandbox DIR [--problems a,b] [--langs x,y] [--reps N] [--rep-problems a,b]
        Stage a sandbox at DIR (outside this checkout): the files agents may see (CONVENTIONS.md,
        run_tests.py, each problem's SPEC.md, APPROACH.md and visible tests, read-only), Claude Code settings
        that keep agents out of this checkout and transcripts, and DIR/args.json:
        run-config.json, the overrides, the sandbox root and this machine's toolchains.
    tools/impl_run.py launch DIR [--auth env|subscription]
        Run every task as its own headless Claude Code session in DIR with a clean environment (no CLAUDE.md,
        memory, user settings, plugins or MCP servers), a few at a time (tools/runner.py). Takes hours for a
        full run; rerunning it resumes an interrupted run. Progress goes to DIR/launch.log.
    tools/impl_run.py finish DIR --dest DEST [--stage] [--force]
        Audit the run, rerun every implementation's public tests (and held-out tests where they exist), copy
        the sources into DEST, archive the anonymised transcripts in DEST/transcripts/, and record provenance in
        DEST/run.json, DEST/prompts/, DEST/audit/ and DEST/results/. --stage git-adds DEST. A run whose audit
        has integrity findings is not recorded unless --force is given.

The five large problems also have held-out tests, problems/<slug>/heldout/, which agents never see: finish
scores them separately, recorded as `hidden` in the results.
"""
import argparse
import concurrent.futures
import datetime
import functools
import glob
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import runner  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY_MAGIC = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe",
                b"\x7fELF", b"!<arch>\n", b"MZ")
BUILD_FILES = re.compile(r"\.(o|obj|a|pyc)$")
# Build-output directories by language; a source directory with the same name in another language (a Go
# package called build, say) is kept.
BUILD_DIRS = {
    "cpp": r"build|cmake-build[^/]*|CMakeFiles|obj|\.cache",
    "rust": r"target",
    "go": r"",
    "d": r"\.dub",
    "python": r"__pycache__|[^/]*\.egg-info|build|dist",
    "haskell": r"dist-newstyle|\.stack-work",
    "clojure": r"\.cpcache|target|classes",
}
ANY_BUILD_DIR = r"\.dub|target|build|obj|\.build|__pycache__|[^/]*\.egg-info|dist-newstyle|\.stack-work|\.cpcache"
LANG_IN_PATH = re.compile(r"(?:^|/)rep\d+/(cpp|rust|go|d|python|haskell|clojure)/")
# What agents may see: top-level files, and per problem these files and directories.
SANDBOX_TOP = ("CONVENTIONS.md", "run_tests.py")
SANDBOX_FILES = ("SPEC.md", "APPROACH.md", "verify.py", "spec_examples.json")
SANDBOX_DIRS = ("tests", "corpus", "data")


def is_binary_header(head):
    return any(head.startswith(m) for m in BINARY_MAGIC)


def is_build_output(path, lang=None):
    """Whether a path is a build output: a compiled object file, or a file under one of its language's build
    directories. Without lang, the language comes from a <rep>/<lang>/ part of the path, if any."""
    if BUILD_FILES.search(path):
        return True
    if lang is None:
        m = LANG_IN_PATH.search(path)
        lang = m.group(1) if m else None
    dirs = BUILD_DIRS.get(lang, ANY_BUILD_DIR) if lang else ANY_BUILD_DIR
    return bool(dirs) and re.search(rf"/({dirs})/", path) is not None


def find_impls(out):
    """(rep, lang, slug) for every implementation directory under out that has a run.sh."""
    found = []
    for rep in sorted(os.listdir(out)):
        for lang in sorted(os.listdir(os.path.join(out, rep))) if os.path.isdir(os.path.join(out, rep)) else []:
            ldir = os.path.join(out, rep, lang)
            for slug in sorted(os.listdir(ldir)) if os.path.isdir(ldir) else []:
                if os.path.isfile(os.path.join(ldir, slug, "run.sh")):
                    found.append((rep, lang, slug))
    return found


def main_checkout(root):
    """The main working tree of the repository containing root (a linked worktree resolves to its main tree)."""
    try:
        common = subprocess.run(["git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, check=True).stdout.strip()
        return os.path.dirname(common)
    except (OSError, subprocess.CalledProcessError):
        return root




def prompt_options(prompt):
    """The workflow options an older run's task prompt was generated with, read back from its text."""
    m = re.search(r"--compiler=(\S+?)[,\s]", prompt)
    names = {"D": "d", "C++": "cpp", "Rust": "rust", "Go": "go", "Python": "python"}
    notes = sorted({names[n] for n in re.findall(r"^[ \t]*(D|C\+\+|Rust|Go|Python) notes: ", prompt, re.M)})
    return {"approach": "Required approach: read" in prompt,
            "efficiency": "It is important that the implementation is efficient." in prompt,
            "notes": notes,
            "dc": m.group(1) if m else None}


def add_run(record, run):
    """Add or update one run in a run.json record, keyed by its run id."""
    for r in record.setdefault("runs", []):
        if r.get("workflow_run") == run.get("workflow_run"):
            r.update(run)
            return record
    record["runs"].append(run)
    return record


def present_agents(out, agents):
    """The (rep, lang, slug) agents whose implementation directory exists under out."""
    return [a for a in agents if os.path.isdir(os.path.join(out, *a))]


def anonymise(text):
    """Replace the root a prompt was generated for with <root>, and the home directory with ~."""
    m = re.search(r"(?:Problem specification: |specification in )(\S+)/problems/", text)
    if m:
        text = text.replace(m.group(1), "<root>")
    return text.replace(os.path.expanduser("~"), "~")


# --- sandbox -------------------------------------------------------------------------------------------

project_slug = runner.project_slug


def run_text(argv):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        return (p.stdout or p.stderr).strip().splitlines()[0].strip().rstrip(":")
    except (OSError, IndexError, subprocess.SubprocessError):
        return None


def version(argv, pattern):
    text = run_text(argv) or ""
    m = re.search(pattern, text)
    return m.group(1) if m else None


def clojure_version():
    """"Clojure X on Java Y" for the clojure CLI on PATH, from a throwaway directory so no .cpcache is left
    behind; None without the CLI."""
    if not shutil.which("clojure"):
        return None
    with tempfile.TemporaryDirectory() as d:
        try:
            p = subprocess.run(["clojure", "-M", "-e", '(print (clojure-version) (System/getProperty "java.version"))'],
                               cwd=d, capture_output=True, text=True, timeout=300)
        except (OSError, subprocess.SubprocessError):
            return None
    parts = p.stdout.split()
    return f"Clojure {parts[0]} on Java {parts[1]}" if p.returncode == 0 and len(parts) == 2 else None


# The test frameworks provided offline, and what each is for (named in the prompt by runner.build_line).
# By full commit, so tools.deps checks its local copy instead of fetching tags from GitHub.
CLOJURE_TEST_DEPS = ('{io.github.cognitect-labs/test-runner {:git/sha "dfb30dd6605cb6c0efc275e1df1736f6e90d4d73"} '
                     'org.clojure/test.check {:mvn/version "1.1.1"}}')
HASKELL_TEST_DEPS = ["hspec", "tasty", "tasty-hunit", "tasty-quickcheck", "QuickCheck"]
PYTHON_TEST_PACKAGES = ["pytest"]


def run_checked(argv, what, **kw):
    p = subprocess.run(argv, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        sys.exit(f"could not prepare {what} ({' '.join(argv)}):\n{p.stdout[-2000:]}{p.stderr[-2000:]}")
    return p


def seed_clojure(dest):
    """Download what the clojure CLI, the Cognitect test-runner and test.check need into a fresh Maven repository and gitlibs
    directory under dest. Agents have no network, so each Clojure workspace gets a copy; fresh directories rather
    than ~/.m2 keep any other cached library out of reach."""
    m2, gitlibs = os.path.join(dest, "m2"), os.path.join(dest, "gitlibs")
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "config"))
        with open(os.path.join(d, "config", "deps.edn"), "w") as f:
            f.write("{:mvn/local-repo %s}\n" % json.dumps(m2))
        os.makedirs(os.path.join(d, "project"))
        with open(os.path.join(d, "project", "deps.edn"), "w") as f:
            f.write("{:aliases {:test {:extra-deps %s}}}\n" % CLOJURE_TEST_DEPS)
        env = dict(os.environ, CLJ_CONFIG=os.path.join(d, "config"), CLJ_CACHE=os.path.join(d, "cache"),
                   GITLIBS=gitlibs, GIT_CONFIG_GLOBAL=os.devnull)
        run_checked(["clojure", "-P", "-A:test"], "the Clojure libraries", cwd=os.path.join(d, "project"), env=env)
    return {"m2": m2, "gitlibs": gitlibs}


def apply_hackage_revisions(repo, index_tar):
    """Give each package tarball in repo its latest Hackage revision of the .cabal file, as cabal sees it when
    resolving against Hackage; original bounds are often too tight for the installed GHC."""
    want = {}
    for f in glob.glob(os.path.join(repo, "*.tar.gz")):
        m = re.match(r"(.+)-([\d.]+)\.tar\.gz$", os.path.basename(f))
        want[(m.group(1), m.group(2))] = f
    latest = {}
    with tarfile.open(index_tar) as t:
        for ti in t:
            parts = ti.name.split("/")
            if len(parts) == 3 and parts[2].endswith(".cabal") and (parts[0], parts[1]) in want:
                latest[(parts[0], parts[1])] = t.extractfile(ti).read()
    for (pkg, ver), f in want.items():
        rev = latest.get((pkg, ver))
        if rev is None:
            continue
        out = io.BytesIO()
        with tarfile.open(f) as src, tarfile.open(fileobj=out, mode="w:gz") as dst:
            for ti in src:
                data = src.extractfile(ti).read() if ti.isfile() else None
                if ti.name == f"{pkg}-{ver}/{pkg}.cabal":
                    data, ti.size = rev, len(rev)
                dst.addfile(ti, io.BytesIO(data) if data is not None else None)
        with open(f, "wb") as fh:
            fh.write(out.getvalue())


def seed_haskell(dest):
    """Download the Haskell test frameworks and their dependencies into a local package repository under dest
    and build them into a cabal store there, which Haskell workspaces read but never write. Building from the
    local repository itself keeps the store's package hashes identical to what agents' projects resolve."""
    repo, store = os.path.join(dest, "hackage"), os.path.join(dest, "store")
    os.makedirs(repo, exist_ok=True)
    env = dict(os.environ, **({"C_INCLUDE_PATH": ffi_include()} if ffi_include() else {}))
    with tempfile.TemporaryDirectory() as d:
        project = os.path.join(d, "project")
        os.makedirs(project)
        with open(os.path.join(project, "seed.cabal"), "w") as f:
            f.write("cabal-version: 3.0\nname: seed\nversion: 0\nlibrary\n  build-depends: base, "
                    + ", ".join(HASKELL_TEST_DEPS) + "\n  default-language: GHC2021\n")
        online = dict(env, CABAL_DIR=os.path.join(d, "online"))
        run_checked(["cabal", "update"], "the Hackage index", env=online)
        run_checked(["cabal", "build", "--dependencies-only", "--only-download"], "the Haskell test frameworks",
                    cwd=project, env=online)
        for f in glob.glob(os.path.join(d, "online", "packages", "hackage.haskell.org", "*", "*", "*.tar.gz")):
            shutil.copy(f, repo)
        apply_hackage_revisions(repo, os.path.join(d, "online", "packages", "hackage.haskell.org", "01-index.tar"))
        local = os.path.join(d, "local")
        write_cabal_config(local, repo, store)
        shutil.rmtree(os.path.join(project, "dist-newstyle"), ignore_errors=True)
        run_checked(["cabal", "build", "--dependencies-only"], "the Haskell test frameworks", cwd=project,
                    env=dict(env, CABAL_DIR=local))
    for cache in glob.glob(os.path.join(repo, "*.cache")):
        os.remove(cache)
    return {"repo": repo, "store": store}


def seed_python(dest):
    """Download pytest and its dependencies as wheels, for each Python workspace's own environment."""
    wheels = os.path.join(dest, "wheels")
    run_checked([sys.executable, "-m", "pip", "download", "-q", "-d", wheels, *PYTHON_TEST_PACKAGES], "pytest")
    return {"wheels": wheels}


def seed_test_tools(box, langs):
    """Everything the languages in langs need offline, prepared once per sandbox in box/tools/."""
    seeders = {"clojure": seed_clojure, "haskell": seed_haskell, "python": seed_python}
    return {lang: seeders[lang](os.path.join(box, "tools", lang)) for lang in langs if lang in seeders}


def write_cabal_config(cabal_dir, repo=None, store=None):
    """A cabal configuration without network: only the local repository (or none) and, if given, a store."""
    os.makedirs(cabal_dir, exist_ok=True)
    with open(os.path.join(cabal_dir, "config"), "w") as f:
        if repo:
            f.write(f"repository local\n  url: file+noindex://{repo}\nactive-repositories: local\n")
        else:
            f.write("active-repositories: :none\n")
        if store:
            f.write(f"store-dir: {store}\n")


@functools.lru_cache(maxsize=None)
def gnu_tools_dir():
    """Homebrew's GNU sed under its plain name, or None. Agents write GNU sed commands (sed -i without a
    suffix); macOS's BSD sed rejects them, which costs a failed call each time, in every language."""
    path = "/opt/homebrew/opt/gnu-sed/libexec/gnubin"
    return path if os.path.isfile(os.path.join(path, "sed")) else None


@functools.lru_cache(maxsize=None)
def macos_version():
    """The macOS major version, or None elsewhere."""
    v = run_text(["sw_vers", "-productVersion"]) if sys.platform == "darwin" else None
    return v.split(".")[0] if v else None


@functools.lru_cache(maxsize=None)
def ffi_include():
    """The directory holding ffi.h on macOS, which GHC's runtime headers include but Homebrew's GHC doesn't add
    to the C compiler's search path; None elsewhere."""
    sdk = run_text(["xcrun", "--show-sdk-path"]) if sys.platform == "darwin" else None
    path = os.path.join(sdk, "usr", "include", "ffi") if sdk else None
    return path if path and os.path.isfile(os.path.join(path, "ffi.h")) else None


@functools.lru_cache(maxsize=None)
def java_home():
    """The JDK the clojure CLI runs on, or None without the CLI. Agents' sessions and the clean rebuilds both
    get it as JAVA_HOME, so a project that calls java itself gets the same JDK in both (on macOS /usr/bin/java
    would otherwise pick its own default, which may be another version, or unreadable inside the sandbox)."""
    if not shutil.which("clojure"):
        return None
    with tempfile.TemporaryDirectory() as d:
        try:
            p = subprocess.run(["clojure", "-M", "-e", '(print (System/getProperty "java.home"))'], cwd=d,
                               capture_output=True, text=True, timeout=300)
        except (OSError, subprocess.SubprocessError):
            return None
    return p.stdout.strip() if p.returncode == 0 and p.stdout.strip() else None


def tool_env(ws):
    """The environment a workspace's builds and tests run with, in its session and in finish's clean rebuild:
    where cabal and the clojure CLI keep their configuration and caches, the JDK that java means, no git
    configuration from the home directory (the sandbox hides it, and git would fail), the headers GHC needs,
    and the workspace's own Python environment, if it has one."""
    cache = os.path.join(ws, ".cache")
    env = {"CABAL_DIR": os.path.join(cache, "cabal"), "CLJ_CONFIG": os.path.join(cache, "clj-config"),
           "CLJ_CACHE": os.path.join(cache, "clj"), "GITLIBS": os.path.join(cache, "gitlibs"),
           "GIT_CONFIG_GLOBAL": os.devnull}
    if java_home():
        env["JAVA_HOME"] = java_home()
    if ffi_include():
        env["C_INCLUDE_PATH"] = ffi_include()
    if macos_version():
        # Linkers otherwise warn on every build that objects target a different macOS version (LDC's default).
        env["MACOSX_DEPLOYMENT_TARGET"] = macos_version() + ".0"
    venv = os.path.join(cache, "venv", "bin")
    first = [d for d in (gnu_tools_dir(), venv if os.path.isdir(venv) else None) if d]
    if first:
        env["PATH"] = os.pathsep.join(first + [os.environ.get("PATH", "")])
    return env


def offline_tool_config(ws, lang=None, seeds=None):
    """Toolchain configuration inside a workspace for a session without network. cabal sees only the local
    package repository of Haskell test frameworks (and their prebuilt store) besides GHC's own packages; the
    clojure CLI gets its own Maven repository and gitlibs; Python gets its own environment with pytest."""
    cache, seeds = os.path.join(ws, ".cache"), seeds or {}
    hs = seeds.get("haskell") if lang == "haskell" else None
    if hs:
        shutil.copytree(hs["repo"], os.path.join(cache, "hackage"), dirs_exist_ok=True)
        write_cabal_config(os.path.join(cache, "cabal"), os.path.join(cache, "hackage"), hs["store"])
    else:
        write_cabal_config(os.path.join(cache, "cabal"))
    os.makedirs(os.path.join(cache, "clj-config"), exist_ok=True)
    with open(os.path.join(cache, "clj-config", "deps.edn"), "w") as f:
        f.write("{:mvn/local-repo %s}\n" % json.dumps(os.path.join(cache, "m2")))
    clj = seeds.get("clojure") if lang == "clojure" else None
    if clj:
        shutil.copytree(clj["m2"], os.path.join(cache, "m2"), dirs_exist_ok=True)
        shutil.copytree(clj["gitlibs"], os.path.join(cache, "gitlibs"), dirs_exist_ok=True,
                        ignore=lambda d, names: [n for n in names if n.endswith(".ipc")])
    py = seeds.get("python") if lang == "python" else None
    if py:
        venv = os.path.join(cache, "venv")
        run_checked([sys.executable, "-m", "venv", venv], "a Python environment")
        run_checked([os.path.join(venv, "bin", "python"), "-m", "pip", "install", "-q", "--no-index", "--find-links",
                     py["wheels"], *PYTHON_TEST_PACKAGES], "pytest")


def gtest_version(prefixes=("/opt/homebrew", "/usr/local", "/usr")):
    """The version of the first GoogleTest CMake package found under prefixes, or None."""
    for prefix in prefixes:
        path = os.path.join(prefix, "lib", "cmake", "GTest", "GTestConfigVersion.cmake")
        if os.path.isfile(path):
            m = re.search(r'set\(PACKAGE_VERSION "([^"]+)"\)', open(path).read())
            if m:
                return m.group(1)
    return None


def detect_toolchains(dc="ldc2"):
    """{lang: description} of the installed toolchains, for the prompt and the run record."""
    cxx = run_text(["c++", "--version"]) or ""
    cxx_name = "Apple clang" if cxx.startswith("Apple clang") else "clang" if "clang" in cxx else "GCC"
    cxx_ver = (re.search(r"version (\d+[\d.]*)", cxx) or re.search(r"(\d+\.\d+[\d.]*)", cxx) or [None, None])[1]
    parts = {
        "cpp": [f"{cxx_name} {cxx_ver}" if cxx_ver else None,
                (lambda v: f"CMake {v}" if v else None)(version(["cmake", "--version"], r"version (\S+)")),
                (lambda v: f"GoogleTest {v}" if v else None)(gtest_version())],
        "rust": [(lambda v: f"Rust {v} (rustc and cargo)" if v else None)(version(["rustc", "--version"], r"rustc (\S+)"))],
        "go": [(lambda v: f"Go {v}" if v else None)(version(["go", "version"], r"go(\d[\d.]*)"))],
        "d": [(lambda v: f"LDC {v}" if v else None)(version([dc, "--version"], r"\((\d[\d.]*)\)"))
              if dc.endswith("ldc2") else (lambda v: f"DMD {v}" if v else None)(version([dc, "--version"], r"v(\d[\d.]*)")),
              (lambda v: f"dub {v}" if v else None)(version(["dub", "--version"], r"version (\d[\d.]*)"))],
        "python": [(lambda v: f"Python {v}" if v else None)(version(["python3", "--version"], r"Python (\S+)"))],
        "haskell": [(lambda v: f"GHC {v}" if v else None)(version(["ghc", "--numeric-version"], r"(\d[\d.]*)")),
                    (lambda v: f"cabal {v}" if v else None)(version(["cabal", "--numeric-version"], r"(\d[\d.]*)"))],
        "clojure": [clojure_version()],
    }
    def listed(ps):
        ps = [p for p in ps if p]
        return ", ".join(ps[:-1]) + " and " + ps[-1] if len(ps) > 1 else "".join(ps)
    return {lang: listed(ps) for lang, ps in parts.items()}


def read_denials(home, box, repo, main=None):
    """The directories shell commands may not read: the home directory and anything else agents must not see
    that lies outside it, without listing paths already covered (agents see this list, so it names as little
    as possible)."""
    kept = []
    for p in [home, box, main or repo, repo]:
        if p and not any(p == q or p.startswith(q.rstrip("/") + "/") for q in kept):
            kept.append(p)
    return kept


def toolchain_roots(home, dc="ldc2"):
    """Installation directories of the toolchains that live under the home directory, which shell commands
    must still be able to read."""
    roots = set()
    for tool in ("c++", "cmake", "rustc", "cargo", "go", dc, "dub", "python3", "ghc", "cabal", "clojure", "java"):
        path = shutil.which(tool)
        if path:
            real = os.path.realpath(path)
            if real.startswith(home + "/"):
                roots.add(os.path.dirname(os.path.dirname(real)))
    for argv in (["go", "env", "GOROOT"], ["python3", "-c", "import sys; print(sys.base_prefix)"],
                 ["rustc", "--print", "sysroot"], ["ghc", "--print-libdir"]):
        out = run_text(argv)
        if out and os.path.realpath(out).startswith(home + "/"):
            roots.add(os.path.realpath(out))
    # Go reads its own configuration (environment and telemetry settings) from beside GOENV on every command.
    goenv = run_text(["go", "env", "GOENV"])
    if goenv and os.path.isdir(os.path.dirname(goenv)) and os.path.realpath(goenv).startswith(home + "/"):
        roots.add(os.path.dirname(os.path.realpath(goenv)))
    return sorted(r for r in roots if not any(r != o and r.startswith(o + "/") for o in roots))


def sandbox_settings(ws, deny_dirs, allow_dirs):
    """Claude Code project settings for one task's workspace.

    Shell commands run in the OS sandbox, which fails closed and has no escape, may read
    nothing under deny_dirs except allow_dirs, may write only in the workspace and /tmp, and have no network.
    Claude Code describes the sandbox's rules to the agent, so they name no repository, test or project paths.
    Toolchain caches live inside the workspace."""
    cache = os.path.join(ws, ".cache")
    return {
        "sandbox": {"enabled": True, "failIfUnavailable": True, "allowUnsandboxedCommands": False,
                    "filesystem": {"denyRead": list(deny_dirs), "allowRead": list(allow_dirs),
                                   "allowWrite": ["/tmp", "/private/tmp"]},
                    "network": {"allowedDomains": []}},
        "env": {"BASH_DEFAULT_TIMEOUT_MS": "600000", "BASH_MAX_TIMEOUT_MS": "1200000",
                "GOCACHE": os.path.join(cache, "go-build"), "GOMODCACHE": os.path.join(cache, "go-mod"),
                "GOPATH": os.path.join(cache, "gopath"), "GOTOOLCHAIN": "local", "GOTELEMETRY": "off",
                "CARGO_HOME": os.path.join(cache, "cargo"), "DUB_HOME": os.path.join(cache, "dub"),
                **tool_env(ws),
                "XDG_CACHE_HOME": cache, **runner.CLEAN_ENV},
    }


def copy_tree(src, dst):
    if os.path.isdir(src):
        shutil.copytree(src, dst)
    elif os.path.isfile(src):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)


def link_tree(src, dst):
    """Hard-link a file or directory tree (copying where linking fails), returning the files placed."""
    placed = []
    pairs = [(src, dst)] if os.path.isfile(src) else [
        (os.path.join(dp, fn), os.path.join(dst, os.path.relpath(os.path.join(dp, fn), src)))
        for dp, _, fns in os.walk(src) for fn in fns] if os.path.isdir(src) else []
    for s, d in pairs:
        os.makedirs(os.path.dirname(d), exist_ok=True)
        try:
            os.link(s, d)
        except OSError:
            shutil.copy2(s, d)
        placed.append(d)
    return placed


def harness_files(box):
    """Sandbox-relative paths of the master copy's files agents must not change: problems/, run_tests.py,
    CONVENTIONS.md."""
    files = [rel for rel in ("run_tests.py", "CONVENTIONS.md") if os.path.isfile(os.path.join(box, rel))]
    for dp, _, fns in os.walk(os.path.join(box, "problems")):
        files += [os.path.relpath(os.path.join(dp, fn), box) for fn in fns]
    return sorted(files)


def sha256_file(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def protect_harness(box):
    """Make the master copy's harness files read-only and return their hashes."""
    hashes = {}
    for rel in harness_files(box):
        path = os.path.join(box, rel)
        hashes[rel] = sha256_file(path)
        os.chmod(path, 0o444)
    return hashes


def changed_harness_files(box):
    """Harness files, in the master copy or any workspace, that differ from or are missing compared with the
    hashes recorded at staging."""
    recorded = json.load(open(os.path.join(box, "harness.json")))
    master = recorded["master"]
    changed = [rel for rel, h in master.items()
               if not os.path.isfile(os.path.join(box, rel)) or sha256_file(os.path.join(box, rel)) != h]
    for ws, rels in recorded["workspaces"].items():
        for rel in rels:
            path = os.path.join(box, ws, rel)
            if not os.path.isfile(path) or sha256_file(path) != master[rel]:
                changed.append(os.path.join(ws, rel))
    return sorted(changed)


def referenced_problems(box, slug):
    """Other problems whose SPEC.md or APPROACH.md this problem's SPEC.md or APPROACH.md refers to."""
    refs = set()
    for name in ("SPEC.md", "APPROACH.md"):
        path = os.path.join(box, "problems", slug, name)
        if os.path.isfile(path):
            refs.update(re.findall(r"([a-z][a-z-]+)/(?:SPEC|APPROACH)\.md", open(path).read()))
    return sorted(r for r in refs if r != slug and os.path.isdir(os.path.join(box, "problems", r)))


def build_workspace(box, ws, slug):
    """Hard-link one task's view of the harness into its workspace: the top-level files, its problem, and the
    SPEC.md and APPROACH.md of problems its spec refers to. Returns the workspace-relative files placed."""
    placed = []
    for rel in SANDBOX_TOP:
        placed += link_tree(os.path.join(box, rel), os.path.join(ws, rel))
    placed += link_tree(os.path.join(box, "problems", slug), os.path.join(ws, "problems", slug))
    for ref in referenced_problems(box, slug):
        for name in ("SPEC.md", "APPROACH.md"):
            placed += link_tree(os.path.join(box, "problems", ref, name), os.path.join(ws, "problems", ref, name))
    return sorted(os.path.relpath(p, ws) for p in placed)


META_FILES = ("args.json", "sandbox.json", "harness.json", "tasks.json", "launch.json", "launch.log")


def stage_sandbox(repo, box, toolchains, overrides=None, allow_dirty=False, projects=None, home=None,
                  toolchain_roots=None, seeds=None):
    repo, box = os.path.realpath(repo), os.path.realpath(box)
    if box == repo or box.startswith(repo + os.sep):
        sys.exit(f"the sandbox must be outside the checkout ({repo})")
    if os.path.isdir(box) and os.listdir(box):
        sys.exit(f"{box} is not empty")
    commit = run_text(["git", "-C", repo, "rev-parse", "HEAD"])
    status = subprocess.run(["git", "-C", repo, "status", "--porcelain"], capture_output=True, text=True)
    dirty = status.returncode == 0 and bool(status.stdout.strip())
    if dirty and not allow_dirty:
        sys.exit(f"{repo} has uncommitted changes; commit them so the run records the exact harness")
    for rel in SANDBOX_TOP:
        copy_tree(os.path.join(repo, rel), os.path.join(box, rel))
    pdir = os.path.join(repo, "problems")
    for slug in sorted(os.listdir(pdir)):
        if not os.path.isfile(os.path.join(pdir, slug, "SPEC.md")):
            continue
        for rel in SANDBOX_FILES + SANDBOX_DIRS:
            copy_tree(os.path.join(pdir, slug, rel), os.path.join(box, "problems", slug, rel))
    master = protect_harness(box)
    config = json.load(open(os.path.join(repo, "run-config.json")))
    args = {**config, **{k: v for k, v in (overrides or {}).items() if v is not None}, "root": box,
            "toolchains": toolchains}
    projects = projects or os.path.expanduser("~/.claude/projects")
    task_items = runner.items(args, sandbox_problems(box))
    tasks = {it["label"]: os.path.relpath(runner.workspace(box, it["label"]), box) for it in task_items}
    placed = {tasks[it["label"]]: build_workspace(box, os.path.join(box, tasks[it["label"]]), it["slug"])
              for it in task_items}
    home = os.path.realpath(home or os.path.expanduser("~"))
    roots = toolchain_roots if toolchain_roots is not None else globals()["toolchain_roots"](home, args.get("dc", "ldc2"))
    deny = read_denials(home, box, repo, main_checkout(repo))
    if seeds is None:
        seeds = seed_test_tools(box, args["langs"])
    for label, rel in tasks.items():
        ws = os.path.join(box, rel)
        lang = label.split(":")[1]
        offline_tool_config(ws, lang, seeds)
        own_transcripts = runner.transcript_dir(ws, projects)
        os.makedirs(own_transcripts, exist_ok=True)
        os.makedirs(os.path.join(ws, ".claude"), exist_ok=True)
        with open(os.path.join(ws, ".claude", "settings.json"), "w") as f:
            # A Haskell workspace reads the prebuilt store of test frameworks, which lives in the sandbox.
            shared = [seeds["haskell"]["store"]] if lang == "haskell" and "haskell" in seeds else []
            json.dump(sandbox_settings(ws, deny, [ws, own_transcripts, *roots, *shared]), f, indent=1)
    with open(os.path.join(box, "harness.json"), "w") as f:
        json.dump({"master": master, "workspaces": placed}, f, indent=0)
    with open(os.path.join(box, "tasks.json"), "w") as f:
        json.dump(tasks, f, indent=1)
    with open(os.path.join(box, "args.json"), "w") as f:
        json.dump(args, f, indent=1)
    env = {"harness_commit": commit, "harness_dirty": dirty, "claude_code": run_text(["claude", "--version"]),
           "os": run_text(["uname", "-srm"]), "toolchains": toolchains,
           "staged": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
           "repo": repo, "read_denied": deny, "toolchain_roots": roots}
    with open(os.path.join(box, "sandbox.json"), "w") as f:
        json.dump(env, f, indent=1)
    return args


def sandbox_problems(box):
    pdir = os.path.join(box, "problems")
    return sorted(d for d in os.listdir(pdir) if os.path.isfile(os.path.join(pdir, d, "SPEC.md")))


def launch(a):
    box = os.path.realpath(a.dir)
    if not os.path.isfile(os.path.join(box, "args.json")):
        sys.exit(f"{box} is not a sandbox; make one with `impl_run.py sandbox`")
    args = json.load(open(os.path.join(box, "args.json")))
    lpath = os.path.join(box, "launch.json")
    state = json.load(open(lpath)) if os.path.isfile(lpath) else {
        "run": "run-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S")}
    state["auth"] = a.auth
    with open(lpath, "w") as f:
        json.dump(state, f)
    logf = open(os.path.join(box, "launch.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    complete = runner.run(box, args, state["run"], sandbox_problems(box), auth=a.auth, log=log)
    return 0 if complete else 1


# --- finish --------------------------------------------------------------------------------------------

def import_impls(src, dest, lang=None):
    """Copy the sources under src (repN/lang/slug projects) to dest, leaving out build outputs and binaries."""
    copied = 0
    for dp, dns, fns in os.walk(src):
        dns[:] = [d for d in dns
                  if not is_build_output("/" + os.path.relpath(os.path.join(dp, d), src) + "/", lang)]
        for fn in fns:
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, src)
            if is_build_output("/" + rel, lang) or os.path.islink(full):
                continue
            with open(full, "rb") as f:
                if is_binary_header(f.read(8)):
                    continue
            os.makedirs(os.path.join(dest, os.path.dirname(rel)), exist_ok=True)
            shutil.copy2(full, os.path.join(dest, rel))
            copied += 1
    return copied


ACCOUNT_KEYS = {"accountUuid", "organizationUuid", "userEmail", "email", "emailAddress", "organizationName",
                "orgName", "accountName"}


def redact_accounts(text):
    """Remove account details from a JSON-lines transcript: session-owner and credential_org entries are
    dropped, and account, organisation and email fields elsewhere are replaced."""
    def clean(x):
        if isinstance(x, dict):
            return {k: "<redacted>" if k in ACCOUNT_KEYS else clean(v) for k, v in x.items()}
        if isinstance(x, list):
            return [clean(v) for v in x]
        return x

    out = []
    for line in text.splitlines(keepends=True):
        try:
            d = json.loads(line)
        except ValueError:
            out.append(line)
            continue
        if not isinstance(d, dict):
            out.append(line)
            continue
        if d.get("type") == "session-owner" or (d.get("attachment") or {}).get("type") == "credential_org":
            continue
        out.append(json.dumps(clean(d)) + "\n")
    return "".join(out)


def archive_transcripts(wf, tar, sandbox, home=None, redact=()):
    """Write a run directory (manifest, prompts, session transcripts) to a .tar.gz with the sandbox path, home
    directory and any redact strings replaced."""
    home = home or os.path.expanduser("~")
    name = os.path.basename(wf.rstrip("/"))
    os.makedirs(os.path.dirname(os.path.abspath(tar)), exist_ok=True)
    with tarfile.open(tar, "w:gz") as t:
        d = tarfile.TarInfo(name)
        d.type, d.mode = tarfile.DIRTYPE, 0o755
        t.addfile(d)
        for dp, dns, fns in os.walk(wf):
            dns.sort()
            for fn in sorted(fns):
                path = os.path.join(dp, fn)
                text = open(path, errors="replace").read()
                if path.endswith(".jsonl"):
                    text = redact_accounts(text)
                text = text.replace(sandbox, "<root>").replace(home, "~")
                # Claude Code names transcript directories after the working directory, with / as -.
                text = text.replace(project_slug(sandbox), "<root>").replace(project_slug(home) + "-", "~/")
                for s in redact:
                    text = text.replace(s, "<redacted>")
                data = text.encode()
                info = tarfile.TarInfo(f"{name}/{os.path.relpath(path, wf)}")
                info.size, info.mode = len(data), 0o644
                t.addfile(info, io.BytesIO(data))


def latest_attempts(manifest):
    """The last attempt of every task, in manifest order."""
    last = {}
    for e in (json.loads(line) for line in open(manifest)):
        last[e["label"]] = e
    return list(last.values())


def task_workspaces(box):
    """{label: absolute workspace path} from the sandbox's tasks.json."""
    return {label: os.path.join(box, rel) for label, rel in json.load(open(os.path.join(box, "tasks.json"))).items()}


def collect_sessions(box, rdir, projects=None):
    """Copy every attempt's session transcript (and its subagent transcripts and spilled outputs) from its
    workspace's transcript directory into rdir/sessions/."""
    projects = projects or os.path.expanduser("~/.claude/projects")
    ws = task_workspaces(box)
    dst = os.path.join(rdir, "sessions")
    os.makedirs(dst, exist_ok=True)
    for e in (json.loads(line) for line in open(os.path.join(rdir, "manifest.jsonl"))):
        sid = e["session_id"]
        src = os.path.join(projects, project_slug(ws[e["label"]]))
        if os.path.isfile(os.path.join(src, sid + ".jsonl")):
            shutil.copy2(os.path.join(src, sid + ".jsonl"), os.path.join(dst, sid + ".jsonl"))
        if os.path.isdir(os.path.join(src, sid)):
            shutil.copytree(os.path.join(src, sid), os.path.join(dst, sid), dirs_exist_ok=True)


BUILD_TIMEOUT = 3600


def verify_task(ws, slug, scratch, problems, lang=None):
    """Build a clean copy of a task's project (its sources only, as `finish` publishes them) in scratch, then
    run the public tests (and the held-out tests in problems/<slug>/heldout, where the problem has them) on that
    build, from the task's
    workspace. A project whose build.sh fails from clean fails, whatever the agent's own build did."""
    src, copy = os.path.join(ws, slug), os.path.join(scratch, slug)
    shutil.rmtree(copy, ignore_errors=True)
    res = {"clean_build": False}
    if not os.path.isfile(os.path.join(src, "run.sh")):
        return {**res, "public": "no run.sh", "public_pass": False}
    import_impls(src, copy, lang)
    try:
        b = subprocess.run(["bash", os.path.join(copy, "build.sh")], cwd=copy, capture_output=True, text=True,
                           timeout=BUILD_TIMEOUT, env={**os.environ, **tool_env(ws)})
        res["clean_build"] = b.returncode == 0
        tail = (b.stdout + b.stderr).strip().splitlines()[-3:]
    except subprocess.TimeoutExpired:
        tail = ["build timed out"]
    runs = [("public", [])]
    heldout = os.path.join(problems, slug, "heldout")
    if os.path.isdir(heldout):
        runs.append(("hidden", ["--tests-dir", heldout]))
    for kind, extra in runs:
        if not res["clean_build"]:
            res[kind], res[kind + "_pass"] = "clean build failed: " + " | ".join(tail), False
            continue
        p = subprocess.run([sys.executable, "run_tests.py", slug, *extra, "--", os.path.join(copy, "run.sh")],
                           cwd=ws, capture_output=True, text=True, env={**os.environ, **tool_env(ws)})
        res[kind] = (p.stdout.strip().splitlines() or ["no output"])[-1]
        res[kind + "_pass"] = p.returncode == 0
    return res


def verify(box, args, entries, problems, workers=4):
    """Verify every completed task from a clean build (verify_task), a few at a time.
    {label: {"clean_build": bool, "public": line, "public_pass": bool, ...}}."""
    ws = task_workspaces(box)

    def one(e):
        w = ws[e["label"]]
        return e["label"], verify_task(w, e["slug"], os.path.join(box, "verify", os.path.basename(w)), problems,
                                       e["lang"])

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        return dict(pool.map(one, [e for e in entries if not e["infra_error"]]))


def record_provenance(dest, rdir, box, run_id, entries, verified):
    """Write DEST/run.json (options, environment, models, tasks, prompt hashes, results) and one prompt per
    language to DEST/prompts/."""
    args = json.load(open(os.path.join(box, "args.json")))
    env = json.load(open(os.path.join(box, "sandbox.json")))
    launch_state = json.load(open(os.path.join(box, "launch.json")))
    options = {k: v for k, v in args.items() if k not in ("root", "toolchains")}
    pdir = os.path.join(rdir, "prompts")
    prompts = {f[:-4]: open(os.path.join(pdir, f)).read() for f in sorted(os.listdir(pdir))}
    all_attempts = [json.loads(line) for line in open(os.path.join(rdir, "manifest.jsonl"))]
    run_info = {"workflow_run": run_id, "runner": "impl_run.py launch (one headless Claude Code session per task)",
                "started": min(e["started"] for e in all_attempts), "ended": max(e["ended"] for e in all_attempts),
                "recorded": datetime.date.today().isoformat(),
                "harness_commit": env.get("harness_commit"), "harness_dirty": env.get("harness_dirty"),
                "claude_code": env.get("claude_code"), "os": env.get("os"), "toolchains": env.get("toolchains"),
                "sandbox": True, "auth": launch_state.get("auth"), "models": [args.get("model")],
                "agents": len([e for e in entries if not e["infra_error"]]),
                "infra_errors": sum(e["infra_error"] for e in all_attempts),
                "unfinished": sorted(e["label"] for e in entries if e["infra_error"]),
                "public_tests_pass": sum(v.get("public_pass", False) for v in verified.values()),
                "options": options,
                "prompt_sha256": {k: hashlib.sha256(v.encode()).hexdigest() for k, v in prompts.items()},
                "transcripts": f"transcripts/{run_id}.tar.gz", "audit": f"audit/{run_id}.json",
                "results": f"results/{run_id}.json",
                "implementations": sorted(e["label"].replace(":", "/") for e in entries if not e["infra_error"])}
    path = os.path.join(dest, "run.json")
    record = json.load(open(path)) if os.path.exists(path) else {}
    add_run(record, run_info)
    with open(path, "w") as f:
        json.dump(record, f, indent=1)
        f.write("\n")
    os.makedirs(os.path.join(dest, "prompts"), exist_ok=True)
    seen = set()
    for name, text in prompts.items():
        lang = name.split("-")[1]
        if lang not in seen:
            seen.add(lang)
            with open(os.path.join(dest, "prompts", f"{run_id}-{lang}.txt"), "w") as f:
                f.write(anonymise(text))
    print(f"recorded {run_info['agents']} tasks of {run_id} in {path}")


def anonymise_findings(findings, box, home=None):
    """Audit findings with the sandbox path written as <root> and the home directory as ~, for publishing."""
    home = home or os.path.expanduser("~")
    return [{**f, "detail": f.get("detail", "").replace(box, "<root>").replace(home, "~")} for f in findings]


def finish(a):
    box = os.path.realpath(a.dir)
    dest = os.path.abspath(a.dest)
    args = json.load(open(os.path.join(box, "args.json")))
    env = json.load(open(os.path.join(box, "sandbox.json")))
    run_id = a.run or json.load(open(os.path.join(box, "launch.json")))["run"]
    rdir = os.path.join(box, "runs", run_id)
    entries = latest_attempts(os.path.join(rdir, "manifest.jsonl"))
    print(f"run {run_id}: {len(entries)} tasks")
    collect_sessions(box, rdir)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import audit
    projects = os.path.expanduser("~/.claude/projects")
    shared = [p for p in [os.path.join(box, "tools", "haskell", "store")] if os.path.isdir(p)]
    findings = audit.scan_run(rdir, [env["repo"], projects, box], workspaces=task_workspaces(box),
                              projects=projects, shared=shared)
    findings += [{"agent": "-", "kind": "harness-modified", "detail": rel} for rel in changed_harness_files(box)]
    for x in findings:
        print(f"audit   {x['kind']:20s} {x['agent']:28s} {x['detail'][:120]}")
    print(f"audit: {len(findings)} findings")
    if any(x["kind"] in audit.INTEGRITY for x in findings) and not a.force:
        print("not recording a run with integrity findings; inspect them, then rerun with --force to record anyway")
        return 1
    verified = verify(box, args, entries, os.path.join(ROOT, "problems"))
    with open(os.path.join(rdir, "results.json"), "w") as f:
        json.dump(verified, f, indent=1)
    for label, v in sorted(verified.items()):
        if not v.get("public_pass") or v.get("hidden_pass") is False:
            print(f"verify  {label}: {v.get('public')}" + (f"; held-out {v['hidden']}" if "hidden" in v else ""))
    ws = task_workspaces(box)
    n = sum(import_impls(os.path.join(ws[e["label"]], e["slug"]), os.path.join(dest, e["rep"], e["lang"], e["slug"]),
                         e["lang"])
            for e in entries if not e["infra_error"])
    print(f"copied {n} source files to {dest}")
    violations = audit.scan_impls(dest)
    for x in violations:
        print(f"audit   {x['kind']:20s} {x['agent']:28s} {x['detail'][:120]}")
    findings += violations
    for sub, data in (("audit", anonymise_findings(findings, box)), ("results", verified)):
        os.makedirs(os.path.join(dest, sub), exist_ok=True)
        with open(os.path.join(dest, sub, f"{run_id}.json"), "w") as f:
            json.dump(data, f, indent=1)
    email = run_text(["git", "config", "user.email"])
    tar = os.path.join(dest, "transcripts", f"{run_id}.tar.gz")
    archive_transcripts(rdir, tar, box, redact=[email] if email else [])
    print(f"archived transcripts in {tar}")
    record_provenance(dest, rdir, box, run_id, entries, verified)
    if a.stage:
        stage(dest)
    return 0


def stage(out):
    """git add the sources under out, leaving out build directories and compiled binaries."""
    subprocess.run(["git", "-C", ROOT, "add", "-f", out], check=True)
    # Added or modified paths only: staged deletions have no file to inspect.
    staged = subprocess.run(["git", "-C", ROOT, "diff", "--cached", "--name-only", "--diff-filter=AM", "--", out],
                            capture_output=True, text=True, check=True).stdout.split()
    drop = []
    for path in staged:
        full = os.path.join(ROOT, path)
        if is_build_output(path):
            drop.append(path)
            continue
        with open(full, "rb") as f:
            if is_binary_header(f.read(8)):
                drop.append(path)
    for i in range(0, len(drop), 200):
        subprocess.run(["git", "-C", ROOT, "rm", "-q", "--cached", "--"] + drop[i:i + 200], check=True)
    print(f"staged {len(staged) - len(drop)} source files under {out}; left out {len(drop)} build outputs")


def sandbox(a):
    split = lambda s: s.split(",") if s else None
    over = {"problems": split(a.problems), "langs": split(a.langs), "reps": a.reps, "repProblems": split(a.rep_problems)}
    config = json.load(open(os.path.join(ROOT, "run-config.json")))
    args = stage_sandbox(ROOT, a.dir, detect_toolchains(config.get("dc", "ldc2")), over,
                         allow_dirty=a.allow_dirty)
    print(json.dumps(args, indent=1))
    print(f"sandbox ready; run `tools/impl_run.py launch {a.dir}`")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sandbox")
    s.add_argument("dir")
    s.add_argument("--problems")
    s.add_argument("--langs")
    s.add_argument("--reps", type=int)
    s.add_argument("--rep-problems")
    s.add_argument("--allow-dirty", action="store_true", help="stage from a checkout with uncommitted changes")
    s.set_defaults(fn=sandbox)
    l = sub.add_parser("launch")
    l.add_argument("dir")
    l.add_argument("--auth", choices=["env", "subscription"], default="env",
                   help="env: the environment's credentials (ANTHROPIC_API_KEY if set); subscription: your Claude "
                        "Code login")
    l.set_defaults(fn=launch)
    f = sub.add_parser("finish")
    f.add_argument("dir", help="the sandbox")
    f.add_argument("--dest", required=True, help="where the implementations go, e.g. implementations")
    f.add_argument("--run", help="run id; default the sandbox's run")
    f.add_argument("--stage", action="store_true", help="git add the new sources without build outputs")
    f.add_argument("--force", action="store_true", help="record the run even if the audit has integrity findings")
    f.set_defaults(fn=finish)
    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    main()
