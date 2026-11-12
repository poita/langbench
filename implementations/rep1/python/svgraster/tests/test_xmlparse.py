from svgraster.xmlparse import parse_xml, resolve_entities


def test_basic_tree_and_prefixes():
    root = parse_xml('<?xml version="1.0"?><!-- c --><svg:svg xmlns:svg="x"><svg:rect a="1" xlink:href="#q"/></svg:svg>')
    assert root.tag == "svg"
    assert root.children[0].tag == "rect"
    assert root.children[0].attrs == {"a": "1", "href": "#q"}


def test_doctype_cdata_and_gt_in_value():
    text = ('<!DOCTYPE svg [ <!ENTITY a "b>"> ]><svg><![CDATA[ <rect/> ]]>'
            "<g a='x>y'><circle/></g></svg>")
    root = parse_xml(text)
    assert [c.tag for c in root.children] == ["g"]
    assert root.children[0].attrs["a"] == "x>y"
    assert root.children[0].children[0].tag == "circle"


def test_last_duplicate_attribute_wins():
    assert parse_xml('<svg a="1" b:a="2"/>').attrs["a"] == "2"


def test_entities():
    assert resolve_entities("&amp;&lt;&gt;&quot;&apos;&#65;&#x42;&foo;") == "&<>\"'AB&foo;"
