"""gitrepo: read a git repository straight off disk.

The object database, DEFLATE decompression and SHA-1 are all implemented in
this package; neither ``git`` nor ``zlib``/``hashlib`` is used.

Quick start::

    from gitrepo import Repository, run_command

    repo = Repository("project/.git")
    head = repo.rev_parse(b"HEAD")
    print(repo.commit(head).subject)
    print(run_command(repo, b"log HEAD 5").decode())
"""

from .commands import run_command
from .diff import Change, diff_trees, flatten
from .errors import (CommandError, CorruptObjectError, GitRepoError,
                     ObjectNotFoundError, RevisionError)
from .history import walk
from .inflate import inflate, zlib_decompress
from .objects import Commit, TreeEntry, parse_commit, parse_tree
from .odb import ObjectDatabase, hash_object
from .quoting import quote_path
from .repository import Repository
from .sha1 import Sha1, sha1_digest, sha1_hex

__all__ = [
    "Change", "CommandError", "Commit", "CorruptObjectError", "GitRepoError",
    "ObjectDatabase", "ObjectNotFoundError", "Repository", "RevisionError", "Sha1",
    "TreeEntry", "diff_trees", "flatten", "hash_object", "inflate", "parse_commit",
    "parse_tree", "quote_path", "run_command", "sha1_digest", "sha1_hex", "walk",
    "zlib_decompress",
]
__version__ = "1.0.0"
