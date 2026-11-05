/// End-to-end tests over small hand-assembled database images.
module test_database;

import dbbuilder;
import sqlitefile;

private enum uint ps = 512;

private string run(Database db, Catalog cat, string line) @trusted
{
    return cast(string) answer(db, cat, line);
}

private Value T(string s) @safe
{
    return Value.makeText(s);
}

private Value I(long i) @safe
{
    return Value.makeInt(i);
}

private Value R(double d) @safe
{
    return Value.makeReal(d);
}

/// people(id INTEGER PRIMARY KEY, name TEXT, age INTEGER, height REAL, photo BLOB) + index on age.
/// Page 1 schema, page 2 table, page 3 index.
private ubyte[] miniImage() @safe
{
    auto people = "CREATE TABLE people(\n id INTEGER PRIMARY KEY,\n name TEXT NOT NULL,\n age INTEGER,\n height REAL,\n photo BLOB)";
    auto idx = "CREATE INDEX people_age ON people(age)";
    auto schema = btreePage(ps, 0x0d, [
        tableLeafCell(1, schemaRow("table", "people", "people", 2, people)),
        tableLeafCell(2, schemaRow("index", "people_age", "people", 3, idx)),
        tableLeafCell(3, schemaRow("table", "sqlite_sequence", "sqlite_sequence", 4,
            "CREATE TABLE sqlite_sequence(name,seq)")),
        tableLeafCell(4, schemaRow("index", "sqlite_autoindex_people_1", "people", 5, null)),
    ], 0, 100);
    auto rows = btreePage(ps, 0x0d, [
        tableLeafCell(1, record([Value.makeNull(), T("Ada"), I(36), R(1.65), Value.makeBlob([0, 1, 2])])),
        tableLeafCell(2, record([Value.makeNull(), T("Grace"), I(45), R(1.7), Value.makeNull()])),
        tableLeafCell(3, record([Value.makeNull(), T("Alan"), Value.makeNull(), R(1.8), Value.makeBlob([])])),
        tableLeafCell(6, record([Value.makeNull(), T(""), I(0), I(0), Value.makeBlob([0x7f])])),
    ]);
    auto index = btreePage(ps, 0x0a, [
        indexLeafCell(record([Value.makeNull(), I(3)])),
        indexLeafCell(record([I(0), I(6)])),
        indexLeafCell(record([I(36), I(1)])),
        indexLeafCell(record([I(45), I(2)])),
    ]);
    auto seq = btreePage(ps, 0x0d, []);
    auto auto_ = btreePage(ps, 0x0a, []);
    return assemble(ps, [schema, rows, index, seq, auto_]);
}

@system unittest // the worked example of the spec
{
    auto db = new Database(miniImage());
    auto cat = Catalog.load(db);
    assert(run(db, cat, ".tables") == "people\n");
    assert(run(db, cat, "SELECT * FROM people") ==
        "1\tAda\t36\t1.65\t000102\n2\tGrace\t45\t1.7\tNULL\n3\tAlan\tNULL\t1.8\t\n6\t\t0\t0.0\t7F\n");
    assert(run(db, cat, "SELECT name,height FROM people ORDER BY height DESC LIMIT 2") == "Alan\t1.8\nGrace\t1.7\n");
    assert(run(db, cat, "SELECT name FROM people WHERE age IS NULL") == "Alan\n");
    assert(run(db, cat, "SELECT name FROM people WHERE age > 40") == "Grace\n");
    assert(run(db, cat, "SELECT rowid,name FROM people WHERE photo IS NOT NULL") == "1\tAda\n3\tAlan\n6\t\n");
    assert(run(db, cat, "INDEX people_age 45") == "2\tGrace\t45\t1.7\tNULL\n");
    assert(run(db, cat, "INDEX people_age '36'") == "1\tAda\t36\t1.65\t000102\n");
    assert(run(db, cat, "INDEX people_age NULL") == "");
    assert(run(db, cat, "INDEX people_age 7") == "");
    assert(run(db, cat, "COUNT people") == "4\n");
    assert(run(db, cat, "SELECT nope FROM people") == "error\n");
}

@system unittest // ordering, ties and limits
{
    auto db = new Database(miniImage());
    auto cat = Catalog.load(db);
    assert(run(db, cat, "SELECT id FROM people ORDER BY age") == "3\n6\n1\n2\n");
    assert(run(db, cat, "SELECT id FROM people ORDER BY age DESC") == "2\n1\n6\n3\n");
    assert(run(db, cat, "SELECT id FROM people LIMIT 0") == "");
    assert(run(db, cat, "SELECT id FROM people LIMIT 2") == "1\n2\n");
    assert(run(db, cat, "SELECT id FROM people WHERE height = 0") == "6\n");
    assert(run(db, cat, "SELECT id FROM people WHERE age >= '36'") == "1\n2\n");
    assert(run(db, cat, "SELECT id FROM people WHERE name < 'B' AND age IS NOT NULL") == "1\n6\n");
}

@system unittest // schema listing and error cases
{
    auto db = new Database(miniImage());
    auto cat = Catalog.load(db);
    assert(run(db, cat, ".schema people") ==
        "CREATE TABLE people(\n id INTEGER PRIMARY KEY,\n name TEXT NOT NULL,\n age INTEGER,\n height REAL,\n photo BLOB);\n"
        ~ "CREATE INDEX people_age ON people(age);\n");
    assert(run(db, cat, ".schema people_age") == "");
    assert(run(db, cat, ".schema nothing") == "");
    assert(run(db, cat, "SELECT * FROM people_age") == "error\n");
    assert(run(db, cat, "SELECT * FROM sqlite_schema") == "error\n");
    assert(run(db, cat, "INDEX sqlite_autoindex_people_1 1") == "error\n");
    assert(run(db, cat, "INDEX people 1") == "error\n");
    assert(run(db, cat, "COUNT people_age") == "error\n");
    assert(run(db, cat, "COUNT sqlite_sequence") == "0\n");
}

