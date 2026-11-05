#!/usr/bin/env python3
"""Builds problems/gitrepo/corpus/ : the git directories the tests are cut from.

Two kinds of repository end up in corpus/:

* clones of small permissively licensed public projects, repacked in several
  ways so that the suite covers packs with OFS_DELTA deltas, packs with
  REF_DELTA deltas, several packs at once, and fully loose object stores;
* synthetic repositories built with git plumbing at fixed timestamps, which
  carry the awkward cases a real project does not have (symlinks, gitlinks,
  names needing C-style quoting, an unborn HEAD, a corrupt loose object).

Network access is needed only for the clones. The results are vendored, so
this script runs once; gen_tests.py only copies from corpus/.
"""
import os
import shutil
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
WORK = "/tmp/gitrepo_corpus_work"

UPSTREAM = [
    ("inherits", "https://github.com/isaacs/inherits.git"),
    ("split", "https://github.com/dominictarr/split.git"),
    ("itsdangerous", "https://github.com/pallets/itsdangerous.git"),
    ("jscookie", "https://github.com/js-cookie/js-cookie.git"),
]

CONFIG = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n"


def run(args, **kw):
    kw.setdefault("check", True)
    return subprocess.run(args, **kw)


def git(gitdir, *args, **kw):
    kw.setdefault("check", True)
    kw.setdefault("capture_output", True)
    return subprocess.run(["git", "--git-dir", gitdir] + list(args), **kw)


def strip_repo(gitdir):
    """Removes everything the tests do not need from a git directory."""
    for name in ("hooks", "logs", "info", "branches", "worktrees", "modules"):
        shutil.rmtree(os.path.join(gitdir, name), ignore_errors=True)
    for name in ("index", "description", "FETCH_HEAD", "ORIG_HEAD", "shallow",
                 "COMMIT_EDITMSG", "packed-refs.lock"):
        try:
            os.remove(os.path.join(gitdir, name))
        except FileNotFoundError:
            pass
    objinfo = os.path.join(gitdir, "objects", "info")
    if os.path.isdir(objinfo):
        shutil.rmtree(objinfo)
    packdir = os.path.join(gitdir, "objects", "pack")
    if os.path.isdir(packdir):
        for fn in os.listdir(packdir):
            if not (fn.endswith(".pack") or fn.endswith(".idx")):
                os.remove(os.path.join(packdir, fn))
    with open(os.path.join(gitdir, "config"), "w") as f:
        f.write(CONFIG)


def unpack_all(gitdir):
    """Explodes every pack into loose objects and removes the packs."""
    packdir = os.path.join(gitdir, "objects", "pack")
    packs = sorted(fn for fn in os.listdir(packdir) if fn.endswith(".pack"))
    for fn in packs:
        src = os.path.join(packdir, fn)
        tmp = os.path.join(WORK, "unpack.pack")
        shutil.move(src, tmp)
        with open(tmp, "rb") as f:
            run(["git", "--git-dir", gitdir, "unpack-objects"], stdin=f,
                capture_output=True)
        os.remove(tmp)
    for fn in os.listdir(packdir):
        os.remove(os.path.join(packdir, fn))


def unpack_refs(gitdir):
    """Turns packed-refs into loose ref files."""
    path = os.path.join(gitdir, "packed-refs")
    if not os.path.exists(path):
        return
    with open(path, "rb") as f:
        lines = f.read().split(b"\n")
    for line in lines:
        if not line or line.startswith(b"#") or line.startswith(b"^"):
            continue
        sha, _, name = line.partition(b" ")
        dest = os.path.join(gitdir, name.decode())
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(sha + b"\n")
    os.remove(path)


def clone(name, url):
    dest = os.path.join(WORK, name + ".git")
    if os.path.isdir(dest):
        return dest
    run(["git", "clone", "--quiet", "--bare", url, dest], capture_output=True)
    return dest


def copy_repo(src, name):
    dest = os.path.join(CORPUS, name)
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(src, dest, symlinks=True)
    return dest


# ---------------------------------------------------------------- synthetic

