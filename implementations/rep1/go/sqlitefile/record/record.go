package record

import (
	"encoding/binary"
	"errors"
	"math"

	"sqlitefile/value"
)

// ErrCorrupt is returned for a record whose header is inconsistent.
var ErrCorrupt = errors.New("record: corrupt record")

// Record is a parsed record: the serial types from its header and the offset
// of each column's bytes in the body. Column values are decoded on demand.
type Record struct {
	data    []byte
	types   []uint64
	offsets []int // start of each column's bytes in data
}

// Parse reads the header of the record in data. The returned Record keeps a
// reference to data.
func Parse(data []byte) (*Record, error) {
	r := &Record{}
	return r, r.Reset(data)
}

// Reset re-parses r from data, reusing its storage.
func (r *Record) Reset(data []byte) error {
	hdr, n := Varint(data)
	if n == 0 || hdr < int64(n) || hdr > int64(len(data)) {
		return ErrCorrupt
	}
	r.data = data
	r.types = r.types[:0]
	r.offsets = r.offsets[:0]
	pos := n
	body := int(hdr)
	for pos < int(hdr) {
		t, m := Varint(data[pos:hdr])
		if m == 0 || t < 0 {
			return ErrCorrupt
		}
		pos += m
		size := SerialSize(uint64(t))
		if size < 0 {
			return ErrCorrupt
		}
		r.types = append(r.types, uint64(t))
		r.offsets = append(r.offsets, body)
		body += size
		if body > len(data) {
			return ErrCorrupt
		}
	}
	return nil
}

// Len is the number of values physically present in the record.
func (r *Record) Len() int { return len(r.types) }

// SerialType returns the serial type of column i.
func (r *Record) SerialType(i int) uint64 { return r.types[i] }

// SerialSize returns the body size in bytes of a value with the given serial
// type, or -1 for the unused types 10 and 11.
func SerialSize(t uint64) int {
	switch {
	case t <= 4:
		return int(t)
	case t == 5:
		return 6
	case t == 6 || t == 7:
		return 8
	case t == 8 || t == 9:
		return 0
	case t == 10 || t == 11:
		return -1
	}
	if t > math.MaxInt32*2 {
		return -1
	}
	return int((t - 12) / 2)
}

// Value decodes column i. Columns beyond the end of the record read as NULL.
func (r *Record) Value(i int) value.Value {
	if i < 0 || i >= len(r.types) {
		return value.NullValue
	}
	t := r.types[i]
	b := r.data[r.offsets[i]:]
	switch t {
	case 0:
		return value.NullValue
	case 1:
		return value.NewInt(int64(int8(b[0])))
	case 2:
		return value.NewInt(int64(int16(binary.BigEndian.Uint16(b))))
	case 3:
		v := int64(b[0])<<16 | int64(b[1])<<8 | int64(b[2])
		return value.NewInt(v << 40 >> 40)
	case 4:
		return value.NewInt(int64(int32(binary.BigEndian.Uint32(b))))
	case 5:
		v := int64(binary.BigEndian.Uint16(b))<<32 | int64(binary.BigEndian.Uint32(b[2:]))
		return value.NewInt(v << 16 >> 16)
	case 6:
		return value.NewInt(int64(binary.BigEndian.Uint64(b)))
	case 7:
		return value.NewReal(math.Float64frombits(binary.BigEndian.Uint64(b)))
	case 8:
		return value.NewInt(0)
	case 9:
		return value.NewInt(1)
	}
	size := int((t - 12) / 2)
	if t%2 == 0 {
		return value.NewBlob(b[:size])
	}
	return value.NewText(string(b[:size]))
}

// Encode builds the record encoding of vals. It is used by tests and tools
// that need to produce database content; the reader itself never writes.
func Encode(vals []value.Value) []byte {
	var types []byte
	var body []byte
	for _, v := range vals {
		switch v.Kind {
		case value.Null:
			types = PutVarint(types, 0)
		case value.Integer:
			switch {
			case v.Int == 0:
				types = PutVarint(types, 8)
			case v.Int == 1:
				types = PutVarint(types, 9)
			case v.Int >= math.MinInt8 && v.Int <= math.MaxInt8:
				types = PutVarint(types, 1)
				body = append(body, byte(v.Int))
			case v.Int >= math.MinInt16 && v.Int <= math.MaxInt16:
				types = PutVarint(types, 2)
				body = binary.BigEndian.AppendUint16(body, uint16(v.Int))
			case v.Int >= -(1<<23) && v.Int < 1<<23:
				types = PutVarint(types, 3)
				body = append(body, byte(v.Int>>16), byte(v.Int>>8), byte(v.Int))
			case v.Int >= math.MinInt32 && v.Int <= math.MaxInt32:
				types = PutVarint(types, 4)
				body = binary.BigEndian.AppendUint32(body, uint32(v.Int))
			case v.Int >= -(1<<47) && v.Int < 1<<47:
				types = PutVarint(types, 5)
				body = append(body, byte(v.Int>>40), byte(v.Int>>32), byte(v.Int>>24), byte(v.Int>>16), byte(v.Int>>8), byte(v.Int))
			default:
				types = PutVarint(types, 6)
				body = binary.BigEndian.AppendUint64(body, uint64(v.Int))
			}
		case value.Real:
			types = PutVarint(types, 7)
			body = binary.BigEndian.AppendUint64(body, math.Float64bits(v.Real))
		case value.Text:
			types = PutVarint(types, int64(len(v.Str))*2+13)
			body = append(body, v.Str...)
		case value.Blob:
			types = PutVarint(types, int64(len(v.Str))*2+12)
			body = append(body, v.Str...)
		}
	}
	hdr := len(types) + 1
	if hdr > 127 { // header-size varint needs two bytes
		hdr = len(types) + 2
	}
	out := PutVarint(nil, int64(hdr))
	out = append(out, types...)
	return append(out, body...)
}
