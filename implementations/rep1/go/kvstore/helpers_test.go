package tessera

import "example.com/tessera/value"

func mustDoc(i int) value.Value {
	return value.ObjectValue(
		value.Field{Name: "i", Val: value.IntValue(int64(i))},
		value.Field{Name: "pad", Val: value.StringValue("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")},
	)
}
