package tessera

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/rand"
	"reflect"
	"sort"
	"strings"
	"testing"

	"example.com/tessera/crc"
)

func runScript(t *testing.T, main, wal []byte, lines ...string) Output {
	t.Helper()
	return RunScript(main, wal, []byte(strings.Join(lines, "\n")+"\n"))
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(strings.Join(strings.Fields(s), ""))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func statBlock(pages, free, freehead, docs, root, height, commits, indexes, wal int) string {
	return fmt.Sprintf("  pages %d\n  free %d\n  freehead %d\n  docs %d\n  root %d\n  height %d\n  commits %d\n  indexes %d\n  wal %d\n",
		pages, free, freehead, docs, root, height, commits, indexes, wal)
}

func TestSpecExample21_1_CheckpointBytes(t *testing.T) {
	out := runScript(t, nil, nil, `put "a" 1`, `checkpoint`, `stat`)
	want := "[1] ok put created\n[2] ok checkpoint pages 2\n[3] ok stat\n" + statBlock(2, 0, 0, 1, 2, 1, 1, 0, 32)
	if string(out.Results) != want {
		t.Fatalf("results:\n%s\nwant:\n%s", out.Results, want)
	}
	if len(out.DatabaseTDB) != 2048 {
		t.Fatalf("main.tdb is %d bytes", len(out.DatabaseTDB))
	}
	header := mustHex(t, `54 45 53 53 45 52 41 31 00 01 04 00 00 00 00 02
		00 00 00 00 00 00 00 00 00 00 00 02 00 00 00 01
		00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00`)
	if !bytes.Equal(out.DatabaseTDB[:48], header) || !allZero(out.DatabaseTDB[48:1024]) {
		t.Errorf("header page mismatch: %x", out.DatabaseTDB[:48])
	}
	leaf := make([]byte, PageSize)
	copy(leaf, mustHex(t, "01 00 00 01 03 ea 00 00 00 00 00 00 00 00 00 00 03 ea"))
	copy(leaf[0x3ea:], mustHex(t, "00 01 00 00 00 09 00 09 00 00 00 00 61 03 00 00 00 00 00 00 00 01"))
	if !bytes.Equal(out.DatabaseTDB[1024:], leaf) {
		t.Errorf("leaf page mismatch")
	}
	if !bytes.Equal(out.LogTWAL, walHeader()) {
		t.Errorf("log is not an empty log")
	}
}

func allZero(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}

func TestWALHeaderBytes(t *testing.T) {
	want := mustHex(t, `54 45 53 53 57 41 4c 31 00 01 04 00 00 00 00 00
		00 00 00 00 00 00 00 00 00 00 00 00 51 e7 21 53`)
	if !bytes.Equal(walHeader(), want) {
		t.Fatalf("walHeader = %x", walHeader())
	}
}

func TestFirstCommitLogRecords(t *testing.T) {
	out := runScript(t, nil, nil, `put "a" 1`)
	if len(out.LogTWAL) != 2152 {
		t.Fatalf("log is %d bytes, want 2152", len(out.LogTWAL))
	}
	rec := func(off int) []byte { return out.LogTWAL[off : off+24] }
	if !bytes.Equal(rec(32), mustHex(t, "01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 01 00 00 04 00 76 29 2e 36")) {
		t.Errorf("page 1 record header: %x", rec(32))
	}
	if !bytes.Equal(rec(32+1048), mustHex(t, "01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 02 00 00 04 00 76 0d 60 f7")) {
		t.Errorf("page 2 record header: %x", rec(32+1048))
	}
	if !bytes.Equal(rec(32+2096), mustHex(t, "02 00 00 00 00 00 00 00 00 00 00 01 00 00 00 02 00 00 00 00 a8 a0 aa 22")) {
		t.Errorf("commit record: %x", rec(32+2096))
	}
	// Untouched main file: a fresh single page.
	if len(out.DatabaseTDB) != PageSize || binary.BigEndian.Uint32(out.DatabaseTDB[12:]) != 1 {
		t.Errorf("main.tdb should be the fresh page")
	}
}

func TestSpecExample21_2_FreeListReuse(t *testing.T) {
	out := runScript(t, nil, nil,
		`put "k1" "x"`, `put "k2" "y"`, `delete "k1"`, `delete "k2"`, `stat`, `put "k3" "z"`, `stat`)
	want := "[1] ok put created\n[2] ok put created\n[3] ok delete removed\n[4] ok delete removed\n[5] ok stat\n" +
		statBlock(2, 1, 2, 0, 0, 0, 4, 0, 8512) +
		"[6] ok put created\n[7] ok stat\n" + statBlock(2, 0, 0, 1, 2, 1, 5, 0, 10632)
	if string(out.Results) != want {
		t.Fatalf("results:\n%s", out.Results)
	}
}

func TestSpecExample21_3_Overflow(t *testing.T) {
	var nums []string
	for i := 1; i <= 25; i++ {
		nums = append(nums, fmt.Sprint(i))
	}
	list := "[" + strings.Join(nums, ",") + "]"
	out := runScript(t, nil, nil, `put "big" `+list, `stat`, `get "big"`, `delete "big"`, `stat`)
	want := "[1] ok put created\n[2] ok stat\n" + statBlock(3, 0, 0, 1, 3, 1, 1, 0, 3200) +
		"[3] ok get value\n  " + list + "\n[4] ok delete removed\n[5] ok stat\n" + statBlock(3, 2, 3, 0, 0, 0, 2, 0, 6368)
	if string(out.Results) != want {
		t.Fatalf("results:\n%s", out.Results)
	}
}

func TestSpecExample21_4_Transactions(t *testing.T) {
	out := runScript(t, nil, nil, `begin`, `put "a" 1`, `put "b" 2`, `stat`, `rollback`, `stat`,
		`begin`, `put "a" 1`, `commit`, `stat`)
	want := "[1] ok begin\n[2] ok put created\n[3] ok put created\n[4] ok stat\n" + statBlock(2, 0, 0, 2, 2, 1, 0, 0, 32) +
		"[5] ok rollback\n[6] ok stat\n" + statBlock(1, 0, 0, 0, 0, 0, 0, 0, 32) +
		"[7] ok begin\n[8] ok put created\n[9] ok commit 1 frames 2\n[10] ok stat\n" + statBlock(2, 0, 0, 1, 2, 1, 1, 0, 2152)
	if string(out.Results) != want {
		t.Fatalf("results:\n%s", out.Results)
	}
	if len(out.DatabaseTDB) != PageSize {
		t.Errorf("main.tdb should stay one page")
	}
}

func TestSpecExample21_5_Errors(t *testing.T) {
	out := runScript(t, nil, nil, `put "a" 1`, `put "a" 2`, `get "zz"`, `delete "zz"`, `frobnicate`, `put "a"`,
		`put "a" 007`, `put "a" 9223372036854775808`, `put "a" {x:1,x:2}`, `put "\ud800" 1`, `put "" 1`,
		`commit`, `rollback`, `begin`, `begin`, `checkpoint`)
	want := `[1] ok put created
[2] ok put replaced
[3] error not-found
[4] error not-found
[5] error unknown-command
[6] error syntax
[7] error syntax
[8] error int-range
[9] error dup-field
[10] error bad-utf8
[11] error bad-key
[12] error no-txn
[13] error no-txn
[14] ok begin
[15] error txn-active
[16] error txn-active
`
	if string(out.Results) != want {
		t.Fatalf("results:\n%s", out.Results)
	}
	if len(out.LogTWAL) != 32+2*2120 {
		t.Errorf("log is %d bytes", len(out.LogTWAL))
	}
}

func TestSpecExample21_6_Index(t *testing.T) {
	out := runScript(t, nil, nil,
		`put "u1" {name:"ada",age:36}`, `put "u2" {name:"bob",age:29}`, `put "u3" {name:"cy",age:36}`,
		`create index age`, `indexes`, `find age == 36`, `find age > 30`,
		`find age == 36 and name == "cy"`, `find not(age == 36)`, `stat`)
	want := `[1] ok put created
[2] ok put created
[3] ok put created
[4] ok create index age entries 3
[5] ok indexes 1
  0 age root 3 entries 3
[6] ok find 2 plan index age
  "u1" = {"age":36,"name":"ada"}
  "u3" = {"age":36,"name":"cy"}
[7] ok find 2 plan index age
  "u1" = {"age":36,"name":"ada"}
  "u3" = {"age":36,"name":"cy"}
[8] ok find 1 plan index age
  "u3" = {"age":36,"name":"cy"}
[9] ok find 1 plan scan
  "u2" = {"age":29,"name":"bob"}
[10] ok stat
` + statBlock(3, 0, 0, 3, 2, 1, 4, 1, 8512)
	if string(out.Results) != want {
		t.Fatalf("results:\n%s", out.Results)
	}
}

func TestOverflowReplaceReversesChain(t *testing.T) {
	// SPEC §14.3: replacing a 2005-byte document with itself frees the chain
	// first and then reallocates it, so the chain runs 3 -> 2.
	doc := `"` + strings.Repeat("x", 2005-5) + `"`
	out := runScript(t, nil, nil, `put "a" `+doc, `put "a" `+doc, `stat`, `checkpoint`)
	if !strings.Contains(string(out.Results), statBlock(4, 0, 0, 1, 4, 1, 2, 0, 32+4216+4216)) {
		t.Fatalf("results:\n%s", out.Results)
	}
	leaf := out.DatabaseTDB[3*PageSize:]
	n := decodeNode(leaf)
	if n.cells[0].overflow != 3 {
		t.Errorf("leaf overflow = %d, want 3", n.cells[0].overflow)
	}
	if next := binary.BigEndian.Uint32(out.DatabaseTDB[2*PageSize+4:]); next != 2 {
		t.Errorf("page 3 next = %d, want 2", next)
	}
}

func TestExplicitTransactionKeepsOpenOnError(t *testing.T) {
	out := runScript(t, nil, nil, `begin`, `put "a" 1`, `get "nope"`, `commit`, `stat`)
	if !strings.Contains(string(out.Results), "[4] ok commit 1 frames 2\n") {
		t.Fatalf("results:\n%s", out.Results)
	}
}

func TestEmptyScriptAndOutputs(t *testing.T) {
	out := RunScript(nil, nil, nil)
	if len(out.Results) != 0 || len(out.DatabaseTDB) != PageSize || !bytes.Equal(out.LogTWAL, walHeader()) {
		t.Fatal("empty script outputs wrong")
	}
	out = RunScript(nil, nil, []byte("stat\n\n"))
	if !strings.HasPrefix(string(out.Results), "[1] ok stat\n") || !strings.HasSuffix(string(out.Results), "[2] error syntax\n") {
		t.Fatalf("results:\n%s", out.Results)
	}
	if got := splitLines([]byte("a\nb")); len(got) != 2 {
		t.Errorf("split without trailing LF: %d", len(got))
	}
}

func TestScanOptions(t *testing.T) {
	setup := []string{}
	for _, k := range []string{"a", "b", "c", "d", "e"} {
		setup = append(setup, fmt.Sprintf(`put %q %d`, k, k[0]-'a'))
	}
	run := func(cmd string) string {
		out := runScript(t, nil, nil, append(append([]string{}, setup...), cmd)...)
		lines := strings.Split(string(out.Results), "\n")
		return strings.Join(lines[5:], "|")
	}
	tests := map[string]string{
		`scan keys`:                         `[6] ok scan 5|  "a"|  "b"|  "c"|  "d"|  "e"|`,
		`scan from "b" to "d" keys`:         `[6] ok scan 2|  "b"|  "c"|`,
		`scan limit 2 reverse keys`:         `[6] ok scan 2|  "e"|  "d"|`,
		`scan reverse from "b" to "d" keys`: `[6] ok scan 2|  "c"|  "b"|`,
		`scan from "d" to "b" keys`:         `[6] ok scan 0|`,
		`scan limit 0`:                      `[6] ok scan 0|`,
		`scan from "" keys limit 1`:         `[6] ok scan 1|  "a"|`,
		`scan to "" keys`:                   `[6] ok scan 0|`,
		`scan from "c" limit 1`:             `[6] ok scan 1|  "c" = 2|`,
		`scan reverse to "a" keys`:          `[6] ok scan 0|`,
		`scan reverse from "zzz" keys`:      `[6] ok scan 0|`,
	}
	for cmd, want := range tests {
		if got := run(cmd); got != want {
			t.Errorf("%s:\n got %s\nwant %s", cmd, got, want)
		}
	}
}

func TestPredicateSemantics(t *testing.T) {
	setup := []string{
		`put "1" {a:1,s:"x"}`, `put "2" {a:"1"}`, `put "3" {b:null}`, `put "4" {a:[1]}`, `put "5" 7`,
		`put "6" {a:{b:2}}`, `put "7" {a:null}`, `put "8" {a:true}`,
	}
	find := func(pred string) string {
		out := runScript(t, nil, nil, append(append([]string{}, setup...), "find "+pred)...)
		lines := strings.Split(string(out.Results), "\n")
		var keys []string
		for _, l := range lines[len(setup)+1:] {
			if i := strings.Index(l, " = "); i > 0 {
				keys = append(keys, strings.Trim(l[:i], ` "`))
			}
		}
		return strings.Join(keys, ",")
	}
	tests := map[string]string{
		`a == 1`:                              "1",
		`a != 1`:                              "2,4,6,7,8",
		`not(a == 1)`:                         "2,3,4,5,6,7,8",
		`a < 5`:                               "1",
		`a >= "0"`:                            "2",
		`a == null`:                           "7",
		`a <= null`:                           "7",
		`a > null`:                            "",
		`a >= true`:                           "8",
		`a == [1]`:                            "4",
		`a < [2]`:                             "",
		`a.b == 2`:                            "6",
		`exists a.b`:                          "6",
		`missing a`:                           "3,5",
		`exists b and a == null`:              "",
		`a == 1 or a == "1"`:                  "1,2",
		`(a == 1 or b == null) and missing s`: "3",
		`a == {b:2}`:                          "6",
		`exists a limit 2`:                    "1,2",
	}
	for pred, want := range tests {
		if got := find(pred); got != want {
			t.Errorf("find %s: got %q, want %q", pred, got, want)
		}
	}
}

func TestPlanSelection(t *testing.T) {
	db := Open(nil, nil)
	for _, l := range []string{`create index b`, `create index a`, `create index c.d`} {
		if r := db.Exec(l); !strings.HasPrefix(r.Status, "ok") {
			t.Fatal(r.Status)
		}
	}
	plan := func(pred string) string {
		cmd, err := ParseCommand("find " + pred)
		if err != nil {
			t.Fatal(err)
		}
		return db.Plan(cmd.Pred)
	}
	tests := map[string]string{
		`x == 1`:                            "scan",
		`a != 1`:                            "scan",
		`a == [1]`:                          "scan",
		`a == {}`:                           "scan",
		`not(a == 1)`:                       "scan",
		`a == 1 or b == 1`:                  "scan",
		`b == 1 and a == 1`:                 "index a",
		`b < 1 and a == 1`:                  "index a",
		`b == 1 and a > 1`:                  "index b",
		`b > 1 and a > 1`:                   "index a",
		`(a > 1 and (c.d == 2 and b == 3))`: "index b",
		`a > 1 and a < 5`:                   "index a",
		`c . d >= "x"`:                      "index c.d",
	}
	for pred, want := range tests {
		if got := plan(pred); got != want {
			t.Errorf("plan(%s) = %s, want %s", pred, got, want)
		}
	}
}

func TestIndexLifecycle(t *testing.T) {
	out := runScript(t, nil, nil,
		`put "u1" {a:1}`, `put "u2" {a:"s"}`, `put "u3" {a:[1]}`, `put "u4" {b:1}`, `put "u5" {a:null}`,
		`create index a`, `create index a`, `create index b`, `drop index zzz`,
		`indexes`, `update "u4" a 5`, `unset "u1" a`, `delete "u2"`, `put "u5" {a:false}`, `indexes`,
		`drop index a`, `create index c`, `indexes`)
	want := `[1] ok put created
[2] ok put created
[3] ok put created
[4] ok put created
[5] ok put created
[6] ok create index a entries 3
[7] error index-exists
[8] ok create index b entries 1
[9] error index-missing
[10] ok indexes 2
  0 a root 3 entries 3
  1 b root 4 entries 1
[11] ok update updated
[12] ok unset updated
[13] ok delete removed
[14] ok put replaced
[15] ok indexes 2
  0 a root 3 entries 2
  1 b root 4 entries 1
[16] ok drop index a pages 1
[17] ok create index c entries 0
[18] ok indexes 2
  0 c root 0 entries 0
  1 b root 4 entries 1
`
	if string(out.Results) != want {
		t.Fatalf("results:\n%s", out.Results)
	}
}

func TestIndexLimits(t *testing.T) {
	long := strings.Repeat("x", 126)
	out := runScript(t, nil, nil,
		`put "k" {s:"`+long+`"}`, `create index s`, `put "k" {s:"short"}`, `create index s`,
		`put "kk" {s:"`+long+`"}`, `put "k" {t:"`+long+`"}`, `put "kk" {s:[1]}`, `put "k" {s:"`+long[:125]+`"}`)
	want := "[1] ok put created\n[2] error index-key-too-long\n[3] ok put replaced\n[4] ok create index s entries 1\n" +
		"[5] error index-key-too-long\n[6] ok put replaced\n[7] ok put created\n[8] error index-key-too-long\n"
	if string(out.Results) != want {
		t.Fatalf("results:\n%s", out.Results)
	}
	var lines []string
	for i := 0; i < 16; i++ {
		lines = append(lines, fmt.Sprintf("create index f%d", i))
	}
	lines = append(lines, `create index g`, `put "q" {f0:"`+long+`"}`)
	out = runScript(t, nil, nil, lines...)
	if !strings.Contains(string(out.Results), "[17] error index-limit\n[18] error index-key-too-long\n") {
		t.Fatalf("results: %s", out.Results)
	}
	// A failed command leaves no trace: sixteen single-frame commits only.
	if len(out.LogTWAL) != 32+16*(1048+24) {
		t.Errorf("log size %d", len(out.LogTWAL))
	}
}

func TestUpdateUnsetErrors(t *testing.T) {
	out := runScript(t, nil, nil, `put "a" {x:1}`, `put "s" 5`,
		`update "zz" a 1`, `update "s" a 1`, `update "a" x.y 1`, `update "a" n.m.o 1`, `get "a"`,
		`unset "zz" a`, `unset "s" a`, `unset "a" q`, `unset "a" x.y`, `unset "a" x`, `get "a"`)
	want := `[1] ok put created
[2] ok put created
[3] error not-found
[4] error not-object
[5] error not-object
[6] ok update updated
[7] ok get value
  {"n":{"m":{"o":1}},"x":1}
[8] error not-found
[9] error not-object
[10] error no-field
[11] error not-object
[12] ok unset updated
[13] ok get value
  {"n":{"m":{"o":1}}}
`
	if string(out.Results) != want {
		t.Fatalf("results:\n%s", out.Results)
	}
	// depth and size on update
	deep := strings.Repeat("[", 32) + strings.Repeat("]", 32)
	out = runScript(t, nil, nil, `put "a" {}`, `update "a" x `+deep, `update "a" x.y.z 1`,
		`put "b" "`+strings.Repeat("z", 65536)+`"`, `put "b" "`+strings.Repeat("z", 65531)+`"`)
	got := string(out.Results)
	if !strings.Contains(got, "[2] error depth\n[3] ok update updated\n[4] error doc-too-large\n[5] ok put created\n") {
		t.Fatalf("results:\n%s", got)
	}
}

// ---------------------------------------------------------------------------
// Recovery

func buildLog(t *testing.T, lines ...string) (Output, []byte) {
	out := runScript(t, nil, nil, lines...)
	return out, out.LogTWAL
}

func TestRecoveryEveryCutPoint(t *testing.T) {
	full, log := buildLog(t, `put "a" 1`, `put "b" 2`, `put "c" 3`)
	_ = full
	// ends of commits are at these offsets
	commitEnds := map[int]int{32: 0, 32 + 2120: 1, 32 + 2*2120: 2, 32 + 3*2120: 3}
	for cut := 0; cut <= len(log); cut++ {
		want := 0
		for end, n := range commitEnds {
			if cut >= end && n > want {
				want = n
			}
		}
		out := RunScript(nil, log[:cut], []byte("stat\n"))
		wantWAL := 32 + want*2120
		s := string(out.Results)
		if !strings.Contains(s, fmt.Sprintf("  docs %d\n", want)) || !strings.Contains(s, fmt.Sprintf("  wal %d\n", wantWAL)) {
			t.Fatalf("cut %d: want %d docs\n%s", cut, want, s)
		}
		if len(out.LogTWAL) != wantWAL && !(cut < 32 && len(out.LogTWAL) == 32) {
			t.Fatalf("cut %d: log length %d, want %d", cut, len(out.LogTWAL), wantWAL)
		}
		if !bytes.Equal(out.DatabaseTDB, freshPage()) {
			t.Fatalf("cut %d: recovery must not modify main.tdb", cut)
		}
	}
}

func freshPage() []byte {
	h := freshHeader()
	return h.encode()
}

func TestRecoveryRejectsDamage(t *testing.T) {
	_, log := buildLog(t, `put "a" 1`, `put "b" 2`)
	mutate := func(name string, f func(b []byte) []byte, wantDocs int) {
		t.Helper()
		b := f(append([]byte(nil), log...))
		out := RunScript(nil, b, []byte("stat\n"))
		if !strings.Contains(string(out.Results), fmt.Sprintf("  docs %d\n", wantDocs)) {
			t.Errorf("%s: results\n%s", name, out.Results)
		}
	}
	mutate("bad magic", func(b []byte) []byte { b[0] = 'X'; return b }, 0)
	mutate("bad reserved", func(b []byte) []byte { b[20] = 1; return b }, 0)
	mutate("bad header crc", func(b []byte) []byte { b[31] ^= 1; return b }, 0)
	mutate("empty", func(b []byte) []byte { return nil }, 0)
	mutate("flip payload bit of 2nd txn", func(b []byte) []byte { b[32+2120+100] ^= 1; return b }, 1)
	mutate("nonzero pad byte", func(b []byte) []byte { b[32+2120+1] = 1; return b }, 1)
	mutate("trailing zeroes", func(b []byte) []byte { return append(b, make([]byte, 100)...) }, 2)
	mutate("txn id mismatch", func(b []byte) []byte {
		// rewrite the second commit record with a different txn id and valid CRC
		off := len(b) - 24
		rec := appendRecord(nil, 2, 99, 2, nil)
		copy(b[off:], rec)
		return b
	}, 1)
	mutate("wrong frame count", func(b []byte) []byte {
		off := len(b) - 24
		rec := appendRecord(nil, 2, 2, 3, nil)
		copy(b[off:], rec)
		return b
	}, 1)
	mutate("zero frame count", func(b []byte) []byte {
		off := len(b) - 24
		rec := appendRecord(nil, 2, 2, 0, nil)
		copy(b[off:], rec)
		return b
	}, 1)
}

func TestRecoveryThenWriteAppendsAtValidEnd(t *testing.T) {
	_, log := buildLog(t, `put "a" 1`, `put "b" 2`)
	cut := log[:len(log)-5]
	out := RunScript(nil, cut, []byte("put \"z\" 1\nstat\n"))
	if !strings.Contains(string(out.Results), "  docs 2\n") {
		t.Fatalf("results:\n%s", out.Results)
	}
	if len(out.LogTWAL) != 32+2*2120 {
		t.Fatalf("log length %d", len(out.LogTWAL))
	}
	if !bytes.Equal(out.LogTWAL[:32+2120], log[:32+2120]) {
		t.Fatal("recovered prefix changed")
	}
}

func TestRecoveryPlusCheckpointMatchesDirectRun(t *testing.T) {
	script := []string{`put "a" {n:1}`, `put "b" {n:2}`, `delete "a"`}
	direct := runScript(t, nil, nil, append(append([]string{}, script...), `checkpoint`)...)
	first := runScript(t, nil, nil, script...)
	again := RunScript(first.DatabaseTDB, first.LogTWAL, []byte("checkpoint\n"))
	if !bytes.Equal(direct.DatabaseTDB, again.DatabaseTDB) || !bytes.Equal(direct.LogTWAL, again.LogTWAL) {
		t.Fatal("restart + checkpoint differs from direct run")
	}
}

func TestAutoCheckpoint(t *testing.T) {
	// Each put of a fresh key to a one-leaf tree writes pages 1 and 2:
	// 2120 bytes. 32 + 123*2120 = 260792 < 262144 <= 32 + 124*2120 = 262912.
	var lines []string
	for i := 0; i < 123; i++ {
		lines = append(lines, `put "k" `+fmt.Sprint(i))
	}
	lines = append(lines, `stat`, `put "k" 0`, `stat`)
	out := runScript(t, nil, nil, lines...)
	s := string(out.Results)
	if !strings.Contains(s, "  wal 260792\n") || !strings.Contains(s, "  wal 32\n") {
		t.Fatalf("expected a checkpoint at the 124th commit:\n%s", s[len(s)-400:])
	}
	if len(out.DatabaseTDB) != 2*PageSize {
		t.Errorf("main.tdb length %d", len(out.DatabaseTDB))
	}
}

func TestCheckpointInTxnAndEmpty(t *testing.T) {
	out := runScript(t, nil, nil, `checkpoint`, `begin`, `checkpoint`)
	if string(out.Results) != "[1] ok checkpoint pages 0\n[2] ok begin\n[3] error txn-active\n" {
		t.Fatalf("results:\n%s", out.Results)
	}
}

// ---------------------------------------------------------------------------
// Randomised structural test against a reference model

// checkTree verifies the structural invariants of a tree and returns its cells
// in key order.
func (db *DB) checkTree(t *testing.T, tr tree) [][]byte {
	t.Helper()
	root := tr.root()
	if root == 0 {
		return nil
	}
	var keys [][]byte
	leafDepth := -1
	var leaves []uint32
	var visit func(pg uint32, depth int, lo, hi []byte)
	visit = func(pg uint32, depth int, lo, hi []byte) {
		n := db.readNode(pg)
		if pg != root && len(n.cells) == 0 && n.typ != typeInterior {
			t.Fatalf("empty non-root leaf %d", pg)
		}
		if n.used() > Capacity {
			t.Fatalf("page %d overfull", pg)
		}
		if !bytes.Equal(db.readPage(pg), n.encode()) {
			t.Fatalf("page %d not canonical", pg)
		}
		for i := range n.cells {
			k := n.cells[i].key
			if lo != nil && bytes.Compare(k, lo) <= 0 || hi != nil && bytes.Compare(k, hi) > 0 {
				t.Fatalf("page %d key %q outside (%q,%q]", pg, k, lo, hi)
			}
			if i > 0 && bytes.Compare(n.cells[i-1].key, k) >= 0 {
				t.Fatalf("page %d keys not ascending", pg)
			}
		}
		if n.typ != typeInterior {
			if leafDepth >= 0 && leafDepth != depth {
				t.Fatalf("leaves at different depths")
			}
			leafDepth = depth
			leaves = append(leaves, pg)
			for i := range n.cells {
				keys = append(keys, n.cells[i].key)
			}
			return
		}
		prev := lo
		for i := range n.cells {
			visit(n.cells[i].child, depth+1, prev, n.cells[i].key)
			prev = n.cells[i].key
		}
		visit(n.link, depth+1, prev, hi)
	}
	visit(root, 0, nil, nil)
	for i, pg := range leaves {
		want := uint32(0)
		if i+1 < len(leaves) {
			want = leaves[i+1]
		}
		if got := db.readNode(pg).link; got != want {
			t.Fatalf("leaf %d link = %d, want %d", pg, got, want)
		}
	}
	return keys
}

func (db *DB) checkFreeList(t *testing.T) {
	t.Helper()
	n := uint32(0)
	for p := db.hdr.freeHead; p != 0; p = binary.BigEndian.Uint32(db.readPage(p)[4:]) {
		n++
		if n > db.hdr.pageCount {
			t.Fatal("free list loops")
		}
		if db.readPage(p)[0] != typeFree {
			t.Fatalf("page %d on free list is not free", p)
		}
	}
	if n != db.hdr.freeCount {
		t.Fatalf("free list has %d pages, header says %d", n, db.hdr.freeCount)
	}
}

// reachable counts the pages reachable from the header plus the free list and
// checks they account for every page.
func (db *DB) checkPageAccounting(t *testing.T) {
	t.Helper()
	seen := map[uint32]bool{1: true}
	mark := func(p uint32) {
		if seen[p] {
			t.Fatalf("page %d referenced twice", p)
		}
		seen[p] = true
	}
	var walk func(pg uint32, leafType byte)
	walk = func(pg uint32, leafType byte) {
		mark(pg)
		n := db.readNode(pg)
		if n.typ == typeInterior {
			for i := range n.cells {
				walk(n.cells[i].child, leafType)
			}
			walk(n.link, leafType)
		} else if n.typ == typeLeaf {
			for i := range n.cells {
				for p := n.cells[i].overflow; p != 0; p = binary.BigEndian.Uint32(db.readPage(p)[4:]) {
					mark(p)
				}
			}
		}
	}
	if r := db.hdr.primaryRoot; r != 0 {
		walk(r, typeLeaf)
	}
	for i := range db.hdr.slots {
		if s := &db.hdr.slots[i]; s.live && s.root != 0 {
			walk(s.root, typeIndexLf)
		}
	}
	for p := db.hdr.freeHead; p != 0; p = binary.BigEndian.Uint32(db.readPage(p)[4:]) {
		mark(p)
	}
	if uint32(len(seen)) != db.hdr.pageCount {
		t.Fatalf("%d pages accounted for, page_count is %d", len(seen), db.hdr.pageCount)
	}
}

func TestRandomOperationsAgainstModel(t *testing.T) {
	for seed := int64(1); seed <= 6; seed++ {
		rng := rand.New(rand.NewSource(seed))
		db := Open(nil, nil)
		model := map[string]string{}
		if r := db.Exec(`create index n`); r.Status != "ok create index n entries 0" {
			t.Fatal(r.Status)
		}
		keyOf := func() string {
			return fmt.Sprintf("key-%0*d", 1+rng.Intn(60), rng.Intn(400))
		}
		for step := 0; step < 1500; step++ {
			k := keyOf()
			switch op := rng.Intn(10); {
			case op < 5:
				body := strings.Repeat("v", rng.Intn(500)*rng.Intn(3))
				doc := fmt.Sprintf(`{n:%d,s:"%s"}`, rng.Intn(50), body)
				if r := db.Exec(fmt.Sprintf(`put %q %s`, k, doc)); !strings.HasPrefix(r.Status, "ok put") {
					t.Fatal(r.Status)
				}
				got := db.Exec(fmt.Sprintf(`get %q`, k))
				model[k] = string(got.Lines[0])
			case op < 8:
				_, present := model[k]
				r := db.Exec(fmt.Sprintf(`delete %q`, k))
				if present != (r.Status == "ok delete removed") {
					t.Fatalf("delete %q: %s, present=%v", k, r.Status, present)
				}
				delete(model, k)
			case op < 9:
				db.Exec(fmt.Sprintf(`update %q n %d`, k, rng.Intn(50)))
				if _, ok := model[k]; ok {
					model[k] = string(db.Exec(fmt.Sprintf(`get %q`, k)).Lines[0])
				}
			default:
				db.Exec(fmt.Sprintf(`unset %q n`, k))
				if _, ok := model[k]; ok {
					model[k] = string(db.Exec(fmt.Sprintf(`get %q`, k)).Lines[0])
				}
			}
			if step%100 == 99 {
				checkAgainstModel(t, db, model)
			}
		}
		checkAgainstModel(t, db, model)
		// wipe everything
		for k := range model {
			if r := db.Exec(fmt.Sprintf(`delete %q`, k)); r.Status != "ok delete removed" {
				t.Fatal(r.Status)
			}
		}
		if s := db.Stat(); s.Docs != 0 || s.Root != 0 || db.hdr.slots[0].root != 0 || db.hdr.slots[0].entries != 0 {
			t.Fatalf("seed %d: store not empty after wipe: %+v", seed, s)
		}
		db.checkFreeList(t)
		db.checkPageAccounting(t)
		if int(db.hdr.freeCount) != int(db.hdr.pageCount)-1 {
			t.Fatalf("seed %d: all pages should be free", seed)
		}
	}
}

func checkAgainstModel(t *testing.T, db *DB, model map[string]string) {
	t.Helper()
	keys := db.checkTree(t, db.primary())
	db.checkFreeList(t)
	db.checkPageAccounting(t)
	var want []string
	for k := range model {
		want = append(want, k)
	}
	sort.Strings(want)
	if len(keys) != len(want) || int(db.hdr.primaryCount) != len(want) {
		t.Fatalf("tree holds %d keys, model %d, header %d", len(keys), len(want), db.hdr.primaryCount)
	}
	for i := range keys {
		if string(keys[i]) != want[i] {
			t.Fatalf("key %d: %q vs %q", i, keys[i], want[i])
		}
	}
	for _, k := range want {
		r := db.Exec(fmt.Sprintf(`get %q`, k))
		if string(r.Lines[0]) != model[k] {
			t.Fatalf("get %q = %s, want %s", k, r.Lines[0], model[k])
		}
	}
	// reverse scan equals reversed forward scan
	fwd := db.Scan(ScanOptions{KeysOnly: true})
	rev := db.Scan(ScanOptions{KeysOnly: true, Reverse: true})
	if len(fwd) != len(rev) {
		t.Fatal("scan lengths differ")
	}
	for i := range fwd {
		if !bytes.Equal(fwd[i].Key, rev[len(rev)-1-i].Key) {
			t.Fatal("reverse scan is not the mirror of the forward scan")
		}
	}
	// the index must agree with a scan of the documents
	idxKeys := db.checkTree(t, db.indexTree(0))
	n := 0
	for _, k := range want {
		doc, _ := db.Get([]byte(k))
		if _, ok := doc.Lookup([]string{"n"}); ok {
			n++
		}
	}
	if len(idxKeys) != n || int(db.hdr.slots[0].entries) != n {
		t.Fatalf("index has %d entries (header %d), want %d", len(idxKeys), db.hdr.slots[0].entries, n)
	}
	// index plan and scan plan give the same answer
	for _, op := range []string{"==", "<", "<=", ">", ">="} {
		a, planA := db.Find(mustPred(t, "n "+op+" 20"), -1)
		if planA != "index n" {
			t.Fatalf("plan = %s", planA)
		}
		b, planB := db.Find(mustPred(t, "n "+op+" 20 and (exists n or exists n)"), -1)
		_ = planB
		c := scanFind(db, mustPred(t, "n "+op+" 20"))
		if len(a) != len(c) || len(b) != len(c) {
			t.Fatalf("op %s: index %d, scan %d", op, len(a), len(c))
		}
		for i := range a {
			if !bytes.Equal(a[i].Key, c[i].Key) {
				t.Fatalf("op %s: result %d differs", op, i)
			}
		}
	}
}

func mustPred(t *testing.T, s string) *Predicate {
	t.Helper()
	cmd, err := ParseCommand("find " + s)
	if err != nil {
		t.Fatal(err)
	}
	return cmd.Pred
}

// scanFind evaluates a predicate by brute force.
func scanFind(db *DB, p *Predicate) []Entry {
	var out []Entry
	for _, e := range db.Scan(ScanOptions{}) {
		if p.Eval(e.Doc) {
			out = append(out, e)
		}
	}
	return out
}

func TestLargeSequentialInsertAndDelete(t *testing.T) {
	// Ascending inserts, then deletes in several orders, checking invariants.
	for _, order := range []string{"asc", "desc", "mixed"} {
		db := Open(nil, nil)
		const n = 3000
		keys := make([]string, n)
		for i := range keys {
			keys[i] = fmt.Sprintf("k%06d", i)
			if _, err := db.Put([]byte(keys[i]), mustDoc(i)); err != nil {
				t.Fatal(err)
			}
		}
		db.checkTree(t, db.primary())
		if h := db.Stat().Height; h < 3 {
			t.Fatalf("expected height >= 3, got %d", h)
		}
		switch order {
		case "desc":
			for i, j := 0, n-1; i < j; i, j = i+1, j-1 {
				keys[i], keys[j] = keys[j], keys[i]
			}
		case "mixed":
			rand.New(rand.NewSource(7)).Shuffle(n, func(i, j int) { keys[i], keys[j] = keys[j], keys[i] })
		}
		for i, k := range keys {
			if err := db.Delete([]byte(k)); err != nil {
				t.Fatal(err)
			}
			if i%500 == 0 {
				db.checkTree(t, db.primary())
				db.checkPageAccounting(t)
			}
		}
		if s := db.Stat(); s.Docs != 0 || s.Root != 0 || s.Height != 0 {
			t.Fatalf("%s: %+v", order, s)
		}
		db.checkFreeList(t)
	}
}

func TestRollbackRestoresEverything(t *testing.T) {
	db := Open(nil, nil)
	for i := 0; i < 200; i++ {
		db.Put([]byte(fmt.Sprintf("k%04d", i)), mustDoc(i))
	}
	before := db.hdr
	logBefore := len(db.wal)
	if err := db.Begin(); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 200; i += 2 {
		db.Delete([]byte(fmt.Sprintf("k%04d", i)))
	}
	for i := 0; i < 300; i++ {
		db.Put([]byte(fmt.Sprintf("z%04d", i)), mustDoc(i))
	}
	if err := db.Rollback(); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(db.hdr, before) || len(db.wal) != logBefore {
		t.Fatal("rollback did not restore the header / log")
	}
	db.checkTree(t, db.primary())
	db.checkPageAccounting(t)
	if got := db.Stat().Docs; got != 200 {
		t.Fatalf("docs = %d", got)
	}
}

func TestMainFileUntouchedUntilCheckpoint(t *testing.T) {
	out1 := runScript(t, nil, nil, `put "a" 1`, `checkpoint`, `put "b" 2`)
	out2 := RunScript(out1.DatabaseTDB, out1.LogTWAL, []byte("scan\n"))
	if !bytes.Equal(out2.DatabaseTDB, out1.DatabaseTDB) {
		t.Fatal("main.tdb changed without a checkpoint")
	}
	if !bytes.Equal(out2.LogTWAL, out1.LogTWAL) {
		t.Fatal("log changed by a read-only script")
	}
	want := "[1] ok scan 2\n  \"a\" = 1\n  \"b\" = 2\n"
	if string(out2.Results) != want {
		t.Fatalf("results:\n%s", out2.Results)
	}
}

func TestCRCOfRecords(t *testing.T) {
	rec := appendRecord(nil, 2, 1, 2, nil)
	if got := binary.BigEndian.Uint32(rec[20:]); got != crc.Checksum(rec[:20]) {
		t.Fatal("record crc mismatch")
	}
}
