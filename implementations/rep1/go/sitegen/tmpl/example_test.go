package tmpl_test

import (
	"errors"
	"fmt"

	"example.com/sitegen/tmpl"
)

func ExampleSet_Render() {
	set := tmpl.NewSet()
	set.Add("base.html", "<title>{% block title %}Site{% endblock %}</title>")
	set.Add("page.html", `{% extends "base.html" %}{% block title %}{{ name|upper }} - {{ super() }}{% endblock %}`)

	out, err := set.Render("page.html", map[string]tmpl.Value{"name": "home"})
	fmt.Println(out, err)
	// Output: <title>HOME - Site</title> <nil>
}

func ExampleError() {
	set := tmpl.NewSet()
	set.Add("t", "{{ missing }}")
	_, err := set.Render("t", nil)

	var terr *tmpl.Error
	if errors.As(err, &terr) {
		fmt.Println(terr.Kind)
	}
	// Output: undefined
}

func ExampleDict() {
	user := tmpl.NewDict(2)
	user.Set("name", "Ada")
	user.Set("langs", []tmpl.Value{"go", "c"})

	set := tmpl.NewSet()
	set.Add("t", `{{ user.name }}: {{ user.langs|join(", ") }}`)
	out, _ := set.Render("t", map[string]tmpl.Value{"user": user})
	fmt.Println(out)
	// Output: Ada: go, c
}
