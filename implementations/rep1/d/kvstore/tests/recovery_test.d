module tests.recovery_test;

import tessera.bytes;
import tessera.crc;
import tessera.database;
import tessera.header;
import tessera.interpreter;
import tessera.value;
import tessera.wal;

unittest
{
    // The fixed log header of the specification.
    static immutable ubyte[32] expected = [0x54, 0x45, 0x53, 0x53, 0x57, 0x41, 0x4c, 0x31, 0, 1, 4, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x51, 0xe7, 0x21, 0x53];
    assert(makeWalHeader() == expected[]);
}

unittest
{
    // The first commit of `put "a" 1` appends three records with these CRCs.
    auto db = new Database();
    db.put("a", Value.integer(1));
    auto log = db.logBytes;
    assert(log.length == 2152);
    assert(log[32 .. 56] == [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 4, 0, 0x76, 0x29, 0x2e, 0x36]);
    assert(log[1080 .. 1104] == [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 4, 0, 0x76, 0x0d, 0x60, 0xf7]);
    assert(log[2128 .. 2152] == [2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0xa8, 0xa0, 0xaa, 0x22]);
}

private ubyte[] twoCommits()
{
    auto db = new Database();
    db.put("a", Value.integer(1));
    db.put("b", Value.integer(2));
    return db.logBytes.dup;
}

unittest
{
    // A log cut anywhere keeps exactly the transactions whose commit survived.
    auto full = twoCommits();
    assert(full.length == 4272);
    foreach (cut; [0, 10, 31, 32, 55, 2151, 2152, 2153, 3000, 3199, 4247, 4271, 4272])
    {
        auto db = new Database(null, full[0 .. cut]);
        immutable expectDocs = cut >= 4272 ? 2 : (cut >= 2152 ? 1 : 0);
        assert(db.stat().docs == expectDocs);
        immutable expectLog = cut >= 4272 ? 4272 : (cut >= 2152 ? 2152 : 32);
        assert(db.logBytes.length == expectLog);
        assert(db.logBytes == full[0 .. expectLog] || expectLog == 32);
    }
}

unittest
{
    // A damaged header discards the whole log.
    auto full = twoCommits();
    foreach (damage; [0, 8, 9, 11, 12, 27, 28, 31])
    {
        auto bad = full.dup;
        bad[damage] ^= 1;
        auto db = new Database(null, bad);
        assert(db.stat().docs == 0);
        assert(db.logBytes == makeWalHeader());
    }
}

unittest
{
    // Corrupt records, interleaved transactions and bad frame counts stop the scan.
    auto full = twoCommits();
    auto flipped = full.dup;
    flipped[3000] ^= 0xff; // payload of transaction 2
    assert(new Database(null, flipped).stat().docs == 1);

    auto wrongFrames = full.dup;
    wrongFrames[2128 + 15] = 3; // transaction 1's commit claims 3 frames
    Crc32 c;
    c.put(wrongFrames[2128 .. 2148]);
    setU32(wrongFrames, 2148, c.value); // a valid CRC, so only the frame count is wrong
    assert(new Database(null, wrongFrames).stat().docs == 0);

    auto garbage = full ~ cast(ubyte[]) "trailing garbage that is not a record";
    auto db = new Database(null, garbage);
    assert(db.stat().docs == 2);
    assert(db.logBytes.length == 4272);
}

unittest
{
    // Recovery does not touch the main file; a checkpoint folds the log into it.
    auto full = twoCommits();
    auto db = new Database(null, full);
    assert(db.databaseBytes.length == 1024);
    assert(db.checkpoint() == 2);
    assert(db.databaseBytes.length == 2048);
    assert(db.logBytes == makeWalHeader());
    auto reopened = new Database(db.databaseBytes.dup, db.logBytes);
    assert(reopened.get("b").num == 2);
}

unittest
{
    // Main file and log round-trip through a fresh Database.
    auto db = new Database();
    foreach (i; 0 .. 50)
        db.put("key" ~ cast(char)('a' + i % 26) ~ cast(char)('A' + i / 26), Value.integer(i));
    auto copy = new Database(db.databaseBytes.dup, db.logBytes.dup);
    assert(copy.stat() == db.stat());
    assert(copy.logBytes == db.logBytes);
}
