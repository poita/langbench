package jq_test

import (
	"strings"
	"testing"

	"example.com/jq"
)

// run evaluates filter on doc and returns the output lines plus whether an
// error was raised.
func run(t *testing.T, filter, doc string) (lines []string, failed bool) {
	t.Helper()
	prog, err := jq.Compile(filter)
	if err != nil {
		t.Fatalf("compile %q: %v", filter, err)
	}
	in, err := jq.ParseJSON([]byte(doc))
	if err != nil {
		t.Fatalf("parse %q: %v", doc, err)
	}
	out, err := prog.Query(in)
	for _, v := range out {
		lines = append(lines, jq.Marshal(v))
	}
	return lines, err != nil
}

func TestFilters(t *testing.T) {
	cases := []struct {
		name, filter, doc, want string // want: outputs joined by " ", "!" suffix means error
	}{
		{"identity", `.`, `{"b":1,"a":[1,2]}`, `{"b":1,"a":[1,2]}`},
		{"field", `.a.b, .x.y`, `{"a":{"b":2}}`, `2 null`},
		{"quoted field", `."a b", .["a b"]`, `{"a b":1}`, `1 1`},
		{"negative index", `.[-1], .[5]`, `[1,2,3]`, `3 null`},
		{"slice", `.[1:], .[:-1], .[1:2]`, `[1,2,3]`, `[2,3] [1,2] [2]`},
		{"string slice", `.[1:3]`, `"aéö😀"`, `"éö"`},
		{"iterate", `.[]`, `[1,"a",null]`, `1 "a" null`},
		{"iterate object", `.[]`, `{"b":1,"a":2}`, `1 2`},
		{"pipe comma", `.[] | ., 10`, `[1,2]`, `1 10 2 10`},
		{"cartesian", `[(1,2) + (10,20)]`, `null`, `[11,12,21,22]`},
		{"object cartesian", `{a:(1,2), b:(3,4)}`, `null`,
			`{"a":1,"b":3} {"a":1,"b":4} {"a":2,"b":3} {"a":2,"b":4}`},
		{"object dup keys", `{a:1,b:2,a:3}`, `null`, `{"a":3,"b":2}`},
		{"object shorthand", `9 as $x | {a, "b", $x}`, `{"a":1,"b":2}`, `{"a":1,"b":2,"x":9}`},
		{"computed key", `{(.k): .v}`, `{"k":"z","v":1}`, `{"z":1}`},
		{"index generator order", `[([1,2],[3,4])[(0,1)]]`, `null`, `[1,3,2,4]`},
		{"optional per op", `[([1],2,[3])[0]?]`, `null`, `[1,3]`},
		{"optional iterate", `[(1,[2],3)[]?]`, `null`, `[2]`},
		{"optional only last", `.a.b?`, `5`, `!`},
		{"optional last ok", `.a?`, `5`, ``},
		{"try", `[(1,2,error,3)?]`, `null`, `[1,2]`},
		{"try downstream", `(1,2)? | error`, `null`, `!`},
		{"try tonumber", `[.[] | tonumber?]`, `["1","x","2.5",""]`, `[1,2.5]`},
		{"truthiness", `[.[] | if . then 1 else 0 end]`, `[0,"",[],{},null,false]`, `[1,1,1,1,0,0]`},
		{"if no else", `if .a then 1 end`, `{"a":false}`, `{"a":false}`},
		{"elif", `.[] | if . < 0 then "n" elif . == 0 then "z" else "p" end`, `[-1,0,1]`, `"n" "z" "p"`},
		{"and or short circuit", `false and error, true or error`, `null`, `false true`},
		{"and or values", `[(true,false) and (true,false)]`, `null`, `[true,false,false]`},
		{"binding", `.[] as $x | $x * 2`, `[1,2]`, `2 4`},
		{"shadowing", `1 as $x | 2 as $x | $x`, `null`, `2`},
		{"reduce", `reduce .[] as $x (0; . + $x)`, `[1,2,3]`, `6`},
		{"reduce empty update", `reduce .[] as $x (0; empty)`, `[1,2]`, `null`},
		{"reduce object", `reduce .[] as $o ({}; . + {($o.k): $o.v})`, `[{"k":"b","v":1},{"k":"a","v":2}]`, `{"b":1,"a":2}`},
		{"arith precedence", `1 + 2 * 3 - 4 / 2, 2 * -3, 1 - -1, -(1 + 2)`, `null`, `5 -6 2 -3`},
		{"modulo", `-7 % 3, 7 % -3, 5.5 % 2`, `null`, `-1 1 1`},
		{"div", `3 / 4`, `null`, `0.75`},
		{"string ops", `"a,b,,c" / ",", ("ab" * 2), ("ab" * -1), ("a" + "b")`, `null`, `["a","b","","c"] "abab" null "ab"`},
		{"array ops", `[1,2,3,2] - [2], ([1] + [2]), ([1] + null)`, `null`, `[1,3] [1,2] [1]`},
		{"object merge", `{"z":1,"a":2} + {"m":3,"z":9}, ({"a":{"b":1}} * {"a":{"c":2}})`, `null`,
			`{"z":9,"a":2,"m":3} {"a":{"b":1,"c":2}}`},
		{"comparisons", `[1 < 2, "a" < "b", null < false, [] < {}, {"a":1} == {"a":1}, 1 != 1.0]`, `null`,
			`[true,true,true,true,true,false]`},
		{"length", `[.[] | length]`, `[null,-3,"héllo",[1,2],{"a":1}]`, `[0,3,5,2,1]`},
		{"length bool", `length`, `true`, `!`},
		{"keys", `keys, (.[] | keys)?`, `{"b":1,"a":2}`, `["a","b"]`},
		{"keys array", `keys`, `[5,6]`, `[0,1]`},
		{"has", `has("a"), has("z")`, `{"a":1}`, `true false`},
		{"has array", `has(1), has(2), has(-1), has(1.5)`, `[1,2]`, `true false false true`},
		{"has null", `has(1)`, `null`, `false`},
		{"has mismatch", `has("a")`, `[1]`, `!`},
		{"type", `[.[] | type]`, `[null,true,1,"a",[],{}]`, `["null","boolean","number","string","array","object"]`},
		{"add", `add, ([] | add)`, `[1,2,3]`, `6 null`},
		{"add strings", `add`, `["a",null,"b"]`, `"ab"`},
		{"add arrays", `add`, `[[1],[2,3],[]]`, `[1,2,3]`},
		{"add objects", `add`, `[{"a":1},{"b":2},{"a":3}]`, `{"a":3,"b":2}`},
		{"add object values", `add`, `{"x":1,"y":2}`, `3`},
		{"add mismatch", `add`, `[1,"a"]`, `!`},
		{"select map", `map(select(. > 1))`, `[1,2,3]`, `[2,3]`},
		{"map object", `map(. + 1)`, `{"a":1,"b":2}`, `[2,3]`},
		{"map generator", `map(., 0)`, `[1,2]`, `[1,0,2,0]`},
		{"map non-iterable", `map(.)`, `5`, `!`},
		{"sort", `sort`, `[3,"a",null,[1],{"a":1},true,false,1.5]`, `[null,false,true,1.5,3,"a",[1],{"a":1}]`},
		{"sort_by multi", `sort_by(.a, .b) | map(.id)`, `[{"id":1,"a":2,"b":1},{"id":2,"a":1,"b":2},{"id":3,"a":1,"b":1}]`, `[3,2,1]`},
		{"sort_by stable", `sort_by(.k) | map(.id)`, `[{"id":1,"k":1},{"id":2,"k":0},{"id":3,"k":1},{"id":4,"k":0}]`, `[2,4,1,3]`},
		{"group_by", `group_by(.k) | map(map(.id))`, `[{"id":1,"k":"b"},{"id":2,"k":"a"},{"id":3,"k":"b"}]`, `[[2],[1,3]]`},
		{"unique", `unique`, `[3,1,2,1,"a",3]`, `[1,2,3,"a"]`},
		{"reverse", `reverse, (null | reverse)`, `[1,2,3]`, `[3,2,1] []`},
		{"reverse string", `reverse`, `"abc"`, `!`},
		{"min max", `min, max, ([] | min, max)`, `[2,1,3]`, `1 3 null null`},
		{"min max ties", `[min, max]`, `[{"a":1,"b":2},{"b":2,"a":1}]`, `[{"a":1,"b":2},{"b":2,"a":1}]`},
		{"tostring", `[.[] | tostring]`, `["a",1,[1,"b"],null,{"a":1.5}]`, `["a","1","[1,\"b\"]","null","{\"a\":1.5}"]`},
		{"tonumber", `[.[] | tonumber]`, `["12","-2.5","3.25","0",4]`, `[12,-2.5,3.25,0,4]`},
		{"tonumber bad", `tonumber`, `""`, `!`},
		{"error partial", `1, 2, error, 3`, `null`, `1 2 !`},
		{"error(f)", `error("x"), 1`, `null`, `!`},
		{"error(empty)", `error(empty), 1`, `null`, `1`},
		{"error(null)", `error(null)`, `null`, `!`},
		{"error in array", `[1, error]`, `null`, `!`},
		{"index mismatch", `.["a"]`, `[1]`, `!`},
		{"index null key", `.[null]`, `null`, `!`},
		{"iterate null", `.[]`, `null`, `!`},
		{"div zero", `1 / 0`, `null`, `!`},
		{"mod zero", `5 % 0.5`, `null`, `!`},
		{"neg string", `-.`, `"a"`, `!`},
		{"object key not string", `{(1): 2}`, `null`, `!`},
		{"empty", `empty, 1`, `null`, `1`},
		{"not", `[.[] | not]`, `[null,false,0]`, `[true,true,false]`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			lines, failed := run(t, c.filter, c.doc)
			want := c.want
			wantErr := strings.HasSuffix(want, "!")
			want = strings.TrimSpace(strings.TrimSuffix(want, "!"))
			if got := strings.Join(lines, " "); got != want {
				t.Errorf("output %s, want %s", got, want)
			}
			if failed != wantErr {
				t.Errorf("error = %v, want %v", failed, wantErr)
			}
		})
	}
}

