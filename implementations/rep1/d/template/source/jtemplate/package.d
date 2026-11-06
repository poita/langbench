/**
 * jtemplate — a Jinja-style template engine.
 *
 * Import this module to get the whole public API:
 *
 * ---
 * import jtemplate;
 *
 * auto engine = new Engine;
 * engine.addTemplate("main", "Hello {{ name|upper }}!");
 * writeln(engine.renderJson("main", `{"name": "world"}`)); // Hello WORLD!
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `jtemplate.engine`   — [Engine]: register templates and render them)
 *   $(LI `jtemplate.document` — the stdin document format used by the CLI)
 *   $(LI `jtemplate.value`    — the dynamic [Value] type)
 *   $(LI `jtemplate.json`     — JSON text to [Value])
 *   $(LI `jtemplate.errors`   — [TemplateError] and [ErrorKind])
 *   $(LI `jtemplate.lexer`, `jtemplate.parser`, `jtemplate.ast` — front end)
 *   $(LI `jtemplate.interp`, `jtemplate.ops`, `jtemplate.filters`,
 *        `jtemplate.format`, `jtemplate.scopes` — evaluation)
 * )
 */
module jtemplate;

public import jtemplate.ast;
public import jtemplate.document;
public import jtemplate.engine;
public import jtemplate.errors;
public import jtemplate.filters : applyFilter;
public import jtemplate.format : putFloat, putValue, toStr;
public import jtemplate.json;
public import jtemplate.lexer : lex, LexResult, Segment, SegKind, Token, Tok;
public import jtemplate.parser : filterId, parseTemplate;
public import jtemplate.value;
