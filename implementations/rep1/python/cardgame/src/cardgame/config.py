"""Match configuration (the setup block of a match file, SPEC 4.1)."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Config:
    """Everything the setup block can specify."""

    cards: str = ""
    seed: int = 0
    spire: int = 25
    opening: int = 5
    maxcap: int = 10
    handmax: int = 7
    turnlimit: int = 200
    first: str = "A"
    shuffle: bool = True
    trace: str = "none"
    cap: dict = field(default_factory=lambda: {"A": 0, "B": 0})
    # zone name -> player name -> list of (card id, count) in line order
    zones: dict = field(default_factory=lambda: {
        z: {"A": [], "B": []} for z in ("DECK", "HAND", "FIELD", "ASH", "RIFT")
    })
