module tests.database_test;

import std.algorithm.sorting : sort;
import std.array : array, replicate;
import std.conv : to;
import std.random : Mt19937, uniform;

import tessera.ast;
import tessera.bytes;
import tessera.database;
import tessera.errors;
import tessera.indexing;
import tessera.lexer : CmpOp;
import tessera.parser;
import tessera.value;

private ErrorKind failureOf(scope void delegate() body)
{
    try
        body();
    catch (TesseraException e)
        return e.kind;
    assert(false, "expected a TesseraException");
}

private Value intObject(string field, long n)
{
    return Value.object([field], [Value.integer(n)]);
}

private Value bigDoc(size_t bytes)
{
    // A string document whose serialised size is `bytes` (>= 5).
    return Value.string_("x".replicate(bytes - 5));
}

unittest
{
    auto db = new Database();
    assert(db.put("a", Value.integer(1)));
    assert(!db.put("a", Value.integer(2)));
    assert(db.get("a").num == 2);
    assert(db.contains("a") && !db.contains("b"));
    assert(failureOf({ db.get("b"); }) == ErrorKind.notFound);
    assert(failureOf({ db.remove("b"); }) == ErrorKind.notFound);
    db.remove("a");
    assert(db.stat().docs == 0 && db.stat().root == 0 && db.stat().height == 0);
    assert(failureOf({ db.put("", Value.integer(1)); }) == ErrorKind.badKey);
    assert(failureOf({ db.put("k".replicate(129), Value.integer(1)); }) == ErrorKind.badKey);
}

unittest
{
    // Overflow chains: the page budget of §9 and the free-list order of §14.3.
    auto db = new Database();
    db.put("a", bigDoc(2005)); // chunks of 1012 and 801 on pages 2 and 3, leaf on page 4
    auto st = db.stat();
    assert(st.pages == 4 && st.root == 4);
    db.put("a", bigDoc(2005)); // frees 2 then 3, then reallocates 3 then 2
    st = db.stat();
    assert(st.pages == 4 && st.freePages == 0);
    assert(db.get("a").str.length == 2000);
    db.remove("a"); // chain pages 3,2 freed in chain order, then the leaf page 4
    st = db.stat();
    assert(st.freePages == 3 && st.freeHead == 4);
    // Documents at the size limit.
    db.put("max", bigDoc(maxDocBytes));
    assert(db.get("max").str.length == maxDocBytes - 5);
    assert(failureOf({ db.put("big", bigDoc(maxDocBytes + 1)); }) == ErrorKind.docTooLarge);
}

private enum maxDocBytes = 65_536;

unittest
{
    // Failed writes leave the database byte-identical.
    auto db = new Database();
    db.put("a", Value.object(["name"], [Value.string_("x")]));
    db.createIndex(["name"]);
    auto before = db.logBytes.dup;
    auto stat = db.stat();
    assert(failureOf({ db.put("b", bigDoc(maxDocBytes + 1)); }) == ErrorKind.docTooLarge);
    auto longName = Value.object(["name"], [Value.string_("x".replicate(200))]);
    assert(failureOf({ db.put("b", longName); }) == ErrorKind.indexKeyTooLong);
    assert(failureOf({ db.update("a", ["name"], Value.string_("x".replicate(200))); }) == ErrorKind.indexKeyTooLong);
    assert(failureOf({ db.update("a", ["name", "x"], Value.integer(1)); }) == ErrorKind.notObject);
    assert(failureOf({ db.unset("a", ["nope"]); }) == ErrorKind.noField);
    assert(failureOf({ db.createIndex(["name"]); }) == ErrorKind.indexExists);
    assert(failureOf({ db.dropIndex(["nope"]); }) == ErrorKind.indexMissing);
    assert(db.logBytes == before);
    assert(db.stat() == stat);
}

unittest
{
    // Index key at exactly 128 bytes is accepted; one more is not.
    auto db = new Database();
    db.createIndex(["s"]);
    // key "k" (1 byte): 3 + S + 1 = 128 -> S = 124
    db.put("k", Value.object(["s"], [Value.string_("y".replicate(124))]));
    assert(failureOf({ db.put("k", Value.object(["s"], [Value.string_("y".replicate(125))])); })
            == ErrorKind.indexKeyTooLong);
    // NUL bytes in the string count twice.
    assert(failureOf({ db.put("k", Value.object(["s"], [Value.string_("\u0000" ~ "y".replicate(123))])); })
            == ErrorKind.indexKeyTooLong);
}

