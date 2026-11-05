module tests.encodedword_test;

import mime.encodedword;

unittest // decode_unstructured examples
{
    assert(decodeUnstructured("=?utf-8?Q?caf=C3=A9?=") == "café");
    assert(decodeUnstructured("=?utf-8?Q?a?=   =?utf-8?Q?b?=") == "ab");
    assert(decodeUnstructured("x =?utf-8?Q?a?= y") == "x a y");
    assert(decodeUnstructured("=?utf-8?Q?a?=b") == "ab");
    assert(decodeUnstructured("=?iso-8859-1?Q?caf=E9?=") == "café");
    assert(decodeUnstructured("=?windows-1252?Q?smart=92quote?=") == "smart’quote");
    assert(decodeUnstructured("=?utf-8?B?SsO2cmc=?=") == "Jörg");
    assert(decodeUnstructured("=?utf-8*en?Q?hi?=") == "hi");
    assert(decodeUnstructured("=?utf-8?X?hi?=") == "=?utf-8?X?hi?=");
    assert(decodeUnstructured("  plain    spaced   text  ") == "plain    spaced   text");
    assert(decodeUnstructured("=?utf-8?Q?a?= \t =?utf-8?Q?b?= \t c") == "ab \t c");
}

unittest // Q decoding corner cases
{
    assert(decodeUnstructured("=?utf-8?Q?a_b?=") == "a b");
    assert(decodeUnstructured("=?utf-8?Q?a=Zb?=") == "a=Zb");
    assert(decodeUnstructured("=?utf-8?Q?a=4?=") == "a=4");
    assert(decodeUnstructured("=?utf-8?Q??=") == "");
}

unittest // recognition
{
    EncodedWord w;
    assert(matchEncodedWord("=?utf-8?Q?x?=", 0, w) && w.end == 13 && w.text == "x");
    assert(!matchEncodedWord("=?utf-8?Q?x y?=", 0, w));
    assert(!matchEncodedWord("=? ?Q?x?=", 0, w));
    assert(!matchEncodedWord("=??Q?x?=", 0, w));
    assert(!matchEncodedWord("=?utf-8?Q?x?", 0, w));
    assert(matchEncodedWord("ab=?us-ascii?b?QQ==?=", 2, w) && w.text == "A");
}

unittest // decode_display
{
    assert(decodeDisplay("John Q. Public ") == "John Q. Public");
    assert(decodeDisplay(`"Doe, John" `) == "Doe, John");
    assert(decodeDisplay("=?utf-8?B?SsO2cmc=?= ") == "Jörg");
    assert(decodeDisplay("John (the third) Public ") == "John   Public");
    assert(decodeDisplay(`"=?utf-8?Q?x?=" `) == "=?utf-8?Q?x?=");
    assert(decodeDisplay("foo (c (nested)) ") == "foo");
}
