package sitegen

import "strings"

// escapeText escapes s for XML character data: & < >.
func escapeText(sb *strings.Builder, s string) { escapeXML(sb, s, false) }

// escapeAttr escapes s for a double-quoted XML attribute: & < > ".
func escapeAttr(sb *strings.Builder, s string) { escapeXML(sb, s, true) }

func escapeXML(sb *strings.Builder, s string, quote bool) {
	last := 0
	for i := 0; i < len(s); i++ {
		var rep string
		switch s[i] {
		case '&':
			rep = "&amp;"
		case '<':
			rep = "&lt;"
		case '>':
			rep = "&gt;"
		case '"':
			if !quote {
				continue
			}
			rep = "&quot;"
		default:
			continue
		}
		sb.WriteString(s[last:i])
		sb.WriteString(rep)
		last = i + 1
	}
	sb.WriteString(s[last:])
}
