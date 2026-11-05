/// The embedded database: typed operations over the pager and trees.
module tessera.database;

import std.algorithm.sorting : sort;

import tessera.ast;
import tessera.btree;
import tessera.bytes;
import tessera.constants;
import tessera.docstore;
import tessera.errors;
import tessera.header;
import tessera.indexing;
import tessera.lexer : CmpOp;
import tessera.pager;
import tessera.query;
import tessera.value;

public import tessera.pager : CommitInfo;

/// A key with its document (the document is unset for key-only scans).
struct Row
{
    string key;
    Value doc;
}

/// Result of `find`.
struct FindResult
{
    /// `scan` or `index <path>`.
    string plan;
    /// The matching rows in ascending key order.
    Row[] rows;
}

/// One live index, as listed by `indexes`.
struct IndexInfo
{
    size_t slot;
    string path;
    uint root;
    uint entries;
}

/// Snapshot of the engine's counters, as printed by `stat`.
struct Stats
{
    uint pages;
    uint freePages;
    uint freeHead;
    uint docs;
    uint root;
    uint height;
    ulong commits;
    uint indexes;
    size_t walSize;
}

/// A Tessera database held entirely in memory.
///
/// Create it from the bytes of an existing database file and log (either may
/// be empty), operate on it, then take `databaseBytes` and `logBytes` to
/// persist it. Operations that fail throw `TesseraException` and leave the
/// database unchanged.
final class Database
{
    private Pager pager;
    private bool explicitTxn;

    /// Open a database from file contents; both may be empty.
    this(ubyte[] tdb = null, const(ubyte)[] twal = null)
    {
        pager = new Pager(tdb, twal);
    }

    /// The main database file as it would be written now.
    const(ubyte)[] databaseBytes() const { return pager.mainBytes; }

    /// The write-ahead log as it would be written now.
    const(ubyte)[] logBytes() const { return pager.logBytes; }

    /// True while an explicit transaction is open.
    bool inTransaction() const { return explicitTxn; }

    // ---------------------------------------------------------- transactions

    /// Open an explicit transaction.
    void begin()
    {
        if (explicitTxn)
            fail(ErrorKind.txnActive);
        pager.begin();
        explicitTxn = true;
    }

    /// Commit the explicit transaction.
    CommitInfo commit()
    {
        if (!explicitTxn)
            fail(ErrorKind.noTxn);
        explicitTxn = false;
        return pager.commit();
    }

    /// Roll back the explicit transaction.
    void rollback()
    {
        if (!explicitTxn)
            fail(ErrorKind.noTxn);
        explicitTxn = false;
        pager.rollback();
    }

    /// Copy the log into the main file. Returns the pages copied.
    uint checkpoint()
    {
        if (explicitTxn)
            fail(ErrorKind.txnActive);
        return pager.checkpoint();
    }

    /// Roll back a transaction left open at the end of a script (no error).
    void finish()
    {
        if (explicitTxn)
            rollback();
    }

    /// Run `body` inside the explicit transaction, or inside an implicit one
    /// that commits on success and rolls back on failure.
    private T transact(T)(scope T delegate() body)
    {
        if (explicitTxn)
            return body();
        pager.begin();
        try
        {
            auto r = body();
            pager.commit();
            return r;
        }
        catch (Throwable e)
        {
            pager.rollback();
            throw e;
        }
    }

    // ------------------------------------------------------------- documents

    private static const(ubyte)[] checkedKey(string key)
    {
        if (key.length < 1 || key.length > maxKey)
            fail(ErrorKind.badKey);
        return asBytes(key);
    }

    private bool liveIndexes() const { return pager.header.indexCount > 0; }

