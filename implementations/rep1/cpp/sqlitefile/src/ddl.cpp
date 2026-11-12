#include "sqlitefile/ddl.hpp"

#include <algorithm>

#include "sqlitefile/error.hpp"

namespace sqlitefile {

bool equalsIgnoreCase(std::string_view a, std::string_view b) {
  if (a.size() != b.size()) return false;
  for (std::size_t i = 0; i < a.size(); ++i) {
    char x = a[i], y = b[i];
    if (x >= 'A' && x <= 'Z') x = static_cast<char>(x - 'A' + 'a');
    if (y >= 'A' && y <= 'Z') y = static_cast<char>(y - 'A' + 'a');
    if (x != y) return false;
  }
  return true;
}

std::optional<std::size_t> TableDef::findColumn(std::string_view name) const {
  for (std::size_t i = 0; i < columns.size(); ++i)
    if (equalsIgnoreCase(columns[i].name, name)) return i;
  return std::nullopt;
}

namespace {

enum class Tok { Word, Quoted, String, Punct, Other };

struct Token {
  Tok kind;
  std::string text;  // quoted names are unquoted; words keep their spelling

  bool isWord(std::string_view kw) const {
    return kind == Tok::Word && equalsIgnoreCase(text, kw);
  }
  bool isPunct(char c) const { return kind == Tok::Punct && text[0] == c; }
};

bool isWordChar(unsigned char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         c == '_' || c == '$' || c >= 0x80;
}

std::vector<Token> tokenize(std::string_view s) {
  std::vector<Token> out;
  std::size_t i = 0, n = s.size();
  while (i < n) {
    char c = s[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v') {
      ++i;
    } else if (c == '-' && i + 1 < n && s[i + 1] == '-') {
      while (i < n && s[i] != '\n') ++i;
    } else if (c == '/' && i + 1 < n && s[i + 1] == '*') {
      std::size_t e = s.find("*/", i + 2);
      i = e == std::string_view::npos ? n : e + 2;
    } else if (c == '"' || c == '`' || c == '\'') {
      std::string text;
      ++i;
      while (i < n) {
        if (s[i] == c) {
          if (i + 1 < n && s[i + 1] == c) {
            text.push_back(c);
            i += 2;
            continue;
          }
          break;
        }
        text.push_back(s[i++]);
      }
      ++i;  // closing quote (or end)
      out.push_back({c == '\'' ? Tok::String : Tok::Quoted, std::move(text)});
    } else if (c == '[') {
      std::size_t e = s.find(']', i + 1);
      std::string text(s.substr(i + 1, e == std::string_view::npos ? n : e - i - 1));
      i = e == std::string_view::npos ? n : e + 1;
      out.push_back({Tok::Quoted, std::move(text)});
    } else if (isWordChar(static_cast<unsigned char>(c))) {
      std::size_t j = i;
      while (j < n && isWordChar(static_cast<unsigned char>(s[j]))) ++j;
      out.push_back({Tok::Word, std::string(s.substr(i, j - i))});
      i = j;
    } else if (c == '(' || c == ')' || c == ',' || c == '.' || c == ';') {
      out.push_back({Tok::Punct, std::string(1, c)});
      ++i;
    } else {
      out.push_back({Tok::Other, std::string(1, c)});
      ++i;
    }
  }
  return out;
}

using Tokens = std::vector<Token>;

/// Returns the tokens between the first '(' and its matching ')', split at
/// commas at nesting depth 0.
std::vector<Tokens> parenthesisedItems(const Tokens& toks) {
  std::size_t i = 0;
  while (i < toks.size() && !toks[i].isPunct('(')) ++i;
  if (i == toks.size()) throw FormatError("missing '(' in statement");
  ++i;
  std::vector<Tokens> items(1);
  int depth = 0;
  for (; i < toks.size(); ++i) {
    const Token& t = toks[i];
    if (t.isPunct('(')) {
      ++depth;
    } else if (t.isPunct(')')) {
      if (depth == 0) return items;
      --depth;
    } else if (t.isPunct(',') && depth == 0) {
      items.emplace_back();
      continue;
    }
    items.back().push_back(t);
  }
  throw FormatError("unbalanced parentheses in statement");
}

bool isTypeTerminator(const Token& t) {
  static const char* kw[] = {"CONSTRAINT", "PRIMARY", "NOT",     "NULL",       "UNIQUE",
                             "CHECK",      "DEFAULT", "COLLATE", "REFERENCES", "GENERATED",
                             "AS",         "AUTOINCREMENT"};
  if (t.kind != Tok::Word) return false;
  return std::any_of(std::begin(kw), std::end(kw),
                     [&](const char* k) { return equalsIgnoreCase(t.text, k); });
}

std::string joinType(const Tokens& type_tokens) {
  std::string s;
  for (std::size_t i = 0; i < type_tokens.size(); ++i) {
    const Token& t = type_tokens[i];
    if (i > 0 && t.kind != Tok::Punct && type_tokens[i - 1].kind != Tok::Punct) s += ' ';
    s += t.text;
  }
  return s;
}

}  // namespace

TableDef parseCreateTable(std::string_view sql) {
  Tokens toks = tokenize(sql);
  if (toks.size() < 2 || !toks[0].isWord("CREATE")) throw FormatError("not a CREATE TABLE");
  std::size_t k = 1;
  if (k < toks.size() && (toks[k].isWord("TEMP") || toks[k].isWord("TEMPORARY"))) ++k;
  if (k >= toks.size() || !toks[k].isWord("TABLE")) throw FormatError("not a CREATE TABLE");

  TableDef def;
  struct ColumnPk {
    bool primary = false;
    bool desc = false;
    bool single_word_integer = false;
  };
  std::vector<ColumnPk> col_pk;
  std::optional<std::string> table_pk;  // single-column table-level PRIMARY KEY

  for (const Tokens& item : parenthesisedItems(toks)) {
    if (item.empty()) continue;
    const Token& first = item[0];
    bool constraint = first.kind == Tok::Word &&
                      (first.isWord("CONSTRAINT") || first.isWord("PRIMARY") ||
                       first.isWord("UNIQUE") || first.isWord("CHECK") ||
                       first.isWord("FOREIGN"));
    if (constraint) {
      std::size_t i = 0;
      if (item[0].isWord("CONSTRAINT")) i = 2;
      if (i + 2 < item.size() && item[i].isWord("PRIMARY") && item[i + 1].isWord("KEY") &&
          item[i + 2].isPunct('(')) {
        // Collect the column list; only a single column can alias the rowid.
        std::size_t j = i + 3;
        int depth = 0;
        int commas = 0;
        for (std::size_t m = j; m < item.size(); ++m) {
          if (item[m].isPunct('(')) ++depth;
          else if (item[m].isPunct(')')) { if (depth == 0) break; --depth; }
          else if (item[m].isPunct(',') && depth == 0) ++commas;
        }
        if (commas == 0 && j < item.size()) table_pk = item[j].text;
      }
      continue;
    }

    Column col;
    col.name = first.text;
    ColumnPk pk;
    Tokens type_tokens;
    std::size_t i = 1;
    int depth = 0;
    for (; i < item.size(); ++i) {
      if (depth == 0 && isTypeTerminator(item[i])) break;
      if (item[i].isPunct('(')) ++depth;
      else if (item[i].isPunct(')')) --depth;
      type_tokens.push_back(item[i]);
    }
    col.declared_type = joinType(type_tokens);
    col.affinity = affinityFromDeclaredType(col.declared_type);
    pk.single_word_integer = type_tokens.size() == 1 && type_tokens[0].isWord("INTEGER");
    if (type_tokens.size() == 1 && type_tokens[0].kind == Tok::Quoted &&
        equalsIgnoreCase(type_tokens[0].text, "INTEGER"))
      pk.single_word_integer = true;
    depth = 0;
    for (; i < item.size(); ++i) {
      if (item[i].isPunct('(')) ++depth;
      else if (item[i].isPunct(')')) --depth;
      else if (depth == 0 && item[i].isWord("PRIMARY") && i + 1 < item.size() &&
               item[i + 1].isWord("KEY")) {
        pk.primary = true;
        pk.desc = i + 2 < item.size() && item[i + 2].isWord("DESC");
      }
    }
    def.columns.push_back(std::move(col));
    col_pk.push_back(pk);
  }

  for (std::size_t i = 0; i < def.columns.size() && !def.rowid_alias; ++i)
    if (col_pk[i].primary && !col_pk[i].desc && col_pk[i].single_word_integer)
      def.rowid_alias = i;
  if (!def.rowid_alias && table_pk) {
    if (auto idx = def.findColumn(*table_pk))
      if (col_pk[*idx].single_word_integer) def.rowid_alias = *idx;
  }
  return def;
}

IndexDef parseCreateIndex(std::string_view sql) {
  Tokens toks = tokenize(sql);
  std::size_t k = 0;
  if (k >= toks.size() || !toks[k].isWord("CREATE")) throw FormatError("not a CREATE INDEX");
  ++k;
  if (k < toks.size() && toks[k].isWord("UNIQUE")) ++k;
  if (k >= toks.size() || !toks[k].isWord("INDEX")) throw FormatError("not a CREATE INDEX");

  IndexDef def;
  for (const Tokens& item : parenthesisedItems(toks)) {
    if (item.empty()) throw FormatError("empty index column");
    def.columns.push_back(item[0].text);
    bool desc = false;
    for (std::size_t i = 1; i < item.size(); ++i) {
      if (item[i].isWord("DESC")) desc = true;
      if (item[i].isWord("ASC")) desc = false;
    }
    def.descending.push_back(desc);
  }
  return def;
}

}  // namespace sqlitefile