class Builder:
    """Builds a repository with git plumbing only, at fixed timestamps."""

    def __init__(self, path):
        self.dir = path
        shutil.rmtree(path, ignore_errors=True)
        os.makedirs(path)
        run(["git", "init", "--quiet", "--bare", path], capture_output=True)
        self.index = os.path.join(WORK, "index-" + os.path.basename(path))
        if os.path.exists(self.index):
            os.remove(self.index)
        self.entries = {}

    def _env(self, name, email, when):
        env = dict(os.environ)
        env.update(GIT_INDEX_FILE=self.index, GIT_DIR=self.dir,
                   GIT_AUTHOR_NAME=name, GIT_AUTHOR_EMAIL=email,
                   GIT_AUTHOR_DATE=when, GIT_COMMITTER_NAME=name,
                   GIT_COMMITTER_EMAIL=email, GIT_COMMITTER_DATE=when,
                   LC_ALL="C")
        return env

    def blob(self, data):
        p = subprocess.run(["git", "--git-dir", self.dir, "hash-object", "-w",
                            "-t", "blob", "--stdin"], input=data,
                           capture_output=True, check=True)
        return p.stdout.decode().strip()

    def put(self, path, mode, sha):
        self.entries[path] = (mode, sha)

    def remove(self, path):
        self.entries.pop(path, None)

    def write_tree(self):
        if os.path.exists(self.index):
            os.remove(self.index)
        env = dict(os.environ, GIT_INDEX_FILE=self.index, GIT_DIR=self.dir)
        args = ["git", "update-index", "-z", "--index-info"]
        payload = b""
        for path, (mode, sha) in sorted(self.entries.items()):
            payload += b"%s %s\t%s\x00" % (mode.encode(), sha.encode(),
                                           path.encode() if isinstance(path, str) else path)
        subprocess.run(args, input=payload, env=env,
                       capture_output=True, check=True)
        p = subprocess.run(["git", "write-tree"], env=env, capture_output=True,
                           check=True)
        return p.stdout.decode().strip()

    def commit(self, tree, parents, message, name="Ada Lovelace",
               email="ada@example.org", when="1136214245 +0000"):
        args = ["git", "commit-tree", tree]
        for p in parents:
            args += ["-p", p]
        env = self._env(name, email, when)
        p = subprocess.run(args, input=message.encode(), env=env,
                           capture_output=True, check=True)
        return p.stdout.decode().strip()

    def tag(self, obj, objtype, tagname, message, when="1136214245 +0000"):
        body = ("object %s\ntype %s\ntag %s\ntagger Grace Hopper "
                "<grace@example.org> %s\n\n%s" % (obj, objtype, tagname, when, message))
        p = subprocess.run(["git", "--git-dir", self.dir, "hash-object", "-w",
                            "-t", "tag", "--stdin"], input=body.encode(),
                           capture_output=True, check=True)
        return p.stdout.decode().strip()

    def ref(self, name, sha):
        git(self.dir, "update-ref", name, sha)

    def head(self, target):
        with open(os.path.join(self.dir, "HEAD"), "w") as f:
            f.write(target + "\n")

    def finish(self):
        if os.path.exists(self.index):
            os.remove(self.index)
        strip_repo(self.dir)


def lorem(seed, n):
    """Deterministic pseudo-text, similar between neighbouring seeds."""
    words = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet "
             "kilo lima mike november oscar papa quebec romeo sierra tango "
             "uniform victor whiskey xray yankee zulu").split()
    out = []
    state = seed * 2654435761 % (2 ** 32)
    for i in range(n):
        state = (state * 1103515245 + 12345) % (2 ** 31)
        out.append(words[state % len(words)])
        if i % 9 == 8:
            out.append("\n")
    return (" ".join(out) + "\n").encode()


