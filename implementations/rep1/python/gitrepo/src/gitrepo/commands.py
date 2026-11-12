"""The query commands: ``log``, ``ls-tree``, ``cat-file``, ``diff``,
``rev-parse`` and ``count-objects``.

Each ``cmd_*`` function takes a :class:`~gitrepo.repository.Repository` and
the argument tokens and returns the exact output bytes, or raises
:class:`~gitrepo.errors.GitRepoError`.  :func:`run_command` dispatches a whole
command line and turns every failure into ``b"error\\n"``.
"""

from __future__ import annotations

from .diff import diff_trees
from .errors import CommandError, CorruptObjectError, GitRepoError, RevisionError
from .history import walk
from .objects import S_IFDIR, S_IFMT
from .quoting import quote_path
from .repository import Repository

ERROR_OUTPUT = b"error\n"


def cmd_rev_parse(repo: Repository, args: list[bytes]) -> bytes:
    if len(args) != 1:
        raise CommandError("rev-parse takes one argument")
    return repo.rev_parse(args[0]).encode("ascii") + b"\n"


def cmd_count_objects(repo: Repository, args: list[bytes]) -> bytes:
    if args:
        raise CommandError("count-objects takes no arguments")
    odb = repo.odb
    return b"loose: %d\nin-pack: %d\npacks: %d\n" % (
        odb.loose_count, odb.packed_count, odb.pack_count)


def cmd_cat_file(repo: Repository, args: list[bytes]) -> bytes:
    if len(args) != 1:
        raise CommandError("cat-file takes one argument")
    kind, payload = repo.odb.read_verified(repo.rev_parse(args[0]))
    return b"%s %d\n" % (kind.encode("ascii"), len(payload)) + payload


def cmd_log(repo: Repository, args: list[bytes]) -> bytes:
    if len(args) not in (1, 2):
        raise CommandError("log takes a revision and an optional count")
    limit = None
    if len(args) == 2:
        if not args[1].isdigit() or not args[1].isascii():
            raise CommandError("count must be decimal digits")
        limit = int(args[1])
    start = repo.peel(repo.rev_parse(args[0]), "commit")
    out = bytearray()
    for oid, commit in walk(repo, start, limit):
        out += b"%s %s %d %s\n" % (oid.encode("ascii"), commit.author_name,
                                   commit.author_time, commit.subject)
    return bytes(out)


def _valid_path(path: bytes) -> bool:
    return all(part not in (b"", b".", b"..") for part in path.split(b"/"))


def cmd_ls_tree(repo: Repository, args: list[bytes]) -> bytes:
    if len(args) not in (1, 2):
        raise CommandError("ls-tree takes a revision and an optional path")
    if len(args) == 2 and not _valid_path(args[1]):
        raise CommandError("invalid path")
    tree = repo.peel(repo.rev_parse(args[0]), "tree")
    if len(args) == 2:
        for part in args[1].split(b"/"):
            for entry in repo.tree(tree):
                if entry.name == part:
                    break
            else:
                raise CommandError("no such path")
            if entry.mode & S_IFMT != S_IFDIR:
                raise CommandError("not a tree")
            tree = entry.id
    out = bytearray()
    for entry in repo.tree(tree):
        out += b"%06o %s %s\t%s\n" % (entry.mode, entry.type.encode("ascii"),
                                      entry.id.encode("ascii"), quote_path(entry.name))
    return bytes(out)


def cmd_diff(repo: Repository, args: list[bytes]) -> bytes:
    if len(args) != 2:
        raise CommandError("diff takes two revisions")
    old = repo.peel(repo.rev_parse(args[0]), "tree")
    new = repo.peel(repo.rev_parse(args[1]), "tree")
    out = bytearray()
    for c in diff_trees(repo, old, new):
        out += b":%06o %06o %s %s %s\t%s\n" % (
            c.old_mode, c.new_mode, c.old_id.encode("ascii"), c.new_id.encode("ascii"),
            c.status.encode("ascii"), quote_path(c.path))
    return bytes(out)


COMMANDS = {
    b"log": cmd_log,
    b"ls-tree": cmd_ls_tree,
    b"cat-file": cmd_cat_file,
    b"diff": cmd_diff,
    b"rev-parse": cmd_rev_parse,
    b"count-objects": cmd_count_objects,
}


def run_command(repo: Repository, line: bytes) -> bytes:
    """Execute one command *line* and return its output (``b"error\\n"`` on failure)."""
    tokens = line.split(b" ")
    if any(t == b"" for t in tokens):
        return ERROR_OUTPUT
    handler = COMMANDS.get(tokens[0])
    if handler is None:
        return ERROR_OUTPUT
    try:
        return handler(repo, tokens[1:])
    except (GitRepoError, RecursionError):
        return ERROR_OUTPUT
