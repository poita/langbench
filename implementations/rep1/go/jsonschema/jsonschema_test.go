package jsonschema_test

import (
	"sync"
	"testing"

	"example.com/jsonschema"
	"example.com/jsonschema/jsonvalue"
)

func parse(t *testing.T, s string) jsonvalue.Value {
	t.Helper()
	v, err := jsonvalue.ParseString(s)
	if err != nil {
		t.Fatalf("bad test JSON %q: %v", s, err)
	}
	return v
}

type tc struct {
	data  string
	valid bool
}

// check compiles schema (with optional remotes: URI -> document) and verifies
// each instance.
func check(t *testing.T, schema string, remotes map[string]string, cases []tc) {
	t.Helper()
	c := jsonschema.NewCompiler()
	for uri, doc := range remotes {
		c.AddResource(uri, parse(t, doc))
	}
	s, err := c.Compile(parse(t, schema))
	if err != nil {
		t.Fatalf("compile %s: %v", schema, err)
	}
	for _, cs := range cases {
		got, err := s.Validate(parse(t, cs.data))
		if err != nil {
			t.Errorf("schema %s, data %s: unexpected error %v", schema, cs.data, err)
			continue
		}
		if got != cs.valid {
			t.Errorf("schema %s, data %s: valid = %v, want %v", schema, cs.data, got, cs.valid)
		}
	}
}

func TestBooleanSchemas(t *testing.T) {
	check(t, `true`, nil, []tc{{`1`, true}, {`null`, true}})
	check(t, `false`, nil, []tc{{`1`, false}, {`{}`, false}})
	check(t, `{}`, nil, []tc{{`[1]`, true}})
}

func TestTypes(t *testing.T) {
	check(t, `{"type":"integer"}`, nil, []tc{{`1`, true}, {`1.0`, true}, {`1e2`, true}, {`1.5`, false}, {`"1"`, false}, {`true`, false}})
	check(t, `{"type":"number"}`, nil, []tc{{`1`, true}, {`1.5`, true}, {`true`, false}, {`null`, false}})
	check(t, `{"type":["string","null"]}`, nil, []tc{{`"a"`, true}, {`null`, true}, {`1`, false}})
	check(t, `{"type":"nonsense"}`, nil, []tc{{`1`, false}})
}

func TestEnumConstAreTypeAwareAndExact(t *testing.T) {
	check(t, `{"enum":[1,"1",null,[1],{"a":1}]}`, nil, []tc{
		{`1`, true}, {`1.0`, true}, {`{"a":1.000}`, true}, {`true`, false}, {`false`, false}, {`[2]`, false}, {`"1"`, true},
	})
	check(t, `{"const":{"a":[1,2],"b":null}}`, nil, []tc{
		{`{"b":null,"a":[1.0,2]}`, true}, {`{"a":[2,1],"b":null}`, false},
	})
	check(t, `{"const":0}`, nil, []tc{{`false`, false}, {`-0`, true}, {`0.0`, true}})
}

func TestNumericKeywordsAreExact(t *testing.T) {
	check(t, `{"multipleOf":0.0001}`, nil, []tc{{`0.3`, true}, {`0.0021`, true}, {`0.00751`, false}, {`0`, true}, {`"x"`, true}})
	check(t, `{"maximum":1e308}`, nil, []tc{{`1e308`, true}, {`1e309`, false}, {`1.0000000000000001e308`, false}})
	check(t, `{"minimum":-2,"exclusiveMaximum":3}`, nil, []tc{{`-2`, true}, {`-3`, false}, {`2.999999999999999999`, true}, {`3`, false}})
	check(t, `{"exclusiveMinimum":0.1}`, nil, []tc{{`0.1`, false}, {`0.1000000000000000000001`, true}})
	check(t, `{"minimum":9007199254740993}`, nil, []tc{{`9007199254740992`, false}, {`9007199254740993`, true}})
}

