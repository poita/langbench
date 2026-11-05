package jq_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/peter/jq"
)

// run evaluates filter on doc and returns the outputs joined by newlines,
// with a trailing "error" line if evaluation failed.
func run(t *testing.T, filter, doc string) string {
	t.Helper()
	q, err := jq.Compile(filter)
	if err != nil {
		t.Fatalf("Compile(%q): %v", filter, err)
	}
	in, err := jq.ParseJSON(doc)
	if err != nil {
		t.Fatalf("ParseJSON(%q): %v", doc, err)
	}
	outs, err := q.All(in)
	lines := make([]string, 0, len(outs)+1)
	for _, o := range outs {
		lines = append(lines, jq.Marshal(o))
	}
	if err != nil {
		lines = append(lines, "error")
	}
	return strings.Join(lines, "\n")
}

func TestFilters(t *testing.T) {
	tests := []struct{ name, filter, doc, want string }{
		// paths
		{"identity", `.`, `{"b":1,"a":[1,2]}`, `{"b":1,"a":[1,2]}`},
		{"field", `.a.b`, `{"a":{"b":7}}`, `7`},
		{"missing", `.x.y.z`, `{}`, `null`},
		{"quoted field", `."a b"`, `{"a b":1}`, `1`},
		{"index neg", `.[-1], .[5]`, `[1,2,3]`, "3\nnull"},
		{"index on null", `.[0], .a`, `null`, "null\nnull"},
		{"index null key errors", `.[null]`, `null`, `error`},
		{"field on number errors", `.a`, `5`, `error`},
		{"slice", `.[1:], .[:-1], .[1:2], .[-2:], .[5:], .[2:1]`, `[1,2,3]`, "[2,3]\n[1,2]\n[2]\n[2,3]\n[]\n[]"},
		{"string slice", `.[1:3]`, `"aéxyz"`, `"éx"`},
		{"slice null", `.[1:2]`, `null`, `null`},
		{"iterate object", `.[]`, `{"b":1,"a":2}`, "1\n2"},
		{"iterate null errors", `.[]`, `null`, `error`},
		{"index generator order", `([1,2],[3,4])[(0,1)]`, `null`, "1\n3\n2\n4"},
		// optional
		{"opt field", `.a?`, `5`, ``},
		{"opt not covering target", `.a.b?`, `5`, `error`},
		{"opt index", `[([1],2,[3])[0]?]`, `null`, `[1,3]`},
		{"opt iterate", `[(1,[2],3)[]?]`, `null`, `[2]`},
		{"try stops at error", `[(1,2,error,3)?]`, `null`, `[1,2]`},
		{"try paren", `(.a.b)?`, `5`, ``},
		{"try not downstream", `(1,2)? | error`, `null`, `error`},
		{"tonumber opt", `[.[] | tonumber?]`, `["1","x","2.5"]`, `[1,2.5]`},
		// operators
		{"cartesian", `[(1,2) + (10,20)]`, `null`, `[11,12,21,22]`},
		{"object cartesian", `{a:(1,2), b:(3,4)}`, `null`, "{\"a\":1,\"b\":3}\n{\"a\":1,\"b\":4}\n{\"a\":2,\"b\":3}\n{\"a\":2,\"b\":4}"},
		{"null plus", `null + 1, 1 + null, null + null`, `null`, "1\n1\nnull"},
		{"string concat", `"a" + "b"`, `null`, `"ab"`},
		{"array concat", `[1] + [2,3]`, `null`, `[1,2,3]`},
		{"object add", `{"z":1,"a":2} + {"m":3,"z":9}`, `null`, `{"z":9,"a":2,"m":3}`},
		{"object merge", `{"a":{"b":1,"c":2},"x":1} * {"a":{"b":9},"x":{"y":1}}`, `null`, `{"a":{"b":9,"c":2},"x":{"y":1}}`},
		{"array sub", `[1,2,1,3] - [1]`, `null`, `[2,3]`},
		{"string repeat", `"ab" * 3, 2 * "x", "a" * 0, "a" * -1`, `null`, "\"ababab\"\n\"xx\"\n\"\"\nnull"},
		{"division", `3 / 4, "a,b,,c" / ",", "" / ",", "abc" / ""`, `null`, "0.75\n[\"a\",\"b\",\"\",\"c\"]\n[]\n[\"a\",\"b\",\"c\"]"},
		{"div zero", `1 / 0`, `null`, `error`},
		{"modulo", `-7 % 3, 7 % -3, 5.5 % 2`, `null`, "-1\n1\n1"},
		{"modulo zero", `5 % 0.5`, `null`, `error`},
		{"type mismatch", `1 + "a"`, `null`, `error`},
		{"negate", `-1, -.a, -(.a + 1), 2 * -3, 1 - -1, 1 -1`, `{"a":4}`, "-1\n-4\n-5\n-6\n2\n0"},
		{"negate string", `-"a"`, `null`, `error`},
		{"compare", `1 < 2, "a" < "b", null < false, [1] < [1,0], {} > [], 1 == (1.5 - 0.5)`, `null`, "true\ntrue\ntrue\ntrue\ntrue\ntrue"},
		{"and or", `(true, false) and (true, false)`, `null`, "true\nfalse\nfalse"},
		{"short circuit", `false and error, true or error`, `null`, "false\ntrue"},
		{"or truthiness", `null or 0, 0 and null`, `null`, "true\nfalse"},
		// control flow
		{"if", `if . > 1 then "big" elif . > 0 then "one" else "small" end`, `1`, `"one"`},
		{"if no else", `if . then 1 end`, `false`, `false`},
		{"if generator", `[if (true,false) then 1 else 2 end]`, `null`, `[1,2]`},
		{"as binding", `.[] as $x | $x * 2`, `[1,2]`, "2\n4"},
		{"as shadow", `1 as $x | 2 as $x | $x`, `null`, `2`},
		{"as keeps input", `.a as $x | .b + $x`, `{"a":1,"b":2}`, `3`},
		{"reduce", `reduce .[] as $x (0; . + $x)`, `[1,2,3]`, `6`},
		{"reduce empty update", `reduce .[] as $x (5; empty)`, `[1,2]`, `null`},
		{"reduce last output", `reduce .[] as $x (0; ., 10)`, `[1]`, `10`},
		{"reduce object", `reduce .[] as $o ({}; . + {($o.k): $o.v})`, `[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]`, `{"b":3,"a":2}`},
		// construction
		{"array", `[.[] | . * 2], []`, `[1,2]`, "[2,4]\n[]"},
		{"array error", `[1, error]`, `null`, `error`},
		{"object forms ok", `1 as $v | {a, "b", $v, (.k): 1, "q r": 2}`, `{"a":1,"b":2,"k":"kk"}`, `{"a":1,"b":2,"v":1,"kk":1,"q r":2}`},
		{"object dup keys", `{a:1,b:2,a:3}`, `null`, `{"a":3,"b":2}`},
		{"object computed dup", `{a:1,("a","b"):2}`, `null`, "{\"a\":2}\n{\"a\":1,\"b\":2}"},
		{"object bad key", `{(1):2}`, `null`, `error`},
		{"object pipe value", `{a: .x | length}`, `{"x":[1,2]}`, `{"a":2}`},
		{"object neg value", `{a: -.x}`, `{"x":2}`, `{"a":-2}`},
		// builtins
		{"empty", `empty, 1`, `null`, `1`},
		{"error value", `error("x")`, `null`, `error`},
		{"error empty arg", `error(empty), 1`, `null`, `1`},
		{"error null", `error(null)`, `null`, `error`},
		{"not", `[.[] | not]`, `[null,false,0,""]`, `[true,true,false,false]`},
		{"length", `[.[] | length]`, `[null,-3,"héé",[1,2],{"a":1}]`, `[0,3,3,2,1]`},
		{"length bool", `true | length`, `null`, `error`},
		{"keys", `keys`, `{"b":1,"a":2,"é":3,"Z":4}`, `["Z","a","b","é"]`},
		{"keys array", `keys`, `["x","y"]`, `[0,1]`},
		{"keys scalar", `keys`, `1`, `error`},
		{"has", `has("a"), has("z")`, `{"a":1}`, "true\nfalse"},
		{"has array", `has(0), has(1.5), has(-1), has(2)`, `[1,2]`, "true\ntrue\nfalse\nfalse"},
		{"has null", `has("a"), has(1)`, `null`, "false\nfalse"},
		{"has bad", `has(1)`, `{"a":1}`, `error`},
		{"type", `[.[] | type]`, `[null,true,1,"a",[],{}]`, `["null","boolean","number","string","array","object"]`},
		{"add", `add, ([] | add), (map(.) | add)`, `[1,2,3]`, "6\nnull\n6"},
		{"add strings", `add`, `["a","b",null,"c"]`, `"abc"`},
		{"add arrays", `add`, `[[1],[2,3],[]]`, `[1,2,3]`},
		{"add objects", `add`, `[{"a":1},{"b":2},{"a":3}]`, `{"a":3,"b":2}`},
		{"add object values", `add`, `{"x":1,"y":2}`, `3`},
		{"add mismatch", `add`, `[1,"a"]`, `error`},
		{"add null input", `add`, `null`, `error`},
		{"select", `.[] | select(. > 1)`, `[1,2,3]`, "2\n3"},
		{"map object", `map(. + 1)`, `{"a":1,"b":2}`, `[2,3]`},
		{"map generator", `map(., .)`, `[1,2]`, `[1,1,2,2]`},
		{"map scalar", `map(.)`, `1`, `error`},
		{"sort", `sort`, `[3,"a",null,[1],{"a":1},true,false,1]`, `[null,false,true,1,3,"a",[1],{"a":1}]`},
		{"sort_by stable", `sort_by(.k)`, `[{"k":1,"i":1},{"k":0,"i":2},{"k":1,"i":3},{"k":0,"i":4}]`, `[{"k":0,"i":2},{"k":0,"i":4},{"k":1,"i":1},{"k":1,"i":3}]`},
		{"sort_by multi", `sort_by(.a, -.b)`, `[{"a":1,"b":1},{"a":0,"b":1},{"a":1,"b":2}]`, `[{"a":0,"b":1},{"a":1,"b":2},{"a":1,"b":1}]`},
		{"sort_by neg zero", `sort_by(-.n) | map(.n)`, `[{"n":0},{"n":1}]`, `[1,0]`},
		{"sort scalar", `sort`, `1`, `error`},
		{"group_by", `group_by(.k) | map([.[0].k, length])`, `[{"k":"b"},{"k":"a"},{"k":"b"}]`, `[["a",1],["b",2]]`},
		{"group_by order", `group_by(.k)`, `[{"k":2,"i":1},{"k":1,"i":2},{"k":2,"i":3}]`, `[[{"k":1,"i":2}],[{"k":2,"i":1},{"k":2,"i":3}]]`},
		{"unique", `unique`, `[3,1,2,1,3]`, `[1,2,3]`},
		{"reverse", `reverse, (null | reverse)`, `[1,2,3]`, "[3,2,1]\n[]"},
		{"reverse string", `reverse`, `"abc"`, `error`},
		{"min max", `min, max`, `[3,1,2]`, "1\n3"},
		{"min max empty", `min, max`, `[]`, "null\nnull"},
		{"min max ties", `min, max`, `[{"a":1,"b":2},{"b":2,"a":1}]`, "{\"a\":1,\"b\":2}\n{\"b\":2,\"a\":1}"},
		{"tostring", `[.[] | tostring]`, `["a",1,[1,"b"],{"a":null},true]`, `["a","1","[1,\"b\"]","{\"a\":null}","true"]`},
		{"tonumber", `.[] | tonumber`, `["12","-2.5",3]`, "12\n-2.5\n3"},
		{"tonumber bad", `"abc" | tonumber`, `null`, `error`},
		{"tonumber empty", `"" | tonumber`, `null`, `error`},
		{"tonumber array", `tonumber`, `[1]`, `error`},
		// errors keep earlier output
		{"error after output", `1, error, 2`, `null`, "1\nerror"},
		{"spec example 2", `[(1,2) + (10,20)], {a:(1,2), b:(3,4)}, [.[] | .a?], (.[] | .a.b?)`, `[{"a":{"b":1}},{"a":5},3]`,
			"[11,12,21,22]\n{\"a\":1,\"b\":3}\n{\"a\":1,\"b\":4}\n{\"a\":2,\"b\":3}\n{\"a\":2,\"b\":4}\n[{\"b\":1},5]\n1\nerror"},
		{"spec example 1", `.users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse | map({name, age})`,
			`{"users":[{"name":"ann","age":31,"active":true},{"name":"bob","age":45,"active":false},{"name":"cy","age":30,"active":true},{"name":"di","age":52,"active":true},{"name":"ed","age":29,"active":true},{"name":"flo","age":31,"active":true}]}`,
			`[{"name":"di","age":52},{"name":"flo","age":31},{"name":"ann","age":31},{"name":"cy","age":30}]`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tc.filter, tc.doc); got != tc.want {
				t.Errorf("filter %s on %s\n got: %q\nwant: %q", tc.filter, tc.doc, got, tc.want)
			}
		})
	}
}

