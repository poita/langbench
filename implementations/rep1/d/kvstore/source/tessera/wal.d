/// Write-ahead log records, and recovery of the committed prefix of a log.
module tessera.wal;

import tessera.bytes;
import tessera.constants;
import tessera.crc;

/// The log's record types.
enum ubyte recordPage = 1, recordCommit = 2;

/// The 32-byte log header.
ubyte[] makeWalHeader() pure nothrow @safe
{
    auto h = new ubyte[walHeaderSize];
    h[0 .. 8] = ['T', 'E', 'S', 'S', 'W', 'A', 'L', '1'];
    setU16(h, 8, 1);
    setU16(h, 10, cast(uint) pageSize);
    setU32(h, 28, crc32(h[0 .. 28]));
    return h;
}

private void appendRecord(ref ByteBuffer wal, ubyte type, ulong txn, uint arg, const(ubyte)[] payload)
    pure nothrow @safe
{
    ubyte[walRecordHeader] hdr;
    hdr[0] = type;
    setU64(hdr[], 4, txn);
    setU32(hdr[], 12, arg);
    setU32(hdr[], 16, cast(uint) payload.length);
    Crc32 c;
    c.put(hdr[0 .. 20]);
    c.put(payload);
    setU32(hdr[], 20, c.value);
    wal.put(hdr[]);
    wal.put(payload);
}

/// Append a page-image record.
void appendPageImage(ref ByteBuffer wal, ulong txn, uint page, const(ubyte)[] image) pure nothrow @safe
{
    appendRecord(wal, recordPage, txn, page, image);
}

/// Append a commit record.
void appendCommit(ref ByteBuffer wal, ulong txn, uint frames) pure nothrow @safe
{
    appendRecord(wal, recordCommit, txn, frames, null);
}

/// What recovery makes of an input log.
struct Recovered
{
    /// The log to continue with: the valid prefix, or a fresh header.
    ByteBuffer wal;
    /// Newest committed image of each page the log holds.
    ubyte[][uint] overlay;
}

private bool headerValid(const(ubyte)[] w) pure nothrow @safe
{
    if (w.length < walHeaderSize)
        return false;
    if (w[0 .. 8] != cast(const(ubyte)[]) "TESSWAL1")
        return false;
    if (getU16(w, 8) != 1 || getU16(w, 10) != pageSize)
        return false;
    foreach (b; w[12 .. 28])
        if (b != 0)
            return false;
    return getU32(w, 28) == crc32(w[0 .. 28]);
}

/// Scan a log: replay every transaction whose commit record is intact and
/// trim the log after the last such record.
Recovered recoverLog(const(ubyte)[] input) pure nothrow @safe
{
    Recovered r;
    if (!headerValid(input))
    {
        r.wal.put(makeWalHeader());
        return r;
    }
    size_t off = walHeaderSize;
    size_t validEnd = walHeaderSize;
    bool open = false;
    ulong groupTxn;
    struct Img
    {
        uint page;
        const(ubyte)[] bytes;
    }

    Img[] group;
    scan: while (true)
    {
        immutable rem = input.length - off;
        if (rem < walRecordHeader)
            break;
        auto h = input[off .. off + walRecordHeader];
        immutable type = h[0];
        if (type != recordPage && type != recordCommit)
            break;
        if (h[1] != 0 || h[2] != 0 || h[3] != 0)
            break;
        immutable txn = getU64(h, 4);
        immutable arg = getU32(h, 12);
        immutable plen = getU32(h, 16);
        if (type == recordPage ? plen != pageSize : plen != 0)
            break;
        if (arg < 1)
            break;
        if (rem < walRecordHeader + plen)
            break;
        auto payload = input[off + walRecordHeader .. off + walRecordHeader + plen];
        Crc32 c;
        c.put(h[0 .. 20]);
        c.put(payload);
        if (c.value != getU32(h, 20))
            break;
        if (type == recordPage)
        {
            if (open && groupTxn != txn)
                break scan;
            if (!open)
            {
                open = true;
                groupTxn = txn;
            }
            group ~= Img(arg, payload);
            off += walRecordHeader + plen;
        }
        else
        {
            if (!open || groupTxn != txn || group.length != arg)
                break;
            foreach (ref g; group)
                r.overlay[g.page] = g.bytes.dup;
            group.length = 0;
            open = false;
            off += walRecordHeader;
            validEnd = off;
        }
    }
    r.wal.put(input[0 .. validEnd]);
    return r;
}
