/**
 * A Datalog engine with stratified negation.
 *
 * Programs consist of facts, rules (with negation `not` and comparisons) and
 * queries. The library parses a program, checks that it is safe and
 * stratifiable, computes its perfect model by semi-naive bottom-up evaluation
 * over interned integer constants, and answers the queries.
 *
 * Most callers only need `solve`:
 * ---
 * import datalog;
 * auto result = solve("edge(1,2). edge(2,3).\n"
 *                   ~ "path(X,Y) :- edge(X,Y).\n"
 *                   ~ "path(X,Z) :- edge(X,Y), path(Y,Z).\n"
 *                   ~ "?- path(1, X).");
 * assert(result.ok);
 * assert(result.output == "path(1, 2)\npath(1, 3)\n-- 2\n");
 * ---
 *
 * The individual stages are public too: `parseProgram`, `isSafe`, `stratify`,
 * `evaluate`, `answerQuery`.
 */
module datalog;

public import datalog.analysis;
public import datalog.ast;
public import datalog.engine;
public import datalog.lexer : ParseException;
public import datalog.parser : parseProgram, maxArity;
public import datalog.plan;
public import datalog.query;
public import datalog.relation;

/// Outcome of running a whole program.
struct Result
{
    /// False if the program is unsafe or not stratifiable.
    bool ok;
    /// The query answers, or `"error\n"` if `!ok`.
    string output;
}

/**
 * Runs a Datalog program: parses it, checks safety and stratification, computes
 * the model and answers every query in order.
 *
 * Throws: `ParseException` if the text is not a well-formed program.
 */
Result solve(string source)
{
    import std.array : appender;

    auto program = parseProgram(source);
    Stratification strat;
    if (!isSafe(program) || !stratify(program, strat))
        return Result(false, "error\n");

    auto db = evaluate(program, strat);

    string[] texts;
    foreach (ref c; program.constants)
        texts ~= c.text;

    auto output = appender!(char[]);
    foreach (ref q; program.queries)
        answerQuery(program, db, q, texts, output);
    return Result(true, cast(string) output.data);
}
