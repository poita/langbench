"""The in-memory value tree shared by the decoder, encoder and text codecs."""

from __future__ import annotations

from typing import Any

from .schema import MessageDesc


class Message:
    """One message instance.

    ``values`` maps a field number to its value; a field that is absent has no
    entry. Value representation by field shape:

    * singular scalar: ``int``, ``bool``, ``str`` or ``bytes``
    * singular message: a nested :class:`Message` (present even when empty)
    * repeated field: a ``list`` of the element values above
    """

    __slots__ = ("desc", "values")

    def __init__(self, desc: MessageDesc, values: dict[int, Any] | None = None):
        self.desc = desc
        self.values: dict[int, Any] = {} if values is None else values

    def __getitem__(self, name: str) -> Any:
        """Return the value of field ``name``; raise ``KeyError`` if absent."""
        return self.values[self.desc.by_name[name].number]

    def get(self, name: str, default: Any = None) -> Any:
        """Return the value of field ``name`` or ``default`` if it is absent."""
        fd = self.desc.by_name[name]
        return self.values.get(fd.number, default)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Message):
            return NotImplemented
        return self.desc is other.desc and self.values == other.values

    __hash__ = None  # type: ignore[assignment]

    def __repr__(self) -> str:
        names = {fd.number: fd.name for fd in self.desc.fields}
        body = ", ".join(f"{names[n]}={v!r}" for n, v in sorted(self.values.items()))
        return f"{self.desc.name}({body})"
