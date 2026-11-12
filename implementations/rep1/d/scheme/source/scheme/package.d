/**
 * A small Scheme interpreter.
 *
 * ---
 * import scheme;
 *
 * auto interp = new Interpreter;
 * interp.run(`(display (* 6 7)) (newline)`);
 * assert(interp.takeOutput() == "42\n");
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `scheme.interpreter` - $(LREF Interpreter), the entry point)
 *   $(LI `scheme.reader` - text to datums)
 *   $(LI `scheme.analyzer`, `scheme.ast` - datums to analysed trees)
 *   $(LI `scheme.evaluator` - the trampolined evaluator)
 *   $(LI `scheme.primitives` - built-in procedures)
 *   $(LI `scheme.bignum`, `scheme.numeric` - arbitrary-precision integers)
 *   $(LI `scheme.printer` - `write` / `display` forms)
 *   $(LI `scheme.value`, `scheme.environment`, `scheme.output` - runtime data)
 * )
 */
module scheme;

public import scheme.bignum;
public import scheme.interpreter;
public import scheme.output;
public import scheme.printer;
public import scheme.reader;
public import scheme.value;
