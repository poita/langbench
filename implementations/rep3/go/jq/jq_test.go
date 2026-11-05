package jq_test

import (
	"strings"
	"testing"

	"jq"
	"jq/value"
)

// run compiles filter, runs it on the JSON document and returns the compact
// outputs joined by newlines, with "error" appended if evaluation failed.
func run(t *testing.T, filter, doc string) string {
	t.Helper()
	q, err := jq.Compile(filter)
	if err != nil {
		t.Fatalf("Compile(%q): %v", filter, err)
	}
	in, err := value.ParseString(doc)
	if err != nil {
		t.Fatalf("Parse(%q): %v", doc, err)
	}
	out, err := q.Collect(in)
	var lines []string
	for _, v := range out {
		lines = append(lines, value.JSON(v))
	}
	if err != nil {
		lines = append(lines, "error")
	}
	return strings.Join(lines, "\n")
}

func TestFilters(t *testing.T) {
	tests := []struct{ name, filter, doc, want string }{
		{"identity", `.`, `{"b":1,"a":[1,2]}`, `{"b":1,"a":[1,2]}`},
		{"field", `.a.b`, `{"a":{"b":5}}`, `5`},
		{"missing field", `.a.b.c`, `{"a":{}}`, `null`},
		{"quoted field", `."a b"`, `{"a b":1}`, `1`},
		{"negative index", `.[-1], .[5]`, `[1,2,3]`, "3\nnull"},
		{"slice", `.[1:], .[:-1], .[1:2]`, `[1,2,3]`, "[2,3]\n[1,2]\n[2]"},
		{"string slice", `.[1:3]`, `"aéiou"`, `"éi"`},
		{"iterate object", `.[]`, `{"b":1,"a":2}`, "1\n2"},
		{"pipe comma precedence", `.[] | ., 10`, `[1,2]`, "1\n10\n2\n10"},
		{"cartesian binary", `[(1,2) + (10,20)]`, `null`, `[11,12,21,22]`},
		{"object cartesian", `{a:(1,2), b:(3,4)}`, `null`, "{\"a\":1,\"b\":3}\n{\"a\":1,\"b\":4}\n{\"a\":2,\"b\":3}\n{\"a\":2,\"b\":4}"},
		{"object shorthand", `1 as $x | {a, "b", $x}`, `{"a":1,"b":2}`, `{"a":1,"b":2,"x":1}`},
		{"duplicate keys", `{a:1,b:2,a:3}`, `null`, `{"a":3,"b":2}`},
		{"computed key", `{(.k): .v}`, `{"k":"x","v":1}`, `{"x":1}`},
		{"object add order", `. + {"m":3,"z":9}`, `{"z":1,"a":2}`, `{"z":9,"a":2,"m":3}`},
		{"object mul", `.[0] * .[1]`, `[{"a":{"b":1,"c":2}},{"a":{"b":3}}]`, `{"a":{"b":3,"c":2}}`},
		{"index generator order", `[([1,2],[3,4])[(0,1)]]`, `null`, `[1,3,2,4]`},
		{"optional field", `[.[] | .a?]`, `[{"a":1},5,{"a":2}]`, `[1,2]`},
		{"optional vs inner error", `.a.b?`, `5`, `error`},
		{"optional iterate", `[(1,[2],3)[]?]`, `null`, `[2]`},
		{"try", `[(1,2,error,3)?]`, `null`, `[1,2]`},
		{"try downstream error", `(1,2)? | error`, `null`, `error`},
		{"error(null) caught", `[error(null)?]`, `null`, `[]`},
		{"double question", `[.a??]`, `5`, `[]`},
		{"results before error", `.[] | .a`, `[{"a":1},3]`, "1\nerror"},
		{"and or short circuit", `(false and error), (true or error)`, `null`, "false\ntrue"},
		{"and truthiness", `[(0 and ""), (null or false)]`, `null`, `[true,false]`},
		{"if elif", `.[] | if . < 0 then "neg" elif . == 0 then "zero" else "pos" end`, `[-1,0,1]`, "\"neg\"\n\"zero\"\n\"pos\""},
		{"if no else", `if . then 1 end`, `false`, `false`},
		{"as binding", `.[] as $x | $x * 2`, `[1,2]`, "2\n4"},
		{"shadowing", `1 as $x | 2 as $x | $x`, `null`, `2`},
		{"reduce", `reduce .[] as $x (0; . + $x)`, `[1,2,3]`, `6`},
		{"reduce empty update", `reduce .[] as $x (5; empty)`, `[1,2]`, `null`},
		{"reduce objects", `reduce .[] as $o ({}; . + {($o.k): $o.v})`, `[{"k":"b","v":1},{"k":"a","v":2}]`, `{"b":1,"a":2}`},
		{"unary minus", `[-1, -.a, -(.a + 1), 2 * -3, 1 - -1, 1 -1]`, `{"a":2}`, `[-1,-2,-3,-6,2,0]`},
		{"modulo", `[-7 % 3, 7 % -3, 5.5 % 2]`, `null`, `[-1,1,1]`},
		{"modulo zero", `5 % 0.5`, `null`, `error`},
		{"division", `[1 / 4, "a,b,,c" / ",", "" / ",", "abc" / ""]`, `null`, `[0.25,["a","b","","c"],[],["a","b","c"]]`},
		{"divide by zero", `1 / 0`, `null`, `error`},
		{"string repeat", `["ab" * 2, 2 * "ab", "ab" * 0, "ab" * -1]`, `null`, `["abab","abab","",null]`},
		{"array subtraction", `[1,2,1,3] - [1]`, `null`, `[2,3]`},
		{"null addition", `[null + 1, "a" + null]`, `null`, `[1,"a"]`},
		{"1 == 1.5-0.5", `1 == (1.5 - 0.5)`, `null`, `true`},
		{"comparison types", `[null < false, false < true, true < 0, 1 < "a", "a" < [], [] < {}]`, `null`, `[true,true,true,true,true,true]`},
		{"length", `[.[] | length]`, `[null,-3,"héllo",[1,2],{"a":1}]`, `[0,3,5,2,1]`},
		{"length boolean", `true | length`, `null`, `error`},
		{"keys", `keys, (.[] | keys?)`, `{"b":1,"a":[7]}`, "[\"a\",\"b\"]\n[0]"},
		{"has", `[has("a"), has("z")], ([1,2] | has(1.5, -1, 2))`, `{"a":1}`, "[true,false]\ntrue\nfalse\nfalse"},
		{"has null", `has("a")`, `null`, `false`},
		{"type", `[.[] | type]`, `[null,true,1,"a",[],{}]`, `["null","boolean","number","string","array","object"]`},
		{"add", `add, (map(.) | add), ([] | add)`, `[[1],[2,3]]`, "[1,2,3]\n[1,2,3]\nnull"},
		{"add strings objects", `[(map(.s) | add), (map({(.s): 1}) | add)]`, `[{"s":"a"},{"s":"b"}]`, `["ab",{"a":1,"b":1}]`},
		{"add mismatch", `add`, `[1,"a"]`, `error`},
		{"select map", `map(select(. > 1))`, `[1,2,3]`, `[2,3]`},
		{"map object", `map(. + 1)`, `{"a":1,"b":2}`, `[2,3]`},
		{"sort", `sort`, `[3,"a",null,[1],{"a":1},true,false,1]`, `[null,false,true,1,3,"a",[1],{"a":1}]`},
		{"sort_by multi", `sort_by(.a, .b)`, `[{"a":2,"b":1},{"a":1,"b":2},{"a":1,"b":1}]`, `[{"a":1,"b":1},{"a":1,"b":2},{"a":2,"b":1}]`},
		{"sort_by stable", `sort_by(.k) | map(.v)`, `[{"k":1,"v":"a"},{"k":0,"v":"b"},{"k":1,"v":"c"},{"k":0,"v":"d"}]`, `["b","d","a","c"]`},
		{"group_by", `group_by(.k) | map([.[0].k, length])`, `[{"k":"b"},{"k":"a"},{"k":"b"}]`, `[["a",1],["b",2]]`},
		{"unique", `unique`, `[3,1,3,2,1]`, `[1,2,3]`},
		{"reverse", `reverse, (null | reverse)`, `[1,2,3]`, "[3,2,1]\n[]"},
		{"reverse string", `reverse`, `"abc"`, `error`},
		{"min max", `min, max, ([] | min)`, `[2,1,3]`, "1\n3\nnull"},
		{"tostring", `[.[] | tostring]`, `["a",1,[1,"b"],null]`, `["a","1","[1,\"b\"]","null"]`},
		{"tonumber", `[.[] | tonumber?]`, `["12","-2.5","x","",3]`, `[12,-2.5,3]`},
		{"empty and error(f)", `[empty], [error(empty)], error("x")`, `null`, "[]\n[]\nerror"},
		{"not", `[.[] | not]`, `[null,false,0,""]`, `[true,true,false,false]`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tc.filter, tc.doc); got != tc.want {
				t.Errorf("filter %s on %s\n got: %s\nwant: %s", tc.filter, tc.doc, got, tc.want)
			}
		})
	}
}

func TestCompileErrors(t *testing.T) {
	for _, f := range []string{`.[`, `(1`, `{a:}`, `if 1 then 2`, `1 +`, `nosuchfn`, `reduce . as $x (0)`, `"abc`} {
		if _, err := jq.Compile(f); err == nil {
			t.Errorf("Compile(%q) succeeded, want error", f)
		}
	}
}

func TestRunStopsWhenEmitFails(t *testing.T) {
	q, err := jq.Compile(`.[]`)
	if err != nil {
		t.Fatal(err)
	}
	in, _ := value.ParseString(`[1,2,3]`)
	stop := &stopErr{}
	n := 0
	err = q.Run(in, func(value.Value) error {
		n++
		if n == 2 {
			return stop
		}
		return nil
	})
	if err != error(stop) || n != 2 {
		t.Errorf("err=%v n=%d", err, n)
	}
}

type stopErr struct{}

func (*stopErr) Error() string { return "stop" }

func TestRuntimeErrorType(t *testing.T) {
	q, _ := jq.Compile(`.a`)
	in, _ := value.ParseString(`5`)
	_, err := q.Collect(in)
	if _, ok := err.(*jq.Error); !ok {
		t.Errorf("want *jq.Error, got %T", err)
	}
}
