/// Unit tests for the content model.
module tests.model_test;

import sitegen.model;
import sitegen.source_;

private SiteSource basicSource()
{
    SiteSource s;
    s.siteToml = "title = \"T\"\nbase_url = \"https://e.org\"\nauthor = \"A\"\nposts_per_page = 2\n";
    s.posts["b-post.md"] = "+++\ntitle = \"B\"\ndate = \"2024-02-01\"\ntags = [\"Web Dev\", \"Meta\", \"Meta\"]\n+++\nB body\n\nmore\n";
    s.posts["a-post.md"] = "+++\ntitle = \"A\"\ndate = \"2024-02-01\"\ntags = [\"Meta\"]\n+++\nA body\n";
    s.posts["old.md"] = "+++\ntitle = \"Old\"\ndate = \"2023-12-31\"\nslug = \"ancient\"\n+++\n";
    s.posts["draft.md"] = "+++\ntitle = \"D\"\ndate = \"2025-01-01\"\ndraft = true\ntags = [\"Hidden\"]\n+++\nx\n";
    s.pages["zeta.md"] = "+++\ntitle = \"Z\"\n+++\nz\n";
    s.pages["about.md"] = "+++\ntitle = \"About\"\n+++\n# About\n";
    s.pages["wip.md"] = "+++\ntitle = \"Wip\"\ndraft = true\n+++\n";
    return s;
}

unittest // slugs, dates and the first block
{
    assert(tagSlug("Web Development") == "web-development");
    assert(tagSlug("C++") == "c");
    assert(tagSlug("Rust 2024") == "rust-2024");
    assert(tagSlug("--a  b--") == "a-b");
    assert(longDate("2024-03-05") == "March 5, 2024");
    assert(longDate("1999-12-25") == "December 25, 1999");
    assert(firstBlock("\n  \nfirst\nsecond\n\nthird\n") == "first\nsecond");
    assert(firstBlock("no newline") == "no newline");
    assert(firstBlock("   \n\t\n") == "");
    assert(firstBlock("") == "");
}

unittest // ordering, drafts and defaults
{
    auto src = basicSource();
    auto site = buildSite(src);
    assert(site.posts.length == 3);
    // date descending, ties by slug ascending
    assert(site.posts[0].slug == "a-post");
    assert(site.posts[1].slug == "b-post");
    assert(site.posts[2].slug == "ancient");
    assert(site.pages.length == 2 && site.pages[0].slug == "about" && site.pages[1].slug == "zeta");
    assert(site.posts[1].tags == ["Web Dev", "Meta"]); // duplicate dropped
    assert(site.posts[1].excerpt == "<p>B body</p>\n");
    assert(site.posts[1].content == "<p>B body</p>\n<p>more</p>\n");
    assert(site.posts[0].url == "/posts/a-post/");
}

unittest // tags exist only through published posts and are ordered by slug
{
    auto src = basicSource();
    auto site = buildSite(src);
    assert(site.tags.length == 2);
    assert(site.tags[0].slug == "meta" && site.tags[1].slug == "web-dev");
    assert(site.tags[0].posts == [0, 1]); // canonical order
    assert(site.postTags[1] == [1, 0]); // the post's own tag order
}

unittest // pagination arithmetic
{
    auto src = basicSource();
    auto site = buildSite(src);
    assert(site.indexPageCount == 2); // 3 posts, 2 per page
    src.posts.clear();
    assert(buildSite(src).indexPageCount == 1);
}