unittest
{
    // Index maintenance: put, update, unset, delete keep entries exact.
    auto db = new Database();
    db.createIndex(["age"]);
    db.put("u1", intObject("age", 36));
    db.put("u2", intObject("age", 29));
    db.put("u3", Value.object(["age"], [Value.list([])])); // lists are not indexed
    db.put("u4", Value.object(["name"], [Value.string_("x")])); // missing path
    assert(db.indexes()[0].entries == 2);
    db.update("u2", ["age"], Value.integer(40));
    assert(db.indexes()[0].entries == 2);
    db.unset("u1", ["age"]);
    assert(db.indexes()[0].entries == 1);
    db.update("u4", ["age"], Value.nullValue());
    assert(db.indexes()[0].entries == 2);
    db.remove("u2");
    assert(db.indexes()[0].entries == 1);
    // Dropping an index frees its pages and zeroes the slot.
    assert(db.dropIndex(["age"]) == 1);
    assert(db.indexes().length == 0);
}

unittest
{
    // Index slots: lowest unused slot is reused and never renumbered.
    auto db = new Database();
    db.createIndex(["a"]);
    db.createIndex(["b"]);
    db.dropIndex(["a"]);
    db.createIndex(["c"]);
    auto ix = db.indexes();
    assert(ix.length == 2 && ix[0].slot == 0 && ix[0].path == "c" && ix[1].slot == 1 && ix[1].path == "b");
    foreach (i; 0 .. 14)
        db.createIndex(["x" ~ cast(char)('a' + i)]);
    assert(failureOf({ db.createIndex(["overflow"]); }) == ErrorKind.indexLimit);
}

private Pred pred(string text)
{
    return parseCommand("find " ~ text).pred;
}

unittest
{
    // Plan selection (§17.3).
    auto db = new Database();
    db.createIndex(["b"]);
    db.createIndex(["a"]);
    db.createIndex(["c"]);
    assert(db.find(pred("a != 1")).plan == "scan");
    assert(db.find(pred("a == [1]")).plan == "scan");
    assert(db.find(pred("a < 5")).plan == "index a");
    assert(db.find(pred("b < 5 and a < 5")).plan == "index a");
    assert(db.find(pred("a < 5 and b == 5")).plan == "index b");
    assert(db.find(pred("c == 1 and b == 1")).plan == "index b");
    assert(db.find(pred("(a == 1 and c == 1) and b == 1")).plan == "index a");
    assert(db.find(pred("a == 1 or b == 1")).plan == "scan");
    assert(db.find(pred("not(a == 1)")).plan == "scan");
    assert(db.find(pred("z.a == 1")).plan == "scan");
}

unittest
{
    // Every operator gives the same answer with and without an index.
    auto plain = new Database();
    auto indexed = new Database();
    indexed.createIndex(["v"]);
    Value[] values = [Value.nullValue(), Value.boolean(false), Value.boolean(true), Value.integer(-3),
        Value.integer(0), Value.integer(7), Value.string_(""), Value.string_("a"), Value.string_("a\u0000b"),
        Value.string_("b"), Value.list([Value.integer(1)]), Value.object([], [])];
    foreach (i, v; values)
        foreach (db; [plain, indexed])
            db.put("k" ~ cast(char)('a' + i), Value.object(["v"], [v]));
    foreach (db; [plain, indexed])
        db.put("zz", Value.object(["w"], [Value.integer(1)]));
    foreach (op; ["==", "!=", "<", "<=", ">", ">="])
        foreach (v; values[0 .. 10])
        {
            auto rhs = renderLiteral(v);
            auto a = plain.find(pred("v " ~ op ~ " " ~ rhs));
            auto b = indexed.find(pred("v " ~ op ~ " " ~ rhs));
            assert(a.rows.length == b.rows.length, op ~ " " ~ rhs);
            foreach (i; 0 .. a.rows.length)
                assert(a.rows[i].key == b.rows[i].key);
            assert(a.plan == "scan");
            assert(b.plan == (op == "!=" ? "scan" : "index v"));
        }
}

private string renderLiteral(Value v)
{
    import tessera.render : renderToString;

    return renderToString(v);
}

unittest
{
    // find: limit applies after ordering by key.
    auto db = new Database();
    db.createIndex(["age"]);
    foreach (i; 0 .. 20)
        db.put("u" ~ cast(char)('a' + i), intObject("age", 20 - i));
    auto r = db.find(pred("age < 15"), 3);
    assert(r.plan == "index age" && r.rows.length == 3);
    assert(r.rows[0].key == "ug" && r.rows[1].key == "uh" && r.rows[2].key == "ui");
    assert(db.find(pred("age < 15"), 0).rows.length == 0);
}

