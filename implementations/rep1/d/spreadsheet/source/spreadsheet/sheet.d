/// The spreadsheet engine: cell storage, dependency graph, incremental recalculation.
module spreadsheet.sheet;

import std.algorithm.sorting : sort;

import spreadsheet.ast;
import spreadsheet.cellref;
import spreadsheet.eval;
import spreadsheet.numfmt : parseNumber;
import spreadsheet.parser;
import spreadsheet.stack;
import spreadsheet.value;

/// What a cell holds.
enum ContentKind : ubyte { empty, literal, formula }

private struct Cell
{
    uint key;
    ContentKind content;
    bool selfDep;           /// the formula reads its own cell
    Formula* formula;
    uint[] deps;            /// deduplicated cells this formula reads
    Stack!uint dependents;  /// cells whose formulas read this one
}

/**
 * An in-memory spreadsheet.
 *
 * Cells hold numbers, strings or formulas.  After every `set` or `clear`
 * the sheet is consistent: only the cells that transitively depend on the
 * edited cell are recalculated, and cells on a dependency cycle hold
 * `#CYCLE!`.
 */
final class Sheet
{
    private
    {
        Cell[] cells;
        Value[] values;
        uint[uint] handleOf;   // cell key -> dense handle

        // Scratch state reused by every recalculation (reset in O(|affected|)).
        uint[] mark;           // == generation when the cell is in the affected set
        uint[] depStamp;       // == depGen when already seen while deduplicating
        int[] tIndex, tLow;
        bool[] onStack;
        uint generation, depGen;
        Stack!uint affected, dfsStack, sccStack;
        Stack!Frame frames;

        ulong[] sortedCells;   // (key << 32 | handle), valid unless sortedDirty
        bool sortedDirty = true;
    }

    private static struct Frame
    {
        uint v;
        uint next;
    }

    // ---- public API ------------------------------------------------------

    /**
     * Replace the content of `cell`.
     *
     * `content` is a formula (`=...`), a string literal (`"..."`) or a number
     * literal.  Throws `SyntaxError` for malformed content and
     * `InvalidCellName` for a bad cell name; the sheet is unchanged then.
     */
    void set(const(char)[] cell, string content)
    {
        set(parseName(cell), content);
    }

    /// ditto
    void set(CellRef cell, string content)
    {
        uint h = handleFor(cell.key);
        Formula* newFormula;
        Value literal;
        ContentKind kind;
        if (content.length > 0 && content[0] == '=')
        {
            // Resolving may create handles; that never changes visible state.
            auto f = new Formula;
            *f = parseFormula(content, (CellRef r) => handleFor(r.key));
            newFormula = f;
            kind = ContentKind.formula;
        }
        else if (content.length >= 2 && content[0] == '"' && content[$ - 1] == '"')
        {
            literal = Value.text(content[1 .. $ - 1]);
            kind = ContentKind.literal;
        }
        else
        {
            double d;
            if (!parseNumber(content, d))
                throw new SyntaxError("invalid cell content: " ~ content);
            literal = Value.number(d == 0 ? 0 : d); // -0 is just 0
            kind = ContentKind.literal;
        }
        install(h, kind, newFormula, literal);
    }

    /// Make `cell` empty.
    void clear(const(char)[] cell)
    {
        clear(parseName(cell));
    }

    /// ditto
    void clear(CellRef cell)
    {
        if (auto p = cell.key in handleOf)
            install(*p, ContentKind.empty, null, Value.empty);
    }

    /// The current value of `cell` (empty for a cell that was never set).
    Value get(const(char)[] cell) const
    {
        return get(parseName(cell));
    }

    /// ditto
    Value get(CellRef cell) const
    {
        if (auto p = cell.key in handleOf)
            return values[*p];
        return Value.empty;
    }

    /// The displayed text of `cell` (empty string for an empty cell).
    string display(const(char)[] cell) const
    {
        return get(cell).toString();
    }

    /// True if `cell` has content.
    bool isEmpty(CellRef cell) const
    {
        if (auto p = cell.key in handleOf)
            return cells[*p].content == ContentKind.empty;
        return true;
    }

    /// Number of non-empty cells.
    size_t length() const
    {
        size_t n = 0;
        foreach (ref c; cells)
            if (c.content != ContentKind.empty)
                n++;
        return n;
    }

    /**
     * Write one `<CELL> <displayed value>\n` line per non-empty cell, in
     * row-major order, to the output range `sink` of chars.
     */
    void dump(Sink)(ref Sink sink)
    {
        if (sortedDirty)
        {
            sortedCells.length = 0;
            sortedCells.reserve(cells.length);
            foreach (h, ref c; cells)
                if (c.content != ContentKind.empty)
                    sortedCells ~= (cast(ulong) c.key << 32) | h;
            sort(sortedCells);
            sortedDirty = false;
        }
        foreach (e; sortedCells)
        {
            CellRef.fromKey(cast(uint)(e >> 32)).toString(sink);
            sink.put(' ');
            values[cast(uint) e].display(sink);
            sink.put('\n');
        }
    }

