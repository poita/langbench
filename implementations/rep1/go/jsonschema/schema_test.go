package jsonschema_test

import (
	"strings"
	"sync"
	"testing"

	"example.com/jsonschema"
	"example.com/jsonschema/jsonvalue"
)

func parse(t testing.TB, s string) jsonvalue.Value {
	t.Helper()
	v, err := jsonvalue.ParseString(s)
	if err != nil {
		t.Fatalf("parse %q: %v", s, err)
	}
	return v
}

type instance struct {
	json  string
	valid bool
}

type testCase struct {
	name      string
	schema    string
	remotes   map[string]string
	instances []instance
}

func run(t *testing.T, tests []testCase) {
	t.Helper()
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var c jsonschema.Compiler
			// Register remotes in a deterministic order.
			for _, uri := range sortedKeys(tc.remotes) {
				c.AddResource(uri, parse(t, tc.remotes[uri]))
			}
			s, err := c.Compile(parse(t, tc.schema))
			if err != nil {
				t.Fatalf("Compile: %v", err)
			}
			for _, in := range tc.instances {
				if got := s.Validate(parse(t, in.json)); got != in.valid {
					t.Errorf("Validate(%s) = %v, want %v (schema %s)", in.json, got, in.valid, tc.schema)
				}
			}
		})
	}
}

func sortedKeys(m map[string]string) []string {
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	for i := range keys {
		for j := i + 1; j < len(keys); j++ {
			if keys[j] < keys[i] {
				keys[i], keys[j] = keys[j], keys[i]
			}
		}
	}
	return keys
}

func TestBasicKeywords(t *testing.T) {
	run(t, []testCase{
		{"true schema", `true`, nil, []instance{{`1`, true}, {`null`, true}}},
		{"false schema", `false`, nil, []instance{{`1`, false}, {`{}`, false}}},
		{"empty schema", `{}`, nil, []instance{{`[1]`, true}}},
		{"type integer", `{"type":"integer"}`, nil, []instance{{`1`, true}, {`1.0`, true}, {`1e2`, true}, {`1.5`, false}, {`"1"`, false}, {`true`, false}}},
		{"type number", `{"type":"number"}`, nil, []instance{{`1.5`, true}, {`true`, false}, {`null`, false}}},
		{"type list", `{"type":["string","null"]}`, nil, []instance{{`"a"`, true}, {`null`, true}, {`1`, false}}},
		{"unknown type name", `{"type":"nope"}`, nil, []instance{{`1`, false}}},
		{"enum", `{"enum":[1,"1",null,[1],{"a":1}]}`, nil, []instance{
			{`1`, true}, {`1.0`, true}, {`{"a":1.000}`, true}, {`true`, false}, {`false`, false}, {`[2]`, false}, {`[1.0]`, true}}},
		{"const", `{"const":{"a":[1,2],"b":null}}`, nil, []instance{
			{`{"b":null,"a":[1.0,2]}`, true}, {`{"a":[1,2]}`, false}}},
		{"const null", `{"const":null}`, nil, []instance{{`null`, true}, {`0`, false}}},
		{"const false", `{"const":false}`, nil, []instance{{`false`, true}, {`0`, false}}},
		{"unknown keywords inert", `{"definitions":{"x":false},"foo":{"type":"string"},"dependencies":{"a":["b"]},"format":"ipv4","title":"t"}`, nil,
			[]instance{{`"nope"`, true}, {`{"a":1}`, true}}},
		{"malformed keyword values ignored", `{"minLength":"x","required":"a","type":5,"properties":3}`, nil,
			[]instance{{`"a"`, true}, {`{}`, true}}},
	})
}

