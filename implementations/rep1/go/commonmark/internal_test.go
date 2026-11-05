package commonmark

import (
	"bytes"
	"strings"
	"testing"
)

func TestScanATXStart(t *testing.T) {
	cases := []struct {
		in    string
		level int
		end   int
		ok    bool
	}{
		{"# a", 1, 2, true},
		{"###### a", 6, 7, true},
		{"####### a", 0, 0, false},
		{"#a", 0, 0, false},
		{"#", 1, 1, true},
		{"#  \t a", 1, 5, true},
	}
	for _, c := range cases {
		level, end, ok := scanATXStart([]byte(c.in), 0)
		if level != c.level || end != c.end || ok != c.ok {
			t.Errorf("scanATXStart(%q) = %d,%d,%v; want %d,%d,%v", c.in, level, end, ok, c.level, c.end, c.ok)
		}
	}
}

func TestScanThematicBreak(t *testing.T) {
	yes := []string{"***", "---", "___", "* * *", "- - - - ", "**\t*"}
	no := []string{"**", "*-*", "--", "***a", "", "+++"}
	for _, s := range yes {
		if !scanThematicBreak([]byte(s), 0) {
			t.Errorf("%q should be a thematic break", s)
		}
	}
	for _, s := range no {
		if scanThematicBreak([]byte(s), 0) {
			t.Errorf("%q should not be a thematic break", s)
		}
	}
}

func TestScanFence(t *testing.T) {
	if ch, n, ok := scanFenceStart([]byte("````go"), 0); !ok || ch != '`' || n != 4 {
		t.Errorf("backtick fence: %c %d %v", ch, n, ok)
	}
	if _, _, ok := scanFenceStart([]byte("``` a`"), 0); ok {
		t.Error("backtick in info string must not open a fence")
	}
	if _, n, ok := scanFenceStart([]byte("~~~ a`"), 0); !ok || n != 3 {
		t.Error("tilde fence info may contain backticks")
	}
	if n := scanFenceClose([]byte("````  "), 0, '`'); n != 4 {
		t.Errorf("close fence = %d", n)
	}
	if n := scanFenceClose([]byte("``` a"), 0, '`'); n != 0 {
		t.Errorf("close fence with text = %d", n)
	}
}

func TestScanListMarker(t *testing.T) {
	m, ok := scanListMarker([]byte("12) x"), 0, false)
	if !ok || !m.ordered || m.char != ')' || m.start != 12 || m.width != 3 {
		t.Errorf("got %+v %v", m, ok)
	}
	if _, ok := scanListMarker([]byte("-x"), 0, false); ok {
		t.Error("marker needs trailing whitespace")
	}
	if _, ok := scanListMarker([]byte("2. x"), 0, true); ok {
		t.Error("only 1 may interrupt a paragraph")
	}
	if _, ok := scanListMarker([]byte("- "), 0, true); ok {
		t.Error("empty item may not interrupt a paragraph")
	}
	if _, ok := scanListMarker([]byte("-"), 0, false); !ok {
		t.Error("bare marker at end of line is a marker")
	}
}

