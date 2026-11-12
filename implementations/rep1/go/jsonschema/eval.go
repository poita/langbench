package jsonschema

import (
	"unicode/utf8"

	"example.com/jsonschema/jsonvalue"
)

// evaluator holds the per-validation state: the dynamic scope, the stack of
// base URIs entered while validating, outermost first.
type evaluator struct {
	s     *Schema
	scope []int32
}

// eval reports whether v satisfies n. When ann is non-nil and v is accepted,
// the evaluated items/properties of n are added to ann; when v is rejected
// ann may hold partial garbage, which every caller discards (callers that
// continue after a rejection pass a fresh annots).
func (e *evaluator) eval(n *node, v *jsonvalue.Value, ann *annots) bool {
	if n.isBool {
		return n.boolVal
	}
	pushed := len(e.scope) == 0 || e.scope[len(e.scope)-1] != n.base
	if pushed {
		e.scope = append(e.scope, n.base)
	}
	ok := e.evalObject(n, v, ann)
	if pushed {
		e.scope = e.scope[:len(e.scope)-1]
	}
	return ok
}

func (e *evaluator) evalObject(n *node, v *jsonvalue.Value, ann *annots) bool {
	// Within a schema object, unevaluated* see the annotations of everything
	// else, so collect them locally.
	target := ann
	var local annots
	hasUneval := n.unevalItems != nil || n.unevalProps != nil
	if hasUneval {
		target = &local
	}

	if !e.evalAnyType(n, v) {
		return false
	}
	switch v.Kind() {
	case jsonvalue.NumberKind:
		if !evalNumber(n, v) {
			return false
		}
	case jsonvalue.String:
		if !evalString(n, v) {
			return false
		}
	case jsonvalue.Array:
		if !e.evalArray(n, v, target) {
			return false
		}
	case jsonvalue.ObjectKind:
		if !e.evalProperties(n, v, target) {
			return false
		}
	}
	if !e.evalApplicators(n, v, target) {
		return false
	}

	if hasUneval {
		switch v.Kind() {
		case jsonvalue.Array:
			if n.unevalItems != nil && !e.evalUnevaluatedItems(n, v, &local) {
				return false
			}
		case jsonvalue.ObjectKind:
			if n.unevalProps != nil && !e.evalUnevaluatedProperties(n, v, &local) {
				return false
			}
		}
		if ann != nil {
			ann.merge(&local)
		}
	}
	return true
}

