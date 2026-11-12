import pytest

from sitegen.content import first_block, long_date, parse_page, parse_post, tag_slug
from sitegen.errors import ContentError
from sitegen.frontmatter import split_front_matter


def test_split_front_matter_basic():
    assert split_front_matter("+++\na = 1\n+++\nbody\n") == ("a = 1\n", "body\n")


def test_split_front_matter_empty_body_and_no_trailing_newline():
    assert split_front_matter("+++\na = 1\n+++") == ("a = 1\n", "")
    assert split_front_matter("+++\n+++\n") == ("", "")


def test_delimiter_must_be_a_whole_line():
    text = '+++\nt = "+++"\nu = "x"  \n++++\n +++\n+++\n+++\nbody +++\n'
    front, body = split_front_matter(text)
    assert front == 't = "+++"\nu = "x"  \n++++\n +++\n'
    assert body == "+++\nbody +++\n"


@pytest.mark.parametrize("text", ["", "++\n", "+++ \nx\n+++\n", "+++\na = 1\n", "x\n+++\n+++\n"])
def test_split_front_matter_errors(text):
    with pytest.raises(ContentError):
        split_front_matter(text)


def test_parse_post_defaults():
    post = parse_post("hello.md", '+++\ntitle = "Hi"\ndate = "2024-01-02"\n+++\nText\n')
    assert (post.title, post.date, post.slug, post.tags, post.draft) == ("Hi", "2024-01-02", "hello", (), False)
    assert post.body == "Text\n"


def test_parse_post_all_keys():
    text = '+++\ntitle = "T"\ndate = "2024-01-02"\nslug = "s"\ntags = ["a", "b"]\ndraft = true\n+++\n'
    post = parse_post("x.md", text)
    assert (post.slug, post.tags, post.draft) == ("s", ("a", "b"), True)


def test_parse_page():
    page = parse_page("about.md", '+++\ntitle = "About"\n+++\n# About\n')
    assert (page.title, page.slug, page.draft, page.body) == ("About", "about", False, "# About\n")


@pytest.mark.parametrize("meta", ['date = "2024-01-01"', 'title = 1\ndate = "2024-01-01"', 'title = "t"'])
def test_parse_post_missing_or_mistyped_keys(meta):
    with pytest.raises(ContentError):
        parse_post("p.md", f"+++\n{meta}\n+++\n")


@pytest.mark.parametrize(
    "name, slug",
    [
        ("Web Development", "web-development"),
        ("C++", "c"),
        ("Rust 2024", "rust-2024"),
        ("  --Hello__World--  ", "hello-world"),
        ("Ünïcode", "n-code"),
        ("a---b", "a-b"),
        ("x", "x"),
    ],
)
def test_tag_slug(name, slug):
    assert tag_slug(name) == slug


def test_long_date():
    assert long_date("2024-03-05") == "March 5, 2024"
    assert long_date("1999-12-25") == "December 25, 1999"
    assert long_date("0042-01-10") == "January 10, 0042"


@pytest.mark.parametrize(
    "body, block",
    [
        ("", ""),
        ("\n  \n\t\n", ""),
        ("para\n\nnext\n", "para"),
        ("\n\n  first\nsecond\n\nthird", "  first\nsecond"),
        ("# Title\nmore\n", "# Title\nmore"),
        ("```\ncode\n\nmore\n```\n", "```\ncode"),
        ("one line", "one line"),
    ],
)
def test_first_block(body, block):
    assert first_block(body) == block