func TestNumbers(t *testing.T) {
	run(t, []testCase{
		{"multipleOf exact", `{"multipleOf":0.0001}`, nil, []instance{{`0.3`, true}, {`0.0021`, true}, {`0.00751`, false}, {`"x"`, true}}},
		{"multipleOf integer", `{"multipleOf":2}`, nil, []instance{{`4`, true}, {`4.0`, true}, {`5`, false}, {`0`, true}, {`-4`, true}, {`7.5`, false}}},
		{"multipleOf huge", `{"multipleOf":1e-400}`, nil, []instance{{`1e400`, true}, {`1.5e-400`, false}}},
		{"bounds", `{"minimum":1.5,"maximum":10}`, nil, []instance{{`1.5`, true}, {`10.0`, true}, {`1.4999999999999999999`, false}, {`10.0000001`, false}, {`"x"`, true}}},
		{"exclusive bounds", `{"exclusiveMinimum":0,"exclusiveMaximum":1}`, nil, []instance{{`0`, false}, {`1`, false}, {`0.5`, true}, {`-0.0`, false}}},
		{"big numbers are exact", `{"maximum":1e308}`, nil, []instance{{`1e308`, true}, {`1.0000000000000001e308`, false}, {`1e309`, false}, {`-1e400`, true}}},
		{"huge integer", `{"type":"integer","maximum":123456789012345678901234567890}`, nil, []instance{
			{`123456789012345678901234567890`, true}, {`123456789012345678901234567891`, false}}},
	})
}

func TestStrings(t *testing.T) {
	run(t, []testCase{
		{"length counts code points", `{"minLength":2,"maxLength":2}`, nil, []instance{{`"💩💩"`, true}, {`"💩"`, false}, {`"e\u0301"`, true}, {`"\u00e9"`, false}, {`"abc"`, false}, {`5`, true}}},
		{"length any numeric form", `{"maxLength":2.0,"minLength":1e0}`, nil, []instance{{`"ab"`, true}, {`"abc"`, false}, {`""`, false}}},
		{"pattern searches", `{"pattern":"bar"}`, nil, []instance{{`"foobarbaz"`, true}, {`"foo"`, false}, {`1`, true}}},
		{"pattern anchors", `{"pattern":"^a$"}`, nil, []instance{{`"a"`, true}, {`"a\n"`, false}}},
		{"ECMA word boundary", `{"pattern":"\\bcat\\b"}`, nil, []instance{{`"écat "`, true}, {`"concat"`, false}}},
		{"format is annotation", `{"type":"string","format":"ipv4"}`, nil, []instance{{`"nope"`, true}}},
	})
}

func TestArrays(t *testing.T) {
	run(t, []testCase{
		{"item counts", `{"minItems":1,"maxItems":2}`, nil, []instance{{`[]`, false}, {`[1]`, true}, {`[1,2,3]`, false}, {`"x"`, true}}},
		{"uniqueItems", `{"uniqueItems":true}`, nil, []instance{
			{`[1,2,3]`, true}, {`[1,1.0]`, false}, {`[true,1]`, true}, {`[{"a":1,"b":2},{"b":2,"a":1}]`, false}, {`[[1],[1.0]]`, false}, {`["1",1]`, true}}},
		{"uniqueItems large", `{"uniqueItems":true}`, nil, []instance{
			{`[1,2,3,4,5,6,7,8,9,10,11,12]`, true}, {`[1,2,3,4,5,6,7,8,9,10,11,1.0]`, false}, {`[{"a":1},{"a":2},{"a":3},{"a":4},{"a":5},{"a":6},{"a":7},{"a":8},{"a":9},{"a":1}]`, false}}},
		{"uniqueItems false", `{"uniqueItems":false}`, nil, []instance{{`[1,1]`, true}}},
		{"prefixItems and items", `{"prefixItems":[{"type":"integer"},{"type":"string"}],"items":{"type":"boolean"}}`, nil, []instance{
			{`[]`, true}, {`[1]`, true}, {`[1,"a",true,false]`, true}, {`[1,"a",1]`, false}, {`["a"]`, false}}},
		{"items without prefixItems", `{"items":{"type":"integer"}}`, nil, []instance{{`[1,2]`, true}, {`[1,"a"]`, false}}},
		{"contains", `{"contains":{"type":"integer"}}`, nil, []instance{{`["a",1]`, true}, {`["a"]`, false}, {`[]`, false}, {`"a"`, true}}},
		{"contains counts", `{"contains":{"type":"integer"},"minContains":2,"maxContains":3}`, nil, []instance{
			{`[1,"a",2]`, true}, {`["a",1,2,3,"b"]`, true}, {`[1,"a"]`, false}, {`[1,2,3,4]`, false}}},
		{"minContains zero", `{"contains":{"type":"integer"},"minContains":0}`, nil, []instance{{`[]`, true}, {`["a"]`, true}}},
		{"minContains zero with max", `{"contains":{"type":"integer"},"minContains":0,"maxContains":1}`, nil, []instance{{`[]`, true}, {`[1]`, true}, {`[1,2]`, false}}},
		{"minContains alone is inert", `{"minContains":2}`, nil, []instance{{`[1]`, true}}},
		{"contains count forms", `{"contains":true,"minContains":2.0,"maxContains":2e0}`, nil, []instance{{`[1,2]`, true}, {`[1]`, false}, {`[1,2,3]`, false}}},
	})
}

