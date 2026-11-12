/**
 * Binding: resolves a parsed expression against the tables in scope.
 *
 * Every column reference becomes a (table slot, column index) pair and every
 * semantic rule on expressions is checked here, before anything executes.
 */
module minisql.binder;

import minisql.ast;
import minisql.errors;
import minisql.expr;
import minisql.table;
import minisql.value;

/// A table in scope, under the name its columns are qualified with.
struct Source
{
    string name;
    Table table;
}

/// A resolved column.
struct ResolvedColumn
{
    int slot;
    int column;
}

/// True if `e` contains an aggregate call.
bool containsAggregate(const Expr e) @safe pure nothrow @nogc
{
    if (e is null)
        return false;
    if (e.kind == ExprKind.aggregate)
        return true;
    return containsAggregate(e.lhs) || containsAggregate(e.rhs);
}

/**
 * Binds expressions against a fixed list of sources.
 *
 * Set `allowAggregates` to accept aggregate calls (they are collected in
 * `aggregates`). Set `aggregateQuery` for the select list, HAVING and ORDER
 * BY of an aggregate query: there, a column outside an aggregate call must be
 * one of the `groupColumns`.
 */
final class Binder
{
    Source[] sources;
    bool allowAggregates;
    bool aggregateQuery;
    ResolvedColumn[] groupColumns;
    AggSpec[] aggregates;

    this(Source[] sources) @safe pure nothrow @nogc
    {
        this.sources = sources;
    }

    /// Resolves `qualifier.name` (or bare `name`) to a column.
    ResolvedColumn resolve(string qualifier, string name) const @safe pure
    {
        if (qualifier.length)
        {
            foreach (slot, s; sources)
            {
                if (s.name != qualifier)
                    continue;
                immutable c = s.table.columnIndex(name);
                if (c < 0)
                    fail("no such column");
                return ResolvedColumn(cast(int) slot, cast(int) c);
            }
            fail("no such table");
        }
        ResolvedColumn found;
        int count = 0;
        foreach (slot, s; sources)
        {
            immutable c = s.table.columnIndex(name);
            if (c >= 0)
            {
                found = ResolvedColumn(cast(int) slot, cast(int) c);
                ++count;
            }
        }
        if (count == 0)
            fail("no such column");
        if (count > 1)
            fail("ambiguous column");
        return found;
    }

    /// A bound reference to `c`.
    static BExpr columnExpr(ResolvedColumn c) @safe pure nothrow
    {
        auto b = new BExpr(BKind.column);
        b.slot = c.slot;
        b.column = c.column;
        return b;
    }

    /// Binds `e`.
    BExpr bind(const Expr e, bool insideAggregate = false) @safe pure
    {
        final switch (e.kind)
        {
        case ExprKind.literal:
        {
            auto b = new BExpr(BKind.literal);
            b.value = e.value;
            return b;
        }
        case ExprKind.column:
        {
            immutable c = resolve(e.qualifier, e.name);
            if (aggregateQuery && !insideAggregate)
            {
                bool grouped = false;
                foreach (g; groupColumns)
                    grouped |= g == c;
                if (!grouped)
                    fail("column is not grouped");
            }
            return columnExpr(c);
        }
        case ExprKind.negate:
        {
            auto b = new BExpr(BKind.negate);
            b.lhs = bind(e.lhs, insideAggregate);
            return b;
        }
        case ExprKind.not:
        {
            auto b = new BExpr(BKind.not);
            b.lhs = bind(e.lhs, insideAggregate);
            return b;
        }
        case ExprKind.isNull:
        {
            auto b = new BExpr(BKind.isNull);
            b.lhs = bind(e.lhs, insideAggregate);
            return b;
        }
        case ExprKind.isNotNull:
        {
            auto b = new BExpr(BKind.isNotNull);
            b.lhs = bind(e.lhs, insideAggregate);
            return b;
        }
        case ExprKind.like:
        {
            auto b = new BExpr(BKind.like);
            b.lhs = bind(e.lhs, insideAggregate);
            b.rhs = bind(e.rhs, insideAggregate);
            return b;
        }
        case ExprKind.binary:
        {
            auto b = new BExpr(BKind.binary);
            b.op = e.op;
            b.lhs = bind(e.lhs, insideAggregate);
            b.rhs = bind(e.rhs, insideAggregate);
            return b;
        }
        case ExprKind.aggregate:
        {
            if (!allowAggregates)
                fail("aggregate function not allowed here");
            if (insideAggregate)
                fail("aggregate functions cannot be nested");
            AggSpec spec;
            spec.func = e.func;
            if (!e.star)
                spec.arg = bind(e.lhs, true);
            auto b = new BExpr(BKind.aggregate);
            b.aggIndex = cast(int) aggregates.length;
            aggregates ~= spec;
            return b;
        }
        }
    }
}
