/// Command execution: one function per command, with the error ordering of
/// SPEC §18.3, on top of the pager, the B+trees and the log.
module tessera.engine;

import std.algorithm : sort;
import std.array : Appender, appender;
import std.conv : to;

import tessera.btree;
import tessera.bytes;
import tessera.checkpoint;
import tessera.constants;
import tessera.errors;
import tessera.header;
import tessera.index;
import tessera.node;
import tessera.overflow;
import tessera.pager;
import tessera.parser;
import tessera.query;
import tessera.recover;
import tessera.render;
import tessera.value;
import tessera.wal;

/// A Tessera database session: the state of one database plus the command
/// interpreter. Feed it command lines; it returns result blocks.
final class Engine
{
    private Pager pg;
    private size_t lineNo;

    /// Open a database from the contents of `main.tdb` and `main.twal`. Either
    /// may be empty, meaning absent. Committed transactions of the log are
    /// replayed, anything after the last commit record is dropped (SPEC §16).
    this(const(ubyte)[] mainFile = null, const(ubyte)[] walFile = null)
    {
        pg = openPager(mainFile, walFile);
    }

    /// Execute one command line and append its result block to `results`.
    /// A failing command yields an `error <kind>` block and changes nothing.
    void execute(string line, ref Appender!string results)
    {
        lineNo++;
        try
        {
            auto cmd = parseCommand(line);
            Appender!string block;
            run(cmd, block);
            results.put(block[]);
        }
        catch (TesseraError e)
        {
            errorBlock(results, lineNo, e.kind);
        }
    }

    /// Execute one command line and return its result block.
    string execute(string line)
    {
        Appender!string o;
        execute(line, o);
        return o[];
    }

    /// Execute a whole script (lines separated by LF; a final LF terminates
    /// the last line rather than starting another) and return the contents of
    /// `results.txt`.
    string runScript(string script)
    {
        Appender!string o;
        size_t start = 0;
        while (start < script.length)
        {
            size_t end = start;
            while (end < script.length && script[end] != '\n')
                end++;
            execute(script[start .. end], o);
            start = end + 1;
        }
        return o[];
    }

    /// End of script: an explicit transaction still open is rolled back
    /// (SPEC §2.3). Nothing is checkpointed.
    void finish()
    {
        if (pg.inTransaction)
            pg.rollback();
    }

    /// The bytes `main.tdb` would have right now.
    const(ubyte)[] databaseImage() const
    {
        return pg.mainFile;
    }

    /// The bytes `main.twal` would have right now.
    const(ubyte)[] logImage() const
    {
        return pg.log;
    }

    // -------------------------------------------------------------- dispatch

    private void run(ref Command c, ref Appender!string o)
    {
        final switch (c.cmd)
        {
        case Cmd.begin:
            if (pg.inTransaction)
                fail(ErrorKind.txnActive);
            pg.begin();
            statusLine(o, lineNo, "ok begin");
            break;
        case Cmd.commit:
            if (!pg.inTransaction)
                fail(ErrorKind.noTxn);
            ulong txn;
            uint frames;
            commitNow(txn, frames);
            statusLine(o, lineNo, "ok commit " ~ txn.to!string ~ " frames " ~ frames.to!string);
            break;
        case Cmd.rollback:
            if (!pg.inTransaction)
                fail(ErrorKind.noTxn);
            pg.rollback();
            statusLine(o, lineNo, "ok rollback");
            break;
        case Cmd.checkpoint:
            if (pg.inTransaction)
                fail(ErrorKind.txnActive);
            statusLine(o, lineNo, "ok checkpoint pages " ~ checkpoint(pg).to!string);
            break;
        case Cmd.stat:
            doStat(o);
            break;
        case Cmd.indexes:
            doIndexes(o);
            break;
        case Cmd.put:
            writing({ doPut(c); });
            statusLine(o, lineNo, putCreated ? "ok put created" : "ok put replaced");
            break;
        case Cmd.get:
            doGet(c, o);
            break;
        case Cmd.delete_:
            writing({ doDelete(c); });
            statusLine(o, lineNo, "ok delete removed");
            break;
        case Cmd.update:
            writing({ doUpdate(c); });
            statusLine(o, lineNo, "ok update updated");
            break;
        case Cmd.unset:
            writing({ doUnset(c); });
            statusLine(o, lineNo, "ok unset updated");
            break;
        case Cmd.scan:
            doScan(c, o);
            break;
        case Cmd.find:
            doFind(c, o);
            break;
        case Cmd.createIndex:
            size_t entries;
            writing({ entries = doCreateIndex(c); });
            statusLine(o, lineNo, "ok create index " ~ c.pathText ~ " entries " ~ entries.to!string);
            break;
        case Cmd.dropIndex:
            size_t freed;
            writing({ freed = doDropIndex(c); });
            statusLine(o, lineNo, "ok drop index " ~ c.pathText ~ " pages " ~ freed.to!string);
            break;
        }
    }

