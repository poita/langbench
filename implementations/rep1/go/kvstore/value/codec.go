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

// Serialize returns the stored byte form of v.
func Serialize(v Value) []byte { return AppendSerialized(nil, v) }

// AppendSerialized appends the stored byte form of v to dst.
func AppendSerialized(dst []byte, v Value) []byte {
	switch v.Kind {
	case Null:
		return append(dst, tagNull)
	case Bool:
		if v.Bool {
			return append(dst, tagTrue)
		}
		return append(dst, tagFalse)
	case Int:
		dst = append(dst, tagInt)
		return binary.BigEndian.AppendUint64(dst, uint64(v.Int))
	case String:
		dst = append(dst, tagString)
		dst = binary.BigEndian.AppendUint32(dst, uint32(len(v.Str)))
		return append(dst, v.Str...)
	case List:
		dst = append(dst, tagList)
		dst = binary.BigEndian.AppendUint32(dst, uint32(len(v.List)))
		for _, e := range v.List {
			dst = AppendSerialized(dst, e)
		}
		return dst
	default:
		dst = append(dst, tagObject)
		dst = binary.BigEndian.AppendUint32(dst, uint32(len(v.Fields)))
		for _, f := range v.Fields {
			dst = binary.BigEndian.AppendUint32(dst, uint32(len(f.Name)))
			dst = append(dst, f.Name...)
			dst = AppendSerialized(dst, f.Value)
		}
		return dst
	}
}

// ErrMalformed is returned by Deserialize for ill-formed input.
var ErrMalformed = errors.New("value: malformed serialised document")

// Deserialize decodes a document produced by Serialize. The whole of b must
// be consumed.
func Deserialize(b []byte) (Value, error) {
	v, rest, err := deserialize(b, 0)
	if err != nil {
		return Value{}, err
	}
	if len(rest) != 0 {
		return Value{}, ErrMalformed
	}
	return v, nil
}

func deserialize(b []byte, depth int) (Value, []byte, error) {
	if len(b) == 0 || depth > 64 {
		return Value{}, nil, ErrMalformed
	}
	tag, b := b[0], b[1:]
	switch tag {
	case tagNull:
		return NewNull(), b, nil
	case tagFalse:
		return NewBool(false), b, nil
	case tagTrue:
		return NewBool(true), b, nil
	case tagInt:
		if len(b) < 8 {
			return Value{}, nil, ErrMalformed
		}
		return NewInt(int64(binary.BigEndian.Uint64(b))), b[8:], nil
	case tagString:
		s, rest, err := readBytes(b)
		if err != nil {
			return Value{}, nil, err
		}
		return NewString(string(s)), rest, nil
	case tagList:
		if len(b) < 4 {
			return Value{}, nil, ErrMalformed
		}
		n := int(binary.BigEndian.Uint32(b))
		b = b[4:]
		if n > len(b) {
			return Value{}, nil, ErrMalformed
		}
		elems := make([]Value, n)
		for i := range elems {
			var err error
			elems[i], b, err = deserialize(b, depth+1)
			if err != nil {
				return Value{}, nil, err
			}
		}
		return NewList(elems), b, nil
	case tagObject:
		if len(b) < 4 {
			return Value{}, nil, ErrMalformed
		}
		n := int(binary.BigEndian.Uint32(b))
		b = b[4:]
		if n > len(b) {
			return Value{}, nil, ErrMalformed
		}
		fields := make([]Field, n)
		for i := range fields {
			name, rest, err := readBytes(b)
			if err != nil {
				return Value{}, nil, err
			}
			fields[i].Name = string(name)
			fields[i].Value, b, err = deserialize(rest, depth+1)
			if err != nil {
				return Value{}, nil, err
			}
		}
		return Value{Kind: Object, Fields: fields}, b, nil
	}
	return Value{}, nil, ErrMalformed
}

// readBytes reads a 4-byte length followed by that many bytes.
func readBytes(b []byte) (data, rest []byte, err error) {
	if len(b) < 4 {
		return nil, nil, ErrMalformed
	}
	n := int(binary.BigEndian.Uint32(b))
	b = b[4:]
	if n > len(b) {
		return nil, nil, ErrMalformed
	}
	return b[:n], b[n:], nil
}
