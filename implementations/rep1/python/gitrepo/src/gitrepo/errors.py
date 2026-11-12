"""Exception hierarchy for :mod:`gitrepo`.

Every failure the library can report derives from :class:`GitRepoError`, so
callers can catch that one class.
"""


class GitRepoError(Exception):
    """Base class of every error raised by this package."""


class CorruptObjectError(GitRepoError):
    """An object, pack, index or compressed stream is damaged."""


class ObjectNotFoundError(GitRepoError):
    """An object id is not present in the repository."""


class RevisionError(GitRepoError):
    """A revision expression could not be resolved."""


class CommandError(GitRepoError):
    """A query was malformed (unknown command, bad arguments, ...)."""
