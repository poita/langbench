"""The error type raised by every failing operation (SPEC §18)."""

KINDS = (
    "syntax", "unknown-command", "bad-utf8", "int-range", "dup-field", "depth",
    "bad-key", "bad-path", "not-found", "no-field", "not-object",
    "doc-too-large", "index-key-too-long", "index-exists", "index-missing",
    "index-limit", "txn-active", "no-txn",
)


class TesseraError(Exception):
    """A command or API call failed.

    ``kind`` is one of the error kinds of SPEC §18.1 (for example
    ``"not-found"``). A failing operation never modifies the database.
    """

    def __init__(self, kind: str, detail: str = ""):
        super().__init__(f"{kind}: {detail}" if detail else kind)
        self.kind = kind
