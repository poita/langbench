package syntax

// Stmt is a parsed SQL statement: one of *CreateTable, *Insert, *Delete,
// *Update or *Select.
type Stmt interface{ isStmt() }

// CreateTable is CREATE TABLE name (col type, ...).
type CreateTable struct {
	Name    string
	Columns []ColumnDef
}

// ColumnDef declares one column. Type is "INTEGER" or "TEXT".
type ColumnDef struct {
	Name string
	Type string
}

// Insert is INSERT INTO name VALUES (...), (...).
type Insert struct {
	Table string
	Rows  [][]*Expr
}

// Delete is DELETE FROM name [WHERE expr].
type Delete struct {
	Table string
	Where *Expr // nil if absent
}

// Assignment is one "column = expr" in an UPDATE.
type Assignment struct {
	Column string
	Value  *Expr
}

// Update is UPDATE name SET ... [WHERE expr].
type Update struct {
	Table string
	Set   []Assignment
	Where *Expr // nil if absent
}

// SelectItem is one entry of a select list: either "*" or an expression
// with an optional alias.
type SelectItem struct {
	Star  bool
	Expr  *Expr
	Alias string // "" if none
}

// TableRef is a table in the FROM clause with an optional alias.
type TableRef struct {
	Name  string
	Alias string // "" if none
}

// OrderTerm is one ORDER BY term.
type OrderTerm struct {
	Expr *Expr
	Desc bool
}

// Select is a SELECT statement. A comma join and an INNER JOIN are both
// represented by two entries in From; the ON expression is kept in On.
type Select struct {
	Items   []SelectItem
	From    []TableRef // zero, one or two entries
	On      *Expr      // nil if absent
	Where   *Expr      // nil if absent
	GroupBy []*Expr    // column references only
	Having  *Expr      // nil if absent
	OrderBy []OrderTerm
	Limit   *int64 // nil if absent
	Offset  *int64 // nil if absent
}

func (*CreateTable) isStmt() {}
func (*Insert) isStmt()      {}
func (*Delete) isStmt()      {}
func (*Update) isStmt()      {}
func (*Select) isStmt()      {}

// ExprKind classifies an Expr.
type ExprKind uint8

// Expression kinds.
const (
	ExprInt    ExprKind = iota // Int
	ExprString                 // Str
	ExprNull
	ExprColumn // Qual (may be empty) and Name
	ExprNeg    // unary minus: Left
	ExprNot    // NOT: Left
	ExprBinary // Op, Left, Right
	ExprIsNull // Left IS [NOT] NULL; Negated for IS NOT NULL
	ExprLike   // Left LIKE Right
	ExprAgg    // Func, Left (nil for COUNT(*))
	ExprParen  // parenthesised expression: Left
)

// Expr is an expression tree node. Which fields are meaningful depends on
// Kind; see ExprKind.
type Expr struct {
	Kind    ExprKind
	Int     int64
	Str     string
	Qual    string // table qualifier of a column reference, "" if bare
	Name    string // column name
	Op      string // binary operator: + - * / % = != < <= > >= AND OR
	Func    string // aggregate function name, upper case
	Negated bool   // IS NOT NULL
	Left    *Expr
	Right   *Expr
}
