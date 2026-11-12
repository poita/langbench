/// The pager: the whole database file in memory, its header, and page access.
module sqlitefile.database;

import std.file : read;
import sqlitefile.bytes;
import sqlitefile.errors;

@safe:

/// An open (fully loaded) SQLite database file.
final class Database
{
    private const(ubyte)[] data_;
    private size_t pageSize_;
    private size_t usableSize_;
    private uint pageCount_;
    private uint encoding_;

    /// Loads a database from the file at `path`.
    static Database open(string path) @trusted
    {
        return new Database(cast(const(ubyte)[]) read(path));
    }

    /// Wraps database bytes already in memory (the slice is not copied).
    this(const(ubyte)[] data)
    {
        if (data.length < 100)
            throw new FormatException("file too short to be a SQLite database");
        static immutable magic = "SQLite format 3\0";
        foreach (i, c; magic)
            if (data[i] != c)
                throw new FormatException("not a SQLite 3 database (bad magic)");
        data_ = data;
        const ps = readU16(data, 16);
        pageSize_ = ps == 1 ? 65_536 : ps;
        if (pageSize_ < 512 || (pageSize_ & (pageSize_ - 1)) != 0)
            throw new FormatException("invalid page size");
        const reserved = data[20];
        if (reserved >= pageSize_)
            throw new FormatException("invalid reserved size");
        usableSize_ = pageSize_ - reserved;
        pageCount_ = readU32(data, 28);
        encoding_ = readU32(data, 56);
        if (pageCount_ == 0 || cast(size_t) pageCount_ * pageSize_ > data.length)
            pageCount_ = cast(uint)(data.length / pageSize_); // header count unreliable
    }

    /// Page size in bytes.
    size_t pageSize() const pure nothrow @nogc
    {
        return pageSize_;
    }

    /// Usable size `U`: page size minus the reserved bytes at the end of a page.
    size_t usableSize() const pure nothrow @nogc
    {
        return usableSize_;
    }

    /// Number of pages in the file.
    uint pageCount() const pure nothrow @nogc
    {
        return pageCount_;
    }

    /// Text encoding code from the header (1 = UTF-8, 2 = UTF-16le, 3 = UTF-16be).
    uint textEncoding() const pure nothrow @nogc
    {
        return encoding_;
    }

    /// Returns page `number` (1-based) as a slice of the file.
    const(ubyte)[] page(uint number) const pure
    {
        if (number == 0 || number > pageCount_)
            throw new FormatException("page number out of range");
        const start = (cast(size_t) number - 1) * pageSize_;
        return data_[start .. start + pageSize_];
    }
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!FormatException(new Database(new ubyte[50]));
    assertThrown!FormatException(new Database(new ubyte[512]));
    auto d = new ubyte[1024];
    d[0 .. 16] = cast(const(ubyte)[]) "SQLite format 3\0";
    d[16] = 0x02; // 512
    d[17] = 0x00;
    auto db = new Database(d);
    assert(db.pageSize == 512 && db.usableSize == 512 && db.pageCount == 2);
    assert(db.page(2).length == 512);
    assertThrown!FormatException(db.page(3));
    assertThrown!FormatException(db.page(0));
}
