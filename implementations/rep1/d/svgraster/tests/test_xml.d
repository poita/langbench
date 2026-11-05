module test_xml;

import svgraster.xml;

unittest // prefixes, entities, last duplicate wins
{
    auto d = parseXml(`<?xml version="1.0"?><!-- c --><!DOCTYPE svg [<!ENTITY x "a>b">]>
        <svg:svg xmlns:svg="u" xmlns:xlink="x"><use xlink:href="#a" id='u'/><![CDATA[ <ignored> ]]>
        <g id="a" fill="r&amp;g" k="&#65;&#x42;&bogus;" k="z" w="a>b"><rect id="a"/></g></svg:svg>`);
    assert(d.root !is null && d.root.tag == "svg");
    assert(d.root.children.length == 2);
    auto use = d.root.children[0];
    assert(use.tag == "use" && use.attr("href") == "#a");
    auto g = d.root.children[1];
    assert(g.attr("fill") == "r&g");
    assert(g.attr("k") == "z");
    assert(g.attr("w") == "a>b");
    assert(d.byId("a") is g); // first element with the id wins
    assert(d.byId("missing") is null);
}

unittest // entity decoding
{
    assert(decodeEntities("&lt;&gt;&quot;&apos;&amp;") == "<>\"'&");
    assert(decodeEntities("&#65;&#x42;&#xe9;") == "ABé");
    assert(decodeEntities("&nope; & &#;") == "&nope; & &#;");
    assert(decodeEntities("plain") == "plain");
}

unittest // empty and unusual input
{
    assert(parseXml("").root is null);
    auto d = parseXml("<svg/>");
    assert(d.root !is null && d.root.children.length == 0);
    d = parseXml("<svg a = '1' b = \"2\" ><g></g></svg><svg/>");
    assert(d.root.attr("a") == "1" && d.root.attr("b") == "2");
    assert(d.root.children.length == 1);
}