    // ---------------------------------------------------------- transactions

    private bool putCreated;

    /// Commit the open transaction; checkpoint when the log reached its limit
    /// (SPEC §13.4, §15.7).
    private void commitNow(out ulong txn, out uint frames)
    {
        pg.commit(txn, frames);
        if (pg.logSize >= WAL_LIMIT)
            checkpoint(pg);
    }

    /// Run a writing command: in an implicit transaction when no explicit one
    /// is open (SPEC §13.3).
    private void writing(scope void delegate() body_)
    {
        immutable implicit = !pg.inTransaction;
        if (implicit)
            pg.begin();
        try
            body_();
        catch (Throwable t)
        {
            if (implicit && pg.inTransaction)
                pg.rollback();
            throw t;
        }
        if (implicit)
        {
            ulong txn;
            uint frames;
            commitNow(txn, frames);
        }
    }

    // ----------------------------------------------------------- index helper

    /// Entry keys of one document in every live index (SPEC §14.2).
    private struct Entries
    {
        ubyte[][MAX_INDEXES] key;
        bool[MAX_INDEXES] has;
    }

    private Entries entriesOf(const Value doc, const(ubyte)[] key) const
    {
        Entries e;
        foreach (i, ref s; pg.header.slots)
        {
            if (!s.live)
                continue;
            e.has[i] = entryKey(doc, pathSegments(s.pathText), key, e.key[i]);
        }
        return e;
    }

    /// Fail with `indexKeyTooLong` if any entry is over `MAX_INDEX_KEY`.
    private static void checkEntryLengths(ref const Entries e)
    {
        foreach (i; 0 .. MAX_INDEXES)
            if (e.has[i] && e.key[i].length > MAX_INDEX_KEY)
                fail(ErrorKind.indexKeyTooLong);
    }

    /// Bring every live index from `oldE` to `newE`, in slot order (SPEC §14.3).
    private void applyIndexChanges(ref const Entries oldE, ref const Entries newE)
    {
        foreach (i; 0 .. MAX_INDEXES)
        {
            if (!pg.header.slots[i].live)
                continue;
            immutable ho = oldE.has[i], hw = newE.has[i];
            if (!ho && !hw)
                continue;
            auto tree = Tree.indexTree(pg, i);
            if (!ho)
            {
                Cell c;
                c.key = newE.key[i];
                tree.upsert(c);
                pg.header.slots[i].entries++;
            }
            else if (!hw)
            {
                tree.remove(oldE.key[i]);
                pg.header.slots[i].entries--;
            }
            else if (oldE.key[i] != newE.key[i])
            {
                tree.remove(oldE.key[i]);
                Cell c;
                c.key = newE.key[i];
                tree.upsert(c);
            }
        }
    }

    private Value loadDocument(ref const Cell cell)
    {
        return deserialise(readDocument(pg, cell));
    }

    /// Steps 2 and 3 of SPEC §14.3 for put/update/unset.
    private void storeDocument(const(ubyte)[] key, bool exists, ref const Cell old,
            const(ubyte)[] ser, ref const Entries oldE, ref const Entries newE)
    {
        auto primary = Tree.primary(pg);
        if (exists)
            freeChain(pg, old.overflow);
        primary.upsert(buildCell(pg, key, ser));
        if (!exists)
            pg.header.primaryCount++;
        applyIndexChanges(oldE, newE);
    }

    // -------------------------------------------------------------- writers