def build_basic(path):
    """A repository exercising every tree entry kind and message shape."""
    b = Builder(path)
    names = {
        "README.md": "100644",
        "src/main.c": "100644",
        "src/util.c": "100644",
        "src/deep/nested/table.txt": "100644",
        "scripts/build.sh": "100755",
        "link-to-readme": "120000",
        "empty": "100644",
        "data/blob.bin": "100644",
        "café.txt": "100644",
        "spaced name.txt": "100644",
        'quote"and\\slash.txt': "100644",
        "tab\there.txt": "100644",
    }
    b.put("link-to-readme", "120000", b.blob(b"README.md"))
    b.put("empty", "100644", b.blob(b""))
    b.put("data/blob.bin", "100644", b.blob(bytes(range(256)) * 3))
    b.put("café.txt", "100644", b.blob("café au lait\n".encode()))
    b.put("spaced name.txt", "100644", b.blob(b"spaces are fine\n"))
    b.put('quote"and\\slash.txt', "100644", b.blob(b"quoting required\n"))
    b.put("tab\there.txt", "100644", b.blob(b"tabs too\n"))
    b.put("vendor/sub", "160000", "1" * 40)
    b.put("scripts/build.sh", "100755", b.blob(b"#!/bin/sh\nexec make \"$@\"\n"))

    heads = []
    t0 = 1300000000
    authors = [("Ada Lovelace", "ada@example.org"),
               ("Björn Öberg", "bjorn@example.org"),
               ("Grace Hopper", "grace@example.org")]
    messages = [
        "Initial import",
        "Add utility helpers\n\nThis body is not part of the subject.\n",
        "A subject that the author\nwrapped across two lines\n\nbody here\n",
        "\n\nLeading blank lines before the subject\n",
        "Trailing spaces in subject   \n\nbody\n",
        "",
        "Only a subject, no trailing newline",
        "Subject with  double  spaces\n",
    ]
    parent = []
    for i in range(30):
        b.put("README.md", "100644", b.blob(b"# demo\n\n" + lorem(i, 40)))
        b.put("src/main.c", "100644", b.blob(b"int main(void) {\n" + lorem(i + 100, 120) + b"}\n"))
        b.put("src/util.c", "100644", b.blob(lorem(i + 200, 160)))
        b.put("src/deep/nested/table.txt", "100644", b.blob(lorem(i + 300, 90)))
        if i == 12:
            b.remove("spaced name.txt")
        if i == 17:
            b.put("scripts/build.sh", "100644", b.blob(b"#!/bin/sh\nexec make \"$@\"\n"))
        if i == 21:
            b.put("link-to-readme", "100644", b.blob(b"README.md"))
        if i == 25:
            b.remove("data/blob.bin")
            b.put("data", "100644", b.blob(b"the directory is now a file\n"))
        if i == 27:
            b.remove("data")
            b.put("data/blob.bin", "100644", b.blob(bytes(range(256)) * 3))
            b.put("data/notes.txt", "100644", b.blob(b"and a directory again\n"))
        tree = b.write_tree()
        name, email = authors[i % 3]
        msg = messages[i % len(messages)]
        sha = b.commit(tree, parent, msg, name, email,
                       "%d +0000" % (t0 + i * 3600))
        parent = [sha]
        heads.append(sha)

    # A side branch merged back, so the log walk sees a merge.
    b.put("src/side.c", "100644", b.blob(lorem(999, 70)))
    side_tree = b.write_tree()
    side = b.commit(side_tree, [heads[24]], "Side branch work\n",
                    "Grace Hopper", "grace@example.org",
                    "%d +0000" % (t0 + 25 * 3600 + 60))
    side2 = b.commit(side_tree, [side], "More side work\n",
                     "Grace Hopper", "grace@example.org",
                     "%d +0000" % (t0 + 26 * 3600 + 60))
    merge_tree = b.write_tree()
    merge = b.commit(merge_tree, [heads[-1], side2],
                     "Merge branch 'side'\n", "Ada Lovelace", "ada@example.org",
                     "%d +0000" % (t0 + 31 * 3600))
    b.ref("refs/heads/main", merge)
    b.ref("refs/heads/side", side2)
    b.ref("refs/heads/old", heads[10])
    b.ref("refs/remotes/origin/main", heads[20])
    lw = heads[5]
    b.ref("refs/tags/v0.1", lw)
    at = b.tag(heads[15], "commit", "v1.0", "release one\n")
    b.ref("refs/tags/v1.0", at)
    at2 = b.tag(at, "tag", "v1.0-signed", "tag of a tag\n")
    b.ref("refs/tags/v1.0-signed", at2)
    blob_tag = b.tag(b.blob(b"a tagged blob\n"), "blob", "blobtag", "tagging a blob\n")
    b.ref("refs/tags/blobtag", blob_tag)
    b.head("ref: refs/heads/main")
    b.finish()
    return b


