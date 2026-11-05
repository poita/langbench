package template

import (
	"fmt"
	"sort"
)

// FromGo converts ordinary Go values to template Values: nil becomes None;
// bool, string, int/int8..int64/uint.., float32/float64 map to the matching
// kinds; []any and []string become lists; map[string]any becomes a dict with
// keys in sorted order (use NewDict for a specific order). Values that are
// already template Values (*List, *Dict) pass through. Other types cause a
// panic.
func FromGo(v any) Value {
	switch x := v.(type) {
	case nil:
		return None
	case bool, string, float64, int64, *List, *Dict, noneType:
		return x
	case int:
		return int64(x)
	case int8:
		return int64(x)
	case int16:
		return int64(x)
	case int32:
		return int64(x)
	case uint:
		return int64(x)
	case uint8:
		return int64(x)
	case uint16:
		return int64(x)
	case uint32:
		return int64(x)
	case uint64:
		return int64(x)
	case float32:
		return float64(x)
	case []any:
		items := make([]Value, len(x))
		for i, e := range x {
			items[i] = FromGo(e)
		}
		return &List{Items: items}
	case []string:
		items := make([]Value, len(x))
		for i, e := range x {
			items[i] = e
		}
		return &List{Items: items}
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		d := NewDict(len(keys))
		for _, k := range keys {
			d.Set(k, FromGo(x[k]))
		}
		return d
	}
	panic(fmt.Sprintf("template: cannot convert %T to a template value", v))
}

// ContextFromMap builds a context dict from a Go map (keys sorted).
func ContextFromMap(m map[string]any) *Dict {
	return FromGo(m).(*Dict)
}