    private void doPut(ref Command c)
    {
        auto ser = serialise(c.value);
        if (ser.length > MAX_DOC)
            fail(ErrorKind.docTooLarge);
        immutable key = asBytes(c.key);
        auto newE = entriesOf(c.value, key);
        checkEntryLengths(newE);

        auto primary = Tree.primary(pg);
        Cell old;
        immutable exists = primary.lookup(key, old);
        Entries oldE;
        if (exists && pg.header.indexCount > 0)
        {
            auto oldDoc = loadDocument(old);
            oldE = entriesOf(oldDoc, key);
        }
        putCreated = !exists;
        storeDocument(key, exists, old, ser, oldE, newE);
    }

    private void doDelete(ref Command c)
    {
        immutable key = asBytes(c.key);
        auto primary = Tree.primary(pg);
        Cell old;
        if (!primary.lookup(key, old))
            fail(ErrorKind.notFound);
        Entries oldE;
        if (pg.header.indexCount > 0)
        {
            auto oldDoc = loadDocument(old);
            oldE = entriesOf(oldDoc, key);
        }
        freeChain(pg, old.overflow);
        primary.remove(key);
        pg.header.primaryCount--;
        Entries none;
        applyIndexChanges(oldE, none);
    }

    private void doUpdate(ref Command c)
    {
        immutable key = asBytes(c.key);
        auto primary = Tree.primary(pg);
        Cell old;
        if (!primary.lookup(key, old))
            fail(ErrorKind.notFound);
        auto doc = loadDocument(old);
        auto oldE = entriesOf(doc, key);
        setPath(doc, c.path, c.value);
        if (depthOf(doc) > MAX_DEPTH)
            fail(ErrorKind.depth);
        auto ser = serialise(doc);
        if (ser.length > MAX_DOC)
            fail(ErrorKind.docTooLarge);
        auto newE = entriesOf(doc, key);
        checkEntryLengths(newE);
        storeDocument(key, true, old, ser, oldE, newE);
    }

    private void doUnset(ref Command c)
    {
        immutable key = asBytes(c.key);
        auto primary = Tree.primary(pg);
        Cell old;
        if (!primary.lookup(key, old))
            fail(ErrorKind.notFound);
        auto doc = loadDocument(old);
        auto oldE = entriesOf(doc, key);
        unsetPath(doc, c.path);
        auto ser = serialise(doc);
        auto newE = entriesOf(doc, key);
        storeDocument(key, true, old, ser, oldE, newE);
    }

    private size_t doCreateIndex(ref Command c)
    {
        foreach (ref s; pg.header.slots)
            if (s.live && s.pathText == c.pathText)
                fail(ErrorKind.indexExists);
        if (pg.header.indexCount == MAX_INDEXES)
            fail(ErrorKind.indexLimit);

        // one walk of the primary tree, in key order
        ubyte[][] entries;
        Tree.primary(pg).walkAll((ref const Cell cell) {
            auto doc = loadDocument(cell);
            ubyte[] e;
            if (entryKey(doc, c.path, cell.key, e))
            {
                if (e.length > MAX_INDEX_KEY)
                    fail(ErrorKind.indexKeyTooLong);
                entries ~= e;
            }
            return true;
        });

        size_t slot = 0;
        while (pg.header.slots[slot].live)
            slot++;
        auto s = &pg.header.slots[slot];
        *s = IndexSlot.init;
        s.live = true;
        s.pathLen = cast(ubyte) c.pathText.length;
        s.pathBytes[0 .. c.pathText.length] = asBytes(c.pathText);
        pg.header.indexCount++;

        auto tree = Tree.indexTree(pg, slot);
        foreach (e; entries)
        {
            Cell cell;
            cell.key = e;
            tree.upsert(cell);
            pg.header.slots[slot].entries++;
        }
        return entries.length;
    }

    private size_t doDropIndex(ref Command c)
    {
        foreach (i, ref s; pg.header.slots)
        {
            if (!s.live || s.pathText != c.pathText)
                continue;
            immutable freed = Tree.indexTree(pg, i).dropAll();
            pg.header.slots[i] = IndexSlot.init;
            pg.header.indexCount--;
            return freed;
        }
        fail(ErrorKind.indexMissing);
    }

