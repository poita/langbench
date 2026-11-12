#include "datalog/datalog.h"

namespace datalog {

std::string format_answer(const Atom& query, const std::vector<Tuple>& tuples) {
  std::string out;
  for (const Tuple& t : tuples) {
    out += query.predicate;
    out += '(';
    for (std::size_t i = 0; i < t.size(); ++i) {
      if (i) out += ", ";
      out += t[i].to_string();
    }
    out += ")\n";
  }
  out += "-- " + std::to_string(tuples.size()) + "\n";
  return out;
}

std::string run_program(std::string_view source) {
  Program program = parse_program(source);
  try {
    Engine engine(program);
    std::string out;
    for (const Atom& q : program.queries) out += format_answer(q, engine.query(q));
    return out;
  } catch (const ProgramError&) {
    return "error\n";
  }
}

}  // namespace datalog
