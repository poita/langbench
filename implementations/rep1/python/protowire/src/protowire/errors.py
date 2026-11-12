"""Exception types raised by the library."""


class ProtowireError(ValueError):
    """Raised when wire data or text-form input is malformed.

    The command-line tool turns this into the single output line ``error``.
    """


class SchemaError(ProtowireError):
    """Raised when a schema definition cannot be parsed or resolved."""
