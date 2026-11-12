/// The page cache: the main file, the log overlay and the open transaction's
/// dirty pages (SPEC §13), plus page allocation and the free list (SPEC §10).
module tessera.pager;

import tessera.bytes;
import tessera.constants;
import tessera.header;
import tessera.wal;

/// Owns every byte of state of one database: the main file image, the log,
/// the overlay of committed-but-not-checkpointed pages, the pages dirtied by
/// the open transaction and the decoded header (page 1).
final class Pager
{
    /// The main database file, `pageCount * 1024` bytes (as of the last checkpoint).
    ubyte[] mainFile;
    /// The write-ahead log as it would be written to disk.
    ubyte[] log;
    /// Newest committed image of each page that lives in the log.
    ubyte[][uint] overlay;
    /// Pages written by the open transaction. Page 1 is never stored here: the
    /// decoded `header` stands for it.
    ubyte[][uint] dirty;
    /// The current (possibly uncommitted) header fields.
    Header header;
    /// Whether a transaction is open.
    bool inTransaction;

    private Header savedHeader;

    /// Read a page: dirty set, then overlay, then main file, else zeros
    /// (SPEC §13.1). The returned bytes must not be modified.
    const(ubyte)[] readPage(uint page)
    {
        if (auto p = page in dirty)
            return *p;
        if (auto p = page in overlay)
            return *p;
        immutable off = (cast(size_t) page - 1) * PAGE_SIZE;
        if (off + PAGE_SIZE <= mainFile.length)
            return mainFile[off .. off + PAGE_SIZE];
        return zeroPage;
    }

    /// Store a new image of `page` in the open transaction. The pager takes
    /// ownership of `image`, which must be exactly one page.
    void writePage(uint page, ubyte[] image)
    in (page >= 2 && image.length == PAGE_SIZE)
    {
        dirty[page] = image;
    }

    /// Take a page from the free list, or extend the file (SPEC §10).
    uint allocate()
    {
        if (header.freelistHead != 0)
        {
            immutable p = header.freelistHead;
            header.freelistHead = getU32(readPage(p), 4);
            header.freelistCount--;
            return p;
        }
        return ++header.pageCount;
    }

    /// Push a page on the free list (SPEC §10).
    void free(uint page)
    {
        auto img = new ubyte[PAGE_SIZE];
        putU32(img, 4, header.freelistHead);
        writePage(page, img);
        header.freelistHead = page;
        header.freelistCount++;
    }

    /// Open a transaction, remembering the header for rollback.
    void begin()
    in (!inTransaction)
    {
        savedHeader = header;
        inTransaction = true;
    }

    /// Discard the open transaction.
    void rollback()
    in (inTransaction)
    {
        dirty = null;
        header = savedHeader;
        inTransaction = false;
    }

    /// Commit the open transaction: append its page images and a commit record
    /// to the log, merge them into the overlay (SPEC §13.4 steps 1-4).
    /// Returns the transaction id and the number of page frames written.
    void commit(out ulong txnId, out uint frames)
    in (inTransaction)
    {
        import std.algorithm : sort;

        header.commitCounter++;
        txnId = header.commitCounter;
        auto pages = new uint[dirty.length + 1];
        pages[0] = 1;
        size_t i = 1;
        foreach (p; dirty.byKey)
            pages[i++] = p;
        pages[1 .. $].sort();
        foreach (p; pages)
        {
            auto img = p == 1 ? header.encode() : dirty[p];
            appendRecord(log, RecordType.pageImage, txnId, p, img);
            overlay[p] = img;
        }
        frames = cast(uint) pages.length;
        appendRecord(log, RecordType.commit, txnId, frames, null);
        dirty = null;
        inTransaction = false;
    }

    /// Size in bytes the log file would have right now (SPEC §15.4).
    size_t logSize() const @safe pure nothrow @nogc
    {
        return log.length;
    }
}

private static immutable ubyte[PAGE_SIZE] zeroPage;
