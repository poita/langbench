#include "tessera/command.hpp"

#include <set>

#include "tessera/error.hpp"
#include "tessera/lexer.hpp"
#include "tessera/limits.hpp"

namespace tessera {
namespace {

std::int64_t parse_int(const std::string& text) {
  bool neg = text[0] == '-';
  std::size_t i = neg ? 1 : 0;
  const std::uint64_t limit = neg ? (std::uint64_t(1) << 63) : (std::uint64_t(1) << 63) - 1;
  std::uint64_t v = 0;
  for (; i < text.size(); ++i) {
    std::uint64_t d = static_cast<std::uint64_t>(text[i] - '0');
    if (v > (limit - d) / 10) throw Error(ErrorKind::IntRange);
    v = v * 10 + d;
  }
  return neg ? static_cast<std::int64_t>(~v + 1) : static_cast<std::int64_t>(v);
}

class Parser {
 public:
  explicit Parser(std::vector<Token> tokens) : t_(std::move(tokens)) {}

  Command command();
  Value value_literal() {
    Value v = value(1);
    expect_end();
    return v;
  }

 private:
  const Token* peek(std::size_t ahead = 0) const {
    return pos_ + ahead < t_.size() ? &t_[pos_ + ahead] : nullptr;
  }
  const Token& next() {
    if (pos_ >= t_.size()) throw Error(ErrorKind::Syntax);
    return t_[pos_++];
  }
  void expect_end() const {
    if (pos_ != t_.size()) throw Error(ErrorKind::Syntax);
  }
  void expect_punct(char c) {
    if (!next().is_punct(c)) throw Error(ErrorKind::Syntax);
  }

  static std::string resolve_string(const Token& t) {
    if (t.bad_utf8) throw Error(ErrorKind::BadUtf8);
    return t.text;
  }
  std::string string_arg() {
    const Token& t = next();
    if (t.type != Token::Type::String) throw Error(ErrorKind::Syntax);
    return resolve_string(t);
  }
  std::string key_arg() {
    std::string k = string_arg();
    if (k.empty() || k.size() > kMaxKey) throw Error(ErrorKind::BadKey);
    return k;
  }
  std::int64_t int_arg() {
    const Token& t = next();
    if (t.type != Token::Type::Int) throw Error(ErrorKind::Syntax);
    return parse_int(t.text);
  }
  std::int64_t limit_arg() {
    std::int64_t n = int_arg();
    if (n < 0 || n > kMaxLimit) throw Error(ErrorKind::Syntax);
    return n;
  }

  Path path();
  Value value(int level);
  Value list(int level);
  Value object(int level);
  ScanOptions scan_options();
  std::unique_ptr<Predicate> disjunction();
  std::unique_ptr<Predicate> conjunction();
  std::unique_ptr<Predicate> term();