func (e *evaluator) evalAnyType(n *node, v *jsonvalue.Value) bool {
	if n.types != 0 {
		var m uint8
		switch v.Kind() {
		case jsonvalue.Null:
			m = tNull
		case jsonvalue.Bool:
			m = tBoolean
		case jsonvalue.ObjectKind:
			m = tObject
		case jsonvalue.Array:
			m = tArray
		case jsonvalue.String:
			m = tString
		case jsonvalue.NumberKind:
			m = tNumber
			if num, _ := v.Number(); num.IsInteger() {
				m |= tInteger
			}
		}
		if n.types&m == 0 {
			return false
		}
	}
	if n.hasConst && !jsonvalue.Equal(*v, n.constVal) {
		return false
	}
	if n.hasEnum {
		found := false
		for _, c := range n.enum {
			if jsonvalue.Equal(*v, c) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

func evalNumber(n *node, v *jsonvalue.Value) bool {
	num, _ := v.Number()
	if n.multipleOf != nil && !num.IsMultipleOf(*n.multipleOf) {
		return false
	}
	if n.maximum != nil && num.Cmp(*n.maximum) > 0 {
		return false
	}
	if n.minimum != nil && num.Cmp(*n.minimum) < 0 {
		return false
	}
	if n.exMaximum != nil && num.Cmp(*n.exMaximum) >= 0 {
		return false
	}
	if n.exMinimum != nil && num.Cmp(*n.exMinimum) <= 0 {
		return false
	}
	return true
}

func evalString(n *node, v *jsonvalue.Value) bool {
	s, _ := v.Str()
	if n.maxLength >= 0 || n.minLength >= 0 {
		l := utf8.RuneCountInString(s)
		if n.maxLength >= 0 && l > n.maxLength {
			return false
		}
		if n.minLength >= 0 && l < n.minLength {
			return false
		}
	}
	if n.pattern != nil && !n.pattern.MatchString(s) {
		return false
	}
	return true
}

func (e *evaluator) evalArray(n *node, v *jsonvalue.Value, target *annots) bool {
	arr, _ := v.Array()
	if n.maxItems >= 0 && len(arr) > n.maxItems {
		return false
	}
	if n.minItems >= 0 && len(arr) < n.minItems {
		return false
	}
	if n.uniqueItems && !uniqueItems(arr) {
		return false
	}
	prefix := len(n.prefixItems)
	if prefix > len(arr) {
		prefix = len(arr)
	}
	for i := 0; i < prefix; i++ {
		if !e.eval(n.prefixItems[i], &arr[i], nil) {
			return false
		}
	}
	if target != nil && prefix > 0 {
		target.markPrefix(prefix)
	}
	if n.items != nil {
		start := len(n.prefixItems)
		for i := start; i < len(arr); i++ {
			if !e.eval(n.items, &arr[i], nil) {
				return false
			}
		}
		if target != nil && start < len(arr) {
			target.markFrom(start)
		}
	}
	if n.contains != nil && !e.evalContains(n, arr, target) {
		return false
	}
	return true
}

func (e *evaluator) evalContains(n *node, arr []jsonvalue.Value, target *annots) bool {
	min, max := n.minContains, n.maxContains
	if min == 0 && target == nil {
		// Always satisfied, except that maxContains still bounds the count.
		if max < 0 {
			return true
		}
	}
	matches := 0
	for i := range arr {
		if e.eval(n.contains, &arr[i], nil) {
			matches++
			if target != nil {
				target.markIndex(i, len(arr))
			}
			if target == nil {
				if max >= 0 && matches > max {
					return false
				}
				if max < 0 && matches >= min {
					return true
				}
			}
		}
	}
	return matches >= min && (max < 0 || matches <= max)
}

// uniqueItems reports whether no two elements of arr are JSON-equal.
func uniqueItems(arr []jsonvalue.Value) bool {
	if len(arr) <= 8 {
		for i := 1; i < len(arr); i++ {
			for j := 0; j < i; j++ {
				if jsonvalue.Equal(arr[i], arr[j]) {
					return false
				}
			}
		}
		return true
	}
	seen := make(map[uint64][]int, len(arr))
	for i := range arr {
		h := arr[i].Hash()
		for _, j := range seen[h] {
			if jsonvalue.Equal(arr[i], arr[j]) {
				return false
			}
		}
		seen[h] = append(seen[h], i)
	}
	return true
}

func (e *evaluator) evalProperties(n *node, v *jsonvalue.Value, target *annots) bool {
	o, _ := v.Object()
	if n.maxProperties >= 0 && o.Len() > n.maxProperties {
		return false
	}
	if n.minProperties >= 0 && o.Len() < n.minProperties {
		return false
	}
	for _, name := range n.required {
		if !o.Has(name) {
			return false
		}
	}
	for _, d := range n.depRequired {
		if o.Has(d.name) {
			for _, name := range d.names {
				if !o.Has(name) {
					return false
				}
			}
		}
	}

	if len(n.patProps) == 0 && n.additional == nil {
		// Only "properties": look each declared property up directly.
		for _, p := range n.propList {
			val, ok := o.Get(p.name)
			if !ok {
				continue
			}
			if !e.eval(p.node, &val, nil) {
				return false
			}
			if target != nil {
				target.markProp(p.name)
			}
		}
	} else if len(n.propList) > 0 || len(n.patProps) > 0 || n.additional != nil {
		for i := 0; i < o.Len(); i++ {
			name, val := o.At(i)
			matched := false
			if p, ok := n.props[name]; ok {
				matched = true
				if !e.eval(p, &val, nil) {
					return false
				}
			}
			for _, pp := range n.patProps {
				if pp.re.MatchString(name) {
					matched = true
					if !e.eval(pp.node, &val, nil) {
						return false
					}
				}
			}
			if !matched && n.additional != nil {
				matched = true
				if !e.eval(n.additional, &val, nil) {
					return false
				}
			}
			if matched && target != nil {
				target.markProp(name)
			}
		}
	}

	if n.propertyNames != nil {
		for _, name := range o.Keys() {
			nv := jsonvalue.StringValue(name)
			if !e.eval(n.propertyNames, &nv, nil) {
				return false
			}
		}
	}
	for _, d := range n.depSchemas {
		if o.Has(d.name) && !e.eval(d.node, v, target) {
			return false
		}
	}
	return true
}

func (e *evaluator) evalApplicators(n *node, v *jsonvalue.Value, target *annots) bool {
	if n.ref != nil {
		if !e.evalRef(n.ref, v, target) {
			return false
		}
	}
	if n.dynRef != nil {
		if !e.evalRef(n.dynRef, v, target) {
			return false
		}
	}
	for _, s := range n.allOf {
		if !e.eval(s, v, target) {
			return false
		}
	}
	if len(n.anyOf) > 0 && !e.evalAnyOf(n, v, target) {
		return false
	}
	if len(n.oneOf) > 0 && !e.evalOneOf(n, v, target) {
		return false
	}
	if n.not != nil && e.eval(n.not, v, nil) {
		return false
	}
	if n.ifNode != nil {
		var t annots
		var tp *annots
		if target != nil {
			tp = &t
		}
		if e.eval(n.ifNode, v, tp) {
			if target != nil {
				target.merge(&t)
			}
			if n.thenNode != nil && !e.eval(n.thenNode, v, target) {
				return false
			}
		} else if n.elseNode != nil && !e.eval(n.elseNode, v, target) {
			return false
		}
	}
	return true
}

func (e *evaluator) evalAnyOf(n *node, v *jsonvalue.Value, target *annots) bool {
	any := false
	for _, s := range n.anyOf {
		if target == nil {
			if e.eval(s, v, nil) {
				return true
			}
			continue
		}
		var t annots
		if e.eval(s, v, &t) {
			any = true
			target.merge(&t)
		}
	}
	return any
}

func (e *evaluator) evalOneOf(n *node, v *jsonvalue.Value, target *annots) bool {
	matched := -1
	var kept annots
	for i, s := range n.oneOf {
		var t annots
		var tp *annots
		if target != nil {
			tp = &t
		}
		if e.eval(s, v, tp) {
			if matched >= 0 {
				return false
			}
			matched = i
			kept = t
		}
	}
	if matched < 0 {
		return false
	}
	if target != nil {
		target.merge(&kept)
	}
	return true
}

func (e *evaluator) evalRef(r *ref, v *jsonvalue.Value, target *annots) bool {
	t := r.target
	if t == nil {
		return false // unresolvable reference: nothing can satisfy it
	}
	if r.dynamic {
		// The outermost dynamic scope entry that declares this dynamic anchor wins.
		for _, b := range e.scope {
			if dt, ok := e.s.dynamic[anchorKey{b, r.name}]; ok {
				t = dt
				break
			}
		}
	}
	return e.eval(t, v, target)
}

func (e *evaluator) evalUnevaluatedItems(n *node, v *jsonvalue.Value, local *annots) bool {
	arr, _ := v.Array()
	applied := false
	for i := range arr {
		if local.itemEvaluated(i) {
			continue
		}
		applied = true
		if !e.eval(n.unevalItems, &arr[i], nil) {
			return false
		}
	}
	if applied {
		local.markFrom(0)
	}
	return true
}

func (e *evaluator) evalUnevaluatedProperties(n *node, v *jsonvalue.Value, local *annots) bool {
	o, _ := v.Object()
	var applied []string
	for i := 0; i < o.Len(); i++ {
		name, val := o.At(i)
		if local.propEvaluated(name) {
			continue
		}
		if !e.eval(n.unevalProps, &val, nil) {
			return false
		}
		applied = append(applied, name)
	}
	for _, name := range applied {
		local.markProp(name)
	}
	return true
}
