/**
 * Hindley-Milner type inference for a small ML-like language.
 *
 * The pipeline, one module per stage:
 * $(UL
 *   $(LI `typeinfer.lexer`, `typeinfer.parser`, `typeinfer.ast`: text to syntax tree)
 *   $(LI `typeinfer.types`: the shared type graph with union-find variables)
 *   $(LI `typeinfer.solver`: unification, level-based generalisation, instantiation)
 *   $(LI `typeinfer.env`, `typeinfer.builtins`: the scoped environment and initial bindings)
 *   $(LI `typeinfer.infer`: Algorithm J over the syntax tree)
 *   $(LI `typeinfer.printer`: rendering types)
 *   $(LI `typeinfer.program`: whole-program entry points)
 * )
 *
 * Example:
 * ---
 * import typeinfer;
 * assert(typeCheck("let id x = x;; (id 1, id true);;")
 *     == "id : 'a -> 'a\n- : int * bool\n");
 * ---
 */
module typeinfer;

public import typeinfer.ast;
public import typeinfer.infer;
public import typeinfer.lexer : SyntaxError;
public import typeinfer.parser;
public import typeinfer.printer : typeToString;
public import typeinfer.program;
public import typeinfer.solver : ErrorKind, TypeError;
public import typeinfer.types : Type, Kind;