func TestScanTitle(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{`"abc"`, 5},
		{`"a\"b"`, 6},
		{`"a\"`, 4},
		{`"a\\" b"`, 8},
		{`"abc`, -1},
		{`(a(b)`, -1},
		{`(a\(b)`, 6},
		{`(a\)b`, 4},
		{`'x' y`, 3},
	}
	for _, c := range cases {
		if got := scanTitle([]byte(c.in), 0); got != c.want {
			t.Errorf("scanTitle(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestScanDestination(t *testing.T) {
	cases := []struct {
		in  string
		raw string
		end int
		ok  bool
	}{
		{"/a)", "/a", 2, true},
		{"/a b)", "/a", 2, true},
		{"<a b>)", "a b", 5, true},
		{"<a\nb>)", "", 0, false},
		{`<a\>b>)`, `a\>b`, 6, true},
		{"/a(b))", "/a(b)", 5, true},
		{"/a(b", "", 0, false},
		{`/a\(b)`, `/a\(b`, 5, true},
		{")", "", 0, true},
		{"/a", "", 0, false},
	}
	for _, c := range cases {
		raw, end, ok := scanDestination([]byte(c.in), 0)
		if ok != c.ok || (ok && (string(raw) != c.raw || end != c.end)) {
			t.Errorf("scanDestination(%q) = %q,%d,%v; want %q,%d,%v", c.in, raw, end, ok, c.raw, c.end, c.ok)
		}
	}
	long := strings.Repeat("(", 33) + strings.Repeat(")", 33) + " "
	if _, _, ok := scanDestination([]byte(long), 0); ok {
		t.Error("more than 32 nested parentheses must be rejected")
	}
}

func TestDecodeEntities(t *testing.T) {
	cases := map[string]string{
		"a&amp;b":        "a&b",
		"&lt;&gt;&quot;": "<>\"",
		"&#65;&#x42;":    "AB",
		"&foo;":          "&foo;",
		"&#0;":           "\uFFFD",
		"&&amp;":         "&&",
		"plain":          "plain",
		"&#12345678;":    "&#12345678;",
	}
	for in, want := range cases {
		if got := string(decodeEntities([]byte(in))); got != want {
			t.Errorf("decodeEntities(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestUnescapeBackslashes(t *testing.T) {
	cases := map[string]string{
		`a\*b`:   "a*b",
		`a\b`:    `a\b`,
		`\\`:     `\`,
		`end\`:   `end\`,
		`\&amp;`: "&amp;",
	}
	for in, want := range cases {
		if got := string(unescapeBackslashes([]byte(in))); got != want {
			t.Errorf("unescapeBackslashes(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAppendHref(t *testing.T) {
	cases := map[string]string{
		"/a b":             "/a%20b",
		"a&b'c":            "a&amp;b&#x27;c",
		"é":                "%C3%A9",
		"javascript:x":     "",
		"VBScript:x":       "",
		"file:///x":        "",
		"data:text/plain,": "",
		"data:image/gif;,": "data:image/gif;,",
		"http://x/?a=b#c":  "http://x/?a=b#c",
	}
	for in, want := range cases {
		if got := string(appendHref(nil, []byte(in))); got != want {
			t.Errorf("appendHref(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAppendEscaped(t *testing.T) {
	got := string(appendEscaped(nil, []byte(`<a href="x">&'</a>`)))
	want := `&lt;a href=&quot;x&quot;&gt;&amp;'&lt;/a&gt;`
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestChopTrailingHashes(t *testing.T) {
	cases := map[string]string{
		"foo #":     "foo",
		"foo ###  ": "foo",
		"foo#":      "foo#",
		"###":       "",
		"foo \\#":   "foo \\#",
		"foo":       "foo",
	}
	for in, want := range cases {
		if got := string(chopTrailingHashes([]byte(in))); got != want {
			t.Errorf("chopTrailingHashes(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestTrimTrailingBlankLines(t *testing.T) {
	cases := map[string]string{
		"a\n\n\n":    "a\n",
		"a  \n \n":   "a  \n",
		"a\n\nb\n\n": "a\n\nb\n",
		"\n\n":       "\n",
	}
	for in, want := range cases {
		if got := string(trimTrailingBlankLines([]byte(in))); got != want {
			t.Errorf("trimTrailingBlankLines(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestBacktickMemo checks the code span search memo: after a search has
// reached the end of the content, a closer is not found again unless it
// lies beyond the current position.
func TestBacktickMemo(t *testing.T) {
	var ip inlineParser
	ip.parse([]byte("`a ``b`` c"))
	if !ip.btScanned {
		t.Fatal("search to the end of the content should set the scanned flag")
	}
	if ip.btLast[2] != 6 || ip.btLast[1] != 0 {
		t.Errorf("memo = %v, want last[2]=6", ip.btLast[:3])
	}
	if end, ok := ip.findBacktickCloser(1, 1); ok {
		t.Errorf("memoised search found a closer ending at %d", end)
	}
}

func TestDeepNestingDoesNotOverflow(t *testing.T) {
	var b bytes.Buffer
	b.WriteString(strings.Repeat("> ", 300))
	b.WriteString("x\n")
	b.WriteString(strings.Repeat("[", 20000))
	b.WriteString(strings.Repeat("*a ", 20000))
	b.WriteString(strings.Repeat("]", 20000))
	out := ToHTML(b.Bytes())
	if !bytes.Contains(out, []byte("<blockquote>")) {
		t.Fatal("expected a block quote in the output")
	}
}
