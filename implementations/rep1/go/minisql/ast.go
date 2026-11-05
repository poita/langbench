package minisql

// The parsed (unbound) form of a statement.

type exprKind uint8

const (
	eInt exprKind = iota
	eStr
	eNull
	eCol
	eNeg
	eNot
	eBin // binary operator in op: + - * / % = != < <= > >= and or
	eIsNull
	eLike
	eAgg
)

type expr struct {
	kind       exprKind
	op         string
	l, r       *expr
	ival       int64
	sval       string
	qual, name string // eCol; qual may be empty
	neg        bool   // eIsNull: IS NOT NULL; eLike: NOT LIKE
	fn         string // eAgg: count sum min max avg
	star       bool   // eAgg: COUNT(*)
	arg        *expr  // eAgg
}

type colDef struct {
	name string
	typ  string
}

type createStmt struct {
	name string
	cols []colDef
}

type insertStmt struct {
	table string
	rows  [][]*expr
}

type deleteStmt struct {
	table string
	where *expr
}

type assignment struct {
	col string
	e   *expr
}

type updateStmt struct {
	table string
	sets  []assignment
	where *expr
}

type selItem struct {
	star  bool
	e     *expr
	alias string
}

type tableRef struct {
	name  string
	alias string
}

func (t tableRef) effective() string {
	if t.alias != "" {
		return t.alias
	}
	return t.name
}

type colRef struct{ qual, name string }

// orderTerm is one ORDER BY term. When the term is a single integer token,
// ordinal is set; when it is a single identifier token, ident is set.
type orderTerm struct {
	e       *expr
	desc    bool
	ordinal bool
	ival    int64
	ident   string
}

type selectStmt struct {
	items   []selItem
	from    []tableRef
	on      *expr
	where   *expr
	groupBy []colRef
	having  *expr
	order   []orderTerm
	limit   int64 // -1 when absent
	offset  int64
}
