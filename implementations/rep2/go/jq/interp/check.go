package interp

import (
	"fmt"

	"example.com/jq/syntax"
)

// arity of each supported builtin.
var builtinArity = map[string]int{
	"empty": 0, "error": -1, "not": 0, "length": 0, "keys": 0, "has": 1,
	"type": 0, "add": 0, "select": 1, "map": 1, "sort": 0, "sort_by": 1,
	"group_by": 1, "unique": 0, "reverse": 0, "min": 0, "max": 0,
	"tostring": 0, "tonumber": 0,
}

// check verifies builtin names/arities and variable scoping. scope lists the
// variables currently bound.
func check(n syntax.Node, scope []string) error {
	var errs []error
	walk(n, scope, func(err error) { errs = append(errs, err) })
	if len(errs) > 0 {
		return errs[0]
	}
	return nil
}

func walk(n syntax.Node, scope []string, report func(error)) {
	w := func(c syntax.Node) {
		if c != nil {
			walk(c, scope, report)
		}
	}
	switch n := n.(type) {
	case *syntax.Var:
		for _, s := range scope {
			if s == n.Name {
				return
			}
		}
		report(fmt.Errorf("jq: $%s is not defined", n.Name))
	case *syntax.Index:
		w(n.Term)
		w(n.Key)
	case *syntax.Slice:
		w(n.Term)
		w(n.From)
		w(n.To)
	case *syntax.Iterate:
		w(n.Term)
	case *syntax.Try:
		w(n.Term)
	case *syntax.Pipe:
		w(n.L)
		w(n.R)
	case *syntax.Comma:
		w(n.L)
		w(n.R)
	case *syntax.Binary:
		w(n.L)
		w(n.R)
	case *syntax.And:
		w(n.L)
		w(n.R)
	case *syntax.Or:
		w(n.L)
		w(n.R)
	case *syntax.Neg:
		w(n.X)
	case *syntax.Array:
		w(n.Body)
	case *syntax.Object:
		for _, e := range n.Entries {
			w(e.Key)
			w(e.Val)
		}
	case *syntax.If:
		w(n.Cond)
		w(n.Then)
		w(n.Else)
	case *syntax.As:
		w(n.Source)
		walk(n.Body, append(scope[:len(scope):len(scope)], n.Name), report)
	case *syntax.Reduce:
		w(n.Source)
		w(n.Init)
		walk(n.Update, append(scope[:len(scope):len(scope)], n.Name), report)
	case *syntax.Call:
		want, ok := builtinArity[n.Name]
		if !ok {
			report(fmt.Errorf("jq: %s/%d is not defined", n.Name, len(n.Args)))
		} else if want >= 0 && want != len(n.Args) || want < 0 && len(n.Args) > 1 {
			report(fmt.Errorf("jq: %s/%d is not defined", n.Name, len(n.Args)))
		}
		for _, a := range n.Args {
			w(a)
		}
	}
}