    /// Store `doc` under `key`; true when the key is new.
    bool put(string key, Value doc)
    {
        auto kb = checkedKey(key);
        if (depthOf(doc) > maxDepth)
            fail(ErrorKind.depth);
        auto ser = serialize(doc);
        if (ser.length > maxDoc)
            fail(ErrorKind.docTooLarge);
        auto newKeys = computeIndexKeys(pager.header, doc, kb);
        checkIndexKeys(newKeys);
        auto cur = lookup(pager, TreeRef.primaryTree, kb);
        IndexKeys oldKeys;
        uint oldOverflow;
        immutable exists = cur.valid;
        if (exists)
        {
            oldOverflow = cur.overflow;
            if (liveIndexes)
            {
                auto old = loadDocument(pager, cur);
                oldKeys = computeIndexKeys(pager.header, old, kb);
            }
        }
        return transact!bool({
            store(kb, ser, exists, oldOverflow, oldKeys, newKeys);
            return !exists;
        });
    }

    /// Replace/insert the primary cell and bring the indexes up to date.
    private void store(const(ubyte)[] kb, const(ubyte)[] ser, bool exists, uint oldOverflow,
            const ref IndexKeys oldKeys, const ref IndexKeys newKeys)
    {
        if (exists)
            freeChain(pager, oldOverflow);
        auto cell = buildCell(pager, kb, ser);
        insert(pager, TreeRef.primaryTree, cell);
        if (!exists)
            pager.header.primaryCount++;
        applyIndexChanges(pager, oldKeys, newKeys);
    }

    /// The document under `key`; throws `notFound` when absent.
    Value get(string key)
    {
        auto cur = lookup(pager, TreeRef.primaryTree, asBytes(key));
        if (!cur.valid)
            fail(ErrorKind.notFound);
        return loadDocument(pager, cur);
    }

    /// True when `key` is present.
    bool contains(string key)
    {
        return lookup(pager, TreeRef.primaryTree, asBytes(key)).valid;
    }

    /// Delete `key`; throws `notFound` when absent.
    void remove(string key)
    {
        auto kb = asBytes(key);
        auto cur = lookup(pager, TreeRef.primaryTree, kb);
        if (!cur.valid)
            fail(ErrorKind.notFound);
        immutable overflow = cur.overflow;
        IndexKeys oldKeys, none;
        if (liveIndexes)
        {
            auto old = loadDocument(pager, cur);
            oldKeys = computeIndexKeys(pager.header, old, kb);
        }
        transact!bool({
            freeChain(pager, overflow);
            btreeRemove(kb);
            pager.header.primaryCount--;
            applyIndexChanges(pager, oldKeys, none);
            return true;
        });
    }

    private void btreeRemove(const(ubyte)[] kb)
    {
        tessera.btree.remove(pager, TreeRef.primaryTree, kb);
    }

    /// Set the field at `path` of the document under `key` to `value`,
    /// creating missing intermediate objects.
    void update(string key, const string[] path, Value value)
    {
        auto kb = asBytes(key);
        auto cur = lookup(pager, TreeRef.primaryTree, kb);
        if (!cur.valid)
            fail(ErrorKind.notFound);
        immutable oldOverflow = cur.overflow;
        auto old = loadDocument(pager, cur);
        Value nv;
        if (!setPath(old, path, value, nv))
            fail(ErrorKind.notObject);
        applyReplacement(kb, old, nv, oldOverflow);
    }

    /// Remove the field at `path` of the document under `key`.
    void unset(string key, const string[] path)
    {
        auto kb = asBytes(key);
        auto cur = lookup(pager, TreeRef.primaryTree, kb);
        if (!cur.valid)
            fail(ErrorKind.notFound);
        immutable oldOverflow = cur.overflow;
        auto old = loadDocument(pager, cur);
        Value nv;
        final switch (unsetPath(old, path, nv))
        {
        case PathStatus.ok: break;
        case PathStatus.notObject: fail(ErrorKind.notObject);
        case PathStatus.noField: fail(ErrorKind.noField);
        }
        applyReplacement(kb, old, nv, oldOverflow);
    }

