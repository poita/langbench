/**
 * The database: a set of tables and the statement executor.
 */
module minisql.database;

import std.array : appender;

import minisql.ast;
import minisql.binder;
import minisql.errors;
import minisql.expr;
import minisql.lexer;
import minisql.parser;
import minisql.select;
import minisql.table;
import minisql.value;

/// The result of one statement: rows for a SELECT, nothing otherwise.
struct QueryResult
{
    /// True if the statement was a SELECT.
    bool isQuery;
    /// The output rows of a SELECT, in result order.
    Value[][] rows;
}

/// An in-memory database executing the SQL dialect described in SPEC.md.
final class Database
{
    private Table[string] tables;

    /// The table called `name` (case-insensitive), or null.
    Table table(string name) @safe
    {
        import std.ascii : toLower;
        import std.algorithm : map;
        import std.conv : to;

        auto key = name.map!(c => toLower(c)).to!string;
        if (auto t = key in tables)
            return *t;
        return null;
    }

    /**
     * Parses and executes exactly one statement (a trailing `;` is allowed).
     *
     * Throws: $(REF SqlError, minisql.errors) if the statement is invalid; the
     * database is then unchanged.
     */
    QueryResult execute(string sql) @safe
    {
        auto stmts = splitStatements(sql);
        if (stmts.length != 1)
            fail("expected exactly one statement");
        return executeTokens(stmts[0]);
    }

    /// Parses and executes one statement given as tokens (see `splitStatements`).
    QueryResult executeTokens(const(Token)[] tokens) @safe
    {
        return execute(parseStatement(tokens));
    }

    /// Executes a parsed statement.
    QueryResult execute(Stmt s) @safe
    {
        final switch (s.kind)
        {
        case StmtKind.createTable:
            createTable(s);
            return QueryResult.init;
        case StmtKind.insert:
            insertRows(s);
            return QueryResult.init;
        case StmtKind.delete_:
            deleteRows(s);
            return QueryResult.init;
        case StmtKind.update:
            updateRows(s);
            return QueryResult.init;
        case StmtKind.select:
            return QueryResult(true, executeSelect(tables, s));
        }
    }

    /**
     * Runs a whole script the way the command-line tool does.
     *
     * Each statement is executed in order. The rows of every SELECT are written
     * to `sink` in the output format of SPEC.md (tab-separated values, then a
     * `-- N rows` line); a failing statement writes the single line `error`.
     */
    void runScript(string script, scope void delegate(const(char)[]) @safe sink) @safe
    {
        foreach (stmt; splitStatements(script))
        {
            try
            {
                auto r = executeTokens(stmt);
                if (r.isQuery)
                    writeResult(r, sink);
            }
            catch (SqlError)
                sink("error\n");
        }
    }

    /// Like the sink overload of `runScript`, but returns the output as a string.
    string runScript(string script) @safe
    {
        auto app = appender!string;
        runScript(script, (const(char)[] s) { app.put(s); });
        return app[];
    }

    // --- statements ---

    private void createTable(Stmt s) @safe
    {
        if (table(s.table) !is null)
            fail("table already exists");
        foreach (i, c; s.columnNames)
            foreach (d; s.columnNames[0 .. i])
                if (c == d)
                    fail("duplicate column name");
        tables[s.table] = new Table(s.table, s.columnNames.dup);
    }

    private Table lookup(string name) @safe
    {
        auto t = table(name);
        if (t is null)
            fail("no such table");
        return t;
    }

    private void insertRows(Stmt s) @safe
    {
        auto t = lookup(s.table);
        auto binder = new Binder(null);
        EvalContext ctx;
        Value[][] fresh;
        foreach (row; s.rows)
        {
            if (row.length != t.columns.length)
                fail("wrong number of values");
            auto values = new Value[row.length];
            foreach (i, e; row)
                values[i] = evaluate(binder.bind(e), ctx);
            fresh ~= values;
        }
        t.rows ~= fresh;
    }

    private void deleteRows(Stmt s) @safe
    {
        auto t = lookup(s.table);
        BExpr where;
        if (s.where !is null)
            where = new Binder([Source(t.name, t)]).bind(s.where);
        Value[][] kept;
        EvalContext ctx;
        foreach (row; t.rows)
        {
            ctx.rows[0] = row;
            if (where is null || isTrue(where, ctx))
                continue;
            kept ~= row;
        }
        t.rows = kept;
    }

    private void updateRows(Stmt s) @safe
    {
        auto t = lookup(s.table);
        auto binder = new Binder([Source(t.name, t)]);
        BExpr where;
        if (s.where !is null)
            where = binder.bind(s.where);
        size_t[] targets;
        BExpr[] values;
        foreach (i, name; s.setColumns)
        {
            immutable c = t.columnIndex(name);
            if (c < 0)
                fail("no such column");
            targets ~= c;
            values ~= binder.bind(s.setValues[i]);
        }
        // Compute every new row from the old values first, then assign.
        size_t[] changed;
        Value[][] replacement;
        EvalContext ctx;
        foreach (r, row; t.rows)
        {
            ctx.rows[0] = row;
            if (where !is null && !isTrue(where, ctx))
                continue;
            auto updated = row.dup;
            foreach (i, c; targets)
                updated[c] = evaluate(values[i], ctx);
            changed ~= r;
            replacement ~= updated;
        }
        foreach (i, r; changed)
            t.rows[r] = replacement[i];
    }
}

/// Writes a SELECT result in the output format of SPEC.md.
void writeResult(in QueryResult r, scope void delegate(const(char)[]) @safe sink) @safe
{
    auto line = appender!(char[]);
    foreach (row; r.rows)
    {
        line.clear();
        foreach (i, v; row)
        {
            if (i)
                line.put('\t');
            formatValue(line, v);
        }
        line.put('\n');
        sink(line[]);
    }
    line.clear();
    line.put("-- ");
    putInteger(line, cast(long) r.rows.length);
    line.put(" rows\n");
    sink(line[]);
}
