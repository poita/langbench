// minisql command-line tool: reads a SQL script on stdin, prints SELECT results.
#include <iostream>
#include <iterator>
#include <string>

#include "minisql/minisql.hpp"

int main() {
  std::ios::sync_with_stdio(false);
  const std::string script((std::istreambuf_iterator<char>(std::cin)),
                           std::istreambuf_iterator<char>());
  minisql::Database db;
  db.run_script(script, std::cout);
  std::cout.flush();
  return 0;
}