    // -------------------------------------------------------------- readers

    private void doGet(ref Command c, ref Appender!string o)
    {
        Cell cell;
        if (!Tree.primary(pg).lookup(asBytes(c.key), cell))
            fail(ErrorKind.notFound);
        auto doc = loadDocument(cell);
        statusLine(o, lineNo, "ok get value");
        o.put("  ");
        render(doc, o);
        o.put('\n');
    }

    private void doStat(ref Appender!string o)
    {
        const h = &pg.header;
        statusLine(o, lineNo, "ok stat");
        payloadLine(o, "pages " ~ h.pageCount.to!string);
        payloadLine(o, "free " ~ h.freelistCount.to!string);
        payloadLine(o, "freehead " ~ h.freelistHead.to!string);
        payloadLine(o, "docs " ~ h.primaryCount.to!string);
        payloadLine(o, "root " ~ h.primaryRoot.to!string);
        payloadLine(o, "height " ~ Tree.primary(pg).height().to!string);
        payloadLine(o, "commits " ~ h.commitCounter.to!string);
        payloadLine(o, "indexes " ~ h.indexCount.to!string);
        payloadLine(o, "wal " ~ pg.logSize.to!string);
    }

    private void doIndexes(ref Appender!string o)
    {
        statusLine(o, lineNo, "ok indexes " ~ pg.header.indexCount.to!string);
        foreach (i, ref s; pg.header.slots)
        {
            if (!s.live)
                continue;
            payloadLine(o, i.to!string ~ " " ~ s.pathText ~ " root " ~ s.root.to!string
                    ~ " entries " ~ s.entries.to!string);
        }
    }

    private void doScan(ref Command c, ref Appender!string o)
    {
        auto opt = c.scan;
        Appender!string body_;
        size_t count = 0;
        if (!(opt.hasLimit && opt.limit == 0))
        {
            Tree.primary(pg).walk(asBytes(opt.from), opt.hasFrom, asBytes(opt.to), opt.hasTo,
                    opt.reverse, (ref const Cell cell) {
                count++;
                if (opt.keysOnly)
                    keyLine(body_, cast(const(char)[]) cell.key, null);
                else
                {
                    auto doc = loadDocument(cell);
                    keyLine(body_, cast(const(char)[]) cell.key, &doc);
                }
                return !(opt.hasLimit && count >= opt.limit);
            });
        }
        statusLine(o, lineNo, "ok scan " ~ count.to!string);
        o.put(body_[]);
    }

    private void doFind(ref Command c, ref Appender!string o)
    {
        immutable limit = c.limit;
        auto primary = Tree.primary(pg);
        auto leaf = chooseIndexLeaf(c.pred, (string p) {
            foreach (ref s; pg.header.slots)
                if (s.live && s.pathText == p)
                    return true;
            return false;
        });

        Appender!string body_;
        size_t count = 0;
        immutable full = limit >= 0 && count >= limit; // limit 0: read nothing

        void consider(const(ubyte)[] key, const Value doc)
        {
            if (evaluate(c.pred, doc))
            {
                count++;
                keyLine(body_, cast(const(char)[]) key, &doc);
            }
        }

        if (!full)
        {
            if (leaf is null)
            {
                primary.walkAll((ref const Cell cell) {
                    auto doc = loadDocument(cell);
                    consider(cell.key, doc);
                    return !(limit >= 0 && count >= limit);
                });
            }
            else
            {
                foreach (i, ref s; pg.header.slots)
                {
                    if (!s.live || s.pathText != leaf.pathText)
                        continue;
                    auto pks = collectCandidates(Tree.indexTree(pg, i), leaf);
                    pks.sort!((a, b) => compareBytes(a, b) < 0);
                    foreach (pk; pks)
                    {
                        Cell cell;
                        if (!primary.lookup(pk, cell))
                            continue;
                        auto doc = loadDocument(cell);
                        consider(pk, doc);
                        if (limit >= 0 && count >= limit)
                            break;
                    }
                    break;
                }
            }
        }
        statusLine(o, lineNo, "ok find " ~ count.to!string ~ " plan "
                ~ (leaf is null ? "scan" : "index " ~ leaf.pathText));
        o.put(body_[]);
    }

