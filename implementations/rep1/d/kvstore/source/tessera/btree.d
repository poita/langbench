/// B+tree insert, search, delete, rebalance and traversal (SPEC §11, §12).
///
/// One `Tree` handle serves both the primary tree and every index tree; they
/// differ only in the leaf page type and where the root page number is kept.
module tessera.btree;

import tessera.bytes;
import tessera.constants;
import tessera.node;
import tessera.pager;

/// Callback of `Tree.walk`: receives each cell in turn and returns `false`
/// to stop the traversal.
alias Visitor = bool delegate(ref const Cell cell);

/// A handle on one B+tree of a database.
final class Tree
{
    private Pager pg;
    private PageType leafType;
    private int slot;

    /// The primary tree.
    static Tree primary(Pager pg)
    {
        return new Tree(pg, PageType.primaryLeaf, -1);
    }

    /// The tree of index directory slot `slot`.
    static Tree indexTree(Pager pg, size_t slot)
    {
        return new Tree(pg, PageType.indexLeaf, cast(int) slot);
    }

    private this(Pager pg, PageType leafType, int slot)
    {
        this.pg = pg;
        this.leafType = leafType;
        this.slot = slot;
    }

    /// Root page, `0` when the tree is empty.
    uint root() const
    {
        return slot < 0 ? pg.header.primaryRoot : pg.header.slots[slot].root;
    }

    private void setRoot(uint r)
    {
        if (slot < 0)
            pg.header.primaryRoot = r;
        else
            pg.header.slots[slot].root = r;
    }

    private Node load(uint page)
    {
        return decodeNode(pg.readPage(page));
    }

    private void store(uint page, ref const Node n)
    {
        pg.writePage(page, encodeNode(n));
    }

    /// Height of the tree (SPEC §12.7): 0 when empty, 1 for a lone leaf.
    size_t height()
    {
        size_t h = 0;
        uint p = root;
        while (p != 0)
        {
            h++;
            auto n = load(p);
            if (n.isLeaf)
                break;
            p = n.cells.length ? n.cells[0].child : n.link;
        }
        return h;
    }

    // ----------------------------------------------------------- searching

    /// One interior page on the way down, and the child index taken there.
    private struct Step
    {
        uint page;
        Node node;
        size_t idx;
    }