func TestStringKeywords(t *testing.T) {
	check(t, `{"minLength":2,"maxLength":3}`, nil, []tc{
		{`"💩"`, false}, {`"💩💩"`, true}, {`"\u0065\u0301"`, true}, {`"\u00e9"`, false}, {`"abcd"`, false}, {`5`, true},
	})
	check(t, `{"minLength":2.0,"maxLength":3e0}`, nil, []tc{{`"ab"`, true}, {`"a"`, false}})
	check(t, `{"pattern":"bar"}`, nil, []tc{{`"foobarbaz"`, true}, {`"foo"`, false}, {`1`, true}})
	check(t, `{"pattern":"^a$"}`, nil, []tc{{`"a"`, true}, {`"a\n"`, false}})
	check(t, `{"format":"ipv4","type":"string"}`, nil, []tc{{`"nope"`, true}})
}

func TestArrayKeywords(t *testing.T) {
	check(t, `{"minItems":1,"maxItems":2}`, nil, []tc{{`[]`, false}, {`[1]`, true}, {`[1,2,3]`, false}, {`"abc"`, true}})
	check(t, `{"uniqueItems":true}`, nil, []tc{
		{`[1,2,3]`, true}, {`[1,1.0]`, false}, {`[{"a":1,"b":2},{"b":2,"a":1}]`, false},
		{`[true,1]`, true}, {`[0,false]`, true}, {`[[1],[1.0]]`, false},
		{`[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,2.0]`, false},
		{`[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]`, true},
	})
	check(t, `{"uniqueItems":false}`, nil, []tc{{`[1,1]`, true}})
	check(t, `{"prefixItems":[{"type":"integer"},{"type":"string"}],"items":{"type":"boolean"}}`, nil, []tc{
		{`[1,"a",true]`, true}, {`[1,"a",1]`, false}, {`[1]`, true}, {`["x"]`, false}, {`[]`, true},
	})
	check(t, `{"items":{"type":"integer"}}`, nil, []tc{{`[1,2]`, true}, {`[1,"a"]`, false}})
}

func TestContains(t *testing.T) {
	s := `{"type":"array","contains":{"type":"integer"},"minContains":2,"maxContains":3}`
	check(t, s, nil, []tc{{`[1,"a",2]`, true}, {`["a",1,2,3,"b"]`, true}, {`[1,"a"]`, false}, {`[1,2,3,4]`, false}})
	check(t, `{"contains":{"const":1}}`, nil, []tc{{`[0,1]`, true}, {`[0]`, false}, {`[]`, false}})
	check(t, `{"contains":{"const":1},"minContains":0}`, nil, []tc{{`[]`, true}, {`[2]`, true}})
	check(t, `{"contains":{"const":1},"minContains":0,"maxContains":1}`, nil, []tc{{`[1,1]`, false}, {`[1]`, true}})
	check(t, `{"minContains":2,"maxContains":3}`, nil, []tc{{`[1]`, true}})
}

func TestObjectKeywords(t *testing.T) {
	check(t, `{"required":["a","b"]}`, nil, []tc{{`{"a":1,"b":2}`, true}, {`{"a":1}`, false}, {`[]`, true}})
	check(t, `{"minProperties":1,"maxProperties":2}`, nil, []tc{{`{}`, false}, {`{"a":1}`, true}, {`{"a":1,"b":2,"c":3}`, false}})
	check(t, `{"dependentRequired":{"a":["b"]}}`, nil, []tc{{`{"a":1,"b":2}`, true}, {`{"a":1}`, false}, {`{"b":1}`, true}})
	check(t, `{"dependentSchemas":{"a":{"required":["b"]}}}`, nil, []tc{{`{"a":1}`, false}, {`{"a":1,"b":1}`, true}, {`{}`, true}})
	check(t, `{"properties":{"a":{"type":"integer"}},"patternProperties":{"^x":{"type":"string"},"y$":{"minLength":2}},"additionalProperties":false}`, nil, []tc{
		{`{"a":1,"xa":"s","b":1}`, false}, {`{"a":1,"xa":"s"}`, true}, {`{"xy":"st"}`, true}, {`{"xy":"s"}`, false},
		{`{"xy":"a"}`, false}, {`{"xy":5}`, false}, {`{"a":"1"}`, false},
	})
	check(t, `{"propertyNames":{"maxLength":2}}`, nil, []tc{{`{"ab":1}`, true}, {`{"abc":1}`, false}, {`{}`, true}})
}