func TestObjects(t *testing.T) {
	run(t, []testCase{
		{"property counts", `{"minProperties":1,"maxProperties":2}`, nil, []instance{{`{}`, false}, {`{"a":1}`, true}, {`{"a":1,"b":2,"c":3}`, false}, {`[]`, true}}},
		{"required", `{"required":["a","b"]}`, nil, []instance{{`{"a":1,"b":2}`, true}, {`{"a":1}`, false}, {`[]`, true}}},
		{"properties", `{"properties":{"a":{"type":"integer"},"b":false}}`, nil, []instance{{`{"a":1}`, true}, {`{"a":"x"}`, false}, {`{"b":1}`, false}, {`{"c":1}`, true}}},
		{"patternProperties", `{"patternProperties":{"^a":{"type":"integer"},"b$":{"minimum":5}}}`, nil, []instance{
			{`{"ab":5}`, true}, {`{"ab":4}`, false}, {`{"ac":"x"}`, false}, {`{"cb":6,"zz":"x"}`, true}}},
		{"additionalProperties", `{"properties":{"a":true},"patternProperties":{"^x-":true},"additionalProperties":false}`, nil, []instance{
			{`{"a":1,"x-b":2}`, true}, {`{"c":1}`, false}}},
		{"additionalProperties schema", `{"additionalProperties":{"type":"string"}}`, nil, []instance{{`{"a":"x"}`, true}, {`{"a":1}`, false}}},
		{"propertyNames", `{"propertyNames":{"maxLength":2}}`, nil, []instance{{`{"ab":1}`, true}, {`{"abc":1}`, false}, {`{}`, true}}},
		{"dependentRequired", `{"dependentRequired":{"a":["b","c"]}}`, nil, []instance{{`{}`, true}, {`{"a":1,"b":1,"c":1}`, true}, {`{"a":1,"b":1}`, false}}},
		{"dependentSchemas", `{"dependentSchemas":{"a":{"required":["b"]}}}`, nil, []instance{{`{}`, true}, {`{"a":1,"b":1}`, true}, {`{"a":1}`, false}}},
	})
}

func TestApplicators(t *testing.T) {
	run(t, []testCase{
		{"allOf", `{"allOf":[{"type":"integer"},{"minimum":3}]}`, nil, []instance{{`3`, true}, {`2`, false}, {`3.5`, false}}},
		{"anyOf", `{"anyOf":[{"type":"integer"},{"minimum":3}]}`, nil, []instance{{`1`, true}, {`3.5`, true}, {`2.5`, false}}},
		{"oneOf", `{"oneOf":[{"type":"integer"},{"minimum":3}]}`, nil, []instance{{`1`, true}, {`3.5`, true}, {`3`, false}, {`2.5`, false}}},
		{"not", `{"not":{"type":"integer"}}`, nil, []instance{{`1`, false}, {`"a"`, true}}},
		{"if then else", `{"if":{"minimum":0},"then":{"maximum":10},"else":{"minimum":-10}}`, nil, []instance{
			{`5`, true}, {`11`, false}, {`-5`, true}, {`-11`, false}}},
		{"if alone", `{"if":false}`, nil, []instance{{`1`, true}}},
		{"then without if", `{"then":false}`, nil, []instance{{`1`, true}}},
		{"else without if", `{"else":false}`, nil, []instance{{`1`, true}}},
		{"keywords combine", `{"type":"object","required":["a"],"properties":{"a":{"type":"string"}},"not":{"required":["b"]}}`, nil, []instance{
			{`{"a":"x"}`, true}, {`{"a":"x","b":1}`, false}, {`{"a":1}`, false}}},
	})
}

