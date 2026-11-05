/// The bind pass: resolves names against the schema, assigns aggregate calls
/// to accumulator slots, runs every semantic check and turns literals into
/// ready values. Binding never touches table contents, so once it succeeds
/// execution cannot fail.
module minisql.binder;

import minisql.ast;
import minisql.errors;
import minisql.plan;
import minisql.table;
import minisql.value;

/// Looks tables up by (lower-cased) name.
alias TableLookup = Table delegate(string name) @safe;

private struct Slot
{
    string name; // effective name
    Table table;
}

private BExpr constant(Value v) pure @safe
{
    auto b = new BExpr;
    b.kind = NodeKind.constant;
    b.value = v;
    return b;
}

private bool containsAggregate(const Expr e) pure nothrow @nogc @safe
{
    if (e is null)
        return false;
    if (e.kind == ExprKind.aggregate)
        return true;
    return containsAggregate(e.lhs) || containsAggregate(e.rhs);
}

/// Binds expressions against a set of FROM slots.
private final class ExprBinder
{
    Slot[] slots;
    bool groupMode; // post-aggregation: columns must be grouping columns
    GroupCol[] groupCols;
    AggSpec[] aggs;
    private bool inAggregate;

    this(Slot[] slots) pure nothrow @safe
    {
        this.slots = slots;
    }

    GroupCol resolve(string qualifier, string name) @safe
    {
        if (qualifier !is null)
        {
            foreach (i, s; slots)
            {
                if (s.name == qualifier)
                {
                    immutable c = s.table.columnIndex(name);
                    if (c < 0)
                        fail("no such column: " ~ qualifier ~ "." ~ name);
                    return GroupCol(cast(int) i, c);
                }
            }
            fail("no such table: " ~ qualifier);
        }
        GroupCol found;
        int count = 0;
        foreach (i, s; slots)
        {
            immutable c = s.table.columnIndex(name);
            if (c >= 0)
            {
                found = GroupCol(cast(int) i, c);
                count++;
            }
        }
        if (count == 0)
            fail("no such column: " ~ name);
        if (count > 1)
            fail("ambiguous column: " ~ name);
        return found;
    }

    BExpr bind(const Expr e) @safe
    {
        final switch (e.kind)
        {
        case ExprKind.intLit:
            return constant(Value.makeInt(e.intValue));
        case ExprKind.strLit:
            return constant(Value.makeText(e.text));
        case ExprKind.nullLit:
            return constant(Value.makeNull());
        case ExprKind.column:
            {
                immutable gc = resolve(e.qualifier, e.text);
                if (groupMode && !inAggregate)
                {
                    bool ok = false;
                    foreach (g; groupCols)
                        if (g == gc)
                            ok = true;
                    if (!ok)
                        fail("column is not grouped: " ~ e.text);
                }
                auto b = new BExpr;
                b.kind = NodeKind.column;
                b.slot = gc.slot;
                b.col = gc.col;
                b.mask = cast(ubyte)(1 << gc.slot);
                return b;
            }
        case ExprKind.neg:
            return unary(NodeKind.neg, e);
        case ExprKind.not:
            return unary(NodeKind.not, e);
        case ExprKind.isNull:
            return unary(NodeKind.isNull, e);
        case ExprKind.isNotNull:
            return unary(NodeKind.isNotNull, e);
        case ExprKind.binary:
            {
                auto b = new BExpr;
                b.kind = NodeKind.binary;
                b.op = e.op;
                b.a = bind(e.lhs);
                b.b = bind(e.rhs);
                b.mask = b.a.mask | b.b.mask;
                return b;
            }
        case ExprKind.aggregate:
            {
                if (!groupMode)
                    fail("aggregate function not allowed here");
                if (inAggregate)
                    fail("nested aggregate function");
                AggSpec spec;
                spec.fn = e.fn;
                if (!e.star)
                {
                    inAggregate = true;
                    scope (exit)
                        inAggregate = false;
                    spec.arg = bind(e.lhs);
                }
                auto b = new BExpr;
                b.kind = NodeKind.aggRef;
                b.aggIndex = cast(int) aggs.length;
                aggs ~= spec;
                return b;
            }
        }
    }

    private BExpr unary(NodeKind k, const Expr e) @safe
    {
        auto b = new BExpr;
        b.kind = k;
        b.a = bind(e.lhs);
        b.mask = b.a.mask;
        return b;
    }
}

private void splitConjuncts(BExpr e, ref BExpr[] out_) pure nothrow @safe
{
    if (e.kind == NodeKind.binary && e.op == BinOp.and)
    {
        splitConjuncts(e.a, out_);
        splitConjuncts(e.b, out_);
    }
    else
        out_ ~= e;
}

private Table findTable(TableLookup lookup, string name) @safe
{
    auto t = lookup(name);
    if (t is null)
        fail("no such table: " ~ name);
    return t;
}

/// Binds a single-table WHERE clause (UPDATE, DELETE).
private BExpr[] bindFilter(Slot[] slots, const Expr where_) @safe
{
    BExpr[] filters;
    if (where_ !is null)
        splitConjuncts(new ExprBinder(slots).bind(where_), filters);
    return filters;
}

/// Binds a CREATE TABLE statement, returning the new (empty) table.
Table bindCreate(const CreateStmt st, TableLookup lookup) @safe
{
    if (lookup(st.table) !is null)
        fail("table already exists: " ~ st.table);
    foreach (i, c; st.columns)
        foreach (d; st.columns[0 .. i])
            if (c == d)
                fail("duplicate column name: " ~ c);
    return new Table(st.table, st.columns.dup);
}

