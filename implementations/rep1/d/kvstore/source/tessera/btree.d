/// B+tree operations (search, cursors, insert/replace, delete with borrow and
/// merge, whole-tree free) over canonical pages.
module tessera.btree;

import tessera.bytes;
import tessera.constants;
import tessera.node;
import tessera.pager;

/// Identifies one of the trees: the primary tree or the tree of an index slot.
struct TreeRef
{
    bool primary = true;
    size_t slot;

    /// The primary tree.
    static TreeRef primaryTree() pure nothrow @nogc @safe { return TreeRef(true, 0); }

    /// The tree of index slot `s`.
    static TreeRef indexTree(size_t s) pure nothrow @nogc @safe { return TreeRef(false, s); }

    /// The kind of this tree's leaf pages.
    NodeKind leafKind() const pure nothrow @nogc @safe
    {
        return primary ? NodeKind.primaryLeaf : NodeKind.indexLeaf;
    }
}

/// Root page of a tree (0 when empty).
uint rootOf(const Pager pg, TreeRef t) nothrow
{
    return t.primary ? pg.header.primaryRoot : pg.header.slots[t.slot].root;
}

private void setRoot(Pager pg, TreeRef t, uint root)
{
    if (t.primary)
        pg.header.primaryRoot = root;
    else
        pg.header.slots[t.slot].root = root;
}

/// Height of a tree: 0 when empty, 1 for a lone leaf, and so on.
uint heightOf(const Pager pg, TreeRef t) nothrow
{
    uint p = rootOf(pg, t);
    uint h = 0;
    while (p != 0)
    {
        h++;
        auto img = pg.read(p);
        if (img[0] != typeInterior)
            break;
        p = rawCount(img) ? rawChild(img, 0) : rawLink(img);
    }
    return h;
}

// ------------------------------------------------------------------ cursor

/// A position in a tree's leaf level. Invalid (`!valid`) past the last cell.
struct Cursor
{
    private Pager pager;
    private const(ubyte)[] img;
    private size_t idx;

    /// True while the cursor designates a cell.
    bool valid() const pure nothrow @nogc @safe { return img.length != 0; }

    /// The key of the current cell (a view valid until the page is rewritten).
    const(ubyte)[] key() const pure nothrow @nogc @safe { return rawKey(img, idx); }

    /// For a primary leaf: total serialised document length.
    uint docLen() const pure nothrow @nogc @safe { return getU32(img, rawCellOffset(img, idx) + 2); }

    /// For a primary leaf: first overflow page, 0 when none.
    uint overflow() const pure nothrow @nogc @safe { return getU32(img, rawCellOffset(img, idx) + 8); }

    /// For a primary leaf: the document bytes stored inline.
    const(ubyte)[] inlineData() const pure nothrow @nogc @safe
    {
        immutable off = rawCellOffset(img, idx);
        immutable kl = getU16(img, off);
        immutable il = getU16(img, off + 6);
        return img[off + 12 + kl .. off + 12 + kl + il];
    }

    /// Move to the next cell in key order.
    void next() nothrow
    {
        idx++;
        normalize();
    }

    private void normalize() nothrow
    {
        while (img.length != 0 && idx >= rawCount(img))
        {
            immutable l = rawLink(img);
            if (l == 0)
                img = null;
            else
                img = pager.read(l);
            idx = 0;
        }
    }
}

/// A cursor at the first cell whose key is `>= key`.
Cursor seek(Pager pg, TreeRef t, const(ubyte)[] key) nothrow
{
    Cursor c = Cursor(pg);
    uint p = rootOf(pg, t);
    if (p == 0)
        return c;
    auto img = pg.read(p);
    while (img[0] == typeInterior)
    {
        immutable i = rawLowerBound(img, key);
        p = i < rawCount(img) ? rawChild(img, i) : rawLink(img);
        img = pg.read(p);
    }
    c.img = img;
    c.idx = rawLowerBound(img, key);
    c.normalize();
    return c;
}

/// A cursor at the first cell of the tree.
Cursor first(Pager pg, TreeRef t) nothrow
{
    Cursor c = Cursor(pg);
    uint p = rootOf(pg, t);
    if (p == 0)
        return c;
    auto img = pg.read(p);
    while (img[0] == typeInterior)
    {
        p = rawCount(img) ? rawChild(img, 0) : rawLink(img);
        img = pg.read(p);
    }
    c.img = img;
    c.idx = 0;
    c.normalize();
    return c;
}

/// A cursor at exactly `key`; invalid when the key is absent.
Cursor lookup(Pager pg, TreeRef t, const(ubyte)[] key) nothrow
{
    auto c = seek(pg, t, key);
    if (c.valid && compareBytes(c.key, key) != 0)
        c.img = null;
    return c;
}

// ---------------------------------------------------------------- mutation

private struct PathEntry
{
    uint page;
    Node node;
    size_t idx; // child index taken (== cell count for `link`)
}

