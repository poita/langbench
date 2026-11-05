/**
 * Hindley-Milner type inference for a small ML-like language.
 *
 * Public API:
 *
 *  - `inferProgram`: source text to the program's output text.
 *  - `TypeChecker`: check declarations incrementally, getting `DeclResult`s.
 *  - `runWithLargeStack`: run deeply recursive work on a big-stack thread.
 *
 * The lower layers are public too: `tokenize` ($(MREF typeinfer, lexer)),
 * `parse` ($(MREF typeinfer, parser)), and the inference engine
 * ($(MREF typeinfer, infer), $(MREF typeinfer, unify),
 * $(MREF typeinfer, scheme), $(MREF typeinfer, printer)).
 *
 * Example:
 * ---
 * import typeinfer;
 * assert(inferProgram("let id = fun x -> x;;") == "id : 'a -> 'a\n");
 * ---
 */
module typeinfer;

public import typeinfer.ast;
public import typeinfer.checker;
public import typeinfer.errors;
public import typeinfer.infer;
public import typeinfer.lexer;
public import typeinfer.parser;
public import typeinfer.printer;
public import typeinfer.scheme;
public import typeinfer.stack;
public import typeinfer.types;
public import typeinfer.unify;
