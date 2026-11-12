/// Opening a database: initialise or adopt the main file and replay the log
/// (SPEC §16).
module tessera.recover;

import tessera.constants;
import tessera.header;
import tessera.pager;
import tessera.wal;

/// Build a pager from the bytes of `main.tdb` and `main.twal`. Either may be
/// empty (absent). The main file is not modified by recovery.
Pager openPager(const(ubyte)[] mainFile, const(ubyte)[] logFile)
{
    auto pg = new Pager;
    if (mainFile.length == 0)
        pg.mainFile = Header.fresh().encode();
    else
        pg.mainFile = mainFile.dup;

    auto rec = recoverLog(logFile);
    pg.log = rec.log;
    pg.overlay = rec.overlay;

    if (auto p = 1 in pg.overlay)
        pg.header = Header.decode(*p);
    else
        pg.header = Header.decode(pg.mainFile[0 .. PAGE_SIZE]);
    return pg;
}
