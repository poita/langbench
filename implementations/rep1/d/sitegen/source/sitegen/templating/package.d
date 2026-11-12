/**
 * A Jinja-style template engine.
 *
 * Supported: `{{ expr }}`, `{% %}` statements (`if`/`elif`/`else`, `for`,
 * `set`, `macro`, `include`, `extends`, `block` with `super()`), `{# #}`
 * comments, whitespace control with `-`, the usual operators and thirteen
 * filters.  The semantics follow Jinja2 with strict undefined values and
 * autoescaping off.
 *
 * Example:
 * ---
 * import sitegen.templating;
 *
 * auto engine = new TemplateEngine;
 * engine.addTemplate("hello", "Hello {{ name|upper }}!");
 * Value[string] context;
 * context["name"] = Value.str("world");
 * assert(engine.render("hello", context) == "Hello WORLD!");
 * ---
 */
module sitegen.templating;

public import sitegen.templating.engine : TemplateEngine;
public import sitegen.templating.errors : ErrorKind, TemplateException;
public import sitegen.templating.value : Dict, Kind, Value;