def build_quirks(path):
    """A repository built around the cases a normal history never reaches.

    * every path needing C-style quoting changes in one commit, so a `diff`
      shows that the lines are ordered by the raw path bytes and not by the
      quoted form (the quoted form starts with a `"`, which sorts first);
    * a name holding 0x7f and one holding 0x01, which quote as octal escapes;
    * three commits sharing one committer date below a merge, so the order of
      the default log walk depends on equal dates being inserted last.
    """
    b = Builder(path)
    quoted = {
        "a.txt": "100644",
        "caf\u00e9.txt": "100644",
        "ctrl\x01char.txt": "100644",
        "del\x7fchar.txt": "100644",
        'quote"and\\slash.txt': "100644",
        "tab\there.txt": "100644",
        "zz.txt": "100644",
    }
    for name, mode in quoted.items():
        b.put(name, mode, b.blob(b"one\n"))
    t0 = 1000000000
    root = b.commit(b.write_tree(), [], "Root with awkward names\n",
                    when="%d +0000" % t0)
    # X: every awkward name changes at once.
    for name, mode in quoted.items():
        b.put(name, mode, b.blob(b"two\n"))
    x_tree = b.write_tree()
    x = b.commit(x_tree, [root], "Touch every quoted name\n",
                 when="%d +0000" % (t0 + 3600))
    # Z: a child of X, same committer date as X.
    b.put("zz.txt", "100644", b.blob(b"three\n"))
    z_tree = b.write_tree()
    z = b.commit(z_tree, [x], "Same second as its parent\n",
                 when="%d +0000" % (t0 + 3600))
    # Y: a sibling branch off the root, also at that same second.
    for name, mode in quoted.items():
        b.put(name, mode, b.blob(b"one\n"))
    b.put("side.txt", "100644", b.blob(b"side\n"))
    y_tree = b.write_tree()
    y = b.commit(y_tree, [root], "Sibling at the same second\n",
                 when="%d +0000" % (t0 + 3600))
    # The merge takes Y first, so a wrong tie-break shows up immediately.
    for name, mode in quoted.items():
        b.put(name, mode, b.blob(b"two\n"))
    b.put("zz.txt", "100644", b.blob(b"three\n"))
    merge_tree = b.write_tree()
    merge = b.commit(merge_tree, [y, z], "Merge the siblings\n",
                     when="%d +0000" % (t0 + 7200))
    # A branch whose messages cover the whitespace rules of the subject line:
    # lines that are blank only after stripping, trailing whitespace inside a
    # folded subject, and leading whitespace that is kept.
    subjects = [
        "   \n  \nSubject after whitespace-only lines\n\nbody\n",
        "Subject here\n \nnot part of the subject\n",
        "Folded first   \n  second line\nthird\n\nbody\n",
        "\t\n",
    ]
    parent = [root]
    for i, message in enumerate(subjects):
        b.put("msg.txt", "100644", b.blob(b"message %d\n" % i))
        parent = [b.commit(b.write_tree(), parent, message,
                           when="%d +0000" % (t0 + 10800 + i * 60))]
    b.ref("refs/heads/msgs", parent[0])
    b.ref("refs/heads/main", merge)
    b.ref("refs/heads/root", root)
    b.ref("refs/heads/x", x)
    b.ref("refs/heads/y", y)
    b.ref("refs/heads/z", z)
    b.head("ref: refs/heads/main")
    b.finish()


def build_empty(path):
    b = Builder(path)
    b.head("ref: refs/heads/main")
    b.finish()


def build_detached(path):
    b = Builder(path)
    t = b.write_tree()
    c1 = b.commit(t, [], "Empty tree commit\n", when="1400000000 +0000")
    b.put("only.txt", "100644", b.blob(b"one file\n"))
    t2 = b.write_tree()
    c2 = b.commit(t2, [c1], "Add only.txt\n", when="1400003600 +0000")
    b.ref("refs/heads/main", c2)
    b.head(c1)
    b.finish()


def build_corrupt(path):
    b = Builder(path)
    b.put("a.txt", "100644", b.blob(b"alpha\n"))
    b.put("b.txt", "100644", b.blob(b"bravo\n"))
    t = b.write_tree()
    c = b.commit(t, [], "Two files\n", when="1500000000 +0000")
    b.ref("refs/heads/main", c)
    b.head("ref: refs/heads/main")
    b.finish()
    # A loose object whose stored bytes do not hash to its own name; git fsck
    # reports it as a hash-path mismatch.
    fake = "0123456789abcdef0123456789abcdef01234567"
    payload = b"blob 12\x00corrupted!!\n"
    d = os.path.join(path, "objects", fake[:2])
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, fake[2:]), "wb") as f:
        f.write(zlib.compress(payload, 1))
    # A loose object whose compressed stream is damaged past the header.
    broken = "fedcba9876543210fedcba9876543210fedcba98"
    raw = bytearray(zlib.compress(b"blob 40\x00" + b"x" * 40, 9))
    raw[6] ^= 0xFF
    raw[7] ^= 0xFF
    d = os.path.join(path, "objects", broken[:2])
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, broken[2:]), "wb") as f:
        f.write(bytes(raw))


