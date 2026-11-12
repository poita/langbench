import pytest

from sqlitefile.ddl import parse_create_index, parse_create_table, tokenize


def alias_of(sql):
    t = parse_create_table(sql)
    return None if t.rowid_alias is None else t.columns[t.rowid_alias].name


def test_columns_and_types():
    t = parse_create_table(
        'CREATE TABLE IF NOT EXISTS main."t x"(a, [b c] NVARCHAR(160) NOT NULL, `d` NUMERIC(10,2) DEFAULT 1,'
        ' e INT, CHECK (e > 0), UNIQUE(a,[b c]))'
    )
    assert [(c.name, c.declared_type, c.affinity) for c in t.columns] == [
        ("a", "", "BLOB"),
        ("b c", "NVARCHAR ( 160 )", "TEXT"),
        ("d", "NUMERIC ( 10 , 2 )", "NUMERIC"),
        ("e", "INT", "INTEGER"),
    ]


def test_comments_and_escapes_are_handled():
    t = parse_create_table('CREATE TABLE t(/* x, y */ "a""b" TEXT, -- c, d\n e INTEGER DEFAULT \'x,y)\')')
    assert [c.name for c in t.columns] == ['a"b', "e"]


@pytest.mark.parametrize(
    "sql, alias",
    [
        ("CREATE TABLE t(id INTEGER PRIMARY KEY, x)", "id"),
        ("CREATE TABLE t(id integer PRIMARY KEY AUTOINCREMENT)", "id"),
        ("CREATE TABLE t(id INTEGER PRIMARY KEY DESC)", None),
        ("CREATE TABLE t(id INTEGER, PRIMARY KEY(id DESC))", "id"),
        ("CREATE TABLE t(id INTEGER NOT NULL, CONSTRAINT pk PRIMARY KEY ([id]))", "id"),
        ("CREATE TABLE t(id INT PRIMARY KEY)", None),
        ("CREATE TABLE t(id INTEGER(4) PRIMARY KEY)", None),
        ("CREATE TABLE t(a INTEGER, b INTEGER, PRIMARY KEY(a, b))", None),
        ("CREATE TABLE t(a INTEGER, UNIQUE(a))", None),
        ("CREATE TABLE t(a INTEGER CHECK (a > 0 /* primary key */))", None),
    ],
)
def test_rowid_alias(sql, alias):
    assert alias_of(sql) == alias


def test_create_index():
    idx = parse_create_index('CREATE UNIQUE INDEX IF NOT EXISTS "i" ON main.t (a COLLATE BINARY DESC, [b])')
    assert (idx.table, idx.columns, idx.unique) == ("t", ("a", "b"), True)


def test_tokenize_kinds():
    kinds = [t.kind for t in tokenize("a 'b' \"c\" [d] ( ;")]
    assert kinds == ["word", "string", "quoted", "quoted", "punct", "punct"]