private size_t nodeLowerBound(const ref Node n, const(ubyte)[] key) pure nothrow @nogc @safe
{
    size_t lo = 0, hi = n.cells.length;
    while (lo < hi)
    {
        immutable mid = (lo + hi) / 2;
        if (compareBytes(key, n.cells[mid].key) <= 0)
            hi = mid;
        else
            lo = mid + 1;
    }
    return lo;
}

/// Descend to the leaf for `key`, decoding the interior pages on the way.
private uint descend(Pager pg, TreeRef t, const(ubyte)[] key, ref PathEntry[] path, out const(ubyte)[] leafImg)
{
    uint p = rootOf(pg, t);
    while (true)
    {
        auto img = pg.read(p);
        if (img[0] != typeInterior)
        {
            leafImg = img;
            return p;
        }
        auto node = decodeNode(img);
        immutable i = nodeLowerBound(node, key);
        immutable next = i < node.cells.length ? node.cells[i].child : node.link;
        path ~= PathEntry(p, node, i);
        p = next;
    }
}

/// Insert a cell, or replace the cell with the same key in place.
void insert(Pager pg, TreeRef t, Cell cell)
{
    if (rootOf(pg, t) == 0)
    {
        immutable r = pg.allocate();
        pg.write(r, encodeNode(Node(t.leafKind, 0, null)));
        setRoot(pg, t, r);
    }
    PathEntry[] path;
    const(ubyte)[] img;
    immutable leafPage = descend(pg, t, cell.key, path, img);
    auto leaf = decodeNode(img);
    immutable pos = nodeLowerBound(leaf, cell.key);
    if (pos < leaf.cells.length && compareBytes(leaf.cells[pos].key, cell.key) == 0)
        leaf.cells[pos] = cell;
    else
        leaf.cells = leaf.cells[0 .. pos] ~ cell ~ leaf.cells[pos .. $];
    storeNode(pg, t, path, path.length, leaf, leafPage);
}

/// Write the node at depth `d` of `path` (its parent is `path[d-1]`); when it
/// overflows, split it and install the separator in the parent, cascading.
private void storeNode(Pager pg, TreeRef t, PathEntry[] path, size_t d, Node node, uint page)
{
    while (true)
    {
        if (usedBytes(node) <= pageCapacity)
        {
            pg.write(page, encodeNode(node));
            return;
        }
        // Split point: smallest m in 1..n-1 with 2*P[m] >= T.
        immutable total = usedBytes(node);
        immutable n = node.cells.length;
        size_t prefix = 0, m = 1;
        for (size_t k = 0; k < n; k++)
        {
            prefix += 2 + cellSize(node.kind, node.cells[k]);
            if (k + 1 >= 1 && k + 1 <= n - 1 && 2 * prefix >= total)
            {
                m = k + 1;
                break;
            }
        }
        immutable right = pg.allocate();
        Node rn;
        rn.kind = node.kind;
        rn.link = node.link;
        rn.cells = node.cells[m .. $].dup;
        const(ubyte)[] sep;
        if (node.kind == NodeKind.interior)
        {
            sep = node.cells[m - 1].key;
            node.link = node.cells[m - 1].child;
            node.cells = node.cells[0 .. m - 1].dup;
        }
        else
        {
            sep = node.cells[m - 1].key;
            node.link = right;
            node.cells = node.cells[0 .. m].dup;
        }
        pg.write(right, encodeNode(rn));
        pg.write(page, encodeNode(node));
        if (d == 0)
        {
            immutable nr = pg.allocate();
            Node root;
            root.kind = NodeKind.interior;
            root.link = right;
            root.cells = [Cell(sep, page)];
            pg.write(nr, encodeNode(root));
            setRoot(pg, t, nr);
            return;
        }
        auto parent = &path[d - 1];
        immutable j = parent.idx;
        if (j == parent.node.cells.length)
        {
            parent.node.cells = parent.node.cells ~ Cell(sep, page);
            parent.node.link = right;
        }
        else
        {
            auto cs = parent.node.cells.dup;
            cs[j].child = right;
            parent.node.cells = cs[0 .. j] ~ Cell(sep, page) ~ cs[j .. $];
        }
        node = parent.node;
        page = parent.page;
        d--;
    }
}

/// Delete `key`. Returns false (and changes nothing) when it is absent.
bool remove(Pager pg, TreeRef t, const(ubyte)[] key)
{
    if (rootOf(pg, t) == 0)
        return false;
    PathEntry[] path;
    const(ubyte)[] img;
    immutable leafPage = descend(pg, t, key, path, img);
    auto leaf = decodeNode(img);
    immutable pos = nodeLowerBound(leaf, key);
    if (pos >= leaf.cells.length || compareBytes(leaf.cells[pos].key, key) != 0)
        return false;
    leaf.cells = leaf.cells[0 .. pos] ~ leaf.cells[pos + 1 .. $];
    if (path.length == 0)
    {
        if (leaf.cells.length > 0)
            pg.write(leafPage, encodeNode(leaf));
        else
        {
            pg.free(leafPage);
            setRoot(pg, t, 0);
        }
        return true;
    }
    pg.write(leafPage, encodeNode(leaf));
    if (usedBytes(leaf) >= minFill)
        return true;
    repair(pg, t, path, leaf, leafPage);
    return true;
}