/// A two-level table (interior page 2 over leaves 3 and 4) and a two-level
/// index (interior page 5 over leaves 6 and 7) with duplicate keys, whose
/// interior cells carry real entries.
private ubyte[] treeImage() @safe
{
    auto schema = btreePage(ps, 0x0d, [
        tableLeafCell(1, schemaRow("table", "t", "t", 2, "CREATE TABLE t(k INTEGER PRIMARY KEY, g INT)")),
        tableLeafCell(2, schemaRow("index", "tg", "t", 5, "CREATE INDEX tg ON t(g)")),
    ], 0, 100);
    auto interior = btreePage(ps, 0x05, [tableInteriorCell(3, 2)], 4);
    auto leafA = btreePage(ps, 0x0d, [
        tableLeafCell(1, record([Value.makeNull(), I(7)])),
        tableLeafCell(2, record([Value.makeNull(), I(5)])),
    ]);
    auto leafB = btreePage(ps, 0x0d, [
        tableLeafCell(3, record([Value.makeNull(), I(7)])),
        tableLeafCell(4, record([Value.makeNull(), I(9)])),
    ]);
    // index entries sorted by (g, rowid): (5,2) (7,1) (7,3) (9,4); interior holds (7,1)
    auto idxInterior = btreePage(ps, 0x02, [indexInteriorCell(6, record([I(7), I(1)]))], 7);
    auto idxA = btreePage(ps, 0x0a, [indexLeafCell(record([I(5), I(2)]))]);
    auto idxB = btreePage(ps, 0x0a, [indexLeafCell(record([I(7), I(3)])), indexLeafCell(record([I(9), I(4)]))]);
    return assemble(ps, [schema, interior, leafA, leafB, idxInterior, idxA, idxB]);
}

@system unittest // multi-level trees
{
    auto db = new Database(treeImage());
    auto cat = Catalog.load(db);
    assert(run(db, cat, "SELECT * FROM t") == "1\t7\n2\t5\n3\t7\n4\t9\n");
    assert(run(db, cat, "COUNT t") == "4\n");
    assert(run(db, cat, "INDEX tg 7") == "1\t7\n3\t7\n");
    assert(run(db, cat, "INDEX tg 5") == "2\t5\n");
    assert(run(db, cat, "INDEX tg 9") == "4\t9\n");
    assert(run(db, cat, "INDEX tg 8") == "");
    assert(run(db, cat, "SELECT k FROM t WHERE g = 7 LIMIT 1") == "1\n");
}

/// Table with one payload that spills into an overflow chain.
private ubyte[] overflowImage(out ubyte[] blob) @safe
{
    // table leaf: U = 512, X = 477, M = (500*32/255)-23 = 39
    blob = new ubyte[1500];
    foreach (i, ref b; blob)
        b = cast(ubyte)(i * 7 + 3);
    auto payload = record([Value.makeBlob(blob)]);
    immutable U = ps;
    immutable m = (U - 12) * 32 / 255 - 23;
    immutable x = U - 35;
    assert(payload.length > x);
    immutable k = m + (payload.length - m) % (U - 4);
    immutable local = k <= x ? k : m;
    // overflow pages: 4 bytes next + up to 508 bytes
    ubyte[][] chunks;
    auto rest = payload[local .. $];
    while (rest.length)
    {
        auto n = rest.length < U - 4 ? rest.length : U - 4;
        chunks ~= rest[0 .. n];
        rest = rest[n .. $];
    }
    ubyte[][] ovf;
    foreach (i, c; chunks)
    {
        auto page = new ubyte[ps];
        page[0 .. 4] = be32(i + 1 < chunks.length ? cast(uint)(4 + i + 1) : 0);
        page[4 .. 4 + c.length] = c[];
        ovf ~= page;
    }
    auto cell = varint(payload.length) ~ varint(1) ~ payload[0 .. local] ~ be32(4);
    auto schema = btreePage(ps, 0x0d, [
        tableLeafCell(1, schemaRow("table", "b", "b", 2, "CREATE TABLE b(x BLOB)")),
    ], 0, 100);
    auto leaf = btreePage(ps, 0x0d, [cell]);
    return assemble(ps, [schema, leaf, new ubyte[ps]] ~ ovf)[0 .. $];
}

@system unittest // overflow chains
{
    // page 3 is a filler so that the chain starts at page 4
    ubyte[] blob;
    auto img = overflowImage(blob);
    auto db = new Database(img);
    auto cat = Catalog.load(db);
    auto got = run(db, cat, "SELECT x FROM b");
    string want;
    enum hex = "0123456789ABCDEF";
    foreach (b; blob)
        want ~= hex[b >> 4 .. (b >> 4) + 1] ~ hex[b & 15 .. (b & 15) + 1];
    assert(got == want ~ "\n", "overflow blob mismatch");
    // ORDER BY copies the value out of the shared scratch buffer
    assert(run(db, cat, "SELECT x FROM b ORDER BY x") == want ~ "\n");
}

@system unittest // a damaged file yields errors, not crashes
{
    import std.exception : assertThrown;

    assertThrown!FormatException(new Database(new ubyte[50]));
    auto img = miniImage();
    img[0] = 'X';
    assertThrown!FormatException(new Database(img));
}
