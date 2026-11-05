/**
 * A jq-subset query language: JSON parser, serialiser and filter interpreter.
 *
 * Import this module to get the whole public API:
 *
 * $(UL
 *   $(LI `jq.value`  - `Value`, `JObject`, `compare`)
 *   $(LI `jq.json`   - `parseJson`, `toJson`, `writeJson`)
 *   $(LI `jq.parser` - `parseFilter` (filter text -> AST))
 *   $(LI `jq.interp` - `Program` (compile and run a filter))
 *   $(LI `jq.runner` - `runSpecInput` (the one-filter-one-document stdin contract))
 * )
 */
module jq;

public import jq.value;
public import jq.json;
public import jq.ast;
public import jq.lexer : ParseException;
public import jq.parser;
public import jq.interp;
public import jq.runner;