func TestApplicators(t *testing.T) {
	check(t, `{"allOf":[{"type":"integer"},{"minimum":3}]}`, nil, []tc{{`3`, true}, {`2`, false}, {`"a"`, false}})
	check(t, `{"anyOf":[{"type":"integer"},{"minimum":3}]}`, nil, []tc{{`1`, true}, {`4.5`, true}, {`2.5`, false}})
	check(t, `{"oneOf":[{"type":"integer"},{"minimum":3}]}`, nil, []tc{{`1`, true}, {`4.5`, true}, {`4`, false}, {`2.5`, false}})
	check(t, `{"not":{"type":"string"}}`, nil, []tc{{`1`, true}, {`"a"`, false}})
	s := `{"if":{"properties":{"k":{"const":1}},"required":["k"]},"then":{"required":["a"]},"else":{"required":["b"]}}`
	check(t, s, nil, []tc{{`{"k":1,"a":1}`, true}, {`{"k":1}`, false}, {`{"k":2,"b":1}`, true}, {`{"k":2}`, false}})
	check(t, `{"then":false,"else":false}`, nil, []tc{{`1`, true}})
	check(t, `{"if":false}`, nil, []tc{{`1`, true}})
}

func TestUnevaluatedProperties(t *testing.T) {
	s := `{"allOf":[{"properties":{"a":{"type":"integer"}}},{"properties":{"b":{"type":"integer"}}}],
	      "if":{"required":["a"]},"then":{"properties":{"c":{"type":"string"}}},
	      "unevaluatedProperties":false}`
	check(t, s, nil, []tc{{`{"a":1,"b":2}`, true}, {`{"a":1,"c":"yes"}`, true}, {`{"b":2,"c":"yes"}`, false}, {`{"a":1,"d":0}`, false}})
	check(t, `{"anyOf":[{"properties":{"a":true}},{"properties":{"b":true},"required":["b"]}],"unevaluatedProperties":false}`, nil, []tc{
		{`{"a":1}`, true}, {`{"b":1}`, true}, {`{"a":1,"b":1}`, true}, {`{"c":1}`, false}})
	// Annotations of a rejected branch do not escape.
	check(t, `{"anyOf":[{"properties":{"a":true},"required":["z"]},{"required":["q"]}],"unevaluatedProperties":false}`, nil, []tc{
		{`{"a":1,"q":1}`, false}})
	check(t, `{"not":{"not":{"properties":{"a":true}}},"unevaluatedProperties":false}`, nil, []tc{{`{"a":1}`, false}, {`{}`, true}})
	check(t, `{"properties":{"a":true},"unevaluatedProperties":{"type":"string"}}`, nil, []tc{
		{`{"a":1,"b":"x"}`, true}, {`{"a":1,"b":2}`, false}})
	// Nested unevaluatedProperties contribute to the outer one.
	check(t, `{"allOf":[{"unevaluatedProperties":true}],"unevaluatedProperties":false}`, nil, []tc{{`{"x":1}`, true}})
	check(t, `{"patternProperties":{"^x":true},"dependentSchemas":{"y":{"properties":{"z":true}}},"unevaluatedProperties":false}`, nil, []tc{
		{`{"xa":1}`, true}, {`{"y":1,"z":1}`, false}, {`{"xa":1,"q":1}`, false}})
}

func TestUnevaluatedItems(t *testing.T) {
	check(t, `{"prefixItems":[{"type":"string"}],"unevaluatedItems":false}`, nil, []tc{{`["a"]`, true}, {`["a",1]`, false}, {`[]`, true}})
	check(t, `{"contains":{"type":"string"},"unevaluatedItems":false}`, nil, []tc{{`["a","b"]`, true}, {`["a",1]`, false}})
	check(t, `{"allOf":[{"prefixItems":[true]}],"unevaluatedItems":{"type":"integer"}}`, nil, []tc{{`["x",1,2]`, true}, {`["x","y"]`, false}})
	check(t, `{"items":true,"unevaluatedItems":false}`, nil, []tc{{`[1,2,3]`, true}})
	check(t, `{"oneOf":[{"prefixItems":[true,true]},{"prefixItems":[true],"minItems":5}],"unevaluatedItems":false}`, nil, []tc{
		{`[1,2]`, true}, {`[1,2,3]`, false}})
}

