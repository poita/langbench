package jq

import (
	"errors"
	"strings"
	"testing"
)

// run compiles filter, parses doc and returns the compact results joined by
// newlines, with a trailing "error" line if evaluation failed.
func run(t *testing.T, filter, doc string) string {
	t.Helper()
	f, err := Compile(filter)
	if err != nil {
		t.Fatalf("Compile(%q): %v", filter, err)
	}
	in, err := ParseJSONString(doc)
	if err != nil {
		t.Fatalf("ParseJSON(%q): %v", doc, err)
	}
	var lines []string
	err = f.Run(in, func(v Value) error {
		lines = append(lines, string(Marshal(v)))
		return nil
	})
	if err != nil {
		var je *Error
		if !errors.As(err, &je) {
			t.Fatalf("unexpected non-jq error %v", err)
		}
		lines = append(lines, "error")
	}
	return strings.Join(lines, "\n")
}

func TestFilters(t *testing.T) {
	tests := []struct{ name, filter, doc, want string }{
		{"identity", `.`, `{"b":1,"a":[1,2.5,"x"]}`, `{"b":1,"a":[1,2.5,"x"]}`},
		{"field", `.a.b`, `{"a":{"b":3}}`, `3`},
		{"missing field", `.x`, `{}`, `null`},
		{"field on null", `.x.y`, `null`, `null`},
		{"field on number errors", `.x`, `5`, `error`},
		{"index negative", `.[-1], .[5]`, `[1,2,3]`, "3\nnull"},
		{"index null key errors", `.[null]`, `null`, `error`},
		{"slice", `.[1:3], .[:1], .[-2:], .[2:1]`, `[0,1,2,3]`, "[1,2]\n[0]\n[2,3]\n[]"},
		{"string slice", `.[1:3]`, `"aéiou"`, `"éi"`},
		{"iterate object", `.[]`, `{"b":1,"a":2}`, "1\n2"},
		{"iterate null errors", `.[]`, `null`, `error`},
		{"generator index order", `([1,2],[3,4])[(0,1)]`, `null`, "1\n3\n2\n4"},
		{"right operand outer", `[(1,2) + (10,20)]`, `null`, `[11,12,21,22]`},
		{"object cartesian", `{a:(1,2), b:(3,4)}`, `null`, "{\"a\":1,\"b\":3}\n{\"a\":1,\"b\":4}\n{\"a\":2,\"b\":3}\n{\"a\":2,\"b\":4}"},
		{"object dup key", `{b:1,a:2,b:3}`, `null`, `{"b":3,"a":2}`},
		{"object shorthand", `{a, "b", $x}`, `{"a":1,"b":2}`, `error`},
		{"object shorthand var", `. as $x | {a, $x}`, `{"a":1}`, `{"a":1,"x":{"a":1}}`},
		{"computed key must be string", `{(1): 2}`, `null`, `error`},
		{"object add keeps position", `{"z":1,"a":2} + {"m":3,"z":9}`, `null`, `{"z":9,"a":2,"m":3}`},
		{"object multiply", `{a:{b:1,c:2}} * {a:{b:9},d:1}`, `null`, `{"a":{"b":9,"c":2},"d":1}`},
		{"string ops", `"ab" * 3, "ab" * 0, "ab" * -1, "a,b,,c" / ",", "" / ",", "abc" / ""`, `null`,
			"\"ababab\"\n\"\"\nnull\n[\"a\",\"b\",\"\",\"c\"]\n[]\n[\"a\",\"b\",\"c\"]"},
		{"array minus", `[1,2,3,2,[2]] - [2,[2]]`, `null`, `[1,3]`},
		{"modulo", `-7 % 3, 7 % -3, 5.5 % 2`, `null`, "-1\n1\n1"},
		{"modulo zero", `5 % 0.5`, `null`, `error`},
		{"divide by zero", `1, 1 / 0`, `null`, "1\nerror"},
		{"null plus", `null + 1, "a" + null`, `null`, "1\n\"a\""},
		{"comparison order", `[null,false,true,0,"a",[],{}] | sort == .`, `null`, `true`},
		{"object order", `{"a":2} < {"b":1}, {"a":1,"b":2} == {"b":2,"a":1}`, `null`, "true\ntrue"},
		{"and or short circuit", `false and error, true or error, (true,false) and (true,false)`, `null`, "false\ntrue\ntrue\nfalse\nfalse"},
		{"if without else", `[.[] | if . > 1 then "big" end]`, `[1,2]`, `[1,"big"]`},
		{"if elif", `if . == 1 then "a" elif . == 2 then "b" else "c" end`, `2`, `"b"`},
		{"bind", `.[] as $x | $x * 2`, `[1,2]`, "2\n4"},
		{"bind shadowing", `1 as $x | [$x, (2 as $x | $x), $x]`, `null`, `[1,2,1]`},
		{"reduce", `reduce .[] as $x (0; . + $x)`, `[1,2,3]`, `6`},
		{"reduce empty update gives null", `reduce (1,2) as $x (0; if $x == 2 then empty else . + $x end)`, `null`, `null`},
		{"optional field", `[.[] | .a?]`, `[{"a":1},5,null]`, `[1,null]`},
		{"optional only inner", `.a.b?`, `5`, `error`},
		{"try", `[(1,2,error,3)?]`, `null`, `[1,2]`},
		{"try keeps downstream errors", `(1,2)? | error`, `null`, `error`},
		{"paren try", `[.[] | (.a.b)?]`, `[{"a":{"b":1}},{"a":5},3,null]`, `[1,null]`},
		{"error(null) is caught", `[error(null)?]`, `null`, `[]`},
		{"error before results", `1, error("x"), 2`, `null`, "1\nerror"},
		{"empty", `[empty], [1, empty, 2]`, `null`, "[]\n[1,2]"},
		{"length", `[.[] | length]`, `[null,-2.5,"😀é",[1],{"a":1}]`, `[0,2.5,2,1,1]`},
		{"length boolean errors", `length`, `true`, `error`},
		{"keys", `keys, ([5,6] | keys)`, `{"b":1,"a":2}`, "[\"a\",\"b\"]\n[0,1]"},
		{"has", `has("a"), has("z")`, `{"a":1}`, "true\nfalse"},
		{"has array", `[has(0), has(1.5), has(-1), has(2)]`, `[1,2]`, `[true,true,false,false]`},
		{"type", `[.[] | type]`, `[null,true,1,"s",[],{}]`, `["null","boolean","number","string","array","object"]`},
		{"add", `add, ([] | add)`, `[[1],null,[2]]`, "[1,2]\nnull"},
		{"add strings and objects", `(["a","b"] | add), ([{"a":1},{"b":2},{"a":3}] | add)`, `null`, "\"ab\"\n{\"a\":3,\"b\":2}"},
		{"add mixed errors", `add`, `[1,"a"]`, `error`},
		{"select map", `map(select(. > 1))`, `[1,2,3]`, `[2,3]`},
		{"map object", `map(. + 1)`, `{"a":1,"b":2}`, `[2,3]`},
		{"sort_by multiple", `sort_by(.a, .b) | map(.i)`, `[{"a":1,"b":2,"i":0},{"a":1,"b":1,"i":1},{"a":0,"b":9,"i":2}]`, `[2,1,0]`},
		{"sort_by stable", `sort_by(.k) | map(.i)`, `[{"k":1,"i":0},{"k":0,"i":1},{"k":1,"i":2}]`, `[1,0,2]`},
		{"group_by", `group_by(.k) | map(length)`, `[{"k":"b"},{"k":"a"},{"k":"b"}]`, `[1,2]`},
		{"unique", `unique`, `[3,1,3,2,1]`, `[1,2,3]`},
		{"reverse", `reverse, (null | reverse)`, `[1,2]`, "[2,1]\n[]"},
		{"min max ties", `min, max, ([] | min)`, `[3,1,2]`, "1\n3\nnull"},
		{"tostring", `[.[] | tostring]`, `["a",1,[1,"b"],null]`, `["a","1","[1,\"b\"]","null"]`},
		{"tonumber", `[.[] | tonumber?]`, `["12","-2.5","x","",3]`, `[12,-2.5,3]`},
		{"not", `[true, 0, null] | map(not)`, `null`, `[false,false,true]`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tc.filter, tc.doc); got != tc.want {
				t.Errorf("filter %s on %s:\n got: %q\nwant: %q", tc.filter, tc.doc, got, tc.want)
			}
		})
	}
}