    private void applyReplacement(const(ubyte)[] kb, Value old, Value nv, uint oldOverflow)
    {
        if (depthOf(nv) > maxDepth)
            fail(ErrorKind.depth);
        auto ser = serialize(nv);
        if (ser.length > maxDoc)
            fail(ErrorKind.docTooLarge);
        auto newKeys = computeIndexKeys(pager.header, nv, kb);
        checkIndexKeys(newKeys);
        auto oldKeys = computeIndexKeys(pager.header, old, kb);
        transact!bool({
            store(kb, ser, true, oldOverflow, oldKeys, newKeys);
            return true;
        });
    }

    // --------------------------------------------------------------- queries

    /// Range scan (§6.5). Keys-only scans leave `Row.doc` unset.
    Row[] scan(const ScanOptions o)
    {
        Row[] rows;
        auto tree = TreeRef.primaryTree;
        if (o.hasLimit && o.limit == 0)
            return rows;
        auto inRange = (ref Cursor c) => !o.hasTo || compareBytes(c.key, asBytes(o.to)) < 0;
        auto cur = o.hasFrom ? seek(pager, tree, asBytes(o.from)) : first(pager, tree);
        Row make(ref Cursor c)
        {
            Row r;
            r.key = toStr(c.key);
            if (!o.keysOnly)
                r.doc = loadDocument(pager, c);
            return r;
        }

        if (!o.reverse)
        {
            for (; cur.valid && inRange(cur); cur.next())
            {
                if (o.hasLimit && rows.length >= cast(size_t) o.limit)
                    break;
                rows ~= make(cur);
            }
            return rows;
        }
        Cursor[] hits;
        for (; cur.valid && inRange(cur); cur.next())
            hits ~= cur;
        foreach_reverse (ref c; hits)
        {
            if (o.hasLimit && rows.length >= cast(size_t) o.limit)
                break;
            rows ~= make(c);
        }
        return rows;
    }

    /// Evaluate a predicate (§17). `limit` < 0 means no limit.
    FindResult find(Pred pred, long limit = -1)
    {
        FindResult res;
        auto plan = choosePlan(pred, pager.header);
        res.plan = plan.useIndex ? "index " ~ plan.path : "scan";
        if (limit == 0)
            return res;
        immutable atLimit = () => limit >= 0 && res.rows.length >= cast(size_t) limit;
        auto primary = TreeRef.primaryTree;
        if (!plan.useIndex)
        {
            for (auto c = first(pager, primary); c.valid && !atLimit(); c.next())
            {
                auto doc = loadDocument(pager, c);
                if (matches(pred, doc))
                    res.rows ~= Row(toStr(c.key), doc);
            }
            return res;
        }
        auto v = vkey(plan.leaf.rhs);
        auto keys = candidateKeys(pager, plan.slot, plan.leaf.op, v);
        if (plan.leaf.op != CmpOp.eq)
            keys.sort!((a, b) => compareBytes(a, b) < 0);
        foreach (k; keys)
        {
            if (atLimit())
                break;
            auto c = lookup(pager, primary, k);
            if (!c.valid)
                continue;
            auto doc = loadDocument(pager, c);
            if (matches(pred, doc))
                res.rows ~= Row(toStr(k), doc);
        }
        return res;
    }

    // --------------------------------------------------------------- indexes

    /// Build an index; returns its number of entries.
    uint createIndex(const string[] path)
    {
        return transact!uint(() => tessera.indexing.createIndex(pager, path));
    }

    /// Drop an index; returns the number of pages freed.
    uint dropIndex(const string[] path)
    {
        return transact!uint(() => tessera.indexing.dropIndex(pager, path));
    }

    /// The live indexes in slot order.
    IndexInfo[] indexes() const
    {
        IndexInfo[] r;
        foreach (s, ref sl; pager.header.slots)
            if (sl.live)
                r ~= IndexInfo(s, sl.path, sl.root, sl.entries);
        return r;
    }

    /// Current counters.
    Stats stat() const
    {
        auto h = &pager.header;
        return Stats(h.pageCount, h.freelistCount, h.freelistHead, h.primaryCount, h.primaryRoot,
                heightOf(pager, TreeRef.primaryTree), h.commitCounter, h.indexCount, pager.logSize);
    }
}