def main():
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(CORPUS, exist_ok=True)

    build_basic(os.path.join(WORK, "basic.git"))
    for variant in ("synth-basic-loose", "synth-basic-packed",
                    "synth-basic-refdelta", "synth-basic-mixed"):
        d = copy_repo(os.path.join(WORK, "basic.git"), variant)
        if variant == "synth-basic-loose":
            unpack_refs(d)
            # A remote HEAD symref, so the `refs/remotes/<name>/HEAD` lookup
            # rule is exercised, and a branch sharing a tag's name, so the
            # tags-before-heads order of the lookup rules is observable.
            with open(os.path.join(d, "refs", "remotes", "origin", "HEAD"),
                      "w") as f:
                f.write("ref: refs/remotes/origin/main\n")
            shutil.copyfile(os.path.join(d, "refs", "heads", "old"),
                            os.path.join(d, "refs", "heads", "v0.1"))
        elif variant == "synth-basic-packed":
            git(d, "-c", "pack.useDeltaBaseOffset=true", "repack", "-a", "-d", "-f")
            git(d, "pack-refs", "--all")
        elif variant == "synth-basic-refdelta":
            git(d, "-c", "repack.useDeltaBaseOffset=false", "repack", "-a", "-d", "-f")
            git(d, "pack-refs", "--all")
        elif variant == "synth-basic-mixed":
            # Pack only the objects reachable from an old commit, leave the rest loose.
            old = git(d, "rev-parse", "refs/heads/old").stdout.decode().strip()
            names = git(d, "rev-list", "--objects", old).stdout
            names = b"".join(l.split(b" ")[0] + b"\n" for l in names.split(b"\n") if l)
            subprocess.run(["git", "pack-objects", "--delta-base-offset",
                            os.path.join(d, "objects", "pack", "pack")],
                           input=names, env=dict(os.environ, GIT_DIR=d),
                           capture_output=True, check=True)
            git(d, "prune-packed")
            unpack_refs(d)
            git(d, "update-ref", "refs/heads/extra", old)
        strip_repo(d)

    build_quirks(os.path.join(CORPUS, "synth-quirks"))
    build_empty(os.path.join(CORPUS, "synth-empty"))
    build_detached(os.path.join(CORPUS, "synth-detached"))
    build_corrupt(os.path.join(CORPUS, "synth-corrupt"))

    for name, url in UPSTREAM:
        src = clone(name, url)
        if name == "inherits":
            d = copy_repo(src, "inherits-packed")
            strip_repo(d)
            d = copy_repo(src, "inherits-loose")
            strip_repo(d)
            unpack_all(d)
            unpack_refs(d)
        elif name == "split":
            d = copy_repo(src, "split-refdelta")
            strip_repo(d)
            git(d, "-c", "repack.useDeltaBaseOffset=false", "repack", "-a", "-d", "-f")
            strip_repo(d)
            d = copy_repo(src, "split-multipack")
            strip_repo(d)
            unpack_all(d)
            head = git(d, "rev-parse", "HEAD").stdout.decode().strip()
            # One pack uses OFS_DELTA, the other REF_DELTA; the rest stays loose.
            for rng, ofs in (("HEAD~150..HEAD", True), ("HEAD~220..HEAD~150", False)):
                names = git(d, "rev-list", "--objects", *rng.split()).stdout
                names = b"".join(l.split(b" ")[0] + b"\n" for l in names.split(b"\n") if l)
                cmd = ["git", "pack-objects"]
                cmd += ["--delta-base-offset"] if ofs else []
                cmd += [os.path.join(d, "objects", "pack", "pack")]
                subprocess.run(cmd, input=names, env=dict(os.environ, GIT_DIR=d),
                               capture_output=True, check=True)
                git(d, "prune-packed")
            unpack_refs(d)
            strip_repo(d)
        else:
            d = copy_repo(src, name)
            strip_repo(d)

    for name in sorted(os.listdir(CORPUS)):
        p = os.path.join(CORPUS, name)
        if os.path.isdir(p):
            size = sum(os.path.getsize(os.path.join(dp, f))
                       for dp, _, fs in os.walk(p) for f in fs)
            print("%-24s %8.1f KiB" % (name, size / 1024.0))


if __name__ == "__main__":
    sys.exit(main())
