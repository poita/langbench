/// @file ast.hpp
/// @brief Syntax tree produced by the parser.
///
/// Column references and aggregates carry fields that the binder fills in
/// (`table`, `column`, `agg_index`) just before execution.
#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "minisql/value.hpp"

namespace minisql {

enum class ExprKind { Literal, Column, Unary, Binary, IsNull, Like, Aggregate };
enum class UnaryOp { Negate, Not };
enum class BinaryOp { Or, And, Eq, Ne, Lt, Le, Gt, Ge, Add, Sub, Mul, Div, Mod };
enum class AggFunc { Count, Sum, Min, Max, Avg };

struct Expr {
  ExprKind kind = ExprKind::Literal;

  Value literal;                 ///< Literal
  std::string qualifier;         ///< Column: table name/alias, or empty
  std::string name;              ///< Column: column name
  UnaryOp unary_op = UnaryOp::Negate;
  BinaryOp binary_op = BinaryOp::Add;
  AggFunc func = AggFunc::Count;
  bool negated = false;          ///< IsNull: IS NOT NULL; Like: NOT LIKE
  bool star = false;             ///< Aggregate: COUNT(*)
  std::unique_ptr<Expr> lhs;     ///< operand / left side / aggregate argument
  std::unique_ptr<Expr> rhs;     ///< right side / LIKE pattern

  // Filled in by the binder.
  int table = -1;                ///< Column: index into the FROM list
  int column = -1;               ///< Column: index into the table's columns
  int agg_index = -1;            ///< Aggregate: slot in the group's results
};

using ExprPtr = std::unique_ptr<Expr>;

struct CreateTableStmt {
  std::string table;
  std::vector<std::string> columns;
};

struct InsertStmt {
  std::string table;
  std::vector<std::vector<ExprPtr>> rows;
};

struct DeleteStmt {
  std::string table;
  ExprPtr where;
};

struct UpdateStmt {
  std::string table;
  std::vector<std::pair<std::string, ExprPtr>> assignments;
  ExprPtr where;
};

struct SelectItem {
  bool star = false;
  ExprPtr expr;
  std::string alias;  ///< empty if none
};

struct TableRef {
  std::string name;
  std::string alias;  ///< empty if none
  const std::string& effective_name() const {
    return alias.empty() ? name : alias;
  }
};

struct OrderTerm {
  ExprPtr expr;
  bool descending = false;
  /// Set when the whole term is one bare identifier (possible alias).
  std::string bare_identifier;
  /// Set when the whole term is one bare integer literal (an ordinal).
  std::optional<std::int64_t> ordinal;
};

struct SelectStmt {
  std::vector<SelectItem> items;
  std::vector<TableRef> from;  ///< 0, 1 or 2 entries
  ExprPtr join_on;             ///< ON expression of an INNER JOIN
  ExprPtr where;
  std::vector<std::unique_ptr<Expr>> group_by;  ///< Column expressions
  ExprPtr having;
  std::vector<OrderTerm> order_by;
  std::optional<std::int64_t> limit;
  std::optional<std::int64_t> offset;
};

using Statement = std::variant<CreateTableStmt, InsertStmt, DeleteStmt,
                               UpdateStmt, SelectStmt>;

}  // namespace minisql
