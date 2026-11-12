// ssheet: reads spreadsheet commands on stdin, writes get/dump results to stdout.
#include <iostream>

#include "spreadsheet/script.h"
#include "spreadsheet/sheet.h"

int main() {
  std::ios::sync_with_stdio(false);
  spreadsheet::Sheet sheet;
  spreadsheet::CommandProcessor processor(sheet);
  processor.run(std::cin, std::cout, std::cerr);
  std::cout.flush();
  return 0;
}
