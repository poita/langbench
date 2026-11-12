/// Checkpointing: copy the log's page images into the main file (SPEC §15.6).
module tessera.checkpoint;

import std.algorithm : sort;

import tessera.constants;
import tessera.pager;
import tessera.wal;

/// Copy every overlay page into the main file in ascending page order, set
/// the file length to `page_count * 1024` and reset the log. Returns the
/// number of pages copied. No transaction may be open.
size_t checkpoint(Pager pg)
in (!pg.inTransaction)
{
    immutable n = pg.overlay.length;
    // `page_count` as seen through the overlay is the header's: after
    // recovery and every commit the header is the newest page 1 image.
    immutable fileLen = cast(size_t) pg.header.pageCount * PAGE_SIZE;
    if (pg.mainFile.length < fileLen)
        pg.mainFile.length = fileLen;
    auto pages = pg.overlay.keys;
    pages.sort();
    foreach (p; pages)
    {
        immutable off = (cast(size_t) p - 1) * PAGE_SIZE;
        if (off + PAGE_SIZE > pg.mainFile.length)
            pg.mainFile.length = off + PAGE_SIZE;
        pg.mainFile[off .. off + PAGE_SIZE] = pg.overlay[p][];
    }
    pg.overlay = null;
    pg.log = walHeader();
    return n;
}
