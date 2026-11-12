package value

import (
	"encoding/binary"
	"errors"
)

// Serialisation tags.
const (
	tagNull   = 0x00
	tagFalse  = 0x01
	tagTrue   = 0x02
	tagInt    = 0x03
	tagString = 0x04
	tagList   = 0x05
	tagObject = 0x06
)

// AppendSerialized appends the stored form of v to dst and returns the
// extended slice.
func AppendSerialized(dst []byte, v Value) []byte {
	switch v.Kind {
	case Null:
		return append(dst, tagNull)
	case Bool:
		if v.I != 0 {
			return append(dst, tagTrue)
		}
		return append(dst, tagFalse)
	case Int:
		dst = append(dst, tagInt)
		return binary.BigEndian.AppendUint64(dst, uint64(v.I))
	case String:
		dst = append(dst, tagString)
		dst = binary.BigEndian.AppendUint32(dst, uint32(len(v.S)))
		return append(dst, v.S...)
	case List:
		dst = append(dst, tagList)
		dst = binary.BigEndian.AppendUint32(dst, uint32(len(v.Items)))
		for i := range v.Items {
			dst = AppendSerialized(dst, v.Items[i])
		}
		return dst
	case Object:
		dst = append(dst, tagObject)
		dst = binary.BigEndian.AppendUint32(dst, uint32(len(v.Fields)))
		for i := range v.Fields {
			f := &v.Fields[i]
			dst = binary.BigEndian.AppendUint32(dst, uint32(len(f.Name)))
			dst = append(dst, f.Name...)
			dst = AppendSerialized(dst, f.Val)
		}
		return dst
	}
	return dst
}

// Serialize returns the stored form of v.
func Serialize(v Value) []byte { return AppendSerialized(nil, v) }

// SerializedLen returns len(Serialize(v)) without building the bytes.
func SerializedLen(v Value) int {
	switch v.Kind {
	case Null, Bool:
		return 1
	case Int:
		return 9
	case String:
		return 5 + len(v.S)
	case List:
		n := 5
		for i := range v.Items {
			n += SerializedLen(v.Items[i])
		}
		return n
	case Object:
		n := 5
		for i := range v.Fields {
			n += 4 + len(v.Fields[i].Name) + SerializedLen(v.Fields[i].Val)
		}
		return n
	}
	return 0
}

// ErrCorrupt is returned by Deserialize for malformed input.
var ErrCorrupt = errors.New("value: corrupt serialised document")

// Deserialize is the inverse of Serialize. The whole of b must be one value.
func Deserialize(b []byte) (Value, error) {
	v, rest, err := deserialize(b, 0)
	if err != nil {
		return Value{}, err
	}
	if len(rest) != 0 {
		return Value{}, ErrCorrupt
	}
	return v, nil
}

func deserialize(b []byte, depth int) (Value, []byte, error) {
	if len(b) == 0 || depth > 1000 {
		return Value{}, nil, ErrCorrupt
	}
	tag := b[0]
	b = b[1:]
	switch tag {
	case tagNull:
		return Value{}, b, nil
	case tagFalse:
		return BoolValue(false), b, nil
	case tagTrue:
		return BoolValue(true), b, nil
	case tagInt:
		if len(b) < 8 {
			return Value{}, nil, ErrCorrupt
		}
		return IntValue(int64(binary.BigEndian.Uint64(b))), b[8:], nil
	case tagString:
		if len(b) < 4 {
			return Value{}, nil, ErrCorrupt
		}
		n := uint64(binary.BigEndian.Uint32(b))
		b = b[4:]
		if uint64(len(b)) < n {
			return Value{}, nil, ErrCorrupt
		}
		return StringValue(string(b[:n])), b[n:], nil
	case tagList:
		if len(b) < 4 {
			return Value{}, nil, ErrCorrupt
		}
		n := binary.BigEndian.Uint32(b)
		b = b[4:]
		if uint64(n) > uint64(len(b)) {
			return Value{}, nil, ErrCorrupt
		}
		items := make([]Value, 0, n)
		for i := uint32(0); i < n; i++ {
			var it Value
			var err error
			it, b, err = deserialize(b, depth+1)
			if err != nil {
				return Value{}, nil, err
			}
			items = append(items, it)
		}
		return Value{Kind: List, Items: items}, b, nil
	case tagObject:
		if len(b) < 4 {
			return Value{}, nil, ErrCorrupt
		}
		n := binary.BigEndian.Uint32(b)
		b = b[4:]
		if uint64(n) > uint64(len(b)) {
			return Value{}, nil, ErrCorrupt
		}
		fs := make([]Field, 0, n)
		for i := uint32(0); i < n; i++ {
			if len(b) < 4 {
				return Value{}, nil, ErrCorrupt
			}
			l := uint64(binary.BigEndian.Uint32(b))
			b = b[4:]
			if uint64(len(b)) < l {
				return Value{}, nil, ErrCorrupt
			}
			name := string(b[:l])
			b = b[l:]
			var fv Value
			var err error
			fv, b, err = deserialize(b, depth+1)
			if err != nil {
				return Value{}, nil, err
			}
			fs = append(fs, Field{name, fv})
		}
		return Value{Kind: Object, Fields: fs}, b, nil
	}
	return Value{}, nil, ErrCorrupt
}

// AppendVKey appends the order-preserving, self-delimiting index encoding of a
// scalar value to dst. ok is false for lists and objects, which have no
// encoding.
func AppendVKey(dst []byte, v Value) (out []byte, ok bool) {
	switch v.Kind {
	case Null:
		return append(dst, 0x10), true
	case Bool:
		if v.I != 0 {
			return append(dst, 0x21), true
		}
		return append(dst, 0x20), true
	case Int:
		dst = append(dst, 0x30)
		return binary.BigEndian.AppendUint64(dst, uint64(v.I)^(1<<63)), true
	case String:
		dst = append(dst, 0x40)
		for i := 0; i < len(v.S); i++ {
			c := v.S[i]
			if c == 0 {
				dst = append(dst, 0x00, 0xFF)
			} else {
				dst = append(dst, c)
			}
		}
		return append(dst, 0x00, 0x00), true
	}
	return dst, false
}

// VKey returns the index encoding of a scalar value (nil, false for lists and
// objects).
func VKey(v Value) ([]byte, bool) { return AppendVKey(nil, v) }

// VKeyLen returns the length of VKey(v), or -1 for lists and objects.
func VKeyLen(v Value) int {
	switch v.Kind {
	case Null, Bool:
		return 1
	case Int:
		return 9
	case String:
		n := 3 + len(v.S)
		for i := 0; i < len(v.S); i++ {
			if v.S[i] == 0 {
				n++
			}
		}
		return n
	}
	return -1
}