private size_t lastCost(const ref Node n) pure nothrow @nogc @safe
{
    return 2 + cellSize(n.kind, n.cells[$ - 1]);
}

private size_t firstCost(const ref Node n) pure nothrow @nogc @safe
{
    return 2 + cellSize(n.kind, n.cells[0]);
}

/// Underflow repair: borrow from the left, borrow from the right, merge with
/// the left, merge with the right; propagating upward after a merge.
private void repair(Pager pg, TreeRef t, PathEntry[] path, Node n, uint npage)
{
    while (true)
    {
        auto pe = &path[$ - 1];
        immutable j = pe.idx;
        immutable np = pe.node.cells.length;
        immutable hasL = j >= 1;
        immutable hasR = j < np;
        immutable uint lpage = hasL ? pe.node.cells[j - 1].child : 0;
        immutable uint rpage = hasR ? (j + 1 < np ? pe.node.cells[j + 1].child : pe.node.link) : 0;
        Node l, r;
        if (hasL)
            l = decodeNode(pg.read(lpage));
        if (hasR)
            r = decodeNode(pg.read(rpage));
        immutable interior = n.kind == NodeKind.interior;

        if (hasL && l.cells.length > 0 && usedBytes(l) - lastCost(l) >= minFill)
        {
            auto lastCell = l.cells[$ - 1];
            if (interior)
            {
                n.cells = Cell(pe.node.cells[j - 1].key, l.link) ~ n.cells;
                pe.node.cells[j - 1].key = lastCell.key;
                l.link = lastCell.child;
            }
            else
            {
                n.cells = lastCell ~ n.cells;
                pe.node.cells[j - 1].key = l.cells[$ - 2].key;
            }
            l.cells = l.cells[0 .. $ - 1];
            pg.write(lpage, encodeNode(l));
            pg.write(npage, encodeNode(n));
            storeNode(pg, t, path, path.length - 1, pe.node, pe.page);
            return;
        }
        if (hasR && r.cells.length > 0 && usedBytes(r) - firstCost(r) >= minFill)
        {
            auto firstCell = r.cells[0];
            if (interior)
            {
                n.cells = n.cells ~ Cell(pe.node.cells[j].key, n.link);
                n.link = firstCell.child;
                pe.node.cells[j].key = firstCell.key;
            }
            else
            {
                n.cells = n.cells ~ firstCell;
                pe.node.cells[j].key = firstCell.key;
            }
            r.cells = r.cells[1 .. $];
            pg.write(rpage, encodeNode(r));
            pg.write(npage, encodeNode(n));
            storeNode(pg, t, path, path.length - 1, pe.node, pe.page);
            return;
        }
        if (hasL)
        {
            // Merge N into L; L survives.
            if (interior)
                l.cells = l.cells ~ Cell(pe.node.cells[j - 1].key, l.link);
            l.cells = l.cells ~ n.cells;
            l.link = n.link;
            auto pc = pe.node.cells;
            pe.node.cells = pc[0 .. j - 1] ~ pc[j .. $];
            if (j == np)
                pe.node.link = lpage;
            else
                pe.node.cells[j - 1].child = lpage;
            pg.write(lpage, encodeNode(l));
            pg.free(npage);
        }
        else
        {
            // Merge R into N; N survives.
            if (interior)
                n.cells = n.cells ~ Cell(pe.node.cells[j].key, n.link);
            n.cells = n.cells ~ r.cells;
            n.link = r.link;
            auto pc = pe.node.cells;
            pe.node.cells = pc[0 .. j] ~ pc[j + 1 .. $];
            if (j + 1 == np)
                pe.node.link = npage;
            else
                pe.node.cells[j].child = npage;
            pg.write(npage, encodeNode(n));
            pg.free(rpage);
        }
        // Propagate upward.
        auto parent = pe.node;
        immutable ppage = pe.page;
        path = path[0 .. $ - 1];
        if (path.length == 0)
        {
            if (parent.cells.length == 0)
            {
                setRoot(pg, t, parent.link);
                pg.free(ppage);
            }
            else
                pg.write(ppage, encodeNode(parent));
            return;
        }
        pg.write(ppage, encodeNode(parent));
        if (usedBytes(parent) >= minFill)
            return;
        n = parent;
        npage = ppage;
    }
}

/// Free every page of the tree rooted at `p` in post-order. Returns the
/// number of pages freed.
uint freeTree(Pager pg, uint p)
{
    if (p == 0)
        return 0;
    auto img = pg.read(p);
    uint freed = 0;
    if (img[0] == typeInterior)
    {
        immutable cnt = rawCount(img);
        uint[] kids;
        foreach (i; 0 .. cnt)
            kids ~= rawChild(img, i);
        kids ~= rawLink(img);
        foreach (k; kids)
            freed += freeTree(pg, k);
    }
    pg.free(p);
    return freed + 1;
}