    /// `dump` into a string.
    string dump()
    {
        import std.array : appender;
        auto app = appender!string();
        dump(app);
        return app.data;
    }

    // ---- internals -------------------------------------------------------

    private static CellRef parseName(const(char)[] name)
    {
        CellRef r;
        if (!tryParseCellRef(name, r))
            throw new InvalidCellName("invalid cell name: " ~ name.idup);
        return r;
    }

    private uint handleFor(uint key) @safe nothrow
    {
        if (auto p = key in handleOf)
            return *p;
        uint h = cast(uint) cells.length;
        cells ~= Cell(key);
        values ~= Value.empty;
        mark ~= 0;
        depStamp ~= 0;
        tIndex ~= 0;
        tLow ~= 0;
        onStack ~= false;
        handleOf[key] = h;
        return h;
    }

    /// Replace cell `h`'s content and bring the sheet back to consistency.
    private void install(uint h, ContentKind kind, Formula* formula, Value literal)
    {
        Cell* c = &cells[h];
        if ((c.content == ContentKind.empty) != (kind == ContentKind.empty))
            sortedDirty = true;

        foreach (d; c.deps)
            cells[d].dependents.swapRemove(h);
        c.deps = null;
        c.selfDep = false;
        c.content = kind;
        c.formula = formula;
        values[h] = literal;

        if (formula !is null && !formula.invalid)
        {
            depGen++;
            uint[] deps;
            void note(uint d)
            {
                if (depStamp[d] != depGen)
                {
                    depStamp[d] = depGen;
                    deps ~= d;
                }
            }
            foreach (ref n; formula.nodes)
                if (n.kind == NodeKind.cell)
                    note(n.a);
            foreach (d; formula.rangeCells)
                note(d);
            c.deps = deps;
            c.selfDep = depStamp[h] == depGen;
            foreach (d; deps)
                cells[d].dependents.push(h);
        }
        recalculate(h);
    }

    /// Recompute `start` and everything that transitively reads it.
    private void recalculate(uint start)
    {
        // 1. The affected set A: start plus all transitive dependents.
        generation++;
        affected.clear();
        dfsStack.clear();
        dfsStack.push(start);
        mark[start] = generation;
        while (!dfsStack.empty)
        {
            uint v = dfsStack.pop();
            affected.push(v);
            foreach (d; cells[v].dependents[])
            {
                if (mark[d] != generation)
                {
                    mark[d] = generation;
                    dfsStack.push(d);
                }
            }
        }

        // 2. Iterative Tarjan over A along dependency edges.  Components are
        //    emitted dependencies-first, so each can be evaluated immediately.
        int counter = 0;
        foreach (root; affected[])
        {
            if (tIndex[root] != 0)
                continue;
            tIndex[root] = tLow[root] = ++counter;
            sccStack.push(root);
            onStack[root] = true;
            frames.push(Frame(root, 0));
            while (!frames.empty)
            {
                Frame* fr = &frames.back();
                immutable v = fr.v;
                const(uint)[] deps = cells[v].deps;
                if (fr.next < deps.length)
                {
                    immutable w = deps[fr.next++];
                    if (mark[w] != generation)
                        continue;
                    if (tIndex[w] == 0)
                    {
                        tIndex[w] = tLow[w] = ++counter;
                        sccStack.push(w);
                        onStack[w] = true;
                        frames.push(Frame(w, 0));
                    }
                    else if (onStack[w] && tIndex[w] < tLow[v])
                        tLow[v] = tIndex[w];
                    continue;
                }
                // v's dependencies are all explored.
                if (tLow[v] == tIndex[v])
                    emitComponent(v);
                frames.pop();
                if (!frames.empty)
                {
                    immutable p = frames.back.v;
                    if (tLow[v] < tLow[p])
                        tLow[p] = tLow[v];
                }
            }
        }
        foreach (v; affected[])
            tIndex[v] = 0;
    }

    /// Pop the component rooted at `root` off the Tarjan stack and evaluate it.
    private void emitComponent(uint root)
    {
        if (sccStack.back == root)
        {
            sccStack.pop();
            onStack[root] = false;
            Cell* c = &cells[root];
            if (c.selfDep)
                values[root] = Value.error(Kind.cycle);
            else if (c.content == ContentKind.formula)
                values[root] = evaluate(*c.formula, values);
            return;
        }
        for (;;)
        {
            uint w = sccStack.pop();
            onStack[w] = false;
            values[w] = Value.error(Kind.cycle);
            if (w == root)
                break;
        }
    }
}

/// Thrown when a cell name is not valid (`A1`..`ZZ9999`).
class InvalidCellName : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
