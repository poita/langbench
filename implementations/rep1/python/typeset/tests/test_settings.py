import pytest

from typeset import CodexaError, parse_settings


def err(text):
    with pytest.raises(CodexaError) as info:
        parse_settings(text)
    return info.value.format()


def test_defaults():
    s = parse_settings(None)
    assert (s.body_x, s.body_width, s.body_height) == (72000, 468000, 648000)
    assert s.footer_baseline == 756000
    assert s.footnote_max_height == 324000
    assert s.header_left_even == s.header_left == []


def test_derived_defaults_follow_assignments():
    s = parse_settings("page-height = 400pt\nheader-left = a\nheader-right-even = b\n")
    assert s.footer_baseline == 364000
    assert s.header_left_even == [("lit", "a")]
    assert s.header_right == [] and s.header_right_even == [("lit", "b")]


def test_comments_blank_and_tabs():
    s = parse_settings("# c\n\n  \t\n\tpar-indent\t=\t 3pt # not a comment\n".replace(" # not a comment", ""))
    assert s.par_indent == 3000


def test_error_positions():
    assert err("page-width = 200pt\nmargin-left = 20px\n") == "settings.cfg:2:15: bad-length"
    assert err("  foo\n") == "settings.cfg:1:3: bad-syntax"
    assert err("nope = 1\n") == "settings.cfg:1:1: unknown-setting"
    assert err("leading = 0.5pt\n") == "settings.cfg:1:11: bad-value"
    assert err("leading = 12pt\nleading = 12pt\n") == "settings.cfg:2:1: duplicate-setting"
    assert err("hyphenate = yes\n") == "settings.cfg:1:13: bad-boolean"
    assert err("align = middle\n") == "settings.cfg:1:9: bad-enum"
    assert err("body-font = comic\n") == "settings.cfg:1:13: unknown-font"
    assert err("hyphen-patterns = klingon\n") == "settings.cfg:1:19: unknown-patterns"
    assert err("tolerance = \n") == "settings.cfg:1:13: bad-integer"


def test_text_values():
    assert parse_settings(r"header-left = \{{page}\}" "\n").header_left == [
        ("lit", "{"), ("ph", "page"), ("lit", "}")]
    assert err("header-left = \\{page}\n") == "settings.cfg:1:21: stray-brace"
    assert err("header-left = {pa\\ge}\n") == "settings.cfg:1:15: unknown-placeholder"
    assert err("header-left = }\\q\n") == "settings.cfg:1:15: stray-brace"
    assert err("header-left = ab\\q\n") == "settings.cfg:1:17: bad-escape"
    assert err("toc-title = {page}\n") == "settings.cfg:1:13: bad-value"
    assert err("toc-leader = a b\n") == "settings.cfg:1:14: bad-value"


def test_body_rectangle_reports_last_geometry_key():
    assert err("margin-left = 300pt\nmargin-right = 300pt\n") == "settings.cfg:2:16: bad-value"