    /// Primary keys of the index entries inside the candidate range of a
    /// comparison leaf (SPEC §17.3).
    private static ubyte[][] collectCandidates(Tree tree, const Pred leaf)
    {
        Appender!(ubyte[]) vb;
        appendVkey(leaf.value, vb);
        immutable v = vb[].idup;
        ubyte[][] pks;
        void take(ref const Cell cell)
        {
            pks ~= cell.key[vkeyLength(cell.key) .. $].dup;
        }

        final switch (leaf.op)
        {
        case CmpOp.eq:
            tree.walk(v, true, null, false, false, (ref const Cell cell) {
                if (!hasPrefix(cell.key, v))
                    return false;
                take(cell);
                return true;
            });
            break;
        case CmpOp.lt:
            tree.walk(null, false, v, true, false, (ref const Cell cell) {
                take(cell);
                return true;
            });
            break;
        case CmpOp.le:
            tree.walk(null, false, null, false, false, (ref const Cell cell) {
                if (compareBytes(cell.key, v) >= 0 && !hasPrefix(cell.key, v))
                    return false;
                take(cell);
                return true;
            });
            break;
        case CmpOp.gt:
            tree.walk(v, true, null, false, false, (ref const Cell cell) {
                if (!hasPrefix(cell.key, v))
                    take(cell);
                return true;
            });
            break;
        case CmpOp.ge:
            tree.walk(v, true, null, false, false, (ref const Cell cell) {
                take(cell);
                return true;
            });
            break;
        case CmpOp.ne:
            assert(0);
        }
        return pks;
    }
}

version (unittest)
{
    private string runOn(Engine e, string script)
    {
        immutable r = e.runScript(script);
        e.finish();
        return r;
    }
}

unittest
{
    // SPEC §19.3
    auto e = new Engine;
    assert(runOn(e, "put \"b\" 2\nput \"a\" {name:\"ada\",age:36}\nget \"a\"\nscan\nstat\n") ==
        "[1] ok put created\n[2] ok put created\n[3] ok get value\n  {\"age\":36,\"name\":\"ada\"}\n"
        ~ "[4] ok scan 2\n  \"a\" = {\"age\":36,\"name\":\"ada\"}\n  \"b\" = 2\n"
        ~ "[5] ok stat\n  pages 2\n  free 0\n  freehead 0\n  docs 2\n  root 2\n  height 1\n"
        ~ "  commits 2\n  indexes 0\n  wal 4272\n");
}

unittest
{
    // SPEC §21.1: one document, then a checkpoint
    auto e = new Engine;
    auto r = runOn(e, "put \"a\" 1\ncheckpoint\nstat");
    assert(r[0 .. 38] == "[1] ok put created\n[2] ok checkpoint p");
    assert(e.databaseImage.length == 2048);
    assert(e.logImage == walHeader());
    // page 1 is the header of SPEC §7.2, page 2 the leaf of SPEC §11.3
    assert(e.databaseImage[0 .. 8] == cast(const(ubyte)[]) "TESSERA1");
    assert(e.databaseImage[1024 .. 1028] == [1, 0, 0, 1]);
}

unittest
{
    // SPEC §21.2: deleting everything, then reusing the freed page
    auto e = new Engine;
    auto r = runOn(e, "put \"k1\" \"x\"\nput \"k2\" \"y\"\ndelete \"k1\"\ndelete \"k2\"\nstat\nput \"k3\" \"z\"\nstat");
    assert(r.length > 0);
    import std.algorithm : canFind;

    assert(r.canFind("  free 1\n  freehead 2\n  docs 0\n  root 0\n  height 0\n  commits 4\n  indexes 0\n  wal 8512\n"));
    assert(r.canFind("  free 0\n  freehead 0\n  docs 1\n  root 2\n  height 1\n  commits 5\n  indexes 0\n  wal 10632\n"));
}

unittest
{
    // SPEC §21.3: an overflow chain is allocated before the leaf
    auto e = new Engine;
    string doc = "[";
    foreach (i; 1 .. 26)
        doc ~= (i > 1 ? "," : "") ~ i.to!string;
    doc ~= "]";
    auto r = runOn(e, "put \"big\" " ~ doc ~ "\nstat\nget \"big\"\ndelete \"big\"\nstat");
    import std.algorithm : canFind;

    assert(r.canFind("  pages 3\n  free 0\n  freehead 0\n  docs 1\n  root 3\n"));
    assert(r.canFind("  free 2\n  freehead 3\n  docs 0\n"));
}