func TestUnevaluated(t *testing.T) {
	run(t, []testCase{
		{"across allOf and if/then", `{"allOf":[{"properties":{"a":{"type":"integer"}}},{"properties":{"b":{"type":"integer"}}}],
			"if":{"required":["a"]},"then":{"properties":{"c":{"type":"string"}}},"unevaluatedProperties":false}`, nil, []instance{
			{`{"a":1,"b":2}`, true}, {`{"a":1,"c":"yes"}`, true}, {`{"b":2,"c":"yes"}`, false}, {`{"a":1,"d":0}`, false}}},
		{"anyOf only counts accepting branches", `{"anyOf":[{"properties":{"a":true},"required":["a"]},{"properties":{"b":true},"required":["b"]}],"unevaluatedProperties":false}`, nil, []instance{
			{`{"a":1}`, true}, {`{"a":1,"b":1}`, true}, {`{"b":1,"c":1}`, false}}},
		{"rejected branch contributes nothing", `{"anyOf":[{"properties":{"a":true},"required":["z"]},true],"unevaluatedProperties":false}`, nil, []instance{
			{`{"a":1}`, false}, {`{}`, true}}},
		{"not contributes nothing", `{"not":{"not":{"properties":{"a":true}}},"unevaluatedProperties":false}`, nil, []instance{{`{"a":1}`, false}, {`{}`, true}}},
		{"oneOf", `{"oneOf":[{"properties":{"a":true},"required":["a"]},{"properties":{"b":true},"required":["b"]}],"unevaluatedProperties":false}`, nil, []instance{
			{`{"a":1}`, true}, {`{"a":1,"c":1}`, false}}},
		{"additionalProperties counts", `{"additionalProperties":true,"unevaluatedProperties":false}`, nil, []instance{{`{"a":1}`, true}}},
		{"unevaluatedProperties schema", `{"properties":{"a":true},"unevaluatedProperties":{"type":"integer"}}`, nil, []instance{
			{`{"a":"x","b":1}`, true}, {`{"b":"x"}`, false}}},
		{"nested unevaluatedProperties sees inner", `{"properties":{"foo":{"type":"string"}},"allOf":[{"unevaluatedProperties":true}],"unevaluatedProperties":{"type":"string","maxLength":2}}`, nil, []instance{
			{`{"foo":"foo","bar":"b"}`, true}}},
		{"patternProperties count", `{"patternProperties":{"^x":true},"unevaluatedProperties":false}`, nil, []instance{{`{"xa":1}`, true}, {`{"y":1}`, false}}},
		{"dependentSchemas counts", `{"properties":{"a":true},"dependentSchemas":{"a":{"properties":{"b":true}}},"unevaluatedProperties":false}`, nil, []instance{{`{"a":1,"b":1}`, true}, {`{"b":1}`, false}}},
		{"unevaluatedItems after prefix", `{"prefixItems":[true],"unevaluatedItems":false}`, nil, []instance{{`[1]`, true}, {`[1,2]`, false}, {`[]`, true}}},
		{"unevaluatedItems with items", `{"items":true,"unevaluatedItems":false}`, nil, []instance{{`[1,2,3]`, true}}},
		{"unevaluatedItems with contains", `{"contains":{"type":"string"},"unevaluatedItems":false}`, nil, []instance{
			{`["a"]`, true}, {`["a","b"]`, true}, {`["a",1]`, false}, {`[1,"a"]`, false}}},
		{"unevaluatedItems across allOf", `{"allOf":[{"prefixItems":[true]},{"prefixItems":[true,true]}],"unevaluatedItems":false}`, nil, []instance{
			{`[1,2]`, true}, {`[1,2,3]`, false}}},
		{"unevaluatedItems across anyOf", `{"anyOf":[{"prefixItems":[true,true],"minItems":2},{"prefixItems":[true]}],"unevaluatedItems":{"type":"string"}}`, nil, []instance{
			{`[1,2,"x"]`, true}, {`[1,2,3]`, false}}},
		{"unevaluatedItems schema", `{"prefixItems":[true],"unevaluatedItems":{"type":"integer"}}`, nil, []instance{{`["a",1]`, true}, {`["a","b"]`, false}}},
		{"nested unevaluatedItems", `{"allOf":[{"prefixItems":[true],"unevaluatedItems":true}],"unevaluatedItems":false}`, nil, []instance{{`[1,2,3]`, true}}},
		{"unevaluated inert on other types", `{"unevaluatedProperties":false,"unevaluatedItems":false}`, nil, []instance{{`1`, true}, {`"a"`, true}, {`[]`, true}, {`{}`, true}, {`[1]`, false}, {`{"a":1}`, false}}},
		{"through $ref", `{"$ref":"#/$defs/p","unevaluatedProperties":false,"$defs":{"p":{"properties":{"a":true}}}}`, nil, []instance{{`{"a":1}`, true}, {`{"b":1}`, false}}},
	})
}