func TestCompileErrors(t *testing.T) {
	for _, src := range []string{`.[`, `1 +`, `nosuchbuiltin`, `{a:}`, `if 1 then 2`, `"abc`, `reduce .[] (0; .)`} {
		if _, err := Compile(src); err == nil {
			t.Errorf("Compile(%q) succeeded, want error", src)
		}
	}
}

func TestYieldErrorPropagates(t *testing.T) {
	stop := errors.New("stop")
	f := MustCompile(`(1,2,3)?`)
	n := 0
	err := f.Run(nil, func(Value) error {
		n++
		return stop
	})
	if err != stop || n != 1 {
		t.Errorf("got err=%v after %d results, want stop after 1", err, n)
	}
}

func TestCollect(t *testing.T) {
	res, err := MustCompile(`.[] | if . == 2 then error("x") else . end`).Collect([]Value{1.0, 2.0, 3.0})
	if len(res) != 1 || res[0] != 1.0 {
		t.Errorf("results = %v", res)
	}
	var je *Error
	if !errors.As(err, &je) {
		t.Errorf("err = %v, want *Error", err)
	}
}

func TestObjectSharingIsImmutable(t *testing.T) {
	// Extending the same large object two different ways must not interfere.
	base := NewObject(0)
	for i := 0; i < 40; i++ {
		base.Set(strings.Repeat("k", i+1), float64(i))
	}
	f := MustCompile(`(. + {x: 1}), (. + {y: 2}), (. + {x: 3}) | [has("x"), has("y"), length, .x]`)
	res, err := f.Collect(base)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, r := range res {
		got = append(got, string(Marshal(r)))
	}
	want := []string{`[true,false,41,1]`, `[false,true,41,null]`, `[true,false,41,3]`}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("got %v want %v", got, want)
	}
	if base.Len() != 40 {
		t.Errorf("base mutated: %d keys", base.Len())
	}
}

func TestReduceObjectBuild(t *testing.T) {
	got := run(t, `reduce .[] as $k ({}; . + {($k): 1}) | length`, genKeys(3000))
	if got != "3000" {
		t.Errorf("got %s", got)
	}
}

func genKeys(n int) string {
	var sb strings.Builder
	sb.WriteByte('[')
	for i := 0; i < n; i++ {
		if i > 0 {
			sb.WriteByte(',')
		}
		sb.WriteString(`"key`)
		sb.WriteString(strings.Repeat("a", i%7))
		sb.WriteString(string(Marshal(float64(i)))) // unique suffix
		sb.WriteByte('"')
	}
	sb.WriteByte(']')
	return sb.String()
}
