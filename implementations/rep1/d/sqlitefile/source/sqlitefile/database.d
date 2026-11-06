/// The database image: header fields and page access.
module sqlitefile.database;

import std.file : read;
import sqlitefile.bytes;
import sqlitefile.errors;

@safe:

/// A SQLite database held entirely in memory.
///
/// Pages are never copied: `page` returns a slice into the image.
final class Database
{
    /// The whole file.
    const(ubyte)[] data;
    /// Page size in bytes.
    uint pageSize;
    /// Usable bytes per page (page size minus the reserved region).
    uint usable;
    /// Number of whole pages in the image.
    uint pageCount;

    /// Payload thresholds of SPEC §1.5.
    uint minLocal, maxLocalTable, maxLocalIndex;

    /// Reusable buffer for payloads that spill into overflow pages.
    ubyte[] scratch;

    /// Parses the 100-byte header of `image`; throws `FormatException` if it is not a usable database.
    this(const(ubyte)[] image)
    {
        if (image.length < 100)
            throw new FormatException("file too short for a SQLite header");
        static immutable magic = "SQLite format 3\0";
        foreach (i, c; magic)
            if (image[i] != c)
                throw new FormatException("not a SQLite 3 database");
        uint ps = readBE16(image, 16);
        if (ps == 1)
            ps = 65536;
        if (ps < 512 || (ps & (ps - 1)) != 0)
            throw new FormatException("invalid page size");
        immutable reserved = image[20];
        if (reserved >= ps)
            throw new FormatException("invalid reserved size");
        immutable enc = readBE32(image, 56);
        if (enc != 1)
            throw new FormatException("only UTF-8 databases are supported");
        data = image;
        pageSize = ps;
        usable = ps - reserved;
        pageCount = cast(uint)(image.length / ps);
        if (pageCount == 0)
            throw new FormatException("database has no complete page");
        minLocal = (usable - 12) * 32 / 255 - 23;
        maxLocalTable = usable - 35;
        maxLocalIndex = (usable - 12) * 64 / 255 - 23;
    }

    /// Reads the file at `path` into memory and opens it.
    static Database open(string path) @trusted
    {
        return new Database(cast(const(ubyte)[]) read(path));
    }

    /// The bytes of page `no` (1-based), as a view of the image.
    const(ubyte)[] page(uint no) const pure
    {
        if (no == 0 || no > pageCount)
            throw new FormatException("page number out of range");
        immutable start = cast(size_t)(no - 1) * pageSize;
        return data[start .. start + pageSize];
    }
}
