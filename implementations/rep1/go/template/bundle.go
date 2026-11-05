package template

import (
	"errors"
	"strings"
)

// Bundle is the parsed form of the program's standard input: a JSON context
// and a set of named template sources.
type Bundle struct {
	// Context holds the initial variables, in document order.
	Context *Dict
	// Names lists the template names in input order; Names[0] is the
	// template to render.
	Names []string
	// Sources maps template names to their bodies.
	Sources map[string]string
}

// ParseBundle splits input of the form
//
//	<JSON object>
//	--
//	=== name
//	<body>
//	=== other
//	<body>
//
// into its context and templates. Bodies are slices of input (no copying).
func ParseBundle(input []byte) (*Bundle, error) {
	return parseBundleString(string(input))
}

func parseBundleString(in string) (*Bundle, error) {
	// Find the first line that is exactly "--".
	jsonEnd, rest := -1, 0
	for pos := 0; pos <= len(in); {
		nl := strings.IndexByte(in[pos:], '\n')
		end := len(in)
		if nl >= 0 {
			end = pos + nl
		}
		if in[pos:end] == "--" {
			jsonEnd = pos
			rest = end
			if nl >= 0 {
				rest = end + 1
			}
			break
		}
		if nl < 0 {
			break
		}
		pos = end + 1
	}
	if jsonEnd < 0 {
		return nil, errors.New("bundle: missing '--' separator line")
	}
	v, err := ParseJSON([]byte(in[:jsonEnd]))
	if err != nil {
		return nil, err
	}
	ctx, ok := v.(*Dict)
	if !ok {
		return nil, errors.New("bundle: context must be a JSON object")
	}
	b := &Bundle{Context: ctx, Sources: map[string]string{}}

	tpl := in[rest:]
	// Collect header positions.
	type header struct {
		name      string
		lineStart int // start of the header line
		bodyStart int // first byte after the header line's LF
	}
	var hs []header
	for pos := 0; pos < len(tpl); {
		nl := strings.IndexByte(tpl[pos:], '\n')
		end, next := len(tpl), len(tpl)
		if nl >= 0 {
			end = pos + nl
			next = end + 1
		}
		if strings.HasPrefix(tpl[pos:end], "=== ") {
			hs = append(hs, header{name: strings.TrimSpace(tpl[pos+4 : end]), lineStart: pos, bodyStart: next})
		}
		pos = next
	}
	if len(hs) == 0 {
		return nil, errors.New("bundle: no templates")
	}
	for i, h := range hs {
		var body string
		if i+1 < len(hs) {
			if e := hs[i+1].lineStart - 1; e > h.bodyStart {
				body = tpl[h.bodyStart:e]
			}
		} else {
			body = strings.TrimSuffix(tpl[h.bodyStart:], "\n")
		}
		if _, dup := b.Sources[h.name]; !dup {
			b.Names = append(b.Names, h.name)
			b.Sources[h.name] = body
		}
	}
	return b, nil
}
