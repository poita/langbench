/**
 * A Datalog engine with stratified negation.
 *
 * The library parses a Datalog program, checks that it is safe and
 * stratifiable, computes its perfect model by semi-naive bottom-up evaluation
 * and answers queries.
 *
 * Example:
 * ---
 * import datalog;
 *
 * auto program = parseProgram(`
 *     edge(1, 2). edge(2, 3).
 *     path(X, Y) :- edge(X, Y).
 *     path(X, Z) :- edge(X, Y), path(Y, Z).
 *     ?- path(1, X).
 * `);
 * auto model = new Model(program);
 * auto answer = model.answer(program.queries[0]);  // [[path-tuples as Constants]]
 * ---
 *
 * Or, to get the textual output of the command-line tool:
 * ---
 * string output = solve("edge(1, 2). ?- edge(X, Y).");
 * ---
 *
 * Modules:
 *  - `datalog.lexer`, `datalog.parser`: text to `datalog.ast.Program`
 *  - `datalog.symbols`: constants, their total order, interning
 *  - `datalog.analysis`: safety check and stratification
 *  - `datalog.relation`: tuple storage with incremental hash indexes
 *  - `datalog.plan`, `datalog.exec`: join plans and their execution
 *  - `datalog.engine`: `Model`, the evaluator
 *  - `datalog.driver`: program text in, query output text out
 */
module datalog;

public import datalog.analysis;
public import datalog.ast;
public import datalog.driver;
public import datalog.engine;
public import datalog.errors;
public import datalog.parser;
public import datalog.symbols;
