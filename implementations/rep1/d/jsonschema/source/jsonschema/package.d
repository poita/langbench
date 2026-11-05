/**
 * A JSON Schema draft 2020-12 validator.
 *
 * Importing `jsonschema` gives the whole public API:
 *
 * $(UL
 *   $(LI $(MREF jsonschema.validator): `Validator`, the entry point.)
 *   $(LI $(MREF jsonschema.json): the `Value` tree, `parseJson`, `jsonEqual`.)
 *   $(LI $(MREF jsonschema.number): exact decimal `Number`.)
 *   $(LI $(MREF jsonschema.regex): the ECMA-262 subset `Regex` engine.)
 *   $(LI $(MREF jsonschema.uri), $(MREF jsonschema.pointer): RFC 3986 and RFC 6901 helpers.)
 *   $(LI $(MREF jsonschema.compiler), $(MREF jsonschema.node), $(MREF jsonschema.evaluator): the schema compiler and evaluator.)
 *   $(LI $(MREF jsonschema.request): the request format of the command-line tool.)
 * )
 */
module jsonschema;

public import jsonschema.compiler : SchemaException;
public import jsonschema.json;
public import jsonschema.number;
public import jsonschema.regex : Regex, RegexException;
public import jsonschema.request : processRequest, RequestException;
public import jsonschema.validator : Validator;
