package template_test

import (
	"errors"
	"fmt"
	"testing"

	"example.com/template"
)

func TestEngineRender(t *testing.T) {
	eng := template.NewEngine(map[string]string{
		"main": `{% include "row" %}{{ items|join("+") }}`,
		"row":  "<{{ who|upper }}>",
	})
	ctx := template.ContextFromMap(map[string]any{"who": "ada", "items": []any{1, 2.5, "x"}})
	out, err := eng.Render("main", ctx)
	if err != nil || out != "<ADA>1+2.5+x" {
		t.Fatalf("Render = %q, %v", out, err)
	}
	// The engine can be reused and caches parsed templates.
	out, err = eng.Render("row", ctx)
	if err != nil || out != "<ADA>" {
		t.Fatalf("second Render = %q, %v", out, err)
	}
}

func TestEngineErrors(t *testing.T) {
	eng := template.NewEngine(map[string]string{"main": "{{ missing }}", "bad": "{% if %}"})
	for name, want := range map[string]template.ErrorKind{
		"main": template.ErrUndefined, "bad": template.ErrSyntax, "nope": template.ErrTemplate,
	} {
		out, err := eng.Render(name, nil)
		var te *template.Error
		if !errors.As(err, &te) || te.Kind != want || out != "" {
			t.Errorf("Render(%q) = %q, %v; want kind %s", name, out, err, want)
		}
	}
}

func TestFromGo(t *testing.T) {
	v := template.FromGo(map[string]any{"b": []string{"x"}, "a": 1, "c": nil, "d": 1.5, "e": true})
	got, err := template.Format(v)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{'a': 1, 'b': ['x'], 'c': None, 'd': 1.5, 'e': True}`; got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}

func ExampleEngine_Render() {
	eng := template.NewEngine(map[string]string{
		"main": "{% for p in people %}{{ loop.index }}. {{ p.name|upper }}\n{% endfor %}",
	})
	ctx, _ := template.ParseJSON([]byte(`{"people": [{"name": "ada"}, {"name": "bob"}]}`))
	out, _ := eng.Render("main", ctx.(*template.Dict))
	fmt.Print(out)
	// Output:
	// 1. ADA
	// 2. BOB
}

func ExampleProcess() {
	out, _ := template.Process([]byte("{\"n\": 2}\n--\n=== main\n{{ n * 21 }}\n"))
	fmt.Print(out)
	// Output: 42
}
