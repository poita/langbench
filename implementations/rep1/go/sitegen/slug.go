package sitegen

import "strings"

// TagSlug derives the URL slug of a tag name: ASCII letters are lower-cased,
// every other character that is not a letter or digit becomes '-', runs of
// '-' collapse into one, and leading and trailing '-' are removed.
//
//	TagSlug("Web Development") == "web-development"
//	TagSlug("C++") == "c"
func TagSlug(name string) string {
	var b strings.Builder
	b.Grow(len(name))
	dash := true // suppresses leading dashes and collapses runs
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			dash = false
		case r >= 'A' && r <= 'Z':
			b.WriteRune(r + 'a' - 'A')
			dash = false
		default:
			if !dash {
				b.WriteByte('-')
				dash = true
			}
		}
	}
	return strings.TrimSuffix(b.String(), "-")
}

var monthNames = [...]string{
	"January", "February", "March", "April", "May", "June",
	"July", "August", "September", "October", "November", "December",
}

// DateLong renders a YYYY-MM-DD date as "<Month> <D>, <YYYY>", for example
// "2024-03-05" becomes "March 5, 2024". A string that is not a well-formed
// date is returned unchanged.
func DateLong(date string) string {
	if len(date) != 10 || date[4] != '-' || date[7] != '-' {
		return date
	}
	month := int(date[5]-'0')*10 + int(date[6]-'0')
	day := int(date[8]-'0')*10 + int(date[9]-'0')
	if month < 1 || month > 12 {
		return date
	}
	return monthNames[month-1] + " " + itoa(day) + ", " + date[:4]
}

func itoa(n int) string {
	if n < 10 {
		return string(rune('0' + n))
	}
	return itoa(n/10) + string(rune('0'+n%10))
}