func TestReferences(t *testing.T) {
	run(t, []testCase{
		{"local pointer", `{"$defs":{"i":{"type":"integer"}},"properties":{"a":{"$ref":"#/$defs/i"}}}`, nil, []instance{{`{"a":1}`, true}, {`{"a":"x"}`, false}}},
		{"root recursion", `{"properties":{"child":{"$ref":"#"}},"type":"object"}`, nil, []instance{{`{"child":{"child":{}}}`, true}, {`{"child":{"child":1}}`, false}}},
		{"pointer escapes", `{"$defs":{"a/b":{"type":"integer"},"c~d":{"type":"string"},"e f":{"type":"null"}},
			"allOf":[{"$ref":"#/$defs/a~1b"}] }`, nil, []instance{{`1`, true}, {`"x"`, false}}},
		{"pointer percent decoding", `{"$defs":{"e f":{"type":"null"}},"$ref":"#/$defs/e%20f"}`, nil, []instance{{`null`, true}, {`1`, false}}},
		{"tilde pointer", `{"$defs":{"c~d":{"type":"string"}},"$ref":"#/$defs/c~0d"}`, nil, []instance{{`"s"`, true}, {`1`, false}}},
		{"ref beside siblings", `{"$ref":"#/$defs/i","maximum":5,"$defs":{"i":{"type":"integer"}}}`, nil, []instance{{`3`, true}, {`7`, false}, {`3.5`, false}}},
		{"anchor", `{"$ref":"#foo","$defs":{"a":{"$anchor":"foo","type":"integer"}}}`, nil, []instance{{`1`, true}, {`"x"`, false}}},
		{"anchor in embedded resource", `{"$id":"http://x.test/root","$ref":"http://x.test/other#foo","$defs":{"o":{"$id":"other","$anchor":"foo","type":"integer"}}}`, nil, []instance{{`1`, true}, {`"x"`, false}}},
		{"$id changes the base", `{"$id":"http://x.test/a/root.json","$defs":{"i":{"$id":"b/int.json","type":"integer"}},"properties":{"v":{"$ref":"b/int.json"}}}`, nil, []instance{{`{"v":1}`, true}, {`{"v":"x"}`, false}}},
		{"$id with fragment stripped", `{"$id":"http://x.test/r#","$ref":"http://x.test/r#/$defs/i","$defs":{"i":{"type":"integer"}}}`, nil, []instance{{`1`, true}, {`"x"`, false}}},
		{"ref into nested $id resource by pointer", `{"$id":"http://x.test/r","$defs":{"n":{"$id":"http://x.test/n","$defs":{"s":{"type":"string"}}}},"$ref":"http://x.test/n#/$defs/s"}`, nil, []instance{{`"a"`, true}, {`1`, false}}},
		{"$id inside const is data", `{"const":{"$id":"http://x.test/other"},"$ref":"#/$defs/a","$defs":{"a":true}}`, nil, []instance{{`{"$id":"http://x.test/other"}`, true}, {`{}`, false}}},
		{"ref to $defs under unknown keyword (compiled on demand)", `{"$ref":"#/definitions/i","definitions":{"i":{"type":"integer"}}}`, nil, []instance{{`1`, true}, {`"x"`, false}}},
		{"ref to boolean subschema", `{"$ref":"#/$defs/no","$defs":{"no":false}}`, nil, []instance{{`1`, false}}},
		{"remote refs", `{"$id":"http://localhost:1234/draft2020-12/root-of-its-own.json","type":"object","properties":{"i":{"$ref":"integer.json"},"n":{"$ref":"subSchemas.json#/$defs/integer"}}}`,
			map[string]string{
				"http://localhost:1234/draft2020-12/integer.json":    `{"type":"integer"}`,
				"http://localhost:1234/draft2020-12/subSchemas.json": `{"$defs":{"integer":{"type":"integer"}}}`,
			}, []instance{{`{"i":1,"n":2}`, true}, {`{"i":"1"}`, false}, {`{"n":"1"}`, false}}},
		{"remote with own $id", `{"$ref":"http://example.test/canonical"}`,
			map[string]string{"http://elsewhere.test/file.json": `{"$id":"http://example.test/canonical","type":"string"}`},
			[]instance{{`"a"`, true}, {`1`, false}}},
		{"remote resolves relative to its retrieval URI", `{"$ref":"http://localhost:1234/a/one.json"}`,
			map[string]string{
				"http://localhost:1234/a/one.json": `{"$ref":"two.json"}`,
				"http://localhost:1234/a/two.json": `{"type":"integer"}`,
			}, []instance{{`1`, true}, {`"a"`, false}}},
		{"relative base with no scheme", `{"$id":"sub/","$ref":"x.json"}`,
			map[string]string{"sub/x.json": `{"type":"integer"}`}, []instance{{`1`, true}, {`"a"`, false}}},
		{"urn base", `{"$id":"urn:example:root","$ref":"#/$defs/a","$defs":{"a":{"type":"integer"}}}`, nil, []instance{{`1`, true}, {`"x"`, false}}},
		{"$anchor beats $dynamicAnchor for plain refs", `{"$ref":"#n","$defs":{"d":{"$dynamicAnchor":"n","type":"string"},"a":{"$anchor":"n","type":"integer"}}}`, nil, []instance{{`1`, true}, {`"x"`, false}}},
		{"dangling reference not reached", `{"if":false,"then":{"$ref":"#/nope"}}`, nil, []instance{{`1`, true}}},
		{"dangling reference reached", `{"$ref":"#/nope"}`, nil, []instance{{`1`, false}}},
	})
}