/// A simple model: sorted keys with their integer values.
unittest
{
    // Randomised workload against a model: puts, replaces (with growing and
    // shrinking documents), deletes, scans, checkpoints and reopening.
    auto rng = Mt19937(12345);
    auto db = new Database();
    Value[string] model;
    string keyFor(uint n) { return "key-" ~ cast(char)('a' + n % 26) ~ cast(char)('a' + n / 26 % 26) ~ "-" ~ "p".replicate(n % 40); }

    foreach (step; 0 .. 6000)
    {
        immutable k = keyFor(uniform(0, 600, rng));
        immutable op = uniform(0, 10, rng);
        if (op < 6)
        {
            auto doc = Value.string_("v".replicate(uniform(0, 3) == 0 ? uniform(0, 3000, rng) : uniform(0, 60, rng)));
            db.put(k, doc);
            model[k] = doc;
        }
        else if (op < 9)
        {
            if (k in model)
            {
                db.remove(k);
                model.remove(k);
            }
            else
                assert(failureOf({ db.remove(k); }) == ErrorKind.notFound);
        }
        else if (step % 7 == 0)
            db.checkpoint();
        if (step % 500 == 499)
        {
            ScanOptions o;
            auto rows = db.scan(o);
            auto keys = model.keys;
            keys.sort!((a, b) => compareBytes(asBytes(a), asBytes(b)) < 0);
            assert(rows.length == keys.length);
            foreach (i, key; keys)
            {
                assert(rows[i].key == key);
                assert(valuesEqual(rows[i].doc, model[key]));
            }
            assert(db.stat().docs == keys.length);
            // The files round-trip.
            db = new Database(db.databaseBytes.dup, db.logBytes.dup);
        }
    }
    // Delete everything: every page ends up on the free list.
    foreach (k; model.keys)
        db.remove(k);
    auto st = db.stat();
    assert(st.docs == 0 && st.root == 0);
    assert(st.freePages + 1 == st.pages);
}

unittest
{
    // Index trees agree with the primary tree under churn.
    auto rng = Mt19937(99);
    auto db = new Database();
    db.createIndex(["n"]);
    long[string] model;
    foreach (step; 0 .. 4000)
    {
        immutable k = "doc" ~ cast(char)('a' + uniform(0, 26, rng)) ~ cast(char)('a' + uniform(0, 26, rng));
        if (uniform(0, 4, rng) == 0 && k in model)
        {
            db.remove(k);
            model.remove(k);
        }
        else
        {
            immutable n = uniform(-50, 50, rng);
            db.put(k, intObject("n", n));
            model[k] = n;
        }
    }
    assert(db.indexes()[0].entries == model.length);
    foreach (probe; [-50, -1, 0, 7, 49])
    {
        string[] want;
        foreach (k, n; model)
            if (n < probe)
                want ~= k;
        want.sort!((a, b) => compareBytes(asBytes(a), asBytes(b)) < 0);
        auto res = db.find(pred("n < " ~ probe.to!string));
        assert(res.plan == "index n");
        assert(res.rows.length == want.length);
        foreach (i, r; res.rows)
            assert(r.key == want[i]);
    }
}

unittest
{
    // Index key encoding (§14.1).
    assert(vkey(Value.nullValue()) == [0x10]);
    assert(vkey(Value.boolean(false)) == [0x20]);
    assert(vkey(Value.boolean(true)) == [0x21]);
    assert(vkey(Value.integer(0)) == [0x30, 0x80, 0, 0, 0, 0, 0, 0, 0]);
    assert(vkey(Value.integer(36)) == [0x30, 0x80, 0, 0, 0, 0, 0, 0, 0x24]);
    assert(vkey(Value.integer(-1)) == [0x30, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
    assert(vkey(Value.integer(long.min)) == [0x30, 0, 0, 0, 0, 0, 0, 0, 0]);
    assert(vkey(Value.integer(long.max)) == [0x30, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
    assert(vkey(Value.string_("")) == [0x40, 0, 0]);
    assert(vkey(Value.string_("ada")) == [0x40, 0x61, 0x64, 0x61, 0, 0]);
    assert(vkey(Value.string_("a\u0000b")) == [0x40, 0x61, 0, 0xff, 0x62, 0, 0]);
    assert(vkeyLength(vkey(Value.string_("a\u0000b")) ~ cast(ubyte[]) "key") == 7);
    assert(vkeyLength(vkey(Value.integer(5)) ~ cast(ubyte[]) "key") == 9);
    assert(vkeyLength(vkey(Value.nullValue()) ~ cast(ubyte[]) "key") == 1);
    auto k = makeIndexKey(intObject("age", 36), ["age"], asBytes("u1"));
    assert(k == [0x30, 0x80, 0, 0, 0, 0, 0, 0, 0x24, 0x75, 0x31]);
    assert(makeIndexKey(Value.object(["age"], [Value.list([])]), ["age"], asBytes("u1")) is null);
}
