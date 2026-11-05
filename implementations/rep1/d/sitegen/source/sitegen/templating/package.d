/// A Jinja2-style template engine: `{{ expr }}`, `{% if/for/set/macro/include/extends/block %}`,
/// comments, whitespace control, thirteen filters and block inheritance with `super()`.
///
/// ---
/// import sitegen.templating;
///
/// auto engine = new Engine((string name, out string src) {
///     if (name != "page") return false;
///     src = "{% for x in xs %}[{{ x|upper }}]{% endfor %}";
///     return true;
/// });
/// auto root = new Scope();
/// root.set("xs", Value.of([Value.of("a"), Value.of("b")]));
/// assert(engine.render("page", root) == "[A][B]");
/// ---
module sitegen.templating;

public import sitegen.templating.engine : Engine, TemplateLoader;
public import sitegen.templating.errors : ErrorKind, TemplateError;
public import sitegen.templating.scopes : Scope;
public import sitegen.templating.value : DictObj, Kind, Value, formatFloat, toDisplay;
