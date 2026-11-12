"""Shared fixtures: a tiny card database the tests can rely on."""

from __future__ import annotations

import pytest

MINI_DB = """\
; A small database for the project's own tests.
(card TST-001 (name "Runner") (type unit) (cost 1) (body 2 1)
  (tags test) (keywords vanguard))
(card TST-002 (name "Bolt") (type rite) (cost 1) (tags test) (keywords swift)
  (resolve (targets (any)) (damage 2 (t 1))))
(card TST-003 (name "Scholar") (type unit) (cost 2) (body 1 1)
  (on arrive (draw 1 you)))
(card TST-004 (name "Banner") (type relic) (cost 2)
  (aura (modify 1 0 (units yours))))
(card TST-005 (name "Deathless") (type unit) (cost 3) (body 3 3)
  (keywords tenacity))
(card TST-006 (name "Duelist") (type unit) (cost 2) (body 2 1)
  (keywords riposte))
(card TST-007 (name "Smite") (type rite) (cost 2) (tags test)
  (resolve (targets (unit)) (destroy (t 1))))
(card TST-008 (name "Conjurer") (type unit) (cost 3) (body 1 3)
  (act (cost (ember 1) (exhaust)) (summon TST-001 1 you)))
"""


@pytest.fixture
def db_path(tmp_path):
    path = tmp_path / "mini.spire"
    path.write_text(MINI_DB, encoding="utf-8")
    return str(path)


@pytest.fixture
def match(db_path):
    """Build match-file text: ``match("HAND A TST-002", "A PASS", ...)``."""

    def build(setup: str = "", script: str = "") -> str:
        extra = [ln for ln in setup.splitlines() if ln.strip()]
        words = {ln.split()[0] for ln in extra}
        head = ["CARDS " + db_path, "SEED 1"]
        for default in ("SPIRE 10", "OPENING 0", "SHUFFLE off"):
            if default.split()[0] not in words:
                head.append(default)
        return "\n".join(head + extra + ["START"] + script.splitlines()) + "\n"

    return build
