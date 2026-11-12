package btree

import "sort"

// ScanTable visits every row of the table B-tree rooted at page root in
// ascending rowid order, calling fn with the rowid and the full payload. The
// payload slice may alias the database image and must not be modified or
// retained past fn unless copied. If fn returns false the scan stops.
func (p *Pager) ScanTable(root uint32, fn func(rowid int64, payload []byte) (bool, error)) error {
	_, err := p.scanTable(root, 0, fn)
	return err
}

func (p *Pager) scanTable(pgno uint32, depth int, fn func(int64, []byte) (bool, error)) (bool, error) {
	if depth > maxDepth {
		return false, corrupt("B-tree too deep")
	}
	nd, err := p.node(pgno)
	if err != nil {
		return false, err
	}
	switch nd.typ {
	case TypeLeafTable:
		for i := 0; i < nd.ncell; i++ {
			rowid, pl, err := p.tableLeafCell(nd, i)
			if err != nil {
				return false, err
			}
			cont, err := fn(rowid, pl)
			if err != nil || !cont {
				return false, err
			}
		}
		return true, nil
	case TypeInteriorTable:
		for i := 0; i <= nd.ncell; i++ {
			c, err := nd.child(i)
			if err != nil {
				return false, err
			}
			cont, err := p.scanTable(c, depth+1, fn)
			if err != nil || !cont {
				return false, err
			}
		}
		return true, nil
	}
	return false, corrupt("page %d is not a table page", pgno)
}

// CountTable returns the number of rows in the table B-tree rooted at root by
// summing the cell counts of its leaf pages; no cell is decoded.
func (p *Pager) CountTable(root uint32) (int64, error) {
	return p.countTable(root, 0)
}

func (p *Pager) countTable(pgno uint32, depth int) (int64, error) {
	if depth > maxDepth {
		return 0, corrupt("B-tree too deep")
	}
	nd, err := p.node(pgno)
	if err != nil {
		return 0, err
	}
	switch nd.typ {
	case TypeLeafTable:
		return int64(nd.ncell), nil
	case TypeInteriorTable:
		var total int64
		for i := 0; i <= nd.ncell; i++ {
			c, err := nd.child(i)
			if err != nil {
				return 0, err
			}
			n, err := p.countTable(c, depth+1)
			if err != nil {
				return 0, err
			}
			total += n
		}
		return total, nil
	}
	return 0, corrupt("page %d is not a table page", pgno)
}

// SeekTable finds the row with the given rowid in the table B-tree rooted at
// root. found is false if there is no such row.
func (p *Pager) SeekTable(root uint32, rowid int64) (payload []byte, found bool, err error) {
	pgno := root
	for depth := 0; depth <= maxDepth; depth++ {
		nd, err := p.node(pgno)
		if err != nil {
			return nil, false, err
		}
		switch nd.typ {
		case TypeInteriorTable:
			var kerr error
			// First cell whose key is >= rowid; its left child holds rowid.
			i := sort.Search(nd.ncell, func(i int) bool {
				k, e := nd.tableInteriorKey(i)
				if e != nil {
					kerr = e
				}
				return k >= rowid
			})
			if kerr != nil {
				return nil, false, kerr
			}
			if pgno, err = nd.child(i); err != nil {
				return nil, false, err
			}
		case TypeLeafTable:
			var kerr error
			var got int64
			var pl []byte
			i := sort.Search(nd.ncell, func(i int) bool {
				off, e := nd.cell(i)
				if e != nil {
					kerr = e
					return true
				}
				// Only the rowid is needed to compare; skip the payload size.
				_, n := varintAt(nd.pg, off)
				k, _ := varintAt(nd.pg, off+n)
				return k >= rowid
			})
			if kerr != nil {
				return nil, false, kerr
			}
			if i == nd.ncell {
				return nil, false, nil
			}
			got, pl, err = p.tableLeafCell(nd, i)
			if err != nil {
				return nil, false, err
			}
			if got != rowid {
				return nil, false, nil
			}
			return pl, true, nil
		default:
			return nil, false, corrupt("page %d is not a table page", pgno)
		}
	}
	return nil, false, corrupt("B-tree too deep")
}

// IndexCompare compares a stored index entry (its complete record payload)
// with the search key: negative if the entry sorts before the key, zero if it
// matches, positive if it sorts after.
type IndexCompare func(entry []byte) (int, error)

// SearchIndex visits, in key order, every entry of the index B-tree rooted at
// root for which cmp returns zero. cmp must be consistent with the tree's
// ordering. The search descends only into subtrees that can hold matching
// entries, so it costs O(depth·log(cells per page) + matches).
func (p *Pager) SearchIndex(root uint32, cmp IndexCompare, fn func(entry []byte) error) error {
	_, err := p.searchIndex(root, 0, cmp, fn)
	return err
}

// searchIndex returns done=true once an entry greater than the key was seen.
func (p *Pager) searchIndex(pgno uint32, depth int, cmp IndexCompare, fn func([]byte) error) (bool, error) {
	if depth > maxDepth {
		return false, corrupt("B-tree too deep")
	}
	nd, err := p.node(pgno)
	if err != nil {
		return false, err
	}
	if nd.typ != TypeLeafIndex && nd.typ != TypeInteriorIndex {
		return false, corrupt("page %d is not an index page", pgno)
	}
	// Binary search for the first cell whose entry is >= the key.
	var serr error
	first := sort.Search(nd.ncell, func(i int) bool {
		e, err := p.indexCell(nd, i)
		if err == nil {
			var c int
			if c, err = cmp(e); err == nil {
				return c >= 0
			}
		}
		serr = err
		return true
	})
	if serr != nil {
		return false, serr
	}
	for i := first; i <= nd.ncell; i++ {
		if nd.interior() {
			c, err := nd.child(i)
			if err != nil {
				return false, err
			}
			done, err := p.searchIndex(c, depth+1, cmp, fn)
			if err != nil || done {
				return done, err
			}
		}
		if i == nd.ncell {
			break
		}
		e, err := p.indexCell(nd, i)
		if err != nil {
			return false, err
		}
		c, err := cmp(e)
		if err != nil {
			return false, err
		}
		if c != 0 {
			return c > 0, nil
		}
		if err := fn(e); err != nil {
			return false, err
		}
	}
	return false, nil
}
