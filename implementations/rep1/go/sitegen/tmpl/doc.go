// Package tmpl implements a small Jinja2-style template engine.
//
// The language is a subset of Jinja2: {{ expressions }}, {% statements %} and
// {# comments #}; whitespace control with "-"; the statements if/elif/else,
// for/else, set, macro, include, extends and block (with super()); the
// operators of Python/Jinja; and thirteen filters (upper, lower, trim, escape,
// replace, length, int, join, first, last, reverse, sort, default). Undefined
// values are strict: using one for anything but "is defined" or the default
// filter is an error, and autoescaping is off.
//
// Use an Engine to register named template sources and render one of them
// against a context Dict:
//
//	e := tmpl.New()
//	e.Add("base.html", "<h1>{% block title %}{% endblock %}</h1>")
//	e.Add("page.html", `{% extends "base.html" %}{% block title %}{{ name|upper }}{% endblock %}`)
//	ctx := tmpl.NewDict()
//	ctx.Set("name", "ada")
//	out, err := e.Render("page.html", ctx) // "<h1>ADA</h1>"
//
// Values are plain Go values: nil (none), bool, int64, float64, string,
// List and *Dict. Lists and dicts are shared, never copied, when they are
// bound to names or passed around, so they must not be modified while a render
// is running. An Engine caches parsed templates and is not safe for
// concurrent use.
package tmpl
