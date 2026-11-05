#!/usr/bin/env python3
"""Builds problems/gitrepo/tests/ from the vendored corpus.

Each case copies one repository out of corpus/, writes a commands.txt beside
it, runs reference/main.py to produce the expected output tree, and then
checks every answer against the git CLI. Any disagreement aborts.

The oracle spellings are chosen so that git answers exactly the question the
spec asks:

* `rev-parse <rev>` is checked with `git rev-parse --verify <rev>^{object}`.
  The `^{object}` suffix leaves the result unchanged but forces git to look
  the object up, which plain `git rev-parse` skips for a full 40-hex name.
* `ls-tree <rev> <path>` is checked with `git ls-tree <rev>:<path>`, whose
  output is the entries of that tree with bare names.
* `ls-tree` paths are checked against the spec's `<path>` grammar first; see
  valid_tree_path below.
* a command holding an empty token (from a double or trailing space) is
  invalid by the spec's tokenisation rule and is not passed to git at all:
  git reads `<rev>:` as the root tree, which the spec does not.
* `diff` is checked with `--no-renames`, because the spec has no rename or
  copy detection, and `--abbrev=40` so hashes are not shortened.
* `cat-file` is checked with `git cat-file -t` plus `git cat-file <type>`.
  The one exception is the deliberately damaged object in synth-corrupt,
  whose hash does not match its file name: `git cat-file` does not verify
  loose object hashes, but `git fsck` reports it, so `error` is the answer
  the spec requires and gen_tests confirms it with `git fsck`.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
TESTS = os.path.join(HERE, "tests")
REFERENCE = os.path.join(HERE, "reference", "main.py")


def git(gitdir, *args):
    return subprocess.run(["git", "--git-dir", gitdir] + list(args),
                          capture_output=True)


def rp(gitdir, rev):
    p = git(gitdir, "rev-parse", "--verify", rev)
    if p.returncode != 0:
        raise SystemExit("cannot resolve %s in %s" % (rev, gitdir))
    return p.stdout.decode().strip()


def tags(gitdir):
    return sorted(git(gitdir, "tag").stdout.decode().split())


def blob_at(gitdir, rev, path):
    return rp(gitdir, "%s:%s" % (rev, path))


# ------------------------------------------------------------------ the cases

def case_empty(g):
    return ["count-objects", "rev-parse HEAD", "rev-parse refs/heads/main",
            "log HEAD", "ls-tree HEAD", "diff HEAD HEAD",
            "cat-file 0123456789abcdef0123456789abcdef01234567",
            # malformed command lines
            "count-objects HEAD", "count-objects ", "frobnicate HEAD",
            "CAT-FILE HEAD", "cat-file", "rev-parse HEAD extra",
            "diff HEAD HEAD HEAD"]


def case_detached(g):
    return ["count-objects", "rev-parse HEAD", "rev-parse main",
            "rev-parse refs/heads/main", "rev-parse main^", "log HEAD",
            "log main", "ls-tree HEAD", "ls-tree main",
            "cat-file " + blob_at(g, "main", "only.txt"),
            "diff HEAD main", "diff main HEAD"]


def case_rev_parse_names(g):
    return ["rev-parse " + r for r in [
        "HEAD", "main", "refs/heads/main", "heads/main", "side", "old",
        "origin/main", "refs/remotes/origin/main", "remotes/origin/main",
        "origin", "remotes/origin", "refs/remotes/origin",
        "tags/v0.1", "v0.1", "v1.0", "tags/v1.0", "v1.0-signed", "blobtag",
        "refs/tags/blobtag", "nosuchref", "refs/heads/nosuch", "", "HEAD ",
        # refs/tags/v0.1 and refs/heads/v0.1 both exist: tags win.
        "heads/v0.1", "refs/heads/v0.1", "config", "packed-refs"]]


def case_rev_parse_suffixes(g):
    return ["rev-parse " + r for r in [
        "HEAD^", "HEAD^1", "HEAD^2", "HEAD^3", "HEAD^0", "HEAD~", "HEAD~0",
        "HEAD~1", "HEAD~5", "HEAD^^", "HEAD^^^", "HEAD~2^2", "HEAD^2~1",
        "v1.0^{}", "v1.0^{commit}", "v1.0^{tree}", "v1.0^", "v1.0~2",
        "v1.0-signed^{}", "v1.0-signed^{commit}", "v1.0-signed^{tag}",
        "blobtag^{}", "blobtag^{blob}", "blobtag^{commit}", "blobtag^",
        "HEAD^{tree}", "HEAD^{blob}", "HEAD^{object}", "HEAD^{commit}",
        "old~30", "HEAD^{bogus}"]]


def case_rev_parse_abbrev(g):
    head = rp(g, "HEAD")
    tree = rp(g, "HEAD^{tree}")
    return ["rev-parse " + r for r in [
        head, head[:4], head[:7], head[:12], head[:39], head[:3],
        tree[:8], "0" * 40, "deadbeef",
        head[:7].upper(), head + "^", head[:8] + "~1"]]


def case_ls_tree_root(g):
    return ["ls-tree HEAD", "ls-tree main", "ls-tree v1.0", "ls-tree v0.1",
            "ls-tree HEAD^{tree}", "ls-tree " + rp(g, "HEAD^{tree}"),
            "ls-tree HEAD~29", "ls-tree blobtag", "ls-tree nosuch",
            "ls-tree v1.0-signed"]


def case_ls_tree_paths(g):
    return ["ls-tree HEAD " + p for p in [
        "src", "src/deep", "src/deep/nested", "data", "scripts", "vendor",
        "nosuchdir", "README.md", "src/main.c", "vendor/sub", "src/nosuch",
        "data/blob.bin", ".", "..", "src/.", "src/..", "src/deep/",
        "/src", "src//deep"]] + ["ls-tree HEAD~18 scripts", "ls-tree v1.0 src",
                                 "ls-tree HEAD ", "ls-tree HEAD src src",
                                 "ls-tree  HEAD"]


def case_ls_tree_quoting(g):
    return ["ls-tree HEAD", "ls-tree HEAD~18", "ls-tree HEAD~20",
            "ls-tree old", "ls-tree HEAD~29"]


def case_cat_file_small(g):
    return ["cat-file " + r for r in [
        "HEAD", "HEAD^{tree}", "HEAD~1", rp(g, "refs/tags/v1.0"),
        rp(g, "HEAD"), blob_at(g, "HEAD", "README.md"),
        blob_at(g, "HEAD", "src/main.c"), "refs/tags/blobtag",
        "blobtag^{}", "v0.1", "0" * 40]]


def case_cat_file_binary(g):
    return ["cat-file " + r for r in [
        blob_at(g, "HEAD", "data/blob.bin"), blob_at(g, "HEAD", "empty"),
        blob_at(g, "HEAD", "café.txt"),
        blob_at(g, "HEAD", "quote\"and\\slash.txt"),
        rp(g, "HEAD^{tree}"), rp(g, "HEAD:src"), rp(g, "v1.0"),
        rp(g, "v1.0-signed")]]


def case_cat_file_corrupt(g):
    good = sorted(git(g, "cat-file", "--batch-all-objects",
                      "--batch-check=%(objectname)").stdout.decode().split())
    good = [s for s in good if s not in
            ("0123456789abcdef0123456789abcdef01234567",
             "fedcba9876543210fedcba9876543210fedcba98")]
    return ["count-objects"] + ["cat-file " + s for s in good] + [
        "cat-file 0123456789abcdef0123456789abcdef01234567",
        "cat-file fedcba9876543210fedcba9876543210fedcba98",
        "cat-file 1111111111111111111111111111111111111111",
        "log HEAD", "ls-tree HEAD"]


def case_log_basic(g):
    return ["log HEAD", "log HEAD 1", "log HEAD 0", "log HEAD 5", "log side",
            "log side 3", "log v1.0", "log v1.0-signed", "log old",
            "log blobtag", "log nosuch", "log HEAD -1", "log HEAD 1000",
            "log HEAD 007", "log HEAD 00", "log HEAD 1 2", "log HEAD 1x",
            "log HEAD ", "log"]


def case_log_subjects(g):
    return ["log HEAD 14", "log HEAD~8 8", "log old 11", "log HEAD^2"]


def case_log_merge_order(g):
    return ["log HEAD", "log HEAD 40", "log HEAD^2", "log HEAD^",
            "log HEAD~10 6", "count-objects"]


def case_diff_basic(g):
    return ["diff HEAD HEAD", "diff HEAD~1 HEAD", "diff HEAD HEAD~1",
            "diff HEAD~10 HEAD", "diff HEAD~29 HEAD", "diff HEAD^ HEAD^2",
            "diff HEAD nosuch", "diff HEAD"]


def case_diff_modes(g):
    # HEAD~14..HEAD~13 changes an executable bit, HEAD~10..HEAD~9 turns a
    # symlink into a regular file, HEAD~19..HEAD~18 deletes a path, and
    # HEAD~6..HEAD~5 / HEAD~4..HEAD~3 swap a directory for a file and back.
    return ["diff HEAD~14 HEAD~13", "diff HEAD~13 HEAD~14",
            "diff HEAD~10 HEAD~9", "diff HEAD~9 HEAD~10",
            "diff HEAD~19 HEAD~18", "diff HEAD~30 HEAD~28",
            "diff HEAD~6 HEAD~5", "diff HEAD~5 HEAD~6",
            "diff HEAD~4 HEAD~3", "diff HEAD~6 HEAD~3",
            "ls-tree HEAD~5 data", "ls-tree HEAD~3 data"]


def case_diff_trees_tags(g):
    return ["diff v0.1 v1.0", "diff v1.0 HEAD", "diff v1.0-signed HEAD",
            "diff HEAD^{tree} HEAD~5^{tree}", "diff " + rp(g, "HEAD^{tree}") +
            " " + rp(g, "HEAD~3^{tree}"), "diff blobtag HEAD"]


def case_ofs_delta(g):
    shas = sorted(git(g, "rev-list", "--objects", "HEAD").stdout.decode()
                  .split("\n"))
    names = [s.split(" ")[0] for s in shas if s][:14]
    return ["count-objects", "log HEAD 20"] + ["cat-file " + s for s in names]


def case_mixed_store(g):
    shas = sorted(git(g, "rev-list", "--objects", "HEAD").stdout.decode()
                  .split("\n"))
    names = [s.split(" ")[0] for s in shas if s][:10]
    return ["count-objects", "log HEAD 12", "ls-tree HEAD",
            "rev-parse extra", "rev-parse refs/heads/extra",
            "diff extra HEAD"] + ["cat-file " + s for s in names]


def case_packed_refs(g):
    return ["count-objects"] + ["rev-parse " + r for r in [
        "HEAD", "main", "side", "old", "origin/main", "v0.1", "v1.0",
        "v1.0-signed", "blobtag", "refs/heads/main", "refs/tags/v1.0"]]


def case_inherits_loose(g):
    return ["count-objects", "log HEAD", "log HEAD 5", "ls-tree HEAD",
            "ls-tree HEAD test", "rev-parse HEAD", "rev-parse HEAD~10",
            "diff HEAD~5 HEAD"]


def case_inherits_packed(g):
    t = tags(g)
    return ["count-objects", "log HEAD", "ls-tree HEAD"] + \
        ["rev-parse " + x for x in t] + ["rev-parse %s^{}" % x for x in t] + \
        ["diff %s %s" % (t[0], t[-1]), "log %s 4" % t[-1]]


def case_inherits_objects(g):
    t = tags(g)
    objs = ["cat-file " + rp(g, x) for x in t]
    # This packed blob is stored as a delta whose instructions include a copy
    # with no size bytes, the encoding of a 64 KiB copy.
    return objs + ["cat-file 58dc608cf22d89173223afdf8000cc5cb65cd4ca",
                   "cat-file " + blob_at(g, "HEAD", "inherits.js"),
                   "cat-file " + blob_at(g, "HEAD", "README.md"),
                   "cat-file " + rp(g, "HEAD^{tree}"),
                   "cat-file " + rp(g, "HEAD")]


def case_split_refdelta(g):
    return ["count-objects", "log HEAD", "log HEAD 25", "ls-tree HEAD",
            "ls-tree HEAD test", "ls-tree HEAD examples",
            "rev-parse HEAD~100", "diff HEAD~100 HEAD"]


def case_split_multipack(g):
    names = [s.split(" ")[0] for s in
             git(g, "rev-list", "--objects", "HEAD").stdout.decode().split("\n")
             if s]
    picked = sorted(names)[::37][:16]
    return ["count-objects", "log HEAD 30", "ls-tree HEAD"] + \
        ["cat-file " + s for s in picked]


def case_split_diffs(g):
    return ["diff HEAD~200 HEAD~150", "diff HEAD~150 HEAD~100",
            "diff HEAD~100 HEAD~50", "diff HEAD~50 HEAD",
            "diff HEAD~242 HEAD", "log HEAD 60", "count-objects"]


def case_itsdangerous_log(g):
    return ["count-objects", "log HEAD", "log HEAD 50", "log HEAD 1",
            "rev-parse HEAD", "rev-parse HEAD~200"]


def case_itsdangerous_tags(g):
    t = tags(g)
    return ["rev-parse " + x for x in t] + ["rev-parse %s^{}" % x for x in t] + \
        ["ls-tree HEAD", "ls-tree HEAD src", "diff %s %s" % (t[0], t[-1]),
         "cat-file " + rp(g, t[-1]), "log %s 10" % t[0]]


def case_quirks(g):
    """Tie-broken log order, quoted-path diff order, octal-escaped names."""
    return ["log main", "log main 3", "log main 1", "log y", "log z", "log x",
            "diff root x", "diff x root", "diff root main", "diff y z",
            "diff main^ main^2",
            "ls-tree main", "ls-tree root", "ls-tree y",
            "rev-parse main^", "rev-parse main^2", "rev-parse main^2^",
            "rev-parse main~2", "count-objects",
            "log msgs", "log msgs 2", "cat-file msgs", "rev-parse msgs~3",
            "cat-file " + blob_at(g, "main", "zz.txt"),
            "cat-file " + rp(g, "main^{tree}")]


def case_jscookie_history(g):
    return ["count-objects", "log HEAD", "log HEAD 100", "rev-parse HEAD",
            "rev-parse HEAD~1000", "ls-tree HEAD"]


def case_jscookie_diff(g):
    t = tags(g)
    return ["diff HEAD~1000 HEAD", "diff HEAD~500 HEAD~250",
            "diff %s %s" % (t[0], t[-1]), "ls-tree HEAD src",
            "cat-file " + rp(g, "HEAD^{tree}"), "log HEAD~500 20"]


CASES = [
    ("001_empty_repo", "synth-empty", case_empty),
    ("002_detached_head", "synth-detached", case_detached),
    ("003_rev_parse_names", "synth-basic-loose", case_rev_parse_names),
    ("004_rev_parse_suffixes", "synth-basic-loose", case_rev_parse_suffixes),
    ("005_rev_parse_abbrev", "synth-basic-packed", case_rev_parse_abbrev),
    ("006_ls_tree_root", "synth-basic-loose", case_ls_tree_root),
    ("007_ls_tree_paths", "synth-basic-loose", case_ls_tree_paths),
    ("008_ls_tree_quoting", "synth-basic-packed", case_ls_tree_quoting),
    ("009_cat_file_small", "synth-basic-loose", case_cat_file_small),
    ("010_cat_file_binary", "synth-basic-packed", case_cat_file_binary),
    ("011_cat_file_corrupt", "synth-corrupt", case_cat_file_corrupt),
    ("012_log_basic", "synth-basic-loose", case_log_basic),
    ("013_log_subjects", "synth-basic-packed", case_log_subjects),
    ("014_log_merge_order", "synth-basic-packed", case_log_merge_order),
    ("015_diff_basic", "synth-basic-loose", case_diff_basic),
    ("016_diff_modes", "synth-basic-packed", case_diff_modes),
    ("017_diff_trees_tags", "synth-basic-packed", case_diff_trees_tags),
    ("018_pack_ofs_delta", "synth-basic-packed", case_ofs_delta),
    ("019_pack_ref_delta", "synth-basic-refdelta", case_ofs_delta),
    ("020_mixed_loose_and_pack", "synth-basic-mixed", case_mixed_store),
    ("021_packed_refs", "synth-basic-packed", case_packed_refs),
    ("022_loose_refs", "synth-basic-loose", case_packed_refs),
    ("023_inherits_loose", "inherits-loose", case_inherits_loose),
    ("024_inherits_packed", "inherits-packed", case_inherits_packed),
    ("025_inherits_objects", "inherits-packed", case_inherits_objects),
    ("026_split_ref_delta", "split-refdelta", case_split_refdelta),
    ("027_split_multipack", "split-multipack", case_split_multipack),
    ("028_split_diffs", "split-refdelta", case_split_diffs),
    ("029_itsdangerous_log", "itsdangerous", case_itsdangerous_log),
    ("030_itsdangerous_tags", "itsdangerous", case_itsdangerous_tags),
    ("031_jscookie_history", "jscookie", case_jscookie_history),
    ("032_jscookie_diff", "jscookie", case_jscookie_diff),
    ("033_tie_order_quoting", "synth-quirks", case_quirks),
]

CORRUPT_SHAS = ("0123456789abcdef0123456789abcdef01234567",
                "fedcba9876543210fedcba9876543210fedcba98")


# ---------------------------------------------------------------- the oracle

def valid_tree_path(path):
    """The spec's <path> grammar for ls-tree.

    git accepts `<rev>:src/deep/` and lists the directory; the spec forbids a
    trailing slash, so such a path is filtered out here rather than asked of
    git. Every other malformed form below is rejected by git too.
    """
    if not path or path.startswith("/") or path.endswith("/"):
        return False
    return all(c and c not in (".", "..") for c in path.split("/"))


def oracle(gitdir, line):
    """The answer git gives for one command, or None when git fails."""
    parts = line.split(" ")
    cmd, args = parts[0], parts[1:]
    if any(a == "" for a in args):
        # An empty token (a double or trailing space) makes the command
        # invalid; git would happily read `<rev>:` as the root tree.
        return None
    if cmd == "count-objects":
        if args:
            return None
        out = git(gitdir, "count-objects", "-v").stdout.decode()
        fields = dict(l.split(": ") for l in out.strip().split("\n"))
        return ("loose: %s\nin-pack: %s\npacks: %s\n"
                % (fields["count"], fields["in-pack"], fields["packs"])).encode()
    if cmd == "rev-parse":
        if len(args) != 1:
            return None
        p = git(gitdir, "rev-parse", "--verify", args[0] + "^{object}")
        return p.stdout if p.returncode == 0 else None
    if cmd == "log":
        if not 1 <= len(args) <= 2:
            return None
        cargs = ["log", "--format=%H %an %ad %s", "--date=unix"]
        if len(args) == 2:
            if not args[1] or not all(c in "0123456789" for c in args[1]):
                return None
            cargs += ["-n", args[1]]
        p = git(gitdir, *(cargs + [args[0] + "^{commit}", "--"]))
        return p.stdout if p.returncode == 0 else None
    if cmd == "ls-tree":
        if not 1 <= len(args) <= 2:
            return None
        if len(args) == 2 and not valid_tree_path(args[1]):
            return None
        spec = args[0] if len(args) == 1 else "%s:%s" % (args[0], args[1])
        p = git(gitdir, "ls-tree", spec)
        return p.stdout if p.returncode == 0 else None
    if cmd == "cat-file":
        if len(args) != 1:
            return None
        if args[0] in CORRUPT_SHAS:
            return None
        p = git(gitdir, "cat-file", "-t", args[0] + "^{object}")
        if p.returncode != 0:
            return None
        obj_type = p.stdout.decode().strip()
        q = git(gitdir, "cat-file", obj_type, args[0])
        if q.returncode != 0:
            return None
        return b"%s %d\n%s" % (obj_type.encode(), len(q.stdout), q.stdout)
    if cmd == "diff":
        if len(args) != 2:
            return None
        p = git(gitdir, "diff", "--raw", "--abbrev=40", "--no-renames",
                args[0] + "^{tree}", args[1] + "^{tree}", "--")
        return p.stdout if p.returncode == 0 else None
    return None


def check_corrupt_oracle(gitdir):
    """git fsck must agree that the damaged objects are unreadable."""
    out = git(gitdir, "fsck").stdout + git(gitdir, "fsck").stderr
    text = out.decode("utf-8", "replace")
    for sha in CORRUPT_SHAS:
        # fsck names the damaged file by its path, and a hash-path mismatch is
        # reported under the hash the content actually has.
        if sha not in text and "%s/%s" % (sha[:2], sha[2:]) not in text:
            raise SystemExit("git fsck did not report %s in %s" % (sha, gitdir))


# ------------------------------------------------------------------ the build

def build_case(name, repo, builder):
    gitdir = os.path.join(CORPUS, repo)
    commands = builder(gitdir)
    case = os.path.join(TESTS, name)
    shutil.rmtree(case, ignore_errors=True)
    os.makedirs(os.path.join(case, "input"))
    shutil.copytree(gitdir, os.path.join(case, "input", "repo"), symlinks=True)
    with open(os.path.join(case, "input", "commands.txt"), "wb") as f:
        f.write(("\n".join(commands) + "\n").encode("utf-8"))
    out = os.path.join(case, "expected")
    os.makedirs(out)
    p = subprocess.run([sys.executable, REFERENCE,
                        os.path.join(case, "input"), out], capture_output=True)
    if p.returncode != 0:
        raise SystemExit("reference failed on %s: %s"
                         % (name, p.stderr.decode()[:400]))
    mismatches = 0
    for i, line in enumerate(commands, 1):
        with open(os.path.join(out, "%03d.out" % i), "rb") as f:
            actual = f.read()
        want = oracle(gitdir, line)
        if want is None:
            want = b"error\n"
        if actual != want:
            mismatches += 1
            print("MISMATCH %s #%d: %r" % (name, i, line))
            print("  git:       %r" % want[:200])
            print("  reference: %r" % actual[:200])
    if mismatches:
        raise SystemExit("%s: %d command(s) disagree with git" % (name, mismatches))
    size = sum(os.path.getsize(os.path.join(dp, fn))
               for dp, _, fns in os.walk(case) for fn in fns)
    print("%-28s %3d commands %8.1f KiB" % (name, len(commands), size / 1024.0))


def main():
    if not os.path.isdir(CORPUS):
        raise SystemExit("corpus/ is missing; run make_corpus.py first")
    check_corrupt_oracle(os.path.join(CORPUS, "synth-corrupt"))
    os.makedirs(TESTS, exist_ok=True)
    for name, repo, builder in CASES:
        build_case(name, repo, builder)
    total = sum(os.path.getsize(os.path.join(dp, fn))
                for dp, _, fns in os.walk(TESTS) for fn in fns)
    print("tests/ total %.1f MiB across %d cases" % (total / 1048576.0, len(CASES)))


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'corpus/tests-notice.md'
TEST_LICENCES = [
    ('corpus/licenses/inherits-LICENSE.md',
     'LICENSE-inherits.md'),
    ('corpus/licenses/split-LICENCE.txt',
     'LICENSE-split.txt'),
    ('corpus/licenses/itsdangerous-LICENSE.txt',
     'LICENSE-itsdangerous.txt'),
    ('corpus/licenses/jscookie-LICENSE.txt',
     'LICENSE-jscookie.txt'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


if __name__ == "__main__":
    rc = main()
    copy_licences()
    sys.exit(rc)