func TestCompileErrors(t *testing.T) {
	for _, f := range []string{`.[`, `nosuchbuiltin`, `$undefined`, `length(1)`, `map`} {
		if _, err := jq.Compile(f); err == nil {
			t.Errorf("Compile(%q) should fail", f)
		}
	}
}

func TestRunStopsOnEmitError(t *testing.T) {
	prog, _ := jq.Compile(`.[]`)
	in, _ := jq.ParseJSON([]byte(`[1,2,3]`))
	n := 0
	stop := &jq.Error{Msg: "stop"}
	err := prog.Run(in, func(jq.Value) error {
		n++
		if n == 2 {
			return stop
		}
		return nil
	})
	if err != stop || n != 2 {
		t.Errorf("err=%v n=%d", err, n)
	}
	// An error from emit must not be swallowed by try.
	prog, _ = jq.Compile(`(1,2)?`)
	n = 0
	err = prog.Run(in, func(jq.Value) error { n++; return stop })
	if err != stop || n != 1 {
		t.Errorf("try swallowed downstream error: err=%v n=%d", err, n)
	}
}

func TestProgramReuse(t *testing.T) {
	prog, err := jq.Compile(`map(. * 2)`)
	if err != nil {
		t.Fatal(err)
	}
	for _, doc := range []string{`[1]`, `[1,2]`} {
		in, _ := jq.ParseJSON([]byte(doc))
		out, err := prog.Query(in)
		if err != nil || len(out) != 1 {
			t.Fatalf("%s: %v %v", doc, out, err)
		}
	}
}
