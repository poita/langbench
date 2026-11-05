package bytecode

import "testing"

func TestOpNames(t *testing.T) {
	if PushConst.String() != "PUSH_CONST" || IncLocal.String() != "INC_LOCAL" {
		t.Fatalf("unexpected mnemonics: %s %s", PushConst, IncLocal)
	}
	if int(IncLocal)+1 != len(opNames) {
		t.Fatalf("opNames out of sync with opcodes: %d names, last opcode %d", len(opNames), IncLocal)
	}
}
