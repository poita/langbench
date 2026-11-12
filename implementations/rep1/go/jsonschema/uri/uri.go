// Package uri implements the parts of RFC 3986 that JSON Schema reference
// resolution needs: splitting a URI reference into components, resolving a
// reference against a base (section 5.2), dot-segment removal, recomposition
// and percent-decoding.
//
// The parser is deliberately lenient (as RFC 3986 Appendix B is): every string
// splits into components, so Parse never fails.
package uri

import "strings"

// URI is a URI reference split into its five components. The Has* fields
// distinguish an absent component from an empty one ("a" has no query, "a?"
// has an empty query), which matters for resolution and recomposition.
type URI struct {
	Scheme       string
	Authority    string
	Path         string
	Query        string
	Fragment     string
	HasScheme    bool
	HasAuthority bool
	HasQuery     bool
	HasFragment  bool
}

// Parse splits ref into components (RFC 3986 Appendix B).
func Parse(ref string) URI {
	var u URI
	rest := ref
	if i := strings.IndexByte(rest, '#'); i >= 0 {
		u.Fragment, u.HasFragment = rest[i+1:], true
		rest = rest[:i]
	}
	if i := strings.IndexByte(rest, '?'); i >= 0 {
		u.Query, u.HasQuery = rest[i+1:], true
		rest = rest[:i]
	}
	if i := schemeEnd(rest); i > 0 {
		u.Scheme, u.HasScheme = rest[:i], true
		rest = rest[i+1:]
	}
	if strings.HasPrefix(rest, "//") {
		rest = rest[2:]
		end := strings.IndexByte(rest, '/')
		if end < 0 {
			end = len(rest)
		}
		u.Authority, u.HasAuthority = rest[:end], true
		rest = rest[end:]
	}
	u.Path = rest
	return u
}

// schemeEnd returns the index of the ':' ending a leading scheme, or -1.
func schemeEnd(s string) int {
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z':
		case i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'):
		case c == ':' && i > 0:
			return i
		default:
			return -1
		}
	}
	return -1
}

// String recomposes the URI (RFC 3986 section 5.3).
func (u URI) String() string {
	var sb strings.Builder
	if u.HasScheme {
		sb.WriteString(u.Scheme)
		sb.WriteByte(':')
	}
	if u.HasAuthority {
		sb.WriteString("//")
		sb.WriteString(u.Authority)
	}
	sb.WriteString(u.Path)
	if u.HasQuery {
		sb.WriteByte('?')
		sb.WriteString(u.Query)
	}
	if u.HasFragment {
		sb.WriteByte('#')
		sb.WriteString(u.Fragment)
	}
	return sb.String()
}

// WithoutFragment returns u with its fragment removed.
func (u URI) WithoutFragment() URI {
	u.Fragment, u.HasFragment = "", false
	return u
}

// Resolve resolves the reference ref against base using the strict algorithm
// of RFC 3986 section 5.2.2. base need not be absolute: an empty or relative
// base simply leaves the corresponding components undefined in the result.
func Resolve(base, ref URI) URI {
	var t URI
	switch {
	case ref.HasScheme:
		t = ref
		t.Path = RemoveDotSegments(ref.Path)
	case ref.HasAuthority:
		t = ref
		t.Scheme, t.HasScheme = base.Scheme, base.HasScheme
		t.Path = RemoveDotSegments(ref.Path)
	default:
		t.Scheme, t.HasScheme = base.Scheme, base.HasScheme
		t.Authority, t.HasAuthority = base.Authority, base.HasAuthority
		if ref.Path == "" {
			t.Path = base.Path
			if ref.HasQuery {
				t.Query, t.HasQuery = ref.Query, true
			} else {
				t.Query, t.HasQuery = base.Query, base.HasQuery
			}
		} else {
			if strings.HasPrefix(ref.Path, "/") {
				t.Path = RemoveDotSegments(ref.Path)
			} else {
				t.Path = RemoveDotSegments(merge(base, ref.Path))
			}
			t.Query, t.HasQuery = ref.Query, ref.HasQuery
		}
	}
	t.Fragment, t.HasFragment = ref.Fragment, ref.HasFragment
	return t
}

// ResolveString parses base and ref, resolves one against the other and
// returns the recomposed result.
func ResolveString(base, ref string) string {
	return Resolve(Parse(base), Parse(ref)).String()
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

// RemoveDotSegments implements RFC 3986 section 5.2.4.
func RemoveDotSegments(path string) string {
	if !strings.Contains(path, ".") {
		return path
	}
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
			// Move the first path segment (with its leading '/') to the output.
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

// PercentDecode decodes %XX escapes in s. Malformed escapes are left as they
// are. The decoded bytes are returned as-is, so for UTF-8 text the result is
// the UTF-8 string the escapes encode.
func PercentDecode(s string) string {
	if !strings.Contains(s, "%") {
		return s
	}
	var sb strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) {
			h, l := unhex(s[i+1]), unhex(s[i+2])
			if h >= 0 && l >= 0 {
				sb.WriteByte(byte(h<<4 | l))
				i += 2
				continue
			}
		}
		sb.WriteByte(s[i])
	}
	return sb.String()
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
