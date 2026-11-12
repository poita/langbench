/**
 * The spreadsheet itself: cell storage, the dependency graph and incremental
 * recalculation.
 *
 * Every cell keeps the edges to the cells its formula reads (ranges
 * expanded) and the reverse edges to the cells that read it.  After each
 * edit the *affected set* (the edited cell and everything that transitively
 * reads it) is found by walking reverse edges, Tarjan's strongly-connected-
 * components algorithm orders it dependencies-first, and each component is
 * evaluated once: cyclic components get `#CYCLE!`, the rest are evaluated
 * from the stored values of the cells they read.  Nothing outside the affected
 * set is touched.
 */
module spreadsheet.sheet;

import std.algorithm.sorting : sort;
import std.algorithm.iteration : uniq;
import std.array : array;
import spreadsheet.ast;
import spreadsheet.cellref;
import spreadsheet.eval;
import spreadsheet.parser;
import spreadsheet.value;

/// One non-empty cell as reported by $(LREF Sheet.dump).
struct DumpEntry
{
    CellRef cell;
    Value value;
}

private final class Cell
{
    uint key;
    ContentKind kind = ContentKind.empty;
    Value value;            // current value (empty for an empty cell)
    Expr formula;           // set when kind == formula
    Cell[] deps;            // cells read by the formula, sorted by key, unique
    Cell[uint] dependents;  // reverse edges, by key

    // Scratch state for recalculation; valid when `epoch` equals the sheet's.
    uint epoch;
    int index, low;
    bool onStack, selfLoop;

    this(uint key) pure nothrow @nogc @safe
    {
        this.key = key;
    }
}

/**
 * An in-memory spreadsheet with incremental recalculation.
 *
 * After every call that changes it, each formula cell's value equals the
 * result of evaluating its formula against the current sheet.
 */
final class Sheet
{
    @safe:

    private Cell[uint] cells;
    private uint epoch;
    private size_t nonEmpty;

    /**
     * Sets a cell from command-style content: a number literal, a string
     * literal in double quotes, or a formula starting with `=`.
     *
     * Throws: $(REF ParseException, spreadsheet,parser) if the content is malformed
     * (the sheet is left unchanged).
     */
    void set(CellRef cell, string content)
    {
        setContent(cell, parseContent(content));
    }

    /// Sets a cell from already-parsed content.
    void setContent(CellRef cell, Content content)
    {
        auto c = obtain(cell.key);
        Cell[] oldDeps = c.deps;
        foreach (d; oldDeps)
            d.dependents.remove(c.key);
        c.deps = null;

        if (c.kind == ContentKind.empty && content.kind != ContentKind.empty)
            nonEmpty++;
        else if (c.kind != ContentKind.empty && content.kind == ContentKind.empty)
            nonEmpty--;

        c.kind = content.kind;
        c.formula = null;
        c.value = Value.init;
        final switch (content.kind)
        {
        case ContentKind.empty:
            break;
        case ContentKind.number:
        case ContentKind.text:
            c.value = content.literal;
            break;
        case ContentKind.formula:
            c.formula = content.formula;
            uint[] keys;
            collectDependencies(content.formula, keys);
            keys.sort();
            foreach (k; keys.uniq)
            {
                auto d = obtain(k);
                c.deps ~= d;
                d.dependents[c.key] = c;
            }
            break;
        }

        recalculate(c);

        foreach (d; oldDeps)
            prune(d);
        prune(c);
    }

    /// Makes a cell empty.
    void clear(CellRef cell)
    {
        if (cell.key in cells)
            setContent(cell, Content.init);
    }

    /// The current value of a cell (empty value for an empty cell).
    Value get(CellRef cell) const
    {
        if (auto c = cell.key in cells)
            return c.value;
        return Value.init;
    }

    /// The displayed text of a cell (`""` for an empty cell).
    string display(CellRef cell) const
    {
        return get(cell).toString;
    }

    /// Number of non-empty cells.
    @property size_t length() const pure nothrow @nogc @safe
    {
        return nonEmpty;
    }

    /// All non-empty cells in row-major order.
    DumpEntry[] dump() const
    {
        uint[] keys;
        keys.reserve(nonEmpty);
        foreach (k, c; cells)
            if (c.kind != ContentKind.empty)
                keys ~= k;
        keys.sort();
        auto result = new DumpEntry[keys.length];
        foreach (i, k; keys)
            result[i] = DumpEntry(CellRef.fromKey(k), cells[k].value);
        return result;
    }

    // ---- internals ----

    private Cell obtain(uint key)
    {
        if (auto p = key in cells)
            return *p;
        auto c = new Cell(key);
        cells[key] = c;
        return c;
    }

    /// Drops a placeholder cell nobody uses any more.
    private void prune(Cell c)
    {
        if (c.kind == ContentKind.empty && c.dependents.length == 0)
        {
            if (auto p = c.key in cells)
                if (*p is c)
                    cells.remove(c.key);
        }
    }

    private Value lookup(uint key)
    {
        if (auto c = key in cells)
            return c.value;
        return Value.init;
    }

    private static struct Frame
    {
        Cell cell;
        size_t next;
    }

