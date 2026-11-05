package gitrepo

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

// pack is one loaded .idx/.pack pair, held entirely in memory.
type pack struct {
	name   string
	idx    []byte
	data   []byte
	n      int // number of objects
	fanout [256]uint32
	idsOff int // offset of the sorted id table in idx
	offOff int // offset of the 32-bit offset table
	bigOff int // offset of the 64-bit offset table
}

// parsePack validates the headers of an index/pack pair.
func parsePack(name string, idx, data []byte) (*pack, error) {
	if len(idx) < 8+1024+40 || !bytes.Equal(idx[:4], []byte{0xff, 't', 'O', 'c'}) ||
		binary.BigEndian.Uint32(idx[4:]) != 2 {
		return nil, fmt.Errorf("%w: bad pack index %s", ErrDamaged, name)
	}
	p := &pack{name: name, idx: idx, data: data}
	for i := range p.fanout {
		p.fanout[i] = binary.BigEndian.Uint32(idx[8+4*i:])
		if i > 0 && p.fanout[i] < p.fanout[i-1] {
			return nil, fmt.Errorf("%w: bad fanout in %s", ErrDamaged, name)
		}
	}
	n := int(p.fanout[255])
	p.n = n
	p.idsOff = 8 + 1024
	p.offOff = p.idsOff + 24*n // ids, then CRCs
	p.bigOff = p.offOff + 4*n
	if len(idx) < p.bigOff+40 {
		return nil, fmt.Errorf("%w: truncated pack index %s", ErrDamaged, name)
	}
	if len(data) < 12+20 || !bytes.Equal(data[:4], []byte("PACK")) ||
		binary.BigEndian.Uint32(data[4:]) != 2 {
		return nil, fmt.Errorf("%w: bad packfile %s", ErrDamaged, name)
	}
	return p, nil
}

func (p *pack) idAt(i int) []byte { return p.idx[p.idsOff+20*i : p.idsOff+20*i+20] }

// find returns the position of id in the index.
func (p *pack) find(id *ID) (int, bool) {
	b := id[0]
	lo, hi := 0, int(p.fanout[b])
	if b > 0 {
		lo = int(p.fanout[b-1])
	}
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		switch bytes.Compare(p.idAt(mid), id[:]) {
		case 0:
			return mid, true
		case -1:
			lo = mid + 1
		default:
			hi = mid
		}
	}
	return 0, false
}

// offset returns the packfile offset of the i-th indexed object.
func (p *pack) offset(i int) (int, bool) {
	v := binary.BigEndian.Uint32(p.idx[p.offOff+4*i:])
	if v&0x80000000 == 0 {
		return int(v), true
	}
	j := int(v & 0x7fffffff)
	pos := p.bigOff + 8*j
	if pos+8 > len(p.idx)-40 {
		return 0, false
	}
	o := binary.BigEndian.Uint64(p.idx[pos:])
	if o > uint64(len(p.data)) {
		return 0, false
	}
	return int(o), true
}

// packKey identifies a packed object for the reconstruction cache.
type packKey struct {
	pack *pack
	off  int
}

var packTypes = [5]ObjectType{0, TypeCommit, TypeTree, TypeBlob, TypeTag}

// maxDeltaDepth bounds delta recursion (git's own limit is 50; the margin
// protects against malicious cycles).
const maxDeltaDepth = 4096

// readPacked reconstructs the object at off in p, memoising every result.
func (r *Repository) readPacked(p *pack, off int, depth int) (*rawObject, error) {
	key := packKey{p, off}
	if o, ok := r.packCache[key]; ok {
		if o == nil {
			return nil, fmt.Errorf("%w: unreadable packed object at %d in %s", ErrDamaged, off, p.name)
		}
		return o, nil
	}
	// Mark in progress so reference cycles terminate as failures.
	r.packCache[key] = nil
	o, err := r.decodePacked(p, off, depth)
	if err != nil {
		return nil, err
	}
	r.packCache[key] = o
	return o, nil
}

