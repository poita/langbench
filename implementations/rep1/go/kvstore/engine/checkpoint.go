package engine

import "sort"

// checkpoint copies the overlay into the main file image and resets the log.
// It returns the number of pages copied.
func (p *pager) checkpoint() int {
	n := len(p.overlay)
	pc := int(p.hdr.PageCount) * PageSize
	if len(p.main) < pc {
		p.main = append(p.main, make([]byte, pc-len(p.main))...)
	} else {
		p.main = p.main[:pc]
	}
	pages := make([]uint32, 0, n)
	for pg := range p.overlay {
		pages = append(pages, pg)
	}
	sort.Slice(pages, func(i, j int) bool { return pages[i] < pages[j] })
	for _, pg := range pages {
		copy(p.main[(pg-1)*PageSize:], p.overlay[pg])
	}
	p.overlay = map[uint32][]byte{}
	p.wal = walHeader()
	return n
}
