/**
 * A jq-subset interpreter library.
 *
 * ---
 * import jq;
 *
 * auto program = Program.compile(".users | map(.name)");
 * auto doc = parseJson(`{"users":[{"name":"ann"},{"name":"bob"}]}`);
 * program.run(doc, (Value v) { writeln(toJson(v)); });  // ["ann","bob"]
 * ---
 *
 * Modules:
 *  - `jq.value`   immutable value model, ordering and equality
 *  - `jq.json`    JSON parser and serialiser
 *  - `jq.lexer`, `jq.parser`, `jq.ast`   filter front end
 *  - `jq.ops`     arithmetic and builtin operations on values
 *  - `jq.interp`  push-style evaluator
 *  - `jq.program` compile-once / run-many API
 */
module jq;

public import jq.ast;
public import jq.interp;
public import jq.json;
public import jq.lexer : FilterException;
public import jq.ops;
public import jq.parser : parseFilter;
public import jq.program;
public import jq.value;
