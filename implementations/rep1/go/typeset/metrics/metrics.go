// Package metrics loads Codexa font metric (.cfm) files and answers the
// questions the layout engine asks of a face: glyph advances, kerns, and the
// vertical and glue metrics.
package metrics

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Families, in the order used by face resolution.
const (
	Serif = 0
	Sans  = 1
	Mono  = 2
)

// FaceNames lists the nine faces. A face is referred to by its index here.
var FaceNames = [9]string{
	"serif", "serif-bold", "serif-italic", "serif-bold-italic",
	"sans", "sans-bold", "sans-italic", "sans-bold-italic",
	"mono",
}

// MonoFace is the index of the mono face.
const MonoFace = 8

// FaceIndex resolves a (family, bold, italic) style to a face index.
func FaceIndex(family int, bold, italic bool) int {
	if family == Mono {
		return MonoFace
	}
	i := family * 4
	if bold {
		i++
	}
	if italic {
		i += 2
	}
	return i
}

// Face holds the metrics of one face. All values are in thousandths of an em.
type Face struct {
	Name                                      string
	Ascent, Descent                           int64
	Space, Stretch, Shrink, Extra, DefaultAdv int64
	adv                                       []int32
	kern                                      map[uint64]int32
}

// Adv returns the advance of code point c.
func (f *Face) Adv(c rune) int64 {
	if c >= 0 && int(c) < len(f.adv) && f.adv[c] >= 0 {
		return int64(f.adv[c])
	}
	return f.DefaultAdv
}

// Kern returns the kern for the ordered pair (a, b), or 0.
func (f *Face) Kern(a, b rune) int64 {
	if len(f.kern) == 0 {
		return 0
	}
	return int64(f.kern[uint64(a)<<32|uint64(uint32(b))])
}

// Units returns the width in glyph-space units of the text: the sum of the
// advances plus the kerns of adjacent pairs. It must be scaled once.
func (f *Face) Units(text []rune) int64 {
	var u int64
	for i, c := range text {
		u += f.Adv(c)
		if i > 0 {
			u += f.Kern(text[i-1], c)
		}
	}
	return u
}

// Set is the table of the nine faces.
type Set struct {
	Faces [9]*Face
}

// Face returns the face with the given index.
func (s *Set) Face(i int) *Face { return s.Faces[i] }

// LoadDir loads data/faces/<face>.cfm for the nine faces under dataDir.
func LoadDir(dataDir string) (*Set, error) {
	s := &Set{}
	for i, name := range FaceNames {
		b, err := os.ReadFile(filepath.Join(dataDir, "faces", name+".cfm"))
		if err != nil {
			return nil, err
		}
		f, err := Parse(name, string(b))
		if err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		s.Faces[i] = f
	}
	return s, nil
}

// Fields strips a # comment, trims, and splits a record line into fields.
// It returns nil for an empty line. Shared with the pattern-file reader.
func Fields(line string) []string {
	if i := strings.IndexByte(line, '#'); i >= 0 {
		line = line[:i]
	}
	return strings.Fields(strings.Trim(line, " \t"))
}

// Parse reads the text of a .cfm file.
func Parse(name, text string) (*Face, error) {
	f := &Face{Name: name, kern: map[uint64]int32{}}
	type gl struct {
		cp  rune
		adv int32
	}
	var glyphs []gl
	maxcp := rune(-1)
	for _, line := range strings.Split(text, "\n") {
		fs := Fields(line)
		if len(fs) == 0 {
			continue
		}
		nums := make([]int64, 0, 3)
		for _, s := range fs[1:] {
			if v, err := strconv.ParseInt(s, 10, 64); err == nil {
				nums = append(nums, v)
			}
		}
		need := func(n int) error {
			if len(nums) < n {
				return fmt.Errorf("bad %s record", fs[0])
			}
			return nil
		}
		switch fs[0] {
		case "ascent":
			if err := need(1); err != nil {
				return nil, err
			}
			f.Ascent = nums[0]
		case "descent":
			if err := need(1); err != nil {
				return nil, err
			}
			f.Descent = nums[0]
		case "space":
			if err := need(3); err != nil {
				return nil, err
			}
			f.Space, f.Stretch, f.Shrink = nums[0], nums[1], nums[2]
		case "extra":
			if err := need(1); err != nil {
				return nil, err
			}
			f.Extra = nums[0]
		case "default":
			if err := need(1); err != nil {
				return nil, err
			}
			f.DefaultAdv = nums[0]
		case "glyph":
			if err := need(2); err != nil {
				return nil, err
			}
			glyphs = append(glyphs, gl{rune(nums[0]), int32(nums[1])})
			if rune(nums[0]) > maxcp {
				maxcp = rune(nums[0])
			}
		case "kern":
			if err := need(3); err != nil {
				return nil, err
			}
			f.kern[uint64(nums[0])<<32|uint64(uint32(nums[1]))] = int32(nums[2])
		}
	}
	f.adv = make([]int32, maxcp+1)
	for i := range f.adv {
		f.adv[i] = -1
	}
	for _, g := range glyphs {
		f.adv[g.cp] = g.adv
	}
	return f, nil
}
