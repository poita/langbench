/// A Datalog engine with stratified negation.
///
/// Typical use:
/// ---
/// import datalog;
///
/// string answers = solve("edge(1,2). path(X,Y) :- edge(X,Y). ?- path(X,Y).");
/// ---
/// or step by step:
/// ---
/// auto program = parseProgram(source);
/// checkSafety(program);
/// auto strat   = stratify(program);
/// auto model   = evaluate(program, strat);
/// foreach (ref q; program.queries)
///     foreach (row; model.answer(q))
///         writeln(model.format(q.atom.pred, row));
/// ---
module datalog;

public import datalog.analysis;
public import datalog.ast;
public import datalog.errors;
public import datalog.eval;
public import datalog.parser;
public import datalog.relation;
public import datalog.solver;
