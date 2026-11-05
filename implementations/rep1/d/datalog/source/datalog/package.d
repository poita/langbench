/**
 * A Datalog engine with stratified negation.
 *
 * The library parses a Datalog program, rejects unsafe or unstratifiable ones,
 * computes the perfect model by semi-naive bottom-up evaluation over interned
 * integer constants, and answers queries against the model.
 *
 * Modules:
 * $(UL
 *   $(LI `datalog.lexer`    – tokeniser)
 *   $(LI `datalog.ast`      – program representation and constant ordering)
 *   $(LI `datalog.parser`   – `parseProgram`)
 *   $(LI `datalog.analysis` – safety check and stratification)
 *   $(LI `datalog.relation` – tuple storage, hash set and hash indexes)
 *   $(LI `datalog.plan`     – join-plan compilation)
 *   $(LI `datalog.eval`     – `evaluate`, the semi-naive fixpoint, and `Model`)
 *   $(LI `datalog.query`    – `answer` and `renderAnswer`)
 * )
 *
 * Example:
 * ---
 * import datalog;
 *
 * auto output = runProgram("edge(1,2). edge(2,3).\n"
 *     ~ "path(X,Y) :- edge(X,Y). path(X,Z) :- edge(X,Y), path(Y,Z).\n"
 *     ~ "?- path(1, X).");
 * assert(output == "path(1, 2)\npath(1, 3)\n-- 2\n");
 * ---
 */
module datalog;

public import datalog.analysis;
public import datalog.ast;
public import datalog.errors;
public import datalog.eval;
public import datalog.lexer;
public import datalog.parser;
public import datalog.plan : Plan, compilePlan;
public import datalog.query;
public import datalog.relation : Relation, Index, Value;

/// Output printed for programs that are unsafe or not stratifiable.
enum string errorOutput = "error\n";

/**
 * Parse, check and evaluate `source`, then answer its queries.
 *
 * Returns the text the command-line tool prints: the answers to every query in
 * order, or `"error\n"` if the program is unsafe or not stratifiable.
 * Throws `ParseException` if `source` is not well formed.
 */
string runProgram(string source) @safe
{
    import std.array : appender;

    auto program = parseProgram(source);
    Model model;
    try
        model = evaluate(program);
    catch (UnsafeRuleException)
        return errorOutput;
    catch (StratificationException)
        return errorOutput;

    auto output = appender!string;
    foreach (ref q; program.queries)
        renderAnswer(model, q, output);
    return output.data;
}
