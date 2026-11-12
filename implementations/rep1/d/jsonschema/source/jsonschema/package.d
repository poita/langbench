/**
 * A JSON Schema draft 2020-12 validator written from scratch.
 *
 * Public API:
 * $(UL
 *   $(LI `parseJson` — JSON text to `JsonValue` (numbers are exact decimals).)
 *   $(LI `SchemaValidator` — compile a schema (plus optional remote documents)
 *        and test instances against it.)
 *   $(LI `validateDocument` — the stdin/stdout document format of the CLI.)
 * )
 *
 * Example:
 * ---
 * import jsonschema;
 *
 * auto v = new SchemaValidator(parseJson(`{"type":"integer","minimum":1}`));
 * assert(v.isValid(parseJson("3")));
 * assert(!v.isValid(parseJson("0")));
 * ---
 */
module jsonschema;

public import jsonschema.json;
public import jsonschema.number;
public import jsonschema.regex;
public import jsonschema.runner;
public import jsonschema.schema;
public import jsonschema.uri;
public import jsonschema.validator;