/// Binds an INSERT statement.
BoundInsert bindInsert(const InsertStmt st, TableLookup lookup) @safe
{
    auto b = new BoundInsert;
    b.table = findTable(lookup, st.table);
    auto binder = new ExprBinder(null);
    foreach (row; st.rows)
    {
        if (row.length != b.table.columns.length)
            fail("wrong number of values");
        BExpr[] r;
        foreach (e; row)
            r ~= binder.bind(e);
        b.rows ~= r;
    }
    return b;
}

/// Binds a DELETE statement.
BoundDelete bindDelete(const DeleteStmt st, TableLookup lookup) @safe
{
    auto b = new BoundDelete;
    b.table = findTable(lookup, st.table);
    b.filters = bindFilter([Slot(b.table.name, b.table)], st.where_);
    return b;
}

/// Binds an UPDATE statement.
BoundUpdate bindUpdate(const UpdateStmt st, TableLookup lookup) @safe
{
    auto b = new BoundUpdate;
    b.table = findTable(lookup, st.table);
    auto slots = [Slot(b.table.name, b.table)];
    auto binder = new ExprBinder(slots);
    foreach (i, name; st.columns)
    {
        immutable c = b.table.columnIndex(name);
        if (c < 0)
            fail("no such column: " ~ name);
        b.columns ~= c;
        b.values ~= binder.bind(st.values[i]);
    }
    b.filters = bindFilter(slots, st.where_);
    return b;
}

/// Binds a SELECT statement.
BoundSelect bindSelect(const SelectStmt st, TableLookup lookup) @safe
{
    auto b = new BoundSelect;

    // FROM
    Slot[] slots;
    foreach (r; st.from)
    {
        auto t = findTable(lookup, r.name);
        foreach (s; slots)
            if (s.name == r.effective)
                fail("duplicate table name in FROM: " ~ r.effective);
        slots ~= Slot(r.effective, t);
    }
    b.slotCount = cast(int) slots.length;
    foreach (i, s; slots)
        b.tables[i] = s.table;

    // Expand `*` into one column expression per column.
    struct Item
    {
        const(Expr) expr;
        string alias_;
    }

    Item[] items;
    foreach (it; st.items)
    {
        if (!it.star)
        {
            items ~= Item(it.expr, it.alias_);
            continue;
        }
        if (slots.length == 0)
            fail("* requires a FROM clause");
        foreach (s; slots)
            foreach (c; s.table.columns)
            {
                auto e = new Expr;
                e.kind = ExprKind.column;
                e.qualifier = s.name;
                e.text = c;
                items ~= Item(e, null);
            }
    }

    // Is this an aggregate query?
    bool agg = st.groupBy.length > 0 || containsAggregate(st.having);
    foreach (it; items)
        agg = agg || containsAggregate(it.expr);
    foreach (o; st.orderBy)
        agg = agg || containsAggregate(o.expr);
    b.aggregate = agg;

    auto binder = new ExprBinder(slots);

    // WHERE / ON: aggregates are rejected because the binder is not in group mode.
    BExpr[] conjuncts;
    if (st.on !is null)
        splitConjuncts(binder.bind(st.on), conjuncts);
    if (st.where_ !is null)
        splitConjuncts(binder.bind(st.where_), conjuncts);
    classifyConjuncts(b, conjuncts);

    // GROUP BY
    foreach (g; st.groupBy)
        b.groupCols ~= binder.resolve(g.qualifier, g.name);

    binder.groupMode = agg;
    binder.groupCols = b.groupCols;

    foreach (it; items)
        b.items ~= binder.bind(it.expr);
    if (st.having !is null)
        b.having = binder.bind(st.having);

    // ORDER BY
    foreach (o; st.orderBy)
    {
        SortKey key;
        key.desc = o.desc;
        bool resolved = false;
        if (o.expr.kind == ExprKind.column && o.expr.qualifier is null)
        {
            foreach (i, it; items)
                if (it.alias_ !is null && it.alias_ == o.expr.text)
                {
                    key.field = i;
                    resolved = true;
                    break;
                }
        }
        else if (o.expr.kind == ExprKind.intLit)
        {
            if (o.expr.intValue < 1 || o.expr.intValue > items.length)
                fail("ORDER BY position out of range");
            key.field = cast(size_t)(o.expr.intValue - 1);
            resolved = true;
        }
        if (!resolved)
        {
            key.field = items.length + b.extraKeys.length;
            b.extraKeys ~= binder.bind(o.expr);
        }
        b.sortKeys ~= key;
    }

    b.aggs = binder.aggs;
    b.hasLimit = st.hasLimit;
    b.limit = st.limit;
    b.offset = st.offset;
    return b;
}

/// Sorts the conjuncts of ON and WHERE by the tables they read.
private void classifyConjuncts(BoundSelect b, BExpr[] conjuncts) pure nothrow @safe
{
    foreach (c; conjuncts)
    {
        if (c.mask <= 1)
            b.firstFilters ~= c;
        else if (c.mask == 2)
            b.secondFilters ~= c;
        else if (c.kind == NodeKind.binary && c.op == BinOp.eq && c.a.mask == 1 && c.b.mask == 2)
            b.joinKeys ~= KeyPair(c.a, c.b);
        else if (c.kind == NodeKind.binary && c.op == BinOp.eq && c.a.mask == 2 && c.b.mask == 1)
            b.joinKeys ~= KeyPair(c.b, c.a);
        else
            b.residual ~= c;
    }
}
