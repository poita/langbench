/++
    jinjalite: a small Jinja2-style template engine.

    ---
    import jinjalite;

    auto env = new Environment;
    env.addTemplate("hello", "Hello {{ name|upper }}!");
    writeln(env.render("hello", parseJson(`{"name": "world"}`)));  // Hello WORLD!
    ---

    Modules:
    $(UL
        $(LI `jinjalite.environment`: `Environment`, the template registry and `render`.)
        $(LI `jinjalite.value`: the dynamic `Value` type.)
        $(LI `jinjalite.json`: `parseJson`, building context values.)
        $(LI `jinjalite.errors`: `TemplateError` and `ErrorKind`.)
        $(LI `jinjalite.document`: the stdin format of the command-line tool.)
        $(LI `jinjalite.lexer`, `jinjalite.parser`, `jinjalite.ast`: syntax.)
        $(LI `jinjalite.interpreter`, `jinjalite.scoping`, `jinjalite.operators`, `jinjalite.filters`: evaluation.)
    )
+/
module jinjalite;

public import jinjalite.document;
public import jinjalite.environment;
public import jinjalite.errors;
public import jinjalite.json;
public import jinjalite.value;
