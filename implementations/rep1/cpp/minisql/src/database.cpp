#include "minisql/database.hpp"

#include <ostream>
#include <sstream>

#include "internal.hpp"
#include "minisql/lexer.hpp"
#include "minisql/parser.hpp"

namespace minisql {

namespace {

std::string lower(std::string_view s) {
  std::string r(s);
  for (char& c : r) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
  }
  return r;
}

}  // namespace

ExecResult Database::execute(std::string_view sql) {
  Statement st = parse_statement(sql);
  return execute(st);
}

ExecResult Database::execute(Statement& statement) {
  ExecResult result;
  if (auto* s = std::get_if<SelectStmt>(&statement)) {
    result = detail::execute_select(tables_, *s);
    result.is_query = true;
  } else if (auto* s = std::get_if<CreateTableStmt>(&statement)) {
    detail::execute_create(tables_, *s);
  } else if (auto* s = std::get_if<InsertStmt>(&statement)) {
    detail::execute_insert(tables_, *s);
  } else if (auto* s = std::get_if<UpdateStmt>(&statement)) {
    detail::execute_update(tables_, *s);
  } else if (auto* s = std::get_if<DeleteStmt>(&statement)) {
    detail::execute_delete(tables_, *s);
  }
  return result;
}

void Database::run_script(std::string_view script, std::ostream& out) {
  const std::vector<Token> tokens = tokenize(script);
  for (const TokenRange& range : split_statements(tokens)) {
    try {
      Statement st = parse_statement(tokens.data() + range.first, tokens.data() + range.second);
      ExecResult r = execute(st);
      if (!r.is_query) continue;
      std::string buf;
      for (const Row& row : r.rows) {
        for (std::size_t i = 0; i < row.size(); ++i) {
          if (i) buf += '\t';
          buf += to_string(row[i]);
        }
        buf += '\n';
      }
      buf += "-- " + std::to_string(r.rows.size()) + " rows\n";
      out << buf;
    } catch (const Error&) {
      out << "error\n";
    }
  }
}

std::string Database::run_script(std::string_view script) {
  std::ostringstream os;
  run_script(script, os);
  return os.str();
}

const Table* Database::find_table(std::string_view name) const {
  auto it = tables_.find(lower(name));
  return it == tables_.end() ? nullptr : &it->second;
}

}  // namespace minisql
