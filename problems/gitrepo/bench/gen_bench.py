#!/usr/bin/env python3
"""Builds problems/gitrepo/bench/: three heavy performance inputs.

The inputs use the two largest repositories of the vendored corpus (jscookie,
1085 commits / 4279 objects / 1.2 MiB pack, which sits at the spec's size
limits, and itsdangerous) and fill each commands.txt with 999 commands, the
spec's maximum. Command selection is driven by fixed seeds, so the output is
deterministic. Expected outputs come from reference/main.py and every answer
is cross-checked against the git command line with gen_tests.oracle.

Run: python3 problems/gitrepo/bench/gen_bench.py
"""
import os
import random
import shutil
import subprocess
import sys
import tempfile

BENCH = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(BENCH)
CORPUS = os.path.join(PROBLEM, "corpus")
REFERENCE = os.path.join(PROBLEM, "reference", "main.py")
MAX_COMMANDS = 999

# Long tier (bench-long/): the same three sessions repeated K times over the
# same repositories (K * 999 commands; SPEC.md allows up to 9999). Every
# command writes its own output file, so the total output grows with K and
# disk use, not the time target, bounds K (see NOTES.md).
LONG_K = {
    "001_log_history_walks": 4,
    "002_cat_file_reconstruct": 4,
    "003_mixed_session": 10,
}
LONG_MAX_COMMANDS = 9999

sys.path.insert(0, PROBLEM)
import gen_tests  # noqa: E402  (oracle, git helpers)


def git_lines(gitdir, *args):
    out = gen_tests.git(gitdir, *args)
    if out.returncode != 0:
        raise SystemExit("git %s failed: %s" % (args, out.stderr.decode()))
    return [l for l in out.stdout.decode("utf-8", "replace").split("\n") if l]


def objects_by_type(gitdir):
    """{type: [(id, size)]} for every object in the repository, sorted by id."""
    res = {}
    for line in git_lines(gitdir, "cat-file", "--batch-all-objects",
                          "--batch-check=%(objectname) %(objecttype) %(objectsize)"):
        oid, typ, size = line.split(" ")
        res.setdefault(typ, []).append((oid, int(size)))
    return res


def first_parent_len(gitdir):
    return len(git_lines(gitdir, "rev-list", "--first-parent", "HEAD"))


# ------------------------------------------------------------------ workloads

def bench_log(g, k=1):
    """History walks: full and bounded `log` from many starting points."""
    rng = random.Random(1001)
    tags = gen_tests.tags(g)
    fp = first_parent_len(g)
    merges = git_lines(g, "rev-list", "--merges", "HEAD")
    commits = git_lines(g, "rev-list", "--all")
    cmds = []
    for _ in range(k):
        cmds += ["log HEAD", "log main"]
        cmds += ["log " + t for t in tags]
        # Full walks starting deep in first-parent history.
        for _ in range(15):
            cmds.append("log HEAD~%d" % rng.randrange(0, fp))
    # Bounded walks, the common interactive case ("last n commits of X").
    while len(cmds) < MAX_COMMANDS * k:
        r = rng.random()
        if r < 0.35:
            rev = "HEAD~%d" % rng.randrange(0, fp)
        elif r < 0.55:
            rev = rng.choice(tags)
        elif r < 0.70:
            rev = rng.choice(merges)[:rng.choice((7, 8, 10, 12))] + "^2"
        elif r < 0.85:
            rev = rng.choice(commits)
        else:
            rev = rng.choice(commits)[:rng.choice((7, 9, 12))]
        n = rng.choice((1, 5, 10, 20, 30, 50, 100, 150, 200))
        cmds.append("log %s %d" % (rev, n))
    return cmds


def bench_cat_file(g, k=1):
    """Object reconstruction: inflate, delta chains and SHA-1 verification."""
    rng = random.Random(2002)
    objs = objects_by_type(g)
    blobs_small = [o for o, s in objs["blob"] if s < 50000]
    blobs_large = [o for o, s in objs["blob"] if 50000 <= s <= 460000]
    picked = []
    for _ in range(k):
        round_ = []
        round_ += rng.sample(blobs_small, 520)
        round_ += rng.sample(blobs_large, 30)
        round_ += rng.sample([o for o, _ in objs["tree"]], 293)
        round_ += rng.sample([o for o, _ in objs["commit"]], 130)
        round_ += [o for o, _ in objs["tag"]]
        rng.shuffle(round_)
        picked += round_[:MAX_COMMANDS]
    cmds = []
    for oid in picked:
        # Mostly full ids, some abbreviated: both are realistic spellings.
        if rng.random() < 0.2:
            cmds.append("cat-file " + oid[:rng.choice((7, 10, 16))])
        else:
            cmds.append("cat-file " + oid)
    return cmds


