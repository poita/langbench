// Package uri implements the parts of RFC 3986 that JSON Schema reference
// resolution needs: splitting a URI reference into components, strict
// reference resolution (section 5.2.2, including remove_dot_segments),
// recomposition (section 5.3), fragment handling and percent-decoding.
package uri

import "strings"

// URI is a parsed URI reference. Each optional component carries a flag that
// distinguishes "absent" from "present but empty", which RFC 3986 needs.
type URI struct {
	Scheme       string
	HasScheme    bool
	Authority    string
	HasAuthority bool
	Path         string
	Query        string
	HasQuery     bool
	Fragment     string
	HasFragment  bool
}

// Parse splits a URI reference into its components (RFC 3986 appendix B,
// without a regular expression). It never fails: any string is some
// reference.
func Parse(s string) URI {
	var u URI
	if i := strings.IndexByte(s, '#'); i >= 0 {
		u.Fragment, u.HasFragment = s[i+1:], true
		s = s[:i]
	}
	if i := strings.IndexByte(s, '?'); i >= 0 {
		u.Query, u.HasQuery = s[i+1:], true
		s = s[:i]
	}
	if i := schemeEnd(s); i > 0 {
		u.Scheme, u.HasScheme = s[:i], true
		s = s[i+1:]
	}
	if strings.HasPrefix(s, "//") {
		s = s[2:]
		end := strings.IndexByte(s, '/')
		if end < 0 {
			end = len(s)
		}
		u.Authority, u.HasAuthority = s[:end], true
		s = s[end:]
	}
	u.Path = s
	return u
}

// schemeEnd returns the index of the ':' ending a leading scheme, or -1.
func schemeEnd(s string) int {
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z':
		case (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.') && i > 0:
		case c == ':':
			if i > 0 {
				return i
			}
			return -1
		default:
			return -1
		}
	}
	return -1
}

// String recomposes the URI (RFC 3986 section 5.3).
func (u URI) String() string {
	var b strings.Builder
	if u.HasScheme {
		b.WriteString(u.Scheme)
		b.WriteByte(':')
	}
	if u.HasAuthority {
		b.WriteString("//")
		b.WriteString(u.Authority)
	}
	b.WriteString(u.Path)
	if u.HasQuery {
		b.WriteByte('?')
		b.WriteString(u.Query)
	}
	if u.HasFragment {
		b.WriteByte('#')
		b.WriteString(u.Fragment)
	}
	return b.String()
}

// RemoveDotSegments implements RFC 3986 section 5.2.4.
func RemoveDotSegments(path string) string {
	in := path
	var out []string // output segments, each including its leading '/' if any
	for in != "" {
		switch {
		case strings.HasPrefix(in, "../"):
			in = in[3:]
		case strings.HasPrefix(in, "./"):
			in = in[2:]
		case strings.HasPrefix(in, "/./"):
			in = in[2:]
		case in == "/.":
			in = "/"
		case strings.HasPrefix(in, "/../"):
			in = in[3:]
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
		case in == "/..":
			in = "/"
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
		case in == "." || in == "..":
			in = ""
		default:
			start := 0
			if in[0] == '/' {
				start = 1
			}
			end := strings.IndexByte(in[start:], '/')
			if end < 0 {
				end = len(in)
			} else {
				end += start
			}
			out = append(out, in[:end])
			in = in[end:]
		}
	}
	return strings.Join(out, "")
}

// merge implements RFC 3986 section 5.2.3.
func merge(base URI, refPath string) string {
	if base.HasAuthority && base.Path == "" {
		return "/" + refPath
	}
	if i := strings.LastIndexByte(base.Path, '/'); i >= 0 {
		return base.Path[:i+1] + refPath
	}
	return refPath
}

// ResolveRef resolves reference r against base using the strict algorithm of
// RFC 3986 section 5.2.2. base may be empty or relative; resolution then
// proceeds algorithmically on whatever components it has.
func ResolveRef(base, r URI) URI {
	var t URI
	switch {
	case r.HasScheme:
		t = r
		t.Path = RemoveDotSegments(r.Path)
	case r.HasAuthority:
		t = r
		t.Scheme, t.HasScheme = base.Scheme, base.HasScheme
		t.Path = RemoveDotSegments(r.Path)
	default:
		t.Scheme, t.HasScheme = base.Scheme, base.HasScheme
		t.Authority, t.HasAuthority = base.Authority, base.HasAuthority
		if r.Path == "" {
			t.Path = base.Path
			if r.HasQuery {
				t.Query, t.HasQuery = r.Query, true
			} else {
				t.Query, t.HasQuery = base.Query, base.HasQuery
			}
		} else {
			if strings.HasPrefix(r.Path, "/") {
				t.Path = RemoveDotSegments(r.Path)
			} else {
				t.Path = RemoveDotSegments(merge(base, r.Path))
			}
			t.Query, t.HasQuery = r.Query, r.HasQuery
		}
	}
	t.Fragment, t.HasFragment = r.Fragment, r.HasFragment
	return t
}

// Resolve resolves the reference string ref against the base string and
// returns the recomposed result.
func Resolve(base, ref string) string {
	return ResolveRef(Parse(base), Parse(ref)).String()
}

// SplitFragment splits s at its first '#'. The fragment is returned without
// the '#'; hasFragment tells whether a '#' was present.
func SplitFragment(s string) (doc, fragment string, hasFragment bool) {
	if i := strings.IndexByte(s, '#'); i >= 0 {
		return s[:i], s[i+1:], true
	}
	return s, "", false
}

// StripFragment returns s without any fragment.
func StripFragment(s string) string {
	doc, _, _ := SplitFragment(s)
	return doc
}

// PercentDecode decodes %XX escapes. Malformed escapes are left unchanged.
// The result is the raw byte sequence, which callers treat as UTF-8.
func PercentDecode(s string) string {
	if strings.IndexByte(s, '%') < 0 {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) {
			h1, h2 := unhex(s[i+1]), unhex(s[i+2])
			if h1 >= 0 && h2 >= 0 {
				b.WriteByte(byte(h1<<4 | h2))
				i += 2
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func unhex(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}