func TestDynamicRef(t *testing.T) {
	run(t, []testCase{
		{"extensible generic list", `{
			"$id": "https://example.test/strings",
			"$defs": {
				"itemType": {"$dynamicAnchor": "itemType", "type": "string"},
				"list": {
					"$id": "https://example.test/list",
					"$defs": {"itemType": {"$dynamicAnchor": "itemType"}},
					"type": "array",
					"items": {"$dynamicRef": "#itemType"}
				}
			},
			"$ref": "https://example.test/list"}`, nil, []instance{{`["a","b"]`, true}, {`["a",1]`, false}, {`[]`, true}}},
		{"generic list on its own accepts anything", `{
			"$id": "https://example.test/list",
			"$defs": {"itemType": {"$dynamicAnchor": "itemType"}},
			"type": "array",
			"items": {"$dynamicRef": "#itemType"}}`, nil, []instance{{`["a",1]`, true}}},
		{"$dynamicRef without dynamic anchor acts like $ref", `{"$id":"https://example.test/r","$dynamicRef":"#/$defs/i","$defs":{"i":{"type":"integer"}}}`, nil, []instance{{`1`, true}, {`"a"`, false}}},
		{"$dynamicRef to plain anchor acts like $ref", `{"$id":"https://example.test/r","$dynamicRef":"#a","$defs":{"i":{"$anchor":"a","type":"integer"}}}`, nil, []instance{{`1`, true}, {`"a"`, false}}},
		{"scope is outermost-first across remotes", `{"$id":"https://example.test/root","$dynamicAnchor":"node","type":"object","properties":{"c":{"$ref":"https://example.test/tree"}}}`,
			map[string]string{"https://example.test/tree": `{"$id":"https://example.test/tree","$dynamicAnchor":"node","type":"object","properties":{"c":{"$dynamicRef":"#node"}}}`},
			[]instance{{`{"c":{"c":{"c":{}}}}`, true}, {`{"c":{"c":1}}`, false}}},
	})
}