func TestReferencesAndAnchors(t *testing.T) {
	check(t, `{"$defs":{"pos":{"type":"integer","minimum":1}},"properties":{"n":{"$ref":"#/$defs/pos"}}}`, nil,
		[]tc{{`{"n":1}`, true}, {`{"n":0}`, false}})
	check(t, `{"$ref":"#/$defs/a~1b","$defs":{"a/b":{"type":"string"}}}`, nil, []tc{{`"x"`, true}, {`1`, false}})
	check(t, `{"$ref":"#/$defs/c%25d","$defs":{"c%d":{"type":"string"}}}`, nil, []tc{{`"x"`, true}, {`1`, false}})
	check(t, `{"$ref":"#foo","$defs":{"f":{"$anchor":"foo","type":"string"}}}`, nil, []tc{{`"x"`, true}, {`1`, false}})
	check(t, `{"type":"object","properties":{"x":{"$ref":"#"}}}`, nil, []tc{{`{"x":{"x":{}}}`, true}, {`{"x":1}`, false}})
	// siblings of $ref are evaluated too
	check(t, `{"$ref":"#/$defs/a","maximum":5,"$defs":{"a":{"minimum":1}}}`, nil, []tc{{`3`, true}, {`7`, false}, {`0`, false}})
	// $id changes the base for nested refs
	check(t, `{"$id":"http://x.test/root","properties":{"a":{"$id":"sub/","$ref":"item.json"}}}`,
		map[string]string{"http://x.test/sub/item.json": `{"type":"integer"}`},
		[]tc{{`{"a":1}`, true}, {`{"a":"s"}`, false}})
	// ids and anchors that sit inside data are not identifiers
	check(t, `{"const":{"$id":"http://nope/","$anchor":"zz"},"$ref":"#/$defs/ok","$defs":{"ok":true}}`, nil, []tc{{`{"$id":"http://nope/","$anchor":"zz"}`, true}})
	// an unknown keyword hides its subschemas
	check(t, `{"$ref":"#/foo/bar","foo":{"bar":{"type":"string"}},"$defs":{}}`, nil, nil)
}

func TestWorkedExampleRelativeRemotes(t *testing.T) {
	schema := `{"$id":"http://localhost:1234/draft2020-12/root-of-its-own.json","type":"object",
	  "properties":{"i":{"$ref":"integer.json"},"n":{"$ref":"subSchemas.json#/$defs/integer"}}}`
	remotes := map[string]string{
		"http://localhost:1234/draft2020-12/integer.json":    `{"type":"integer"}`,
		"http://localhost:1234/draft2020-12/subSchemas.json": `{"$defs":{"integer":{"type":"integer"}}}`,
	}
	check(t, schema, remotes, []tc{{`{"i":1,"n":2}`, true}, {`{"i":"1"}`, false}, {`{"n":"x"}`, false}})
}

func TestDynamicRef(t *testing.T) {
	schema := `{
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
	  "$ref": "https://example.test/list"
	}`
	check(t, schema, nil, []tc{{`["a","b"]`, true}, {`["a",1]`, false}, {`[]`, true}})

	// Referenced on its own, the generic list has no outer override.
	check(t, `{"$id":"https://example.test/list2","$ref":"https://example.test/list",
	  "$defs":{"x":{"$id":"https://example.test/list","$defs":{"itemType":{"$dynamicAnchor":"itemType"}},
	  "type":"array","items":{"$dynamicRef":"#itemType"}}}}`, nil, []tc{{`["a",1]`, true}})

	// A plain $anchor of the same name wins over the $dynamicAnchor.
	check(t, `{"$id":"https://example.test/a","$ref":"#t",
	  "$defs":{"d":{"$dynamicAnchor":"t","type":"string"},"p":{"$anchor":"t","type":"integer"}}}`, nil,
		[]tc{{`1`, true}, {`"s"`, false}})

	// $dynamicRef whose name is not a dynamic anchor behaves like $ref.
	check(t, `{"$dynamicRef":"#/$defs/s","$defs":{"s":{"type":"string"}}}`, nil, []tc{{`"a"`, true}, {`1`, false}})
	check(t, `{"$dynamicRef":"#s","$defs":{"s":{"$anchor":"s","type":"string"}}}`, nil, []tc{{`"a"`, true}, {`1`, false}})
}

