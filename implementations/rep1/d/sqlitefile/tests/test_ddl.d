/// Unit tests for the CREATE TABLE / CREATE INDEX parser.
module test_ddl;

import sqlitefile;

@safe unittest // tokenizer
{
    auto t = tokenize(`CREATE TABLE "a""b" ([c d] int, /* x */ e -- y
        )`);
    assert(t[2].kind == TokenKind.quoted && t[2].text == `a"b`);
    assert(t[4].text == "c d");
    assert(t[$ - 1].text == ")");
}

@safe unittest // columns, types and affinities
{
    auto d = parseCreateTable("CREATE TABLE IF NOT EXISTS main.t(a NVARCHAR(160) NOT NULL, b NUMERIC(10,2), c, d UNSIGNED BIG INT DEFAULT 5)");
    assert(d.name == "t");
    assert(d.columns.length == 4);
    assert(d.columns[0].name == "a" && d.columns[0].affinity == Affinity.text);
    assert(d.columns[1].affinity == Affinity.numeric);
    assert(d.columns[2].declaredType == "" && d.columns[2].affinity == Affinity.blob);
    assert(d.columns[3].affinity == Affinity.integer);
    assert(d.rowidAlias == -1);
}

@safe unittest // rowid alias rules
{
    assert(parseCreateTable("CREATE TABLE t(id INTEGER PRIMARY KEY, x)").rowidAlias == 0);
    assert(parseCreateTable("CREATE TABLE t(x, id integer primary key autoincrement)").rowidAlias == 1);
    assert(parseCreateTable("CREATE TABLE t(id INTEGER PRIMARY KEY DESC, x)").rowidAlias == -1);
    assert(parseCreateTable("CREATE TABLE t(id INTEGER, PRIMARY KEY(id DESC))").rowidAlias == 0);
    assert(parseCreateTable("CREATE TABLE t([AlbumId] INTEGER NOT NULL, CONSTRAINT [PK] PRIMARY KEY ([AlbumId]))").rowidAlias == 0);
    assert(parseCreateTable("CREATE TABLE t(code INT PRIMARY KEY, x)").rowidAlias == -1);
    assert(parseCreateTable("CREATE TABLE t(a INTEGER, b INTEGER, PRIMARY KEY(a, b))").rowidAlias == -1);
    assert(parseCreateTable("CREATE TABLE t(a INTEGER(5) PRIMARY KEY)").rowidAlias == -1);
}

@safe unittest // table constraints are not columns; parentheses and commas nest
{
    auto d = parseCreateTable("CREATE TABLE t(a, b, UNIQUE(a, b), CHECK(a > 0 AND b IN (1,2)), FOREIGN KEY(a) REFERENCES u(x, y))");
    assert(d.columns.length == 2);
}

@safe unittest // indexes
{
    auto d = parseCreateIndex(`CREATE UNIQUE INDEX IF NOT EXISTS "ix one" ON t(a COLLATE BINARY DESC, [b])`);
    assert(d.name == "ix one");
    assert(d.table == "t");
    assert(d.columns == ["a", "b"]);
}

@safe unittest // errors
{
    import std.exception : assertThrown;

    assertThrown!FormatException(parseCreateTable("CREATE VIEW v AS SELECT 1"));
    assertThrown!FormatException(parseCreateTable("CREATE TABLE t(a"));
    assertThrown!FormatException(parseCreateIndex("CREATE TABLE t(a)"));
}
