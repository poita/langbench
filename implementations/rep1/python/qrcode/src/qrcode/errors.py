"""Exceptions raised by the :mod:`qrcode` package."""


class QrError(Exception):
    """Base class for all errors raised by this package."""


class DataTooLongError(QrError, ValueError):
    """The payload does not fit in any version (1..40) at the requested level."""


class InvalidQueryError(QrError, ValueError):
    """A CLI query line is malformed."""
