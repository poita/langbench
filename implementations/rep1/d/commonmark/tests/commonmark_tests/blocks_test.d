/// Tests for commonmark.blocks: the block structure of documents.
module commonmark_tests.blocks_test;

import commonmark;

/// Kinds of the children of block `b`.
private BlockKind[] childKinds(ref const Document d, int b)
{
    BlockKind[] r;
    for (int c = d.blocks[b].firstChild; c; c = d.blocks[c].next)
        r ~= d.blocks[c].kind;
    return r;
}

unittest
{
    auto d = parseBlocks("");
    assert(d.blocks.length == 1);
    assert(childKinds(d, 0).length == 0);
}

unittest
{
    auto d = parseBlocks("# h\n\npara\n\n> q\n\n- a\n\n***\n\n    code\n\n```\nf\n```\n");
    import std.algorithm : equal;

    assert(childKinds(d, 0) == [
        BlockKind.heading, BlockKind.paragraph, BlockKind.blockQuote,
        BlockKind.list, BlockKind.thematicBreak, BlockKind.indentedCode,
        BlockKind.fencedCode
    ]);
}

unittest
{
    auto d = parseBlocks("Foo\nbar\n---\n");
    assert(childKinds(d, 0) == [BlockKind.heading]);
    assert(d.blocks[d.blocks[0].firstChild].level == 2);
    assert(d.blocks[d.blocks[0].firstChild].content == "Foo\nbar\n");
}

unittest
{
    // Tight vs loose.
    auto tight = parseBlocks("- a\n- b\n");
    assert(tight.blocks[tight.blocks[0].firstChild].tight);
    auto loose = parseBlocks("- a\n\n- b\n");
    assert(!loose.blocks[loose.blocks[0].firstChild].tight);
}

unittest
{
    auto d = parseBlocks("```  ruby startline=3\nx\n```");
    auto b = d.blocks[d.blocks[0].firstChild];
    assert(b.info == "ruby startline=3");
    assert(b.content == "x\n");
    assert(b.fenceChar == '`' && b.fenceLength == 3);
}

unittest
{
    // ordered list start and delimiter
    auto d = parseBlocks("003) x\n");
    auto l = d.blocks[d.blocks[0].firstChild];
    assert(l.ordered && l.start == 3 && l.marker == ')');
}

unittest
{
    assert(toHtml("# foo #\n") == "<h1>foo</h1>\n");
    assert(toHtml("### ###\n") == "<h3></h3>\n");
    assert(toHtml("#5 bolt\n") == "<p>#5 bolt</p>\n");
    assert(toHtml("> a\nb\n") == "<blockquote>\n<p>a\nb</p>\n</blockquote>\n");
    assert(toHtml("> foo\n---\n") == "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n");
    assert(toHtml("1. a\n2. b\n") == "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n");
    assert(toHtml("2. a\n") == "<ol start=\"2\">\n<li>a</li>\n</ol>\n");
    assert(toHtml("-\n  foo\n") == "<ul>\n<li>foo</li>\n</ul>\n");
    assert(toHtml("-\n\n  foo\n") == "<ul>\n<li></li>\n</ul>\n<p>foo</p>\n");
    assert(toHtml("    a  \n\n\n") == "<pre><code>a  \n</code></pre>\n");
    assert(toHtml("\tfoo\n") == "<pre><code>foo\n</code></pre>\n");
    assert(toHtml("- a\n\t- b\n") == "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n");
    assert(toHtml("```\naaa\n  ```\n") == "<pre><code>aaa\n</code></pre>\n");
    assert(toHtml("```\nunclosed") == "<pre><code>unclosed\n</code></pre>\n");
}
