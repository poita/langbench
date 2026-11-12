package odb

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"sort"

	"gitrepo/object"
)

// pack is one packfile together with its version-2 index, both held in memory.
type pack struct {
	idx, data []byte
	n         int // object count, fanout[255]
	fanout    [256]uint32
	idsOff    int // start of the sorted id table
	offsOff   int // start of the 4-byte offset table
	offs64Off int // start of the 8-byte offset table
	n64       int // entries in the 8-byte offset table
	cache     map[int]*object.Object
}

func openPack(idxPath, packPath string) (*pack, error) {
	data, err := os.ReadFile(packPath)
	if err != nil {
		return nil, err
	}
	idx, err := os.ReadFile(idxPath)
	if err != nil {
		return nil, err
	}
	if len(data) < 12+20 || string(data[:4]) != "PACK" || binary.BigEndian.Uint32(data[4:]) != 2 {
		return nil, fmt.Errorf("%s: not a version 2 packfile", packPath)
	}
	if len(idx) < 8+1024 || string(idx[:4]) != "\xfftOc" || binary.BigEndian.Uint32(idx[4:]) != 2 {
		return nil, fmt.Errorf("%s: not a version 2 pack index", idxPath)
	}
	p := &pack{idx: idx, data: data, cache: map[int]*object.Object{}}
	prev := uint32(0)
	for i := range p.fanout {
		v := binary.BigEndian.Uint32(idx[8+4*i:])
		if v < prev {
			return nil, fmt.Errorf("%s: fanout table not monotonic", idxPath)
		}
		p.fanout[i], prev = v, v
	}
	n := int(p.fanout[255])
	p.n = n
	p.idsOff = 8 + 1024
	p.offsOff = p.idsOff + 20*n + 4*n
	p.offs64Off = p.offsOff + 4*n
	if len(idx) < p.offs64Off+40 {
		return nil, fmt.Errorf("%s: truncated pack index", idxPath)
	}
	p.n64 = (len(idx) - 40 - p.offs64Off) / 8
	return p, nil
}

func (p *pack) idAt(i int) (id object.ID) {
	copy(id[:], p.idx[p.idsOff+20*i:])
	return id
}

// lowerBound returns the index of the first id that is >= id.
func (p *pack) lowerBound(id object.ID) int {
	lo, hi := 0, int(p.fanout[id[0]])
	if id[0] > 0 {
		lo = int(p.fanout[id[0]-1])
	}
	return lo + sort.Search(hi-lo, func(i int) bool {
		return bytes.Compare(p.idx[p.idsOff+20*(lo+i):p.idsOff+20*(lo+i)+20], id[:]) >= 0
	})
}

// find locates id in the pack and returns its offset in the packfile.
func (p *pack) find(id object.ID) (int, bool) {
	i := p.lowerBound(id)
	if i >= p.n || p.idAt(i) != id {
		return 0, false
	}
	v := binary.BigEndian.Uint32(p.idx[p.offsOff+4*i:])
	if v&0x80000000 == 0 {
		return int(v), true
	}
	j := int(v & 0x7fffffff)
	if j >= p.n64 {
		return 0, false
	}
	off := binary.BigEndian.Uint64(p.idx[p.offs64Off+8*j:])
	if off >= uint64(len(p.data)) {
		return 0, false
	}
	return int(off), true
}
