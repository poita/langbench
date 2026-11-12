package jq_test

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"example.com/jq"
)

// run evaluates filter on the JSON text doc and returns the compact outputs
// joined by newlines, with a final "error" line if evaluation failed.
func run(t *testing.T, filter, doc string) string {
	t.Helper()
	q, err := jq.Compile(filter)
	if err != nil {
		t.Fatalf("Compile(%q): %v", filter, err)
	}
	in, err := jq.ParseJSON([]byte(doc))
	if err != nil {
		t.Fatalf("ParseJSON(%q): %v", doc, err)
	}
	outs, err := q.All(in)
	lines := make([]string, 0, len(outs)+1)
	for _, o := range outs {
		lines = append(lines, string(jq.Marshal(o)))
	}
	if err != nil {
		var re *jq.RuntimeError
		if !errors.As(err, &re) {
			t.Fatalf("unexpected error type %T", err)
		}
		lines = append(lines, "error")
	}
	return strings.Join(lines, "\n")
}

func TestFilters(t *testing.T) {
	tests := []struct{ name, filter, doc, want string }{
		{"identity", `.`, `{"b":1,"a":[1,2]}`, `{"b":1,"a":[1,2]}`},
		{"field missing", `.a.b.c`, `{"a":null}`, `null`},
		{"negative index", `.[-1], .[5]`, `[1,2,3]`, "3\nnull"},
		{"slice", `.[1:], .[:-1], .[5:], .[-2:2]`, `[1,2,3]`, "[2,3]\n[1,2]\n[]\n[2]"},
		{"string slice by code point", `.[1:3]`, `"aé😀z"`, `"é😀"`},
		{"cartesian right outer", `[(1,2) + (10,20)]`, `null`, `[11,12,21,22]`},
		{"object cartesian", `{a:(1,2), b:(3,4)}`, `null`, "{\"a\":1,\"b\":3}\n{\"a\":1,\"b\":4}\n{\"a\":2,\"b\":3}\n{\"a\":2,\"b\":4}"},
		{"index generator order", `([1,2],[3,4])[(0,1)]`, `null`, "1\n3\n2\n4"},
		{"dup keys", `{a:1,b:2,a:3}`, `null`, `{"a":3,"b":2}`},
		{"object add order", `{"z":1,"a":2} + {"m":3,"z":9}`, `null`, `{"z":9,"a":2,"m":3}`},
		{"object multiply", `{"a":{"b":1}} * {"a":{"c":2}}`, `null`, `{"a":{"b":1,"c":2}}`},
		{"arith", `[7 % 3, -7 % 3, 7 % -3, 5.5 % 2, 1 - -1, 2 * -3]`, `null`, `[1,-1,1,1,2,-6]`},
		{"string ops", `["a,b,,c" / ",", "" / ",", "abc" / "", "ab" * 2, "ab" * 0, "ab" * -1]`, `null`, `[["a","b","","c"],[],["a","b","c"],"abab","",null]`},
		{"array subtraction", `[1,2,1,3] - [1]`, `null`, `[2,3]`},
		{"short circuit", `false and error, true or error`, `null`, "false\ntrue"},
		{"and generators", `[(true,false) and (true,false)]`, `null`, `[true,false,false]`},
		{"if without else", `if . > 1 then "big" end`, `1`, `1`},
		{"elif", `if . == 1 then "a" elif . == 2 then "b" else "c" end`, `2`, `"b"`},
		{"as binding", `.[] as $x | $x * 2`, `[1,2]`, "2\n4"},
		{"shadowing", `1 as $x | (2 as $x | $x), $x`, `null`, "2\n1"},
		{"reduce", `reduce .[] as $x (0; . + $x)`, `[1,2,3]`, `6`},
		{"reduce empty update gives null", `reduce .[] as $x (0; empty)`, `[1]`, `null`},
		{"reduce last output", `reduce .[] as $x (0; (. + $x, . * 10))`, `[1,2]`, `0`},
		{"optional per op", `[.[] | .a?]`, `[{"a":1},5,null]`, `[1,null]`},
		{"optional scope", `.a.b?`, `5`, `error`},
		{"optional generator", `[(1,[2],3)[]?]`, `null`, `[2]`},
		{"try", `[(1,2,error,3)?]`, `null`, `[1,2]`},
		{"try downstream error", `(1,2)? | error`, `null`, `error`},
		{"try nested", `[.[] | tonumber?]`, `["1","x","2"]`, `[1,2]`},
		{"error(null) is an error", `error(null)`, `null`, `error`},
		{"error partial output", `1, 2, error, 3`, `null`, "1\n2\nerror"},
		{"keys", `keys, (.[] | keys)`, `{"b":[5],"a":{"z":1,"é":2}}`, "[\"a\",\"b\"]\n[0]\n[\"z\",\"é\"]"},
		{"has", `has("a"), has("z")`, `{"a":1}`, "true\nfalse"},
		{"has array", `has(0), has(1.5), has(-1)`, `[1,2]`, "true\ntrue\nfalse"},
		{"length", `[.[] | length]`, `[null,-3,"é😀",[1,2],{"a":1}]`, `[0,3,2,2,1]`},
		{"length boolean", `length`, `true`, `error`},
		{"type", `[.[] | type]`, `[null,true,1,"a",[],{}]`, `["null","boolean","number","string","array","object"]`},
		{"add", `add, (map(.) | add)`, `[[1],[2,3]]`, "[1,2,3]\n[1,2,3]"},
		{"add empty", `add`, `[]`, `null`},
		{"add mixed", `add`, `[1,"a"]`, `error`},
		{"add strings", `add`, `["a","b",null,"c"]`, `"abc"`},
		{"add object values", `add`, `{"a":1,"b":2}`, `3`},
		{"sort mixed", `sort`, `[{"a":1},[1],"b",1,true,false,null]`, `[null,false,true,1,"b",[1],{"a":1}]`},
		{"sort_by multi", `sort_by(.a, -.b)`, `[{"a":1,"b":1},{"a":0,"b":1},{"a":1,"b":2}]`, `[{"a":0,"b":1},{"a":1,"b":2},{"a":1,"b":1}]`},
		{"sort_by stable", `sort_by(.k) | map(.v)`, `[{"k":1,"v":"a"},{"k":0,"v":"b"},{"k":1,"v":"c"},{"k":0,"v":"d"}]`, `["b","d","a","c"]`},
		{"group_by", `group_by(.k) | map(map(.v))`, `[{"k":1,"v":1},{"k":0,"v":2},{"k":1,"v":3}]`, `[[2],[1,3]]`},
		{"unique", `unique`, `[3,1,3,2,1]`, `[1,2,3]`},
		{"min max", `min, max, ([] | min)`, `[2,1,3,1]`, "1\n3\nnull"},
		{"min first max last", `(map({a:.k}) | min | .a), (map({a:.k}) | max | .a)`, `[{"k":1},{"k":1}]`, "1\n1"},
		{"reverse", `reverse, (null | reverse)`, `[1,2]`, "[2,1]\n[]"},
		{"reverse string errors", `reverse`, `"ab"`, `error`},
		{"tostring", `[.[] | tostring]`, `["a",1,[1,"b"],null]`, `["a","1","[1,\"b\"]","null"]`},
		{"tonumber", `[.[] | tonumber]`, `["12","-2.5",3]`, `[12,-2.5,3]`},
		{"tonumber error", `tonumber`, `"1x"`, `error`},
		{"map object", `map(. + 1)`, `{"a":1,"b":2}`, `[2,3]`},
		{"select", `.[] | select(. > 1 or . == null)`, `[1,2,null,3]`, "2\nnull\n3"},
		{"key via expression", `{(.k): .v}`, `{"k":"x","v":1}`, `{"x":1}`},
		{"non-string key", `{(.k): 1}`, `{"k":1}`, `error`},
		{"index errors", `.[0]`, `{"a":1}`, `error`},
		{"null index null errors", `.[null]`, `null`, `error`},
		{"iterate null errors", `.[]`, `null`, `error`},
		{"div by zero", `1 / 0`, `null`, `error`},
		{"mod by zero", `5 % 0.5`, `null`, `error`},
		{"negate string", `-.`, `"a"`, `error`},
		{"null plus", `null + 1, 1 + null, null + null`, `null`, "1\n1\nnull"},
		{"comparisons", `1 == 1.0, "a" < "b", [1] < [1,0], {"a":1} == {"a":1}, null < false`, `null`, "true\ntrue\ntrue\ntrue\ntrue"},
		{"quoted field", `."a b", .["a b"]`, `{"a b":1}`, "1\n1"},
		{"object shorthand", `3 as $v | {a, "b", $v}`, `{"a":1,"b":2}`, `{"a":1,"b":2,"v":3}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tc.filter, tc.doc); got != tc.want {
				t.Errorf("%s on %s:\n got %s\nwant %s", tc.filter, tc.doc, got, tc.want)
			}
		})
	}
}

func Example() {
	q := jq.MustCompile(`.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)`)
	doc, _ := jq.ParseJSON([]byte(`{"users":[{"name":"bo","age":45},{"name":"al","age":31},{"name":"cy","age":20}]}`))
	for v, err := range q.Iter(doc) {
		if err != nil {
			fmt.Println("error:", err)
			return
		}
		fmt.Println(string(jq.Marshal(v)))
	}
	// Output: ["al","bo"]
}
