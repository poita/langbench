/// The public face of the library: an [Engine] holds named template sources
/// and renders one of them against a context.
module jtemplate.engine;

import jtemplate.ast : Template;
import jtemplate.errors;
import jtemplate.interp;
import jtemplate.json;
import jtemplate.parser;
import jtemplate.value;

/// A set of named templates plus a cache of the ones already parsed.
///
/// Templates are parsed and checked lazily, the first time they are needed
/// (by `render`, `include` or `extends`), and then reused. A template that
/// is never needed is never checked, so it may be malformed.
final class Engine : TemplateLoader
{
    private string[string] sources_;
    private Template[string] cache_;

    /// Register (or replace) a template source under `name`.
    void addTemplate(string name, string source)
    {
        sources_[name] = source;
        cache_.remove(name);
    }

    /// True if a template with this name has been registered.
    bool hasTemplate(string name) const
    {
        return (name in sources_) !is null;
    }

    /// Return the parsed template `name`, parsing it on first use.
    ///
    /// Throws a [TemplateError]: `missingTemplate` if the name is unknown,
    /// `syntax` or `filter` if the source is malformed.
    override Template load(string name)
    {
        if (auto t = name in cache_)
            return *t;
        auto src = name in sources_;
        if (src is null)
            throw missingTemplateError("no template named '" ~ name ~ "'");
        auto t = parseTemplate(name, *src);
        cache_[name] = t;
        return t;
    }

    /// Render template `name` with `context` (a dictionary value) as its
    /// variables. Throws a [TemplateError] on any template error; nothing is
    /// returned in that case.
    string render(string name, Value context)
    {
        if (context.kind != Kind.dict)
            throw typeError("the context must be a dictionary");
        return new Interpreter(this).render(name, context.dict);
    }

    /// Like [render], but takes the context as JSON text.
    string renderJson(string name, string contextJson)
    {
        return render(name, parseJson(contextJson));
    }
}