def bench_mixed(g, k=1):
    """A realistic session mixing every command, weighted toward diff."""
    rng = random.Random(3003)
    tags = gen_tests.tags(g)
    fp = first_parent_len(g)
    commits = git_lines(g, "rev-list", "--all")
    merges = git_lines(g, "rev-list", "--merges", "HEAD")
    objs = objects_by_type(g)
    all_ids = [o for lst in objs.values() for o, _ in lst]

    def rand_rev():
        r = rng.random()
        if r < 0.45:
            return "HEAD~%d" % rng.randrange(0, fp)
        if r < 0.70:
            return rng.choice(tags)
        return rng.choice(commits)[:rng.choice((7, 8, 12, 40))]

    def rand_dir(rev):
        dirs = git_lines(g, "ls-tree", "-r", "-d", "--name-only",
                         rev + "^{tree}")
        return rng.choice(dirs) if dirs else None

    cmds = []
    for _ in range(300 * k):
        r = rng.random()
        if r < 0.35:
            m = rng.choice(merges)
            cmds.append("diff %s^ %s" % (m, m))
        elif r < 0.55:
            a, b = rng.sample(tags, 2)
            cmds.append("diff %s %s" % (a, b))
        else:
            cmds.append("diff %s %s" % (rand_rev(), rand_rev()))
    for _ in range(170 * k):
        rev = rand_rev()
        d = rand_dir(rev) if rng.random() < 0.7 else None
        cmds.append("ls-tree %s %s" % (rev, d) if d else "ls-tree " + rev)
    for _ in range(190 * k):
        r = rng.random()
        if r < 0.25:
            rev = rng.choice(all_ids)[:rng.choice((5, 6, 7, 8, 10))]
        elif r < 0.45:
            rev = rng.choice(tags) + rng.choice(("^{}", "^{tree}", "^{commit}",
                                                 "~3", "^", "^{object}"))
        elif r < 0.65:
            rev = "%s^2~%d" % (rng.choice(merges)[:9], rng.randrange(0, 6))
        elif r < 0.85:
            rev = "HEAD~%d^{tree}" % rng.randrange(0, fp)
        else:
            rev = rand_rev()
        cmds.append("rev-parse " + rev)
    for _ in range(150 * k):
        cmds.append("log %s %d" % (rand_rev(), rng.choice((1, 3, 10, 25, 60))))
    blobs = [o for o, s in objs["blob"] if s < 60000]
    trees = [o for o, _ in objs["tree"]]
    while len(cmds) < (MAX_COMMANDS - 9) * k:
        cmds.append("cat-file " + rng.choice(blobs if rng.random() < 0.7
                                             else trees))
    cmds += ["count-objects"] * (9 * k)
    rng.shuffle(cmds)
    return cmds


CASES = [
    ("001_log_history_walks", "jscookie", bench_log),
    ("002_cat_file_reconstruct", "jscookie", bench_cat_file),
    ("003_mixed_session", "itsdangerous", bench_mixed),
]


# ------------------------------------------------------------------ the build

def build_case(name, repo, builder, workdir, bench=BENCH, k=1):
    src = os.path.join(CORPUS, repo)
    # git refuses a repository with no refs/ directory (the corpus copies
    # have none when every ref is packed), so the oracle works on a copy.
    gitdir = os.path.join(workdir, repo)
    if not os.path.isdir(gitdir):
        shutil.copytree(src, gitdir, symlinks=True)
        os.makedirs(os.path.join(gitdir, "refs", "heads"), exist_ok=True)
        os.makedirs(os.path.join(gitdir, "refs", "tags"), exist_ok=True)
    commands = builder(gitdir, k) if k != 1 else builder(gitdir)
    assert len(commands) <= (MAX_COMMANDS if k == 1 else LONG_MAX_COMMANDS)
    case = os.path.join(bench, name)
    shutil.rmtree(case, ignore_errors=True)
    os.makedirs(os.path.join(case, "input"))
    shutil.copytree(src, os.path.join(case, "input", "repo"), symlinks=True)
    with open(os.path.join(case, "input", "commands.txt"), "wb") as f:
        f.write(("\n".join(commands) + "\n").encode("utf-8"))
    out = os.path.join(case, "expected")
    os.makedirs(out)
    p = subprocess.run([sys.executable, REFERENCE,
                        os.path.join(case, "input"), out], capture_output=True)
    if p.returncode != 0:
        raise SystemExit("reference failed on %s: %s"
                         % (name, p.stderr.decode()[:400]))
    mismatches = errors = 0
    for i, line in enumerate(commands, 1):
        with open(os.path.join(out, "%03d.out" % i), "rb") as f:
            actual = f.read()
        want = gen_tests.oracle(gitdir, line)
        if want is None:
            want = b"error\n"
        if actual == b"error\n":
            errors += 1
        if actual != want:
            mismatches += 1
            print("MISMATCH %s #%d: %r" % (name, i, line))
    if mismatches:
        raise SystemExit("%s: %d command(s) disagree with git" % (name, mismatches))
    size = sum(os.path.getsize(os.path.join(dp, fn))
               for dp, _, fns in os.walk(case) for fn in fns)
    print("%-28s %3d commands (%d error) %8.1f KiB"
          % (name, len(commands), errors, size / 1024.0))


def main():
    long_tier = "--long" in sys.argv[1:]
    bench = os.path.join(PROBLEM, "bench-long") if long_tier else BENCH
    os.makedirs(bench, exist_ok=True)
    with tempfile.TemporaryDirectory() as workdir:
        for name, repo, builder in CASES:
            k = LONG_K[name] if long_tier else 1
            build_case(name, repo, builder, workdir, bench, k)


if __name__ == "__main__":
    sys.exit(main())
