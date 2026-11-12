import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from dbbuilder import DbBuilder  # noqa: E402

from sqlitefile import Database  # noqa: E402

PEOPLE_SQL = (
    "CREATE TABLE people(\n    id INTEGER PRIMARY KEY,\n    name TEXT NOT NULL,\n"
    "    age INTEGER,\n    height REAL,\n    photo BLOB)"
)

PEOPLE_ROWS = [
    (1, [None, "Ada", 36, 1.65, b"\x00\x01\x02"]),
    (2, [None, "Grace", 45, 1.7, None]),
    (3, [None, "Alan", None, 1.8, b""]),
    (6, [None, "", 0, 0, b"\x7f"]),  # 0 stored as an integer in a REAL column
]


@pytest.fixture
def mini_bytes() -> bytes:
    b = DbBuilder(4096)
    b.add_table("people", PEOPLE_SQL, PEOPLE_ROWS)
    entries = sorted(
        ([r[2], rowid] for rowid, r in PEOPLE_ROWS if r[2] is not None), key=lambda e: e
    )
    b.add_index("people_age", "people", "CREATE INDEX people_age ON people(age)", entries)
    return b.build()


@pytest.fixture
def mini(mini_bytes) -> Database:
    return Database(mini_bytes)
