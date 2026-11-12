/// The write-ahead log: record encoding and recovery scan (SPEC §15, §16).
module tessera.wal;

import tessera.bytes;
import tessera.constants;
import tessera.crc;

/// Size of the log header in bytes.
enum WAL_HEADER_SIZE = 32;
/// Size of a record header in bytes.
enum RECORD_HEADER_SIZE = 24;

/// Record types.
enum RecordType : ubyte
{
    pageImage = 1,
    commit = 2,
}

/// The constant 32-byte log header (SPEC §15.1).
ubyte[] walHeader() @safe pure nothrow
{
    auto h = new ubyte[WAL_HEADER_SIZE];
    h[0 .. 8] = cast(const(ubyte)[]) "TESSWAL1";
    putU16(h, 8, 1);
    putU16(h, 10, PAGE_SIZE);
    putU32(h, 28, crc32(h[0 .. 28]));
    return h;
}

/// Append one record to `log`. `field` is the page number of a page image or
/// the frame count of a commit record (SPEC §15.2).
void appendRecord(ref ubyte[] log, RecordType type, ulong txnId, uint field,
        const(ubyte)[] payload) @safe pure nothrow
{
    ubyte[RECORD_HEADER_SIZE] h;
    h[0] = type;
    putU64(h[], 4, txnId);
    putU32(h[], 12, field);
    putU32(h[], 16, cast(uint) payload.length);
    Crc32 c;
    c.put(h[0 .. 20]);
    c.put(payload);
    putU32(h[], 20, c.finish());
    log ~= h[];
    log ~= payload;
}

/// What recovery learned from an input log.
struct RecoveredLog
{
    /// The log as the engine continues with it: the valid prefix of the input,
    /// or a fresh header.
    ubyte[] log;
    /// Newest committed image of each page.
    ubyte[][uint] overlay;
}

/// Whether the first bytes of `data` form a valid log header (SPEC §16.2).
bool validHeader(const(ubyte)[] data) @safe pure nothrow
{
    if (data.length < WAL_HEADER_SIZE)
        return false;
    if (data[0 .. 8] != cast(const(ubyte)[]) "TESSWAL1")
        return false;
    if (getU16(data, 8) != 1 || getU16(data, 10) != PAGE_SIZE)
        return false;
    foreach (b; data[12 .. 28])
        if (b != 0)
            return false;
    return getU32(data, 28) == crc32(data[0 .. 28]);
}

/// Replay every committed transaction of `input` (SPEC §16.3, §16.4).
RecoveredLog recoverLog(const(ubyte)[] input) @safe pure
{
    RecoveredLog r;
    if (!validHeader(input))
    {
        r.log = walHeader();
        return r;
    }

    struct Image
    {
        uint page;
        const(ubyte)[] data;
    }

    Image[] group;
    bool open;
    ulong groupTxn;
    size_t off = WAL_HEADER_SIZE;
    size_t validEnd = off;

    scan: while (true)
    {
        immutable rem = input.length - off;
        if (rem < RECORD_HEADER_SIZE)
            break;
        immutable type = input[off];
        if (type != 1 && type != 2)
            break;
        if (input[off + 1] != 0 || input[off + 2] != 0 || input[off + 3] != 0)
            break;
        immutable txn = getU64(input, off + 4);
        immutable field = getU32(input, off + 12);
        immutable payloadLen = getU32(input, off + 16);
        if (type == 1 ? payloadLen != PAGE_SIZE : payloadLen != 0)
            break;
        if (field < 1)
            break;
        if (rem < RECORD_HEADER_SIZE + cast(size_t) payloadLen)
            break;
        Crc32 c;
        c.put(input[off .. off + 20]);
        c.put(input[off + RECORD_HEADER_SIZE .. off + RECORD_HEADER_SIZE + payloadLen]);
        if (c.finish() != getU32(input, off + 20))
            break;

        if (type == 1)
        {
            if (open && groupTxn != txn)
                break;
            if (!open)
            {
                open = true;
                groupTxn = txn;
            }
            group ~= Image(field, input[off + RECORD_HEADER_SIZE .. off + RECORD_HEADER_SIZE + PAGE_SIZE]);
            off += RECORD_HEADER_SIZE + PAGE_SIZE;
        }
        else
        {
            if (!open || groupTxn != txn || group.length != field)
                break;
            foreach (ref im; group)
                r.overlay[im.page] = im.data.dup;
            group.length = 0;
            open = false;
            off += RECORD_HEADER_SIZE;
            validEnd = off;
        }
    }
    r.log = input[0 .. validEnd].dup;
    return r;
}

@safe pure unittest
{
    // SPEC §15.1: the log header bytes
    auto h = walHeader();
    assert(h[28 .. 32] == [0x51, 0xe7, 0x21, 0x53]);
    assert(validHeader(h));
}

@safe pure unittest
{
    // a committed transaction survives; a trailing torn one is dropped
    auto page = new ubyte[PAGE_SIZE];
    page[5] = 7;
    ubyte[] log = walHeader();
    appendRecord(log, RecordType.pageImage, 1, 1, page);
    appendRecord(log, RecordType.commit, 1, 1, null);
    immutable good = log.length;
    appendRecord(log, RecordType.pageImage, 2, 1, page);
    auto r = recoverLog(log);
    assert(r.log.length == good);
    assert(r.overlay.length == 1 && r.overlay[1][5] == 7);

    // a damaged header discards everything
    log[3] ^= 1;
    auto bad = recoverLog(log);
    assert(bad.log.length == 32 && bad.overlay.length == 0);
    assert(recoverLog([]).log.length == 32);
}
