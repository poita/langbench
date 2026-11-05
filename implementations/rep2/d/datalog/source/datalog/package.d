/// A Datalog engine with stratified negation.
///
/// The pipeline is: `parseProgram` → `analyze` (safety and stratification) →
/// `Database.evaluate` (semi-naive bottom-up evaluation) → `matchQuery` /
/// `renderAnswers`. `solve` runs the whole pipeline on a source string.
///
/// ---
/// import datalog;
///
/// string out_ = solve("edge(1,2). path(X,Y) :- edge(X,Y). ?- path(X,Y).");
/// // "path(1, 2)\n-- 1\n"
/// ---
module datalog;

public import datalog.analysis;
public import datalog.ast;
public import datalog.engine;
public import datalog.errors;
public import datalog.lexer;
public import datalog.parser;
public import datalog.plan : Plan, compilePlan;
public import datalog.query;
public import datalog.relation : Relation, Index;

/// Run a program end to end and return the text the command-line tool prints:
/// the answers to every query, or `"error\n"` if the program is unsafe or not
/// stratifiable.
///
/// Throws: `ParseException` if the source is not well-formed.
string solve(string source)
{
    auto prog = parseProgram(source);
    try
    {
        auto db = Database.evaluate(prog);
        return renderAnswers(db);
    }
    catch (ProgramError)
        return "error\n";
}
