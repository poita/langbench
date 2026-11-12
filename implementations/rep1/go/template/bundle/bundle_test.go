package bundle

import (
	"reflect"
	"testing"
)

func TestParse(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  *Bundle
	}{
		{
			"single template drops one trailing LF",
			"{}\n--\n=== main\nHello\n",
			&Bundle{"{}\n", []Template{{"main", "Hello"}}},
		},
		{
			"no trailing LF",
			"{}\n--\n=== main\nHello",
			&Bundle{"{}\n", []Template{{"main", "Hello"}}},
		},
		{
			"several templates; empty line keeps a newline",
			"{\"a\":\n1}\n--\n=== a\nX\n\n=== b/c-d.e\nY\nZ\n=== c\n\n",
			&Bundle{"{\"a\":\n1}\n", []Template{{"a", "X\n"}, {"b/c-d.e", "Y\nZ"}, {"c", ""}}},
		},
		{
			"empty body",
			"{}\n--\n=== a\n\n=== b\n",
			&Bundle{"{}\n", []Template{{"a", ""}, {"b", ""}}},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Parse(tc.input)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestParseErrors(t *testing.T) {
	if _, err := Parse("{}\n=== main\nx"); err != ErrNoSeparator {
		t.Errorf("got %v, want ErrNoSeparator", err)
	}
	if _, err := Parse("{}\n--\nno header"); err != ErrNoTemplate {
		t.Errorf("got %v, want ErrNoTemplate", err)
	}
}