func TestUnresolvedAndErrors(t *testing.T) {
	s, err := jsonschema.CompileJSON([]byte(`{"properties":{"a":{"$ref":"http://nowhere.test/x"},"b":{"$ref":"#/$defs/ok"},"c":{"$ref":"#missing"}},"$defs":{"ok":true}}`))
	if err != nil {
		t.Fatal(err)
	}
	u := s.Unresolved()
	if len(u) != 2 || !strings.Contains(u[0], "#missing") || !strings.Contains(u[1], "nowhere.test") {
		t.Errorf("Unresolved() = %q", u)
	}

	if _, err := jsonschema.CompileJSON([]byte(`{"pattern":"("}`)); err == nil {
		t.Error("invalid pattern should be a compile error")
	}
	if _, err := jsonschema.CompileJSON([]byte(`{"patternProperties":{"[":true}}`)); err == nil {
		t.Error("invalid patternProperties key should be a compile error")
	}
	if _, err := jsonschema.CompileJSON([]byte(`{`)); err == nil {
		t.Error("malformed JSON should be an error")
	}
}

func TestValidateJSON(t *testing.T) {
	s, err := jsonschema.CompileJSON([]byte(`{"type":"integer","minimum":1}`))
	if err != nil {
		t.Fatal(err)
	}
	for in, want := range map[string]bool{`3`: true, `0`: false, `"3"`: false} {
		got, err := s.ValidateJSON([]byte(in))
		if err != nil || got != want {
			t.Errorf("ValidateJSON(%s) = %v, %v; want %v", in, got, err, want)
		}
	}
	if _, err := s.ValidateJSON([]byte(`[`)); err == nil {
		t.Error("ValidateJSON of malformed instance should fail")
	}
}

// A compiled Schema is shared between goroutines.
func TestConcurrentValidation(t *testing.T) {
	s, err := jsonschema.CompileJSON([]byte(`{"$ref":"#/$defs/n","$defs":{"n":{"type":"object","properties":{"c":{"$ref":"#/$defs/n"}},"unevaluatedProperties":false}}}`))
	if err != nil {
		t.Fatal(err)
	}
	good, bad := parse(t, `{"c":{"c":{}}}`), parse(t, `{"c":{"x":1}}`)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				if !s.Validate(good) || s.Validate(bad) {
					t.Error("wrong verdict")
					return
				}
			}
		}()
	}
	wg.Wait()
}

func TestDeepRecursion(t *testing.T) {
	const depth = 3000
	s, err := jsonschema.CompileJSON([]byte(`{"$ref":"#/$defs/t","$defs":{"t":{"type":["array","integer"],"items":{"$ref":"#/$defs/t"}}}}`))
	if err != nil {
		t.Fatal(err)
	}
	doc := strings.Repeat("[", depth) + "1" + strings.Repeat("]", depth)
	if !s.Validate(parse(t, doc)) {
		t.Error("deeply nested instance should be valid")
	}
	doc = strings.Repeat("[", depth) + `"x"` + strings.Repeat("]", depth)
	if s.Validate(parse(t, doc)) {
		t.Error("deeply nested bad leaf should be invalid")
	}
}

func BenchmarkUniqueItems(b *testing.B) {
	s, _ := jsonschema.CompileJSON([]byte(`{"uniqueItems":true}`))
	var sb strings.Builder
	sb.WriteString("[")
	for i := 0; i < 20000; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"id":` + strings.Repeat("1", 1) + string(rune('0'+i%10)) + `,"n":[` + itoa(i) + `]}`)
	}
	sb.WriteString("]")
	v := parse(b, sb.String())
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s.Validate(v)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var d []byte
	for ; n > 0; n /= 10 {
		d = append([]byte{byte('0' + n%10)}, d...)
	}
	return string(d)
}