unittest
{
    // SPEC §21.4: rollback restores the header too
    auto e = new Engine;
    auto r = runOn(e, "begin\nput \"a\" 1\nput \"b\" 2\nstat\nrollback\nstat\nbegin\nput \"a\" 1\ncommit\nstat");
    import std.algorithm : canFind;

    assert(r.canFind("[9] ok commit 1 frames 2\n"));
    assert(r.canFind("  pages 1\n  free 0\n  freehead 0\n  docs 0\n"));
    assert(e.databaseImage.length == 1024);
    assert(e.logImage.length == 2152);
}

unittest
{
    // SPEC §21.5: errors
    auto e = new Engine;
    auto r = runOn(e, "put \"a\" 1\nput \"a\" 2\nget \"zz\"\ndelete \"zz\"\nfrobnicate\nput \"a\"\n"
            ~ "put \"a\" 007\nput \"a\" 9223372036854775808\nput \"a\" {x:1,x:2}\nput \"\\ud800\" 1\n"
            ~ "put \"\" 1\ncommit\nrollback\nbegin\nbegin\ncheckpoint\n");
    assert(r == "[1] ok put created\n[2] ok put replaced\n[3] error not-found\n[4] error not-found\n"
        ~ "[5] error unknown-command\n[6] error syntax\n[7] error syntax\n[8] error int-range\n"
        ~ "[9] error dup-field\n[10] error bad-utf8\n[11] error bad-key\n[12] error no-txn\n"
        ~ "[13] error no-txn\n[14] ok begin\n[15] error txn-active\n[16] error txn-active\n");
    assert(e.logImage.length == 32 + 2 * 2120);
}

unittest
{
    // SPEC §21.6: a secondary index and find
    auto e = new Engine;
    auto r = runOn(e, "put \"u1\" {name:\"ada\",age:36}\nput \"u2\" {name:\"bob\",age:29}\n"
            ~ "put \"u3\" {name:\"cy\",age:36}\ncreate index age\nindexes\nfind age == 36\nfind age > 30\n"
            ~ "find age == 36 and name == \"cy\"\nfind not(age == 36)\nstat\n");
    assert(r == "[1] ok put created\n[2] ok put created\n[3] ok put created\n"
        ~ "[4] ok create index age entries 3\n[5] ok indexes 1\n  0 age root 3 entries 3\n"
        ~ "[6] ok find 2 plan index age\n  \"u1\" = {\"age\":36,\"name\":\"ada\"}\n  \"u3\" = {\"age\":36,\"name\":\"cy\"}\n"
        ~ "[7] ok find 2 plan index age\n  \"u1\" = {\"age\":36,\"name\":\"ada\"}\n  \"u3\" = {\"age\":36,\"name\":\"cy\"}\n"
        ~ "[8] ok find 1 plan index age\n  \"u3\" = {\"age\":36,\"name\":\"cy\"}\n"
        ~ "[9] ok find 1 plan scan\n  \"u2\" = {\"age\":29,\"name\":\"bob\"}\n"
        ~ "[10] ok stat\n  pages 3\n  free 0\n  freehead 0\n  docs 3\n  root 2\n  height 1\n"
        ~ "  commits 4\n  indexes 1\n  wal 8512\n");
}

unittest
{
    // updates, unsets and index maintenance keep the index exact
    auto e = new Engine;
    auto r = runOn(e, "put \"a\" {n:1}\ncreate index n\nupdate \"a\" n 2\nfind n == 2\nunset \"a\" n\n"
            ~ "indexes\nfind n >= 0\nupdate \"a\" x.y 5\nget \"a\"\nunset \"a\" x.z\nunset \"a\" x.y.z\n"
            ~ "update \"a\" x.y.z 1\ndrop index n\ndrop index n\n");
    import std.algorithm : canFind;

    assert(r.canFind("[4] ok find 1 plan index n\n"));
    assert(r.canFind("[6] ok indexes 1\n  0 n root 0 entries 0\n"));
    assert(r.canFind("[7] ok find 0 plan index n\n"));
    assert(r.canFind("[9] ok get value\n  {\"x\":{\"y\":5}}\n"));
    assert(r.canFind("[10] error no-field\n[11] error not-object\n[12] error not-object\n"));
    assert(r.canFind("[13] ok drop index n pages 0\n[14] error index-missing\n"));
}

