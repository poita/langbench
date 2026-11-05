module tests.filters_test;

import jtemplate;
import tests.support;

unittest // case, trim, escape, replace
{
    assert(render(`{{ "aBc1é"|upper }}|{{ "AbC"|lower }}`) == "ABC1é|abc");
    assert(render(`[{{ " \t x y \n"|trim }}]`) == "[x y]");
    assert(render(`{{ "<a href=\"x\">&'</a>"|escape }}`) ==
        "&lt;a href=&#34;x&#34;&gt;&amp;&#39;&lt;/a&gt;");
    assert(render(`{{ "a-b-c"|replace("-", "--") }}|{{ "aaa"|replace("aa", "b") }}`) == "a--b--c|ba");
}

unittest // length
{
    assert(render(`{{ "héllo"|length }} {{ [1,2,3]|length }} {{ d|length }}`, `{"d": {"a":1,"b":2}}`)
           == "5 3 2");
    assert(errorOf(`{{ 5|length }}`) == ErrorKind.type);
}

unittest // int
{
    assert(render(`{{ "42"|int }} {{ " -7 "|int }} {{ "3.9"|int }} {{ "-3.9"|int }} {{ "1e2"|int }}`
                  ~ `{{ ".5e1"|int }} {{ "abc"|int }} {{ 2.9|int }} {{ -2.9|int }} {{ true|int }} {{ none|int }}`)
           == "42 -7 3 -3 1005 0 2 -2 1 0");
}

unittest // join, first, last, reverse
{
    assert(render(`{{ [1, "a", 2.5]|join(", ") }}|{{ "abc"|join("-") }}|{{ [1,2]|join }}`) == "1, a, 2.5|a-b-c|12");
    assert(render(`{{ [1,2,3]|first }}{{ [1,2,3]|last }}{{ "xyz"|first }}{{ d|last }}`, `{"d":{"p":1,"q":2}}`) == "13xq");
    assert(render(`{{ [] |first is defined }}`) == "False");
    assert(render(`{{ "héy"|reverse }} {{ [1,2,3]|reverse|join }}`) == "yéh 321");
}

unittest // sort
{
    assert(render(`{{ [3, 1.5, 2, true]|sort|join(",") }}`) == "True,1.5,2,3");
    assert(render(`{{ ["b", "A", "a", "C"]|sort|join(",") }}`) == "A,a,b,C");
    assert(render(`{{ "dcba"|sort|join }}`) == "abcd");
    assert(errorOf(`{{ [1, "a"]|sort }}`) == ErrorKind.type);
}

unittest // default
{
    assert(render(`{{ nope|default }}|{{ nope|default("d") }}|{{ 0|default("d") }}`) == "|d|0");
    assert(errorOf(`{{ nope|default(1, 2) }}`) == ErrorKind.type);
}

unittest // argument checks come after the undefined check
{
    assert(errorOf(`{{ nope|upper(1) }}`) == ErrorKind.undefined);
    assert(errorOf(`{{ "x"|upper(1) }}`) == ErrorKind.type);
    assert(errorOf(`{{ "x"|replace("a") }}`) == ErrorKind.type);
    assert(errorOf(`{{ nope|upper }}`) == ErrorKind.undefined);
}

unittest // chaining
{
    assert(render(`{{ "  Hi "|trim|upper|replace("I", "ey") }}`) == "Hey");
}
