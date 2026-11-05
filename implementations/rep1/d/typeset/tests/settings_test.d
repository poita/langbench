module tests.settings_test;

import std.exception : collectException;
import typeset.errors;
import typeset.settings;

private string errorOf(string cfg)
{
    auto e = collectException!TypesetError(parseSettings(cfg));
    return e is null ? "ok" : e.diag.toString();
}

unittest // defaults and derived values
{
    auto s = defaultSettings();
    assert(s.pageWidth == 612_000 && s.bodyWidth == 468_000 && s.bodyHeight == 648_000);
    assert(s.footerBaseline == 792_000 - 36_000);
    assert(s.footnoteMaxHeight == 324_000);
    assert(s.hyphenate && s.textAlign == Align.justify);
}

unittest // assignments, comments and derived defaults follow explicit settings
{
    auto s = parseSettings("# comment\n\npage-height = 200pt\n  margin-top=10pt\nheader-left = {title}\n");
    assert(s.pageHeight == 200_000 && s.marginTop == 10_000);
    assert(s.footerBaseline == 164_000);
    assert(s.headerLeftEven.length == 1 && s.headerLeftEven[0].isPlaceholder);
    assert(s.slot(0, false).length == 1);
}

unittest // error codes and their positions
{
    assert(errorOf("page-width = 200pt\nmargin-left = 20px\n") == "settings.cfg:2:15: bad-length");
    assert(errorOf("nokey\n") == "settings.cfg:1:1: bad-syntax");
    assert(errorOf("  zzz = 1\n") == "settings.cfg:1:3: unknown-setting");
    assert(errorOf("leading = 12pt\nleading = 13pt\n") == "settings.cfg:2:1: duplicate-setting");
    assert(errorOf("tolerance = x\n") == "settings.cfg:1:13: bad-integer");
    assert(errorOf("hyphenate = yes\n") == "settings.cfg:1:13: bad-boolean");
    assert(errorOf("align = middle\n") == "settings.cfg:1:9: bad-enum");
    assert(errorOf("body-font = cursive\n") == "settings.cfg:1:13: unknown-font");
    assert(errorOf("hyphen-patterns = french\n") == "settings.cfg:1:19: unknown-patterns");
    assert(errorOf("margin-top = -1pt\n") == "settings.cfg:1:14: bad-value");
    assert(errorOf("leading =\n") == "settings.cfg:1:10: bad-length");
}

unittest // text values: escapes, placeholders and their errors
{
    assert(errorOf("header-left = a\\qb\n") == "settings.cfg:1:16: bad-escape");
    assert(errorOf("header-left = {nope}\n") == "settings.cfg:1:15: unknown-placeholder");
    assert(errorOf("header-left = }\n") == "settings.cfg:1:15: stray-brace");
    assert(errorOf("header-left = \\{page}\n") == "settings.cfg:1:21: stray-brace");
    assert(errorOf("toc-title = {page}\n") == "settings.cfg:1:13: bad-value");
    assert(errorOf("toc-leader = . .\n") == "settings.cfg:1:14: bad-value");
    auto s = parseSettings("header-center = \\{x\\} {page}/{pages}\n");
    assert(s.headerCenter[0].text == "{x} ");
    assert(s.headerCenter.length == 4);
}

unittest // the body rectangle must stay at least 36pt in each direction
{
    assert(errorOf("margin-left = 300pt\nmargin-right = 300pt\n") == "settings.cfg:2:16: bad-value");
}