unittest
{
    // scan ranges, limits and reverse
    auto e = new Engine;
    string script;
    foreach (c; "abcdef")
        script ~= "put \"" ~ c ~ "\" " ~ (c - 'a').to!string ~ "\n";
    script ~= "scan from \"b\" to \"e\" keys\nscan limit 2 reverse keys\nscan from \"e\" to \"b\"\n"
        ~ "scan limit 0\nscan from \"\" limit 1\n";
    auto r = runOn(e, script);
    import std.algorithm : canFind;

    assert(r.canFind("[7] ok scan 3\n  \"b\"\n  \"c\"\n  \"d\"\n"));
    assert(r.canFind("[8] ok scan 2\n  \"f\"\n  \"e\"\n"));
    assert(r.canFind("[9] ok scan 0\n[10] ok scan 0\n[11] ok scan 1\n  \"a\" = 0\n"));
}

unittest
{
    // recovery: only committed transactions of a cut log are replayed, and
    // the log is trimmed to the last commit record (SPEC §16)
    auto e = new Engine;
    runOn(e, "put \"a\" 1\nput \"b\" 2\n");
    auto log = e.logImage.dup;
    assert(log.length == 32 + 2 * 2120);
    foreach (cut; [cast(size_t) 31, 32, 100, 2151, 2152, 2153, 4000, 4271, 4272])
    {
        auto r = new Engine(null, log[0 .. cut]);
        immutable expected = cut >= 4272 ? 4272 : cut >= 2152 ? 2152 : 32;
        assert(r.logImage.length == expected, cut.to!string);
        immutable docs = cut >= 4272 ? 2 : cut >= 2152 ? 1 : 0;
        immutable want = "[1] ok scan " ~ docs.to!string ~ "\n"
            ~ (docs >= 1 ? "  \"a\" = 1\n" : "") ~ (docs >= 2 ? "  \"b\" = 2\n" : "");
        assert(r.execute("scan") == want, cut.to!string);
    }
}

unittest
{
    // a log is replayed over a checkpointed file, and a checkpoint copies
    // the overlay across
    auto a = new Engine;
    runOn(a, "put \"a\" 1\ncheckpoint\nput \"b\" 2\n");
    auto b = new Engine(a.databaseImage, a.logImage);
    assert(b.execute("scan") == "[1] ok scan 2\n  \"a\" = 1\n  \"b\" = 2\n");
    assert(b.execute("checkpoint") == "[2] ok checkpoint pages 2\n");
    assert(b.logImage == walHeader());
    assert(b.databaseImage.length == 2048);
}

unittest
{
    // large documents: overflow chains round-trip and an automatic
    // checkpoint fires once the log reaches WAL_LIMIT
    auto e = new Engine;
    string big = "\"";
    foreach (i; 0 .. 5000)
        big ~= "x";
    big ~= "\"";
    string script;
    foreach (i; 0 .. 60)
        script ~= "put \"k" ~ i.to!string ~ "\" " ~ big ~ "\n";
    script ~= "stat\nget \"k7\"\n";
    auto r = runOn(e, script);
    import std.algorithm : canFind;

    assert(r.canFind("  wal "));
    assert(e.logImage.length < WAL_LIMIT + 10 * 1048);
    assert(e.databaseImage.length > 1024);
    assert(r.canFind(big));
}

unittest
{
    // a failing command inside an explicit transaction leaves it open and untouched
    auto e = new Engine;
    auto r = runOn(e, "begin\nput \"a\" 1\nput \"a\" [[[\nget \"x\"\ncommit\nget \"a\"\n");
    assert(r == "[1] ok begin\n[2] ok put created\n[3] error syntax\n[4] error not-found\n"
        ~ "[5] ok commit 1 frames 2\n[6] ok get value\n  1\n");
}