    /// Recomputes the edited cell and everything that transitively reads it.
    private void recalculate(Cell root)
    {
        const ep = ++epoch;

        // 1. The affected set: walk reverse edges.
        Cell[] affected;
        {
            Cell[] pending = [root];
            root.epoch = ep;
            root.index = 0;
            root.onStack = false;
            root.selfLoop = false;
            while (pending.length)
            {
                auto c = pending[$ - 1];
                pending = pending[0 .. $ - 1];
                affected ~= c;
                foreach (d; c.dependents)
                {
                    if (d.epoch != ep)
                    {
                        d.epoch = ep;
                        d.index = 0;
                        d.onStack = false;
                        d.selfLoop = false;
                        pending ~= d;
                    }
                }
            }
        }

        // 2. Tarjan's SCC over the subgraph induced by the affected set
        //    (iterative: dependency chains can be thousands of cells deep).
        //    Components are emitted dependencies-first.
        int counter = 0;
        Frame[] frames;
        Cell[] stack;
        Cell[] component;

        void visit(Cell c)
        {
            c.index = c.low = ++counter;
            c.onStack = true;
            stack ~= c;
            frames ~= Frame(c, 0);
        }

        foreach (start; affected)
        {
            if (start.index != 0)
                continue;
            visit(start);
            while (frames.length)
            {
                auto f = &frames[$ - 1];
                auto c = f.cell;
                if (f.next < c.deps.length)
                {
                    auto w = c.deps[f.next++];
                    if (w.epoch != ep)
                        continue;
                    if (w is c)
                        c.selfLoop = true;
                    else if (w.index == 0)
                        visit(w);
                    else if (w.onStack && w.index < c.low)
                        c.low = w.index;
                    continue;
                }

                frames = frames[0 .. $ - 1];
                if (frames.length)
                {
                    auto parent = frames[$ - 1].cell;
                    if (c.low < parent.low)
                        parent.low = c.low;
                }
                if (c.low != c.index)
                    continue;

                // c is the root of a component
                component.length = 0;
                Cell m;
                do
                {
                    m = stack[$ - 1];
                    stack = stack[0 .. $ - 1];
                    m.onStack = false;
                    component ~= m;
                }
                while (m !is c);
                evaluateComponent(component, c.selfLoop);
            }
        }
    }

    private void evaluateComponent(Cell[] component, bool selfLoop)
    {
        if (component.length > 1 || selfLoop)
        {
            foreach (m; component)
                m.value = Value.makeError(ErrorCode.cycle);
            return;
        }
        auto c = component[0];
        if (c.kind != ContentKind.formula)
            return;
        auto v = evaluate(c.formula, &lookup);
        c.value = v.isEmpty ? Value.makeNumber(0) : v;
    }
}

version (unittest)
{
    private CellRef ref_(string name)
    {
        CellRef r;
        const ok = tryParseCellRef(name, r);
        assert(ok);
        return r;
    }

    private string show(Sheet s, string name)
    {
        return s.display(ref_(name));
    }
}

///
unittest
{
    auto sheet = new Sheet;
    sheet.set(ref_("A1"), "10");
    sheet.set(ref_("A2"), "32");
    sheet.set(ref_("A3"), "=A1+A2");
    assert(sheet.show("A3") == "42");

    sheet.set(ref_("A1"), "=A3");          // A1 -> A3 -> A1
    assert(sheet.show("A1") == "#CYCLE!");
    assert(sheet.show("A3") == "#CYCLE!");

    sheet.set(ref_("A1"), "5");            // cycle broken
    assert(sheet.show("A3") == "37");
}

unittest
{
    auto s = new Sheet;
    s.set(ref_("B1"), "=A1");
    assert(s.show("B1") == "0");           // empty reads as 0
    s.set(ref_("A1"), "7");
    assert(s.show("B1") == "7");
    s.clear(ref_("A1"));
    assert(s.show("B1") == "0");
    assert(s.length == 1);
    // placeholder for A1 survives only while B1 reads it
    s.clear(ref_("B1"));
    assert(s.length == 0 && s.cells.length == 0);
}

unittest
{
    // self reference and range containing itself
    auto s = new Sheet;
    s.set(ref_("A1"), "=A1+1");
    assert(s.show("A1") == "#CYCLE!");
    s.set(ref_("B2"), "=SUM(A1:C3)");
    assert(s.show("B2") == "#CYCLE!");
    s.set(ref_("A1"), "1");
    assert(s.show("B2") == "#CYCLE!");     // still reads itself
    s.set(ref_("B2"), "=SUM(A1:A3)");
    assert(s.show("B2") == "1");
}

/// `IF` masks a cycle when the cyclic cell is not the selected branch.
unittest
{
    auto s = new Sheet;
    s.set(ref_("A1"), "=A2");
    s.set(ref_("A2"), "=A1");
    s.set(ref_("B1"), "=IF(1,5,A1)");
    s.set(ref_("B2"), "=IF(0,5,A1)");
    assert(s.show("B1") == "5");
    assert(s.show("B2") == "#CYCLE!");
}

unittest
{
    // dump order is row-major
    auto s = new Sheet;
    s.set(ref_("B2"), "1");
    s.set(ref_("AA1"), "2");
    s.set(ref_("Z1"), "3");
    s.set(ref_("A2"), `""`);
    auto d = s.dump();
    string[] names;
    foreach (e; d)
        names ~= e.cell.toString;
    assert(names == ["Z1", "AA1", "A2", "B2"]);
}

unittest
{
    // long dependency chain (9999 cells) does not overflow the stack
    auto s = new Sheet;
    s.set(CellRef(1, 1), "1");
    foreach (r; 2 .. 10_000)
        s.set(CellRef(1, cast(ushort) r), "=A" ~ CellRef(1, cast(ushort)(r - 1)).toString[1 .. $] ~ "+1");
    assert(s.display(CellRef(1, 9999)) == "9999");
    s.set(CellRef(1, 1), "100");
    assert(s.display(CellRef(1, 9999)) == "10098");
    s.set(CellRef(1, 1), "=A9999");
    assert(s.display(CellRef(1, 5000)) == "#CYCLE!");
}
