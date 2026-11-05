package template

import "testing"

func TestFilters(t *testing.T) {
	runCases(t, []renderCase{
		{name: "upper lower", tpl: `{{ "aBc1"|upper }}{{ "aBc1"|lower }}`, want: "ABC1abc1"},
		{name: "trim", tpl: `[{{ " \t\nx y \n"|trim }}]`, want: "[x y]"},
		{name: "escape", tpl: `{{ "<a href=\"x\">&'</a>"|escape }}`, want: "&lt;a href=&#34;x&#34;&gt;&amp;&#39;&lt;/a&gt;"},
		{name: "replace", tpl: `{{ "aaa"|replace("aa", "b") }}{{ 12|replace(1, "x") }}`, want: "ba" + "x2"},
		{name: "length", tpl: `{{ "héé"|length }}{{ [1,2]|length }}{{ d|length }}`, ctx: `{"d":{"a":1}}`, want: "321"},
		{name: "length type", tpl: `{{ 5|length }}`, kind: ErrType},
		{name: "int", tpl: `{{ 3.9|int }}{{ -3.9|int }}{{ true|int }}{{ " 42 "|int }}{{ "+7"|int }}{{ "3.9"|int }}{{ "-2.5e1"|int }}{{ ".5"|int }}{{ "abc"|int }}{{ none|int }}{{ "1e"|int }}`, want: "3-31427" + "3" + "-25" + "0000"},
		{name: "join", tpl: `{{ [1, "a", 2.5]|join(", ") }}|{{ "abc"|join("-") }}|{{ [1,2]|join }}`, want: "1, a, 2.5|a-b-c|12"},
		{name: "first last", tpl: `{{ [1,2,3]|first }}{{ [1,2,3]|last }}{{ "abc"|last }}{{ [] |first is defined }}`, want: "13cFalse"},
		{name: "reverse", tpl: `{{ "abc"|reverse }}{{ [1,2,3]|reverse|join(",") }}`, want: "cba3,2,1"},
		{name: "sort numbers", tpl: `{{ [3, 1.5, 2, true]|sort|join(",") }}`, want: "True,1.5,2,3"},
		{name: "sort strings", tpl: `{{ ["b", "A", "a", "B"]|sort|join(",") }}`, want: "A,a,b,B"},
		{name: "sort mix", tpl: `{{ [1, "a"]|sort }}`, kind: ErrType},
		{name: "sort dict", tpl: `{{ d|sort|join(",") }}`, ctx: `{"d":{"b":1,"a":2}}`, want: "a,b"},
		{name: "default", tpl: `{{ x|default }}|{{ x|default("d") }}|{{ y|default("d") }}|{{ x|default(z)|default(1) }}`, ctx: `{"y":0}`, want: "|d|0|1"},
		{name: "chain", tpl: `{{ "  Hi  "|trim|upper }}`, want: "HI"},
	})
}

func TestIntFormScanners(t *testing.T) {
	for s, want := range map[string]bool{"1": true, "+1": true, "-12": true, "": false, "+": false, "1.0": false, "a": false} {
		if got := isIntForm(s); got != want {
			t.Errorf("isIntForm(%q) = %v", s, got)
		}
	}
	for s, want := range map[string]bool{"1.": true, ".5": true, "1.5e3": true, "-1E+2": true, ".": false, "e5": false, "1e": false, "1.5.2": false, "": false, "+.e1": false} {
		if got := isDecimalForm(s); got != want {
			t.Errorf("isDecimalForm(%q) = %v", s, got)
		}
	}
}
