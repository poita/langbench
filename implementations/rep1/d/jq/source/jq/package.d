/**
 * A jq-subset query language: a from-scratch JSON parser and serializer plus
 * a filter interpreter.
 *
 * ---
 * import jq;
 *
 * auto filter = Filter.compile(`.users | map(select(.age >= 30) | .name)`);
 * auto doc = parseJson(`{"users":[{"name":"ann","age":31},{"name":"bo","age":20}]}`);
 * foreach (result; filter.collect(doc))
 *     writeln(toJson(result)); // ["ann"]
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `jq.value`  - the immutable value model, ordering and equality)
 *   $(LI `jq.json`   - JSON parser and compact serializer)
 *   $(LI `jq.filter` - `Filter`: compile and run filters)
 *   $(LI `jq.error`  - exception types)
 *   $(LI `jq.lexer`, `jq.parser`, `jq.ast`, `jq.interp`, `jq.ops` - internals)
 * )
 */
module jq;

public import jq.error;
public import jq.filter;
public import jq.json;
public import jq.value;
