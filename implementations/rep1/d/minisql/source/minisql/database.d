/// The database: a catalog of tables and the statement pipeline.
module minisql.database;

import std.array : Appender;
import minisql.ast;
import minisql.binder;
import minisql.errors;
import minisql.executor;
import minisql.lexer;
import minisql.parser;
import minisql.result;
import minisql.table;

/// An in-memory database executing a small SQL dialect.
///
/// Every statement goes through three phases: it is parsed to a syntax tree,
/// bound against the current schema (all checks happen here), and executed.
/// A statement that fails to parse or bind has no effect.
final class Database
{
    private Table[string] tables;

    /// Executes exactly one statement (a trailing `;` is optional) and
    /// returns its result. Throws `SqlException` if the statement is invalid,
    /// or if `sql` holds more than one statement.
    Result execute(string sql) @safe
    {
        auto stmts = splitStatements(tokenize(sql));
        if (stmts.length == 0)
            return Result.init;
        if (stmts.length > 1)
            fail("expected a single statement");
        return executeTokens(stmts[0]);
    }

    /// Runs a whole script the way the command-line tool does: every
    /// statement in order, the rows of each SELECT followed by `-- N rows`,
    /// and the single line `error` for each statement that fails. Returns
    /// everything that would be printed.
    string run(string script) @safe
    {
        Appender!(char[]) sink;
        foreach (stmt; splitStatements(tokenize(script)))
        {
            try
            {
                auto r = executeTokens(stmt);
                appendResult(sink, r);
            }
            catch (SqlException)
            {
                sink.put("error\n");
            }
        }
        return (() @trusted => cast(string) sink[])();
    }

    /// Whether a table exists (names are case-insensitive).
    bool hasTable(string name) const @safe
    {
        return (lower(name) in tables) !is null;
    }

    private static string lower(string s) pure @safe
    {
        char[] r = s.dup;
        foreach (ref c; r)
            if (c >= 'A' && c <= 'Z')
                c += 32;
        return (() @trusted => cast(string) r)();
    }

    private Table lookup(string name) @safe
    {
        auto p = name in tables;
        return p ? *p : null;
    }

    private Result executeTokens(const(Token)[] toks) @safe
    {
        auto stmt = parseStatement(toks);
        scope TableLookup find = &lookup;
        if (auto s = cast(SelectStmt) stmt)
            return executeSelect(bindSelect(s, find));
        if (auto s = cast(InsertStmt) stmt)
        {
            executeInsert(bindInsert(s, find));
            return Result.init;
        }
        if (auto s = cast(UpdateStmt) stmt)
        {
            executeUpdate(bindUpdate(s, find));
            return Result.init;
        }
        if (auto s = cast(DeleteStmt) stmt)
        {
            executeDelete(bindDelete(s, find));
            return Result.init;
        }
        auto s = cast(CreateStmt) stmt;
        auto t = bindCreate(s, find);
        tables[t.name] = t;
        return Result.init;
    }
}
