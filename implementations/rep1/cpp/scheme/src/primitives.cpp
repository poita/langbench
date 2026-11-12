#include "scheme/primitives.hpp"

#include <ostream>

#include "scheme/errors.hpp"
#include "scheme/interpreter.hpp"
#include "scheme/numeric.hpp"
#include "scheme/printer.hpp"

namespace scheme {

namespace {

[[noreturn]] void type_error(const char* who) { throw SchemeError(ErrorKind::TypeError, who); }

void require_integers(const char* who, const Value* a, size_t n) {
  for (size_t i = 0; i < n; ++i)
    if (!a[i].is_integer()) type_error(who);
}

void require_string(const char* who, const Value& v) {
  if (!v.is_string()) type_error(who);
}

// ---- arithmetic ------------------------------------------------------------

Value p_add(Interpreter&, Value* a, size_t n) {
  require_integers("+", a, n);
  Value acc = Value::integer(0);
  for (size_t i = 0; i < n; ++i) acc = num::add(acc, a[i]);
  return acc;
}

Value p_mul(Interpreter&, Value* a, size_t n) {
  require_integers("*", a, n);
  Value acc = Value::integer(1);
  for (size_t i = 0; i < n; ++i) acc = num::mul(acc, a[i]);
  return acc;
}

Value p_sub(Interpreter&, Value* a, size_t n) {
  require_integers("-", a, n);
  if (n == 1) return num::negate(a[0]);
  Value acc = a[0];
  for (size_t i = 1; i < n; ++i) acc = num::sub(acc, a[i]);
  return acc;
}

Value p_quotient(Interpreter&, Value* a, size_t n) {
  require_integers("quotient", a, n);
  if (num::is_zero(a[1])) throw SchemeError(ErrorKind::DivisionByZero, "quotient");
  return num::quotient(a[0], a[1]);
}

Value p_remainder(Interpreter&, Value* a, size_t n) {
  require_integers("remainder", a, n);
  if (num::is_zero(a[1])) throw SchemeError(ErrorKind::DivisionByZero, "remainder");
  return num::remainder(a[0], a[1]);
}

template <bool (*Holds)(int)>
Value compare_chain(const char* who, Value* a, size_t n) {
  require_integers(who, a, n);
  for (size_t i = 0; i + 1 < n; ++i)
    if (!Holds(num::compare(a[i], a[i + 1]))) return Value::boolean(false);
  return Value::boolean(true);
}

bool h_eq(int c) { return c == 0; }
bool h_lt(int c) { return c < 0; }
bool h_gt(int c) { return c > 0; }
bool h_le(int c) { return c <= 0; }
bool h_ge(int c) { return c >= 0; }

Value p_num_eq(Interpreter&, Value* a, size_t n) { return compare_chain<h_eq>("=", a, n); }
Value p_lt(Interpreter&, Value* a, size_t n) { return compare_chain<h_lt>("<", a, n); }
Value p_gt(Interpreter&, Value* a, size_t n) { return compare_chain<h_gt>(">", a, n); }
Value p_le(Interpreter&, Value* a, size_t n) { return compare_chain<h_le>("<=", a, n); }
Value p_ge(Interpreter&, Value* a, size_t n) { return compare_chain<h_ge>(">=", a, n); }

// ---- pairs and lists ---------------------------------------------------------

Value p_cons(Interpreter&, Value* a, size_t) { return make_pair(a[0], a[1]); }

Value p_car(Interpreter&, Value* a, size_t) {
  if (!a[0].is_pair()) type_error("car");
  return a[0].as<Pair>()->car;
}

Value p_cdr(Interpreter&, Value* a, size_t) {
  if (!a[0].is_pair()) type_error("cdr");
  return a[0].as<Pair>()->cdr;
}

Value p_list(Interpreter&, Value* a, size_t n) {
  Value result = Value::null();
  for (size_t i = n; i-- > 0;) result = make_pair(std::move(a[i]), std::move(result));
  return result;
}

Value p_null_p(Interpreter&, Value* a, size_t) { return Value::boolean(a[0].is_null()); }
Value p_pair_p(Interpreter&, Value* a, size_t) { return Value::boolean(a[0].is_pair()); }

// ---- predicates ----------------------------------------------------------------

Value p_not(Interpreter&, Value* a, size_t) { return Value::boolean(!a[0].truthy()); }
Value p_number_p(Interpreter&, Value* a, size_t) { return Value::boolean(a[0].is_integer()); }
Value p_boolean_p(Interpreter&, Value* a, size_t) { return Value::boolean(a[0].is_bool()); }
Value p_string_p(Interpreter&, Value* a, size_t) { return Value::boolean(a[0].is_string()); }
Value p_symbol_p(Interpreter&, Value* a, size_t) { return Value::boolean(a[0].is_symbol()); }
Value p_procedure_p(Interpreter&, Value* a, size_t) { return Value::boolean(a[0].is_procedure()); }
Value p_eq_p(Interpreter&, Value* a, size_t) { return Value::boolean(is_eq(a[0], a[1])); }
Value p_equal_p(Interpreter&, Value* a, size_t) { return Value::boolean(is_equal(a[0], a[1])); }

// ---- control -------------------------------------------------------------------

Value p_apply(Interpreter&, Value*, size_t) { return Value(); }  // handled by the evaluator

Value p_error(Interpreter&, Value*, size_t) { throw SchemeError(ErrorKind::UserError); }

// ---- strings and symbols ---------------------------------------------------------

Value p_string_append(Interpreter&, Value* a, size_t n) {
  std::string out;
  for (size_t i = 0; i < n; ++i) require_string("string-append", a[i]);
  for (size_t i = 0; i < n; ++i) out += a[i].as<String>()->value;
  return make_string(std::move(out));
}

Value p_string_length(Interpreter&, Value* a, size_t) {
  require_string("string-length", a[0]);
  return Value::integer(int64_t(a[0].as<String>()->value.size()));
}

Value p_number_to_string(Interpreter&, Value* a, size_t) {
  require_integers("number->string", a, 1);
  return make_string(num::to_string(a[0]));
}

Value p_symbol_to_string(Interpreter&, Value* a, size_t) {
  if (!a[0].is_symbol()) type_error("symbol->string");
  return make_string(a[0].as<Symbol>()->name);
}

// ---- output ----------------------------------------------------------------------

Value p_display(Interpreter& in, Value* a, size_t) {
  std::string s;
  print_value(s, a[0], true);
  in.output() << s;
  return Value();
}

Value p_newline(Interpreter& in, Value*, size_t) {
  in.output() << '\n';
  return Value();
}

}  // namespace

void install_primitives(Interpreter& in) {
  in.define_primitive("+", 0, -1, p_add);
  in.define_primitive("*", 0, -1, p_mul);
  in.define_primitive("-", 1, -1, p_sub);
  in.define_primitive("quotient", 2, 2, p_quotient);
  in.define_primitive("remainder", 2, 2, p_remainder);
  in.define_primitive("=", 2, -1, p_num_eq);
  in.define_primitive("<", 2, -1, p_lt);
  in.define_primitive(">", 2, -1, p_gt);
  in.define_primitive("<=", 2, -1, p_le);
  in.define_primitive(">=", 2, -1, p_ge);

  in.define_primitive("cons", 2, 2, p_cons);
  in.define_primitive("car", 1, 1, p_car);
  in.define_primitive("cdr", 1, 1, p_cdr);
  in.define_primitive("list", 0, -1, p_list);
  in.define_primitive("null?", 1, 1, p_null_p);
  in.define_primitive("pair?", 1, 1, p_pair_p);

  in.define_primitive("not", 1, 1, p_not);
  in.define_primitive("number?", 1, 1, p_number_p);
  in.define_primitive("boolean?", 1, 1, p_boolean_p);
  in.define_primitive("string?", 1, 1, p_string_p);
  in.define_primitive("symbol?", 1, 1, p_symbol_p);
  in.define_primitive("procedure?", 1, 1, p_procedure_p);
  in.define_primitive("eq?", 2, 2, p_eq_p);
  in.define_primitive("equal?", 2, 2, p_equal_p);

  in.define_primitive("apply", 2, -1, p_apply);
  Symbol* apply_sym = in.symbols().intern("apply");
  apply_sym->global.as<Primitive>()->is_apply = true;
  in.define_primitive("error", 0, -1, p_error);

  in.define_primitive("string-append", 0, -1, p_string_append);
  in.define_primitive("string-length", 1, 1, p_string_length);
  in.define_primitive("number->string", 1, 1, p_number_to_string);
  in.define_primitive("symbol->string", 1, 1, p_symbol_to_string);

  in.define_primitive("display", 1, 1, p_display);
  in.define_primitive("newline", 0, 0, p_newline);
}

}  // namespace scheme
