/// Unit tests for the TOML-subset reader and front-matter splitting.
module tests.toml_test;

import sitegen.frontmatter;
import sitegen.toml;
import std.exception : assertThrown;

unittest // value forms
{
    auto d = parseToml("# a comment\n"
            ~ "title  = \"The \\\"Big\\\" Blog\"        # trailing comment\n"
            ~ "posts_per_page = 5\n\n"
            ~ "  draft = false\n"
            ~ "tags = [\"one\", \"two\",]\n"
            ~ "motto = \"line one\\nline two\"\n"
            ~ "neg = -4\n"
            ~ "hash = \"a # b\"\n"
            ~ "uni = \"caf\\u00e9 \\u00E9 é\"\n"
            ~ "empty = [ ]\n");
    assert(d.getString("title") == `The "Big" Blog`);
    assert(d.getInteger("posts_per_page") == 5);
    assert(!d.getBool("draft", true));
    assert(d.getArray("tags") == ["one", "two"]);
    assert(d.getString("motto") == "line one\nline two");
    assert(d.getInteger("neg") == -4);
    assert(d.getString("hash") == "a # b");
    assert(d.getString("uni") == "café é é");
    assert(d.getArray("empty").length == 0);
    assert(d.getString("absent", "dflt") == "dflt");
    // entries keep file order
    assert(d.entries[0].key == "title" && d.entries[$ - 1].key == "empty");
}

unittest // rejected input
{
    assertThrown!TomlException(parseToml("key"));
    assertThrown!TomlException(parseToml("k = \"unterminated"));
    assertThrown!TomlException(parseToml("k = \"bad \\q\""));
    assertThrown!TomlException(parseToml("k = 1 2"));
    assertThrown!TomlException(parseToml("k = [1]"));
    assertThrown!TomlException(parseToml("k = \"a\" x"));
}

unittest // typed getters complain about the wrong type
{
    auto d = parseToml("n = 1\ns = \"x\"\n");
    assertThrown!TomlException(d.getString("n"));
    assertThrown!TomlException(d.getInteger("s"));
}

unittest // front matter
{
    auto fm = splitFrontMatter("+++\ntitle = \"x\"\nnote = \"+++\"\n+++\nbody\n+++\nmore\n");
    assert(fm.meta.getString("title") == "x");
    assert(fm.meta.getString("note") == "+++");
    assert(fm.body_ == "body\n+++\nmore\n");

    assert(splitFrontMatter("+++\ntitle = \"x\"\n+++").body_ == "");
    assert(splitFrontMatter("+++\n+++\n").body_ == "");
    assertThrown!FrontMatterException(splitFrontMatter("no front matter"));
    assertThrown!FrontMatterException(splitFrontMatter("+++\ntitle = \"x\"\n"));
    // `+++` inside a longer line does not end the front matter
    assert(splitFrontMatter("+++\n# +++ here\n+++\nz").body_ == "z");
}