  std::vector<Token> t_;
  std::size_t pos_ = 0;
};

Path Parser::path() {
  Path p;
  std::size_t text_len = 0;
  auto segment = [&] {
    const Token& t = next();
    if (t.type != Token::Type::Word) throw Error(ErrorKind::Syntax);
    text_len += t.text.size() + (p.empty() ? 0 : 1);
    p.push_back(t.text);
    if (p.size() > kMaxPathSegments || text_len > kMaxPath) throw Error(ErrorKind::BadPath);
  };
  segment();
  while (peek() && peek()->is_punct('.')) {
    next();
    segment();
  }
  return p;
}

Value Parser::value(int level) {
  const Token& t = next();
  switch (t.type) {
    case Token::Type::Word:
      if (t.text == "null") return Value::null();
      if (t.text == "true") return Value::boolean(true);
      if (t.text == "false") return Value::boolean(false);
      throw Error(ErrorKind::Syntax);
    case Token::Type::Int: return Value::integer(parse_int(t.text));
    case Token::Type::String: return Value::string(resolve_string(t));
    case Token::Type::Punct:
      if (t.text == "[") return list(level);
      if (t.text == "{") return object(level);
      throw Error(ErrorKind::Syntax);
    default: throw Error(ErrorKind::Syntax);
  }
}

Value Parser::list(int level) {
  std::vector<Value> items;
  if (peek() && peek()->is_punct(']')) {
    next();
    return Value::list(std::move(items));
  }
  while (true) {
    if (level + 1 > kMaxDepth) throw Error(ErrorKind::Depth);
    items.push_back(value(level + 1));
    const Token& t = next();
    if (t.is_punct(',')) continue;
    if (t.is_punct(']')) break;
    throw Error(ErrorKind::Syntax);
  }
  return Value::list(std::move(items));
}

Value Parser::object(int level) {
  std::vector<Value::Field> fields;
  std::set<std::string> seen;
  if (peek() && peek()->is_punct('}')) {
    next();
    return Value::object(std::move(fields));
  }
  while (true) {
    const Token& nt = next();
    std::string name;
    if (nt.type == Token::Type::String) name = resolve_string(nt);
    else if (nt.type == Token::Type::Word) name = nt.text;
    else throw Error(ErrorKind::Syntax);
    if (!seen.insert(name).second) throw Error(ErrorKind::DupField);
    expect_punct(':');
    if (level + 1 > kMaxDepth) throw Error(ErrorKind::Depth);
    fields.emplace_back(std::move(name), value(level + 1));
    const Token& t = next();
    if (t.is_punct(',')) continue;
    if (t.is_punct('}')) break;
    throw Error(ErrorKind::Syntax);
  }
  return Value::object(std::move(fields));
}

ScanOptions Parser::scan_options() {
  ScanOptions o;
  bool have_from = false, have_to = false, have_limit = false, have_reverse = false,
       have_keys = false;
  while (const Token* t = peek()) {
    if (t->type != Token::Type::Word) throw Error(ErrorKind::Syntax);
    std::string w = t->text;
    if (w == "from") {
      if (have_from) throw Error(ErrorKind::Syntax);
      next();
      have_from = true;
      o.from = string_arg();
    } else if (w == "to") {
      if (have_to) throw Error(ErrorKind::Syntax);
      next();
      have_to = true;
      o.to = string_arg();
    } else if (w == "limit") {
      if (have_limit) throw Error(ErrorKind::Syntax);
      next();
      have_limit = true;
      o.limit = limit_arg();
    } else if (w == "reverse") {
      if (have_reverse) throw Error(ErrorKind::Syntax);
      next();
      have_reverse = true;
      o.reverse = true;
    } else if (w == "keys") {
      if (have_keys) throw Error(ErrorKind::Syntax);
      next();
      have_keys = true;
      o.keys_only = true;
    } else {
      throw Error(ErrorKind::Syntax);
    }
  }
  return o;
}

std::unique_ptr<Predicate> Parser::disjunction() {
  auto lhs = conjunction();
  while (peek() && peek()->is_word("or")) {
    next();
    auto node = std::make_unique<Predicate>();
    node->type = Predicate::Type::Or;
    node->lhs = std::move(lhs);
    node->rhs = conjunction();
    lhs = std::move(node);
  }
  return lhs;
}

std::unique_ptr<Predicate> Parser::conjunction() {
  auto lhs = term();
  while (peek() && peek()->is_word("and")) {
    next();
    auto node = std::make_unique<Predicate>();
    node->type = Predicate::Type::And;
    node->lhs = std::move(lhs);
    node->rhs = term();
    lhs = std::move(node);
  }
  return lhs;
}

std::unique_ptr<Predicate> Parser::term() {
  const Token* t = peek();
  if (!t) throw Error(ErrorKind::Syntax);
  auto node = std::make_unique<Predicate>();
  if (t->is_punct('(')) {
    next();
    auto inner = disjunction();
    expect_punct(')');
    return inner;
  }
  if (t->type != Token::Type::Word) throw Error(ErrorKind::Syntax);
  const Token* n1 = peek(1);
  if (t->text == "not" && n1 && n1->is_punct('(')) {
    next();
    next();
    auto inner = disjunction();
    expect_punct(')');
    node->type = Predicate::Type::Not;
    node->lhs = std::move(inner);
    return node;
  }
  if ((t->text == "exists" || t->text == "missing") && n1 && n1->type == Token::Type::Word) {
    node->type = t->text == "exists" ? Predicate::Type::Exists : Predicate::Type::Missing;
    next();
    node->path = path();
    return node;
  }
  node->type = Predicate::Type::Cmp;
  node->path = path();
  const Token& op = next();
  if (op.type != Token::Type::Op) throw Error(ErrorKind::Syntax);
  if (op.text == "==") node->op = CmpOp::Eq;
  else if (op.text == "!=") node->op = CmpOp::Ne;
  else if (op.text == "<") node->op = CmpOp::Lt;
  else if (op.text == "<=") node->op = CmpOp::Le;
  else if (op.text == ">") node->op = CmpOp::Gt;
  else node->op = CmpOp::Ge;
  node->value = value(1);
  return node;
}

Command Parser::command() {
  if (t_.empty()) throw Error(ErrorKind::Syntax);
  if (t_[0].type != Token::Type::Word) throw Error(ErrorKind::Syntax);
  const std::string name = next().text;
  Command c;
  using T = Command::Type;
  if (name == "begin" || name == "commit" || name == "rollback" || name == "checkpoint" ||
      name == "stat" || name == "indexes") {
    c.type = name == "begin" ? T::Begin
             : name == "commit" ? T::Commit
             : name == "rollback" ? T::Rollback
             : name == "checkpoint" ? T::Checkpoint
             : name == "stat" ? T::Stat
                              : T::Indexes;
    expect_end();
  } else if (name == "put") {
    c.type = T::Put;
    c.key = key_arg();
    c.value = value(1);
    expect_end();
  } else if (name == "get" || name == "delete") {
    c.type = name == "get" ? T::Get : T::Delete;
    c.key = key_arg();
    expect_end();
  } else if (name == "update") {
    c.type = T::Update;
    c.key = key_arg();
    c.path = path();
    c.value = value(1);
    expect_end();
  } else if (name == "unset") {
    c.type = T::Unset;
    c.key = key_arg();
    c.path = path();
    expect_end();
  } else if (name == "scan") {
    c.type = T::Scan;
    c.scan = scan_options();
  } else if (name == "find") {
    c.type = T::Find;
    c.predicate = disjunction();
    if (peek() && peek()->is_word("limit")) {
      next();
      c.limit = limit_arg();
    }
    expect_end();
  } else if (name == "create" || name == "drop") {
    c.type = name == "create" ? T::CreateIndex : T::DropIndex;
    if (!next().is_word("index")) throw Error(ErrorKind::Syntax);
    c.path = path();
    expect_end();
  } else {
    throw Error(ErrorKind::UnknownCommand);
  }
  return c;
}

}  // namespace

Command parse_command(std::string_view line) {
  Parser p(lex(line));
  return p.command();
}

Value parse_value_literal(std::string_view text) {
  Parser p(lex(text));
  return p.value_literal();
}

}  // namespace tessera
