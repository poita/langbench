package protowire

import "errors"

// Limits from the wire format.
const (
	maxVarintLen = 10
	maxTagLen    = 5
	maxLenLen    = 5

	// MaxDepth is the deepest message nesting accepted when decoding or
	// parsing text.
	MaxDepth = 1000
)

// ErrDecode is wrapped by every error returned when decoding wire data.
var ErrDecode = errors.New("protowire: malformed wire data")

var (
	errTruncated   = errors.Join(ErrDecode, errors.New("truncated data"))
	errVarintLong  = errors.Join(ErrDecode, errors.New("varint too long"))
	errBadTag      = errors.Join(ErrDecode, errors.New("invalid tag"))
	errBadLength   = errors.Join(ErrDecode, errors.New("invalid length"))
	errBadGroup    = errors.Join(ErrDecode, errors.New("mismatched group"))
	errBadUTF8     = errors.Join(ErrDecode, errors.New("invalid UTF-8 in string"))
	errBadPacked   = errors.Join(ErrDecode, errors.New("malformed packed payload"))
	errTooDeep     = errors.Join(ErrDecode, errors.New("nesting too deep"))
	errUnknownWire = errors.Join(ErrDecode, errors.New("invalid wire type"))
)

// readVarint reads a varint of at most max bytes from b[pos:] and returns its
// value (modulo 2^64) and the position after it.
func readVarint(b []byte, pos, max int) (uint64, int, error) {
	var v uint64
	for i := 0; i < max; i++ {
		if pos+i >= len(b) {
			return 0, 0, errTruncated
		}
		c := b[pos+i]
		v |= uint64(c&0x7f) << (7 * uint(i))
		if c < 0x80 {
			return v, pos + i + 1, nil
		}
	}
	return 0, 0, errVarintLong
}

// readTag reads and validates a tag, returning field number and wire type.
func readTag(b []byte, pos int) (num uint32, wt uint64, next int, err error) {
	v, next, err := readVarint(b, pos, maxTagLen)
	if err != nil {
		return 0, 0, 0, err
	}
	if v>>32 != 0 || v>>3 == 0 {
		return 0, 0, 0, errBadTag
	}
	wt = v & 7
	if wt == 6 || wt == 7 {
		return 0, 0, 0, errUnknownWire
	}
	return uint32(v >> 3), wt, next, nil
}

// readLen reads a length prefix and checks it against the remaining bytes.
func readLen(b []byte, pos int) (n, next int, err error) {
	v, next, err := readVarint(b, pos, maxLenLen)
	if err != nil {
		return 0, 0, err
	}
	if v > uint64(len(b)-next) {
		return 0, 0, errBadLength
	}
	return int(v), next, nil
}

// skipPayload skips the payload of a field with wire type 0, 1, 2 or 5.
func skipPayload(b []byte, pos int, wt uint64) (int, error) {
	switch wt {
	case wireVarint:
		_, p, err := readVarint(b, pos, maxVarintLen)
		return p, err
	case wireFixed64:
		if len(b)-pos < 8 {
			return 0, errTruncated
		}
		return pos + 8, nil
	case wireFixed32:
		if len(b)-pos < 4 {
			return 0, errTruncated
		}
		return pos + 4, nil
	case wireBytes:
		n, p, err := readLen(b, pos)
		return p + n, err
	}
	return 0, errUnknownWire
}

// skipField skips a field whose tag (number num, wire type wt) has just been
// read; pos is the position after the tag. Groups are skipped iteratively.
func skipField(b []byte, pos int, num uint32, wt uint64) (int, error) {
	switch wt {
	case wireEndGrp:
		return 0, errBadGroup
	case wireStartGrp:
		stack := []uint32{num}
		for len(stack) > 0 {
			n, w, p, err := readTag(b, pos)
			if err != nil {
				return 0, err
			}
			pos = p
			switch w {
			case wireStartGrp:
				stack = append(stack, n)
			case wireEndGrp:
				if stack[len(stack)-1] != n {
					return 0, errBadGroup
				}
				stack = stack[:len(stack)-1]
			default:
				if pos, err = skipPayload(b, pos, w); err != nil {
					return 0, err
				}
			}
		}
		return pos, nil
	}
	return skipPayload(b, pos, wt)
}

func appendVarint(dst []byte, v uint64) []byte {
	for v >= 0x80 {
		dst = append(dst, byte(v)|0x80)
		v >>= 7
	}
	return append(dst, byte(v))
}

func varintLen(v uint64) int {
	n := 1
	for v >= 0x80 {
		v >>= 7
		n++
	}
	return n
}

func zigzag32(v int32) uint64 { return uint64(uint32((v << 1) ^ (v >> 31))) }
func zigzag64(v int64) uint64 { return uint64((v << 1) ^ (v >> 63)) }

func unzigzag32(u uint32) int32 { return int32(u>>1) ^ -int32(u&1) }
func unzigzag64(u uint64) int64 { return int64(u>>1) ^ -int64(u&1) }
