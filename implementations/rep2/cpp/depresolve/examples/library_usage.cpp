// Minimal use of the depresolve library: build a registry in code and resolve.
#include <iostream>

#include "depresolve/depresolve.hpp"

int main() {
  using namespace depresolve;

  Registry registry;
  registry.add_version("a", *Version::parse("1.0.0"), {{"c", *Range::parse("^1.0.0")}});
  registry.add_version("b", *Version::parse("1.0.0"), {{"c", *Range::parse("~1.2.0")}});
  for (const char* v : {"1.1.0", "1.2.5", "1.3.0"}) registry.add_version("c", *Version::parse(v), {});
  registry.finalize();

  const std::vector<Dependency> root = {{"a", Range::any()}, {"b", Range::any()}};
  const Resolution resolution = resolve(registry, root);
  std::cout << format_resolution(resolution);  // a 1.0.0 / b 1.0.0 / c 1.2.5
  std::cout << "steps: " << resolution.stats.steps << "\n";
}