    /// Smallest `i` with `key <= k[i]`, or the cell count (descend `link`).
    private static size_t childIndex(ref const Node n, const(ubyte)[] key)
    {
        size_t lo = 0, hi = n.cells.length;
        while (lo < hi)
        {
            immutable mid = (lo + hi) / 2;
            if (compareBytes(n.cells[mid].key, key) < 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }

    /// Descend from the (non-zero) root to the leaf that would hold `key`.
    private void descend(const(ubyte)[] key, ref Step[] path, out uint leafPage, out Node leaf)
    {
        uint p = root;
        assert(p != 0);
        while (true)
        {
            auto n = load(p);
            if (n.isLeaf)
            {
                leafPage = p;
                leaf = n;
                return;
            }
            immutable i = childIndex(n, key);
            immutable next = i < n.cells.length ? n.cells[i].child : n.link;
            path ~= Step(p, n, i);
            p = next;
        }
    }

    /// Find the cell with exactly this key. The returned cell's slices stay
    /// valid until the next write.
    bool lookup(const(ubyte)[] key, out Cell found)
    {
        if (root == 0)
            return false;
        Step[] path;
        uint leafPage;
        Node leaf;
        descend(key, path, leafPage, leaf);
        immutable i = childIndex(leaf, key);
        if (i < leaf.cells.length && compareBytes(leaf.cells[i].key, key) == 0)
        {
            found = leaf.cells[i];
            return true;
        }
        return false;
    }

    // ------------------------------------------------------------ inserting

    /// Insert `cell`, or replace the cell with the same key in place
    /// (SPEC §12.2). Returns `true` when an existing cell was replaced.
    bool upsert(Cell cell)
    {
        Node leaf;
        uint leafPage;
        Step[] path;
        if (root == 0)
        {
            leafPage = pg.allocate();
            leaf.type = leafType;
            setRoot(leafPage);
        }
        else
            descend(cell.key, path, leafPage, leaf);

        immutable i = childIndex(leaf, cell.key);
        immutable replaced = i < leaf.cells.length && compareBytes(leaf.cells[i].key, cell.key) == 0;
        if (replaced)
        {
            leaf.cells = leaf.cells.dup;
            leaf.cells[i] = cell;
        }
        else
            leaf.cells = leaf.cells[0 .. i] ~ cell ~ leaf.cells[i .. $];
        storeSplitting(path, leafPage, leaf);
        return replaced;
    }

    /// Write `node` as page `page`, splitting it, and then its ancestors in
    /// `path`, while it overflows (SPEC §12.3).
    private void storeSplitting(Step[] path, uint page, Node node)
    {
        size_t level = path.length;
        while (true)
        {
            if (node.used() <= CAPACITY)
            {
                store(page, node);
                return;
            }

            // the split point: smallest m in 1..n-1 with 2*P[m] >= T
            immutable total = node.used();
            size_t m = 0, prefix = 0;
            while (true)
            {
                prefix += node.cellCost(node.cells[m]);
                m++;
                if (2 * prefix >= total)
                    break;
            }

            immutable right = pg.allocate();
            Node left, rnode;
            left.type = rnode.type = node.type;
            const(ubyte)[] sep;
            if (node.isLeaf)
            {
                left.cells = node.cells[0 .. m].dup;
                rnode.cells = node.cells[m .. $].dup;
                rnode.link = node.link;
                left.link = right;
                sep = node.cells[m - 1].key;
            }
            else
            {
                left.cells = node.cells[0 .. m - 1].dup;
                rnode.cells = node.cells[m .. $].dup;
                rnode.link = node.link;
                left.link = node.cells[m - 1].child;
                sep = node.cells[m - 1].key;
            }
            store(page, left);
            store(right, rnode);

            if (level == 0)
            {
                immutable newRoot = pg.allocate();
                Node r;
                r.type = PageType.interior;
                Cell c;
                c.key = sep;
                c.child = page;
                r.cells = [c];
                r.link = right;
                store(newRoot, r);
                setRoot(newRoot);
                return;
            }

            auto st = path[level - 1];
            auto par = st.node;
            Cell sc;
            sc.key = sep;
            sc.child = page;
            if (st.idx == par.cells.length)
            {
                par.cells = par.cells ~ sc;
                par.link = right;
            }
            else
            {
                auto cells = par.cells.dup;
                cells[st.idx].child = right;
                par.cells = cells[0 .. st.idx] ~ sc ~ cells[st.idx .. $];
            }
            page = st.page;
            node = par;
            level--;
        }
    }

    // ------------------------------------------------------------- deleting

    /// Remove the cell with this key (SPEC §12.4). Returns `false` when it is
    /// not in the tree.
    bool remove(const(ubyte)[] key)
    {
        if (root == 0)
            return false;
        Step[] path;
        uint leafPage;
        Node leaf;
        descend(key, path, leafPage, leaf);
        immutable i = childIndex(leaf, key);
        if (i >= leaf.cells.length || compareBytes(leaf.cells[i].key, key) != 0)
            return false;
        leaf.cells = leaf.cells[0 .. i] ~ leaf.cells[i + 1 .. $];

        if (path.length == 0)
        {
            if (leaf.cells.length > 0)
                store(leafPage, leaf);
            else
            {
                pg.free(leafPage);
                setRoot(0);
            }
            return true;
        }
        if (leaf.used() >= MIN_FILL)
        {
            store(leafPage, leaf);
            return true;
        }
        rebalance(path, leafPage, leaf);
        return true;
    }

    /// Repair an underflowing page: borrow left, borrow right, merge left,
    /// merge right, then propagate upward after a merge (SPEC §12.5).
    private void rebalance(Step[] path, uint nPage, Node n)
    {
        size_t level = path.length;
        while (true)
        {
            auto st = path[level - 1];
            auto par = st.node;
            par.cells = par.cells.dup;
            immutable j = st.idx;
            immutable np = par.cells.length;

            immutable hasL = j >= 1;
            immutable hasR = j < np;
            uint lPage, rPage;
            Node ln, rn;
            if (hasL)
            {
                lPage = par.cells[j - 1].child;
                ln = load(lPage);
            }
            if (hasR)
            {
                rPage = j + 1 < np ? par.cells[j + 1].child : par.link;
                rn = load(rPage);
            }

            if (hasL && ln.cells.length > 0
                && ln.used() - ln.cellCost(ln.cells[$ - 1]) >= MIN_FILL)
            {
                // borrow from the left
                auto lastCell = ln.cells[$ - 1];
                if (n.isLeaf)
                {
                    n.cells = lastCell ~ n.cells;
                    ln.cells = ln.cells[0 .. $ - 1];
                    par.cells[j - 1].key = ln.cells[$ - 1].key;
                }
                else
                {
                    Cell moved;
                    moved.key = par.cells[j - 1].key;
                    moved.child = ln.link;
                    n.cells = moved ~ n.cells;
                    par.cells[j - 1].key = lastCell.key;
                    ln.link = lastCell.child;
                    ln.cells = ln.cells[0 .. $ - 1];
                }
                store(lPage, ln);
                store(nPage, n);
                storeSplitting(path[0 .. level - 1], st.page, par);
                return;
            }
            if (hasR && rn.cells.length > 0
                && rn.used() - rn.cellCost(rn.cells[0]) >= MIN_FILL)
            {
                // borrow from the right
                auto firstCell = rn.cells[0];
                if (n.isLeaf)
                {
                    n.cells = n.cells ~ firstCell;
                    rn.cells = rn.cells[1 .. $];
                    par.cells[j].key = firstCell.key;
                }
                else
                {
                    Cell moved;
                    moved.key = par.cells[j].key;
                    moved.child = n.link;
                    n.cells = n.cells ~ moved;
                    n.link = firstCell.child;
                    par.cells[j].key = firstCell.key;
                    rn.cells = rn.cells[1 .. $];
                }
                store(rPage, rn);
                store(nPage, n);
                storeSplitting(path[0 .. level - 1], st.page, par);
                return;
            }

            if (hasL)
            {
                // merge with the left: the left page survives
                if (n.isLeaf)
                    ln.cells = ln.cells ~ n.cells;
                else
                {
                    Cell moved;
                    moved.key = par.cells[j - 1].key;
                    moved.child = ln.link;
                    ln.cells = ln.cells ~ moved ~ n.cells;
                }
                ln.link = n.link;
                store(lPage, ln);
                if (j == np)
                    par.link = lPage;
                else
                    par.cells[j].child = lPage;
                par.cells = par.cells[0 .. j - 1] ~ par.cells[j .. $];
                pg.free(nPage);
            }
            else
            {
                // merge with the right: N survives
                if (n.isLeaf)
                    n.cells = n.cells ~ rn.cells;
                else
                {
                    Cell moved;
                    moved.key = par.cells[j].key;
                    moved.child = n.link;
                    n.cells = n.cells ~ moved ~ rn.cells;
                }
                n.link = rn.link;
                store(nPage, n);
                if (j + 1 == np)
                    par.link = nPage;
                else
                    par.cells[j + 1].child = nPage;
                par.cells = par.cells[0 .. j] ~ par.cells[j + 1 .. $];
                pg.free(rPage);
            }

            // propagate upward
            if (level == 1)
            {
                if (par.cells.length == 0)
                {
                    setRoot(par.link);
                    pg.free(st.page);
                }
                else
                    store(st.page, par);
                return;
            }
            if (par.used() >= MIN_FILL)
            {
                store(st.page, par);
                return;
            }
            store(st.page, par);
            n = par;
            nPage = st.page;
            level--;
        }
    }

    // ----------------------------------------------------------- traversing

    /// Visit the cells with `lo <= key < hi` in ascending (or descending, when
    /// `reverse`) key order, until `visit` returns `false`. A `null` bound is
    /// open. One descent, then leaf order: O(h + cells visited).
    void walk(const(ubyte)[] lo, bool hasLo, const(ubyte)[] hi, bool hasHi,
            bool reverse, scope Visitor visit)
    {
        if (root == 0)
            return;
        if (hasLo && hasHi && compareBytes(lo, hi) >= 0)
            return;
        walkPage(root, lo, hasLo, hi, hasHi, reverse, visit);
    }

    /// Visit every cell in key order.
    void walkAll(scope Visitor visit)
    {
        walk(null, false, null, false, false, visit);
    }

    private bool walkPage(uint page, const(ubyte)[] lo, bool hasLo, const(ubyte)[] hi,
            bool hasHi, bool reverse, scope Visitor visit)
    {
        auto n = load(page);
        immutable count = n.cells.length;
        if (n.isLeaf)
        {
            if (!reverse)
            {
                size_t i = hasLo ? childIndex(n, lo) : 0;
                for (; i < count; i++)
                {
                    if (hasHi && compareBytes(n.cells[i].key, hi) >= 0)
                        return false;
                    if (!visit(n.cells[i]))
                        return false;
                }
                return true;
            }
            // first index whose key is >= hi, then step back
            size_t i = hasHi ? childIndex(n, hi) : count;
            while (i > 0)
            {
                i--;
                if (hasLo && compareBytes(n.cells[i].key, lo) < 0)
                    return false;
                if (!visit(n.cells[i]))
                    return false;
            }
            return true;
        }
        if (!reverse)
        {
            size_t i = hasLo ? childIndex(n, lo) : 0;
            for (; i <= count; i++)
            {
                immutable child = i < count ? n.cells[i].child : n.link;
                if (!walkPage(child, lo, hasLo, hi, hasHi, reverse, visit))
                    return false;
                if (hasHi && i < count && compareBytes(n.cells[i].key, hi) >= 0)
                    return false;
            }
            return true;
        }
        size_t i = hasHi ? childIndex(n, hi) : count;
        while (true)
        {
            immutable child = i < count ? n.cells[i].child : n.link;
            if (!walkPage(child, lo, hasLo, hi, hasHi, reverse, visit))
                return false;
            if (i == 0)
                return true;
            if (hasLo && compareBytes(n.cells[i - 1].key, lo) < 0)
                return false;
            i--;
        }
    }

    /// Free every page of the tree in post-order (SPEC §12.6) and empty it.
    /// Returns the number of pages freed.
    size_t dropAll()
    {
        size_t freed = 0;
        if (root != 0)
            freed = freePages(root);
        setRoot(0);
        return freed;
    }

    private size_t freePages(uint page)
    {
        auto n = load(page);
        size_t freed = 0;
        if (!n.isLeaf)
        {
            foreach (ref c; n.cells)
                freed += freePages(c.child);
            freed += freePages(n.link);
        }
        pg.free(page);
        return freed + 1;
    }
}

version (unittest)
{
    import std.algorithm : sort;
    import std.random : Random, uniform;
    import std.conv : to;

    private Cell indexCell(string key)
    {
        Cell c;
        c.key = cast(const(ubyte)[]) key;
        return c;
    }

    /// Check separator bounds and uniform leaf depth; returns the leaf depth.
    private size_t checkSubtree(Pager pg, uint page, const(ubyte)[] lo, bool hasLo,
            const(ubyte)[] hi, bool hasHi, bool isRoot)
    {
        auto n = decodeNode(pg.readPage(page));
        assert(isRoot || n.cells.length > 0, "non-root page is empty");
        assert(n.used() <= CAPACITY);
        foreach (i, ref c; n.cells)
        {
            if (i)
                assert(compareBytes(n.cells[i - 1].key, c.key) < 0);
            if (hasLo)
                assert(n.isLeaf ? compareBytes(c.key, lo) > 0 : compareBytes(c.key, lo) > 0);
            if (hasHi && n.isLeaf)
                assert(compareBytes(c.key, hi) <= 0);
        }
        if (n.isLeaf)
            return 1;
        size_t depth = 0;
        foreach (i; 0 .. n.cells.length + 1)
        {
            immutable child = i < n.cells.length ? n.cells[i].child : n.link;
            const(ubyte)[] cLo = i > 0 ? n.cells[i - 1].key : lo;
            immutable cHasLo = i > 0 || hasLo;
            const(ubyte)[] cHi = i < n.cells.length ? n.cells[i].key : hi;
            immutable cHasHi = i < n.cells.length || hasHi;
            immutable d = checkSubtree(pg, child, cLo, cHasLo, cHi, cHasHi, false);
            assert(depth == 0 || depth == d, "leaves at different depths");
            depth = d;
        }
        return depth + 1;
    }
}

unittest
{
    // Random inserts and deletes against a sorted model, checking the
    // structure after every few operations.
    import tessera.recover : openPager;

    auto pg = openPager(null, null);
    pg.begin();
    auto tree = Tree.indexTree(pg, 0);
    pg.header.slots[0].live = true;
    auto rng = Random(42);
    bool[string] model;

    foreach (step; 0 .. 6000)
    {
        immutable k = "key" ~ uniform(0, 1500, rng).to!string ~ "xxxxxxxxxxxxxxxxxxxxxxxx"[0 .. uniform(0, 24, rng)];
        immutable del = step > 2500 ? uniform(0, 3, rng) != 0 : uniform(0, 4, rng) == 0;
        if (del)
        {
            assert(tree.remove(cast(const(ubyte)[]) k) == ((k in model) !is null));
            model.remove(k);
        }
        else
        {
            assert(tree.upsert(indexCell(k)) == ((k in model) !is null));
            model[k] = true;
        }
        if (step % 97 == 0 && tree.root != 0)
        {
            checkSubtree(pg, tree.root, null, false, null, false, true);
            immutable h = tree.height;
            assert(h >= 1);
        }
    }

    auto keys = model.keys;
    keys.sort();
    string[] forward, backward;
    tree.walkAll((ref const Cell c) { forward ~= cast(string) c.key.idup; return true; });
    assert(forward == keys);
    tree.walk(null, false, null, false, true, (ref const Cell c) { backward ~= cast(string) c.key.idup; return true; });
    assert(backward.length == keys.length);
    foreach (i, k; backward)
        assert(k == keys[$ - 1 - i]);

    // bounded range, both directions
    const(ubyte)[] lo = cast(const(ubyte)[]) "key3", hi = cast(const(ubyte)[]) "key6";
    string[] want;
    foreach (k; keys)
        if (k >= "key3" && k < "key6")
            want ~= k;
    string[] got;
    tree.walk(lo, true, hi, true, false, (ref const Cell c) { got ~= cast(string) c.key.idup; return true; });
    assert(got == want);
    got = null;
    tree.walk(lo, true, hi, true, true, (ref const Cell c) { got ~= cast(string) c.key.idup; return true; });
    assert(got.length == want.length);

    // a visitor can stop the walk
    size_t seen;
    tree.walkAll((ref const Cell c) { return ++seen < 5; });
    assert(seen == 5);

    // dropping the tree frees every page exactly once
    immutable before = pg.header.freelistCount;
    immutable freed = tree.dropAll();
    assert(pg.header.freelistCount == before + freed);
    assert(tree.root == 0 && tree.height == 0);
    // everything on the free list is distinct
    bool[uint] seenPages;
    for (uint p = pg.header.freelistHead; p != 0; p = getU32(pg.readPage(p), 4))
    {
        assert(p !in seenPages);
        seenPages[p] = true;
    }
    assert(seenPages.length == pg.header.freelistCount);
}