func TestRecursiveMetaStyleSchema(t *testing.T) {
	// A tree schema in the style of the 2020-12 meta-schema.
	schema := `{"$id":"https://t.test/tree","$dynamicAnchor":"node","type":"object",
	  "properties":{"children":{"type":"array","items":{"$dynamicRef":"#node"}},"v":{"type":"integer"}}}`
	check(t, schema, nil, []tc{
		{`{"v":1,"children":[{"v":2,"children":[{"v":3}]}]}`, true},
		{`{"children":[{"children":[{"v":"x"}]}]}`, false},
	})
}

func TestDeepNesting(t *testing.T) {
	schema := `{"$id":"https://d.test/","$ref":"#/$defs/n","$defs":{"n":{"type":["array","integer"],"items":{"$ref":"#/$defs/n"}}}}`
	depth := 3000
	data := ""
	for i := 0; i < depth; i++ {
		data += "["
	}
	data += "1"
	for i := 0; i < depth; i++ {
		data += "]"
	}
	check(t, schema, nil, []tc{{data, true}, {data + "", true}})
}

func TestErrors(t *testing.T) {
	s, err := jsonschema.CompileJSON([]byte(`{"properties":{"a":{"$ref":"nowhere.json"}}}`))
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := s.ValidateJSON([]byte(`{}`)); !ok || err != nil {
		t.Errorf("unreachable bad ref must not matter: %v %v", ok, err)
	}
	if ok, err := s.ValidateJSON([]byte(`{"a":1}`)); ok || err == nil {
		t.Errorf("reached bad ref: ok=%v err=%v", ok, err)
	}

	s, _ = jsonschema.CompileJSON([]byte(`{"pattern":"("}`))
	if ok, err := s.ValidateJSON([]byte(`"x"`)); ok || err == nil {
		t.Errorf("bad pattern: ok=%v err=%v", ok, err)
	}
	if ok, err := s.ValidateJSON([]byte(`1`)); !ok || err != nil {
		t.Errorf("bad pattern is inert for numbers: %v %v", ok, err)
	}

	s, _ = jsonschema.CompileJSON([]byte(`{"$ref":"#"}`))
	if ok, err := s.ValidateJSON([]byte(`1`)); ok || err == nil {
		t.Errorf("reference cycle: ok=%v err=%v", ok, err)
	}

	if _, err := jsonschema.CompileJSON([]byte(`{`)); err == nil {
		t.Error("malformed schema JSON accepted")
	}
	if _, err := jsonschema.CompileJSON([]byte(`3`)); err == nil {
		t.Error("non-schema accepted")
	}
	if _, err := s.ValidateJSON([]byte(`[`)); err == nil {
		t.Error("malformed instance JSON accepted")
	}
}

func TestSchemaIsSafeForConcurrentUse(t *testing.T) {
	s, err := jsonschema.CompileJSON([]byte(`{"$defs":{"i":{"type":"integer"}},"items":{"$ref":"#/$defs/i"},"unevaluatedItems":false}`))
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				if ok, _ := s.ValidateJSON([]byte(`[1,2,3]`)); !ok {
					t.Error("expected valid")
				}
				if ok, _ := s.ValidateJSON([]byte(`[1,"x"]`)); ok {
					t.Error("expected invalid")
				}
			}
		}()
	}
	wg.Wait()
}

func TestCompilerReuseKeepsResourcesIndependent(t *testing.T) {
	c := jsonschema.NewCompiler()
	c.AddResource("http://r.test/int", parse(t, `{"type":"integer"}`))
	a, err := c.Compile(parse(t, `{"$ref":"http://r.test/int"}`))
	if err != nil {
		t.Fatal(err)
	}
	b, err := c.Compile(parse(t, `{"type":"string"}`))
	if err != nil {
		t.Fatal(err)
	}
	if ok, _ := a.Validate(parse(t, `1`)); !ok {
		t.Error("a should accept 1")
	}
	if ok, _ := b.Validate(parse(t, `1`)); ok {
		t.Error("b should reject 1")
	}
}