func TestValuesAreNotMutated(t *testing.T) {
	doc := `{"a":{"x":1},"l":[3,1,2]}`
	got := run(t, `. as $d | (.a + {y:2}), (.a * {x:{z:1}}), (.l | sort), (.l | reverse), $d`, doc)
	want := "{\"x\":1,\"y\":2}\n{\"x\":{\"z\":1}}\n[1,2,3]\n[2,1,3]\n" + doc
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestCompileErrors(t *testing.T) {
	for _, f := range []string{`.[`, `$undefined`, `nosuchbuiltin`, `map`, `length(1)`} {
		if _, err := jq.Compile(f); err == nil {
			t.Errorf("Compile(%q) succeeded", f)
		}
	}
}

func TestRunErrorTypes(t *testing.T) {
	q, _ := jq.Compile(`.a`)
	in, _ := jq.ParseJSON(`5`)
	err := q.Run(in, func(jq.Value) error { return nil })
	var re *jq.RuntimeError
	if !errors.As(err, &re) {
		t.Fatalf("got %v, want *RuntimeError", err)
	}

	// Errors from the callback pass through try untouched.
	q, _ = jq.Compile(`(1,2)?`)
	stop := errors.New("stop")
	n := 0
	err = q.Run(in, func(jq.Value) error { n++; return stop })
	if err != stop || n != 1 {
		t.Errorf("err=%v n=%d", err, n)
	}
}

func TestQueryReuse(t *testing.T) {
	q, err := jq.Compile(`.[] | . * 2`)
	if err != nil {
		t.Fatal(err)
	}
	for _, doc := range []string{`[1]`, `[1,2]`} {
		in, _ := jq.ParseJSON(doc)
		outs, err := q.All(in)
		if err != nil || len(outs) != len(in.Elems()) {
			t.Errorf("doc %s: %v %v", doc, outs, err)
		}
	}
}

func TestLargeAddIsLinear(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("[")
	for i := 0; i < 20000; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`"abcdefghij"`)
	}
	sb.WriteString("]")
	if got := run(t, `add | length`, sb.String()); got != "200000" {
		t.Errorf("got %s", got)
	}
}
