/// Helpers shared by the unit-test modules.
module tests.support;

import jtemplate;

/// Render the main template `tpl` (plus `extra` named templates) against the
/// JSON `ctx` and return the output.
string render(string tpl, string ctx = "{}", string[string] extra = null)
{
    auto e = new Engine;
    e.addTemplate("main", tpl);
    foreach (k, v; extra)
        e.addTemplate(k, v);
    return e.renderJson("main", ctx);
}

/// Render and return the kind of the error it raises; fails the test if
/// rendering succeeds.
ErrorKind errorOf(string tpl, string ctx = "{}", string[string] extra = null)
{
    try
        render(tpl, ctx, extra);
    catch (TemplateError e)
        return e.kind;
    assert(0, "expected a template error for: " ~ tpl);
}