func (r *Repository) decodePacked(p *pack, off int, depth int) (*rawObject, error) {
	if depth > maxDeltaDepth {
		return nil, fmt.Errorf("%w: delta chain too deep", ErrDamaged)
	}
	data := p.data
	if off < 12 || off >= len(data)-20 {
		return nil, fmt.Errorf("%w: bad pack offset %d", ErrDamaged, off)
	}
	pos := off
	c := data[pos]
	pos++
	typ := (c >> 4) & 7
	size := uint64(c & 15)
	shift := uint(4)
	for c&0x80 != 0 {
		if pos >= len(data) || shift > 56 {
			return nil, fmt.Errorf("%w: bad pack object header", ErrDamaged)
		}
		c = data[pos]
		pos++
		size |= uint64(c&0x7f) << shift
		shift += 7
	}
	hint := int(min(size, 1<<30))
	switch typ {
	case 1, 2, 3, 4:
		out, _, err := r.inf.Zlib(data[pos:], hint)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrDamaged, err)
		}
		return &rawObject{Type: packTypes[typ], Data: out}, nil
	case 6, 7:
		var base *rawObject
		var err error
		if typ == 6 {
			if pos >= len(data) {
				return nil, fmt.Errorf("%w: truncated ofs-delta", ErrDamaged)
			}
			b := data[pos]
			pos++
			v := uint64(b & 0x7f)
			for b&0x80 != 0 {
				if pos >= len(data) || v > 1<<50 {
					return nil, fmt.Errorf("%w: bad ofs-delta offset", ErrDamaged)
				}
				b = data[pos]
				pos++
				v = (v+1)<<7 | uint64(b&0x7f)
			}
			if v == 0 || v > uint64(off) {
				return nil, fmt.Errorf("%w: ofs-delta base out of range", ErrDamaged)
			}
			base, err = r.readPacked(p, off-int(v), depth+1)
		} else {
			if pos+IDSize > len(data) {
				return nil, fmt.Errorf("%w: truncated ref-delta", ErrDamaged)
			}
			var bid ID
			copy(bid[:], data[pos:])
			pos += IDSize
			base, err = r.readObject(bid, depth+1)
		}
		if err != nil {
			return nil, err
		}
		delta, _, err := r.inf.Zlib(data[pos:], hint)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrDamaged, err)
		}
		res, err := applyDelta(base.Data, delta)
		if err != nil {
			return nil, err
		}
		return &rawObject{Type: base.Type, Data: res}, nil
	}
	return nil, fmt.Errorf("%w: invalid pack object type %d", ErrDamaged, typ)
}

// deltaVarint reads a little-endian base-128 integer.
func deltaVarint(d []byte, pos *int) (uint64, bool) {
	var v uint64
	shift := uint(0)
	for {
		if *pos >= len(d) || shift > 56 {
			return 0, false
		}
		b := d[*pos]
		*pos++
		v |= uint64(b&0x7f) << shift
		shift += 7
		if b&0x80 == 0 {
			return v, true
		}
	}
}

// applyDelta applies a git delta to base. Bounds are checked per
// instruction.
func applyDelta(base, delta []byte) ([]byte, error) {
	bad := func(why string) ([]byte, error) {
		return nil, fmt.Errorf("%w: delta: %s", ErrDamaged, why)
	}
	pos := 0
	if _, ok := deltaVarint(delta, &pos); !ok { // base size: not checked
		return bad("truncated header")
	}
	rsize, ok := deltaVarint(delta, &pos)
	if !ok || rsize > 1<<31 {
		return bad("bad result size")
	}
	out := make([]byte, 0, rsize)
	for pos < len(delta) {
		op := delta[pos]
		pos++
		if op&0x80 != 0 {
			var off, size uint64
			for i := uint(0); i < 4; i++ {
				if op&(1<<i) != 0 {
					if pos >= len(delta) {
						return bad("truncated copy")
					}
					off |= uint64(delta[pos]) << (8 * i)
					pos++
				}
			}
			for i := uint(0); i < 3; i++ {
				if op&(0x10<<i) != 0 {
					if pos >= len(delta) {
						return bad("truncated copy")
					}
					size |= uint64(delta[pos]) << (8 * i)
					pos++
				}
			}
			if size == 0 {
				size = 0x10000
			}
			if off > uint64(len(base)) || size > uint64(len(base))-off {
				return bad("copy out of range")
			}
			if uint64(len(out))+size > rsize {
				return bad("result too long")
			}
			out = append(out, base[off:off+size]...)
		} else if op != 0 {
			n := int(op)
			if pos+n > len(delta) {
				return bad("truncated insert")
			}
			if uint64(len(out))+uint64(n) > rsize {
				return bad("result too long")
			}
			out = append(out, delta[pos:pos+n]...)
			pos += n
		} else {
			return bad("zero opcode")
		}
	}
	if uint64(len(out)) != rsize {
		return bad("result size mismatch")
	}
	return out, nil
}
