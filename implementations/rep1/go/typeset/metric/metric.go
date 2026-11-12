// Package metric loads Codexa font metric (.cfm) files and measures text.
//
// A Face holds the glyph advances, kerning pairs and vertical metrics of one
// font face; a Set holds the nine faces and resolves a Style to a Face.
package metric

import (
	"bufio"
	"fmt"
	"io"
	"io/fs"
	"strconv"
	"strings"

	"typeset/dim"
)

// Family is a font family.
type Family string

// The three font families.
const (
	Serif Family = "serif"
	Sans  Family = "sans"
	Mono  Family = "mono"
)

// Style selects a face: a family plus bold and italic switches.
type Style struct {
	Family Family
	Bold   bool
	Italic bool
}

// FaceName returns the name of the face the style resolves to.
func (s Style) FaceName() string {
	if s.Family == Mono {
		return "mono"
	}
	n := string(s.Family)
	if s.Bold {
		n += "-bold"
	}
	if s.Italic {
		n += "-italic"
	}
	return n
}

// Face is one font face. Advances and kerns are in thousandths of an em.
type Face struct {
	Name    string
	Ascent  int64
	Descent int64
	Space   int64
	Stretch int64
	Shrink  int64
	Extra   int64
	Default int64

	glyph map[rune]int64
	kern  map[[2]rune]int64
}

// Advance returns the advance of c in glyph units.
func (f *Face) Advance(c rune) int64 {
	if a, ok := f.glyph[c]; ok {
		return a
	}
	return f.Default
}

// Kern returns the kern between the ordered pair (a, b) in glyph units.
func (f *Face) Kern(a, b rune) int64 {
	return f.kern[[2]rune{a, b}]
}

// Units returns the width of text in glyph units: the advances plus the kerns
// of adjacent pairs.
func (f *Face) Units(text []rune) int64 {
	var u int64
	for i, c := range text {
		u += f.Advance(c)
		if i > 0 {
			u += f.Kern(text[i-1], c)
		}
	}
	return u
}

// Width returns the width of text in millipoints at the given size. The
// kerns are summed in glyph space and the total is scaled once.
func (f *Face) Width(text []rune, size int64) int64 {
	return dim.Scale(f.Units(text), size)
}

// StringWidth is Width for a string.
func (f *Face) StringWidth(text string, size int64) int64 {
	return f.Width([]rune(text), size)
}

// ParseFace reads a .cfm file.
func ParseFace(r io.Reader) (*Face, error) {
	f := &Face{glyph: map[rune]int64{}, kern: map[[2]rune]int64{}}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<16), 1<<24)
	n := 0
	for sc.Scan() {
		n++
		line := sc.Text()
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		nums := make([]int64, 0, 3)
		for _, s := range fields[1:] {
			v, err := strconv.ParseInt(s, 10, 64)
			if err != nil {
				nums = nums[:0]
				break
			}
			nums = append(nums, v)
		}
		need := func(k int) error {
			if len(nums) != k {
				return fmt.Errorf("line %d: %s needs %d numbers", n, fields[0], k)
			}
			return nil
		}
		var err error
		switch fields[0] {
		case "cfm":
		case "face":
			if len(fields) != 2 {
				return nil, fmt.Errorf("line %d: bad face record", n)
			}
			f.Name = fields[1]
		case "ascent":
			if err = need(1); err == nil {
				f.Ascent = nums[0]
			}
		case "descent":
			if err = need(1); err == nil {
				f.Descent = nums[0]
			}
		case "space":
			if err = need(3); err == nil {
				f.Space, f.Stretch, f.Shrink = nums[0], nums[1], nums[2]
			}
		case "extra":
			if err = need(1); err == nil {
				f.Extra = nums[0]
			}
		case "default":
			if err = need(1); err == nil {
				f.Default = nums[0]
			}
		case "glyph":
			if err = need(2); err == nil {
				f.glyph[rune(nums[0])] = nums[1]
			}
		case "kern":
			if err = need(3); err == nil {
				f.kern[[2]rune{rune(nums[0]), rune(nums[1])}] = nums[2]
			}
		default:
			err = fmt.Errorf("line %d: unknown record %q", n, fields[0])
		}
		if err != nil {
			return nil, err
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return f, nil
}

// FaceNames lists the nine face names.
var FaceNames = []string{
	"serif", "serif-bold", "serif-italic", "serif-bold-italic",
	"sans", "sans-bold", "sans-italic", "sans-bold-italic",
	"mono",
}

// Set is the collection of loaded faces.
type Set struct {
	faces map[string]*Face
}

// NewSet builds a Set from already parsed faces.
func NewSet(faces ...*Face) *Set {
	s := &Set{faces: map[string]*Face{}}
	for _, f := range faces {
		s.faces[f.Name] = f
	}
	return s
}

// LoadSet reads dir/<face>.cfm for each of the nine faces from fsys.
func LoadSet(fsys fs.FS, dir string) (*Set, error) {
	s := &Set{faces: map[string]*Face{}}
	for _, name := range FaceNames {
		file, err := fsys.Open(dir + "/" + name + ".cfm")
		if err != nil {
			return nil, err
		}
		f, err := ParseFace(file)
		file.Close()
		if err != nil {
			return nil, fmt.Errorf("%s.cfm: %w", name, err)
		}
		if f.Name == "" {
			f.Name = name
		}
		s.faces[name] = f
	}
	return s, nil
}

// Face resolves a style to its face.
func (s *Set) Face(st Style) *Face {
	return s.faces[st.FaceName()]
}

// ByName returns the face with the given name, or nil.
func (s *Set) ByName(name string) *Face {
	return s.faces[name]
}
