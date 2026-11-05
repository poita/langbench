/// The page store: main file, log overlay and the open transaction's dirty
/// pages, plus the free list, commit and checkpoint.
module tessera.pager;

import std.algorithm.sorting : sort;

import tessera.bytes;
import tessera.constants;
import tessera.header;
import tessera.wal;

/// Result of a commit.
struct CommitInfo
{
    /// The new commit counter.
    ulong txnId;
    /// Number of page-image records appended.
    uint frames;
}

/// Page access with three layers (dirty set, log overlay, main file).
final class Pager
{
    private ubyte[] mainFile;
    private ByteBuffer log;
    private ubyte[][uint] overlay;
    private ubyte[][uint] dirty;
    private Header saved;
    private bool txnOpen;

    /// The decoded header page, including uncommitted changes.
    Header header;

    private static immutable ubyte[pageSize] zeroPage;

    /// Open a database from the bytes of `main.tdb` (may be empty for a fresh
    /// one) and `main.twal` (may be empty).
    this(ubyte[] tdb, const(ubyte)[] twal)
    {
        if (tdb.length == 0)
        {
            Header fresh;
            mainFile = encodeHeader(fresh);
        }
        else
            mainFile = tdb;
        auto rec = recoverLog(twal);
        log = rec.wal;
        overlay = rec.overlay;
        if (auto p = 1 in overlay)
            header = decodeHeader(*p);
        else
            header = decodeHeader(mainFile[0 .. pageSize]);
    }

    /// The main file as it would be written out.
    const(ubyte)[] mainBytes() const pure nothrow @safe { return mainFile; }

    /// The log as it would be written out.
    const(ubyte)[] logBytes() const pure nothrow @safe { return log.data; }

    /// Current log size in bytes.
    size_t logSize() const pure nothrow @safe { return log.length; }

    /// True while a transaction is open.
    bool inTransaction() const pure nothrow @safe { return txnOpen; }

    /// A read-only view of page `p` (must not be modified by the caller).
    const(ubyte)[] read(uint p) const nothrow
    {
        if (auto d = p in dirty)
            return *d;
        if (auto o = p in overlay)
            return *o;
        immutable end = cast(size_t) p * pageSize;
        if (p >= 1 && end <= mainFile.length)
            return mainFile[end - pageSize .. end];
        return zeroPage[];
    }

    /// Store a page image in the open transaction. The pager takes ownership
    /// of `image` (exactly 1024 bytes): the caller must not modify it again.
    void write(uint p, ubyte[] image)
    {
        assert(txnOpen && image.length == pageSize && p >= 2);
        dirty[p] = image;
    }

    /// Open a transaction.
    void begin()
    {
        assert(!txnOpen);
        saved = header;
        txnOpen = true;
    }

    /// Discard the open transaction.
    void rollback()
    {
        assert(txnOpen);
        dirty = null;
        header = saved;
        txnOpen = false;
    }

    /// Commit the open transaction, running an automatic checkpoint when the
    /// log has reached its limit.
    CommitInfo commit()
    {
        assert(txnOpen);
        header.commitCounter++;
        dirty[1] = encodeHeader(header);
        auto pages = dirty.keys;
        pages.sort();
        immutable txn = header.commitCounter;
        foreach (p; pages)
            appendPageImage(log, txn, p, dirty[p]);
        appendCommit(log, txn, cast(uint) pages.length);
        foreach (p; pages)
            overlay[p] = dirty[p];
        dirty = null;
        txnOpen = false;
        if (log.length >= walLimit)
            checkpoint();
        return CommitInfo(txn, cast(uint) pages.length);
    }

    /// Copy the overlay into the main file and reset the log. Returns the
    /// number of pages copied.
    uint checkpoint()
    {
        assert(!txnOpen);
        auto pages = overlay.keys;
        pages.sort();
        immutable pc = cast(size_t) header.pageCount;
        mainFile.length = pc * pageSize;
        foreach (p; pages)
        {
            immutable o = (cast(size_t) p - 1) * pageSize;
            if (o + pageSize <= mainFile.length)
                mainFile[o .. o + pageSize] = overlay[p][];
        }
        overlay = null;
        log.clear();
        log.put(makeWalHeader());
        return cast(uint) pages.length;
    }

    /// Allocate a page: pop the free list or extend the file.
    uint allocate()
    {
        if (header.freelistHead != 0)
        {
            immutable p = header.freelistHead;
            header.freelistHead = getU32(read(p), 4);
            header.freelistCount--;
            return p;
        }
        return ++header.pageCount;
    }

    /// Push page `p` onto the free list.
    void free(uint p)
    {
        auto img = new ubyte[pageSize];
        setU32(img, 4, header.freelistHead);
        write(p, img);
        header.freelistHead = p;
        header.freelistCount++;
    }
}
