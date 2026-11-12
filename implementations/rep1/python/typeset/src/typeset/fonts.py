"""Font metric (``.cfm``) files and face resolution."""

from __future__ import annotations

import os
from dataclasses import dataclass, field

from .units import scale


def face_name(family: str, bold: bool, italic: bool) -> str:
    """Resolve (family, bold, italic) to a face name."""
    if family == "mono":
        return "mono"
    return family + ("-bold" if bold else "") + ("-italic" if italic else "")


def _clean_lines(text: str):
    for raw in text.split("\n"):
        line = raw.split("#", 1)[0].strip(" \t")
        if line:
            yield line.split()


@dataclass
class Face:
    """Metrics of one face; all numbers are glyph-space units (1/1000 em)."""

    name: str
    ascent: int = 0
    descent: int = 0
    space: int = 0
    stretch: int = 0
    shrink: int = 0
    extra: int = 0
    default: int = 0
    adv: dict[str, int] = field(default_factory=dict)
    kern: dict[str, int] = field(default_factory=dict)

    @property
    def is_mono(self) -> bool:
        return self.name == "mono"

    def units(self, text: str) -> int:
        """Advance of *text* in glyph units, with kerning (unscaled)."""
        adv = self.adv
        d = self.default
        total = 0
        for c in text:
            total += adv.get(c, d)
        kern = self.kern
        if kern and len(text) > 1:
            for i in range(len(text) - 1):
                total += kern.get(text[i:i + 2], 0)
        return total

    def width(self, text: str, size: int) -> int:
        """Width in millipoints of *text* at *size*: one ``scale`` of the sum."""
        return scale(self.units(text), size)

    def ascent_mp(self, size: int) -> int:
        return scale(self.ascent, size)

    def descent_mp(self, size: int) -> int:
        return scale(self.descent, size)


def parse_face(text: str) -> Face:
    """Parse the contents of a ``.cfm`` file."""
    face = Face(name="")
    for rec in _clean_lines(text):
        key, args = rec[0], rec[1:]
        if key == "face":
            face.name = args[0]
        elif key == "ascent":
            face.ascent = int(args[0])
        elif key == "descent":
            face.descent = int(args[0])
        elif key == "space":
            face.space, face.stretch, face.shrink = (int(a) for a in args[:3])
        elif key == "extra":
            face.extra = int(args[0])
        elif key == "default":
            face.default = int(args[0])
        elif key == "glyph":
            face.adv[chr(int(args[0]))] = int(args[1])
        elif key == "kern":
            face.kern[chr(int(args[0])) + chr(int(args[1]))] = int(args[2])
    return face


class FontLibrary:
    """Loads faces lazily from ``<data_dir>/faces/<face>.cfm``."""

    def __init__(self, data_dir: str = "data") -> None:
        self.data_dir = data_dir
        self._faces: dict[str, Face] = {}

    def get(self, name: str) -> Face:
        face = self._faces.get(name)
        if face is None:
            path = os.path.join(self.data_dir, "faces", name + ".cfm")
            with open(path, "rb") as fh:
                face = parse_face(fh.read().decode("utf-8"))
            if not face.name:
                face.name = name
            self._faces[name] = face
        return face

    def resolve(self, family: str, bold: bool = False, italic: bool = False) -> Face:
        return self.get(face_name(family, bold, italic))
