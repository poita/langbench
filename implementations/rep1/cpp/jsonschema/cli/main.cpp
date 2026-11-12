// jsonschema-cli: reads {"schema", "tests", "remotes"?} from stdin and prints
// `valid` / `invalid` for every test instance.

#include <pthread.h>

#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "jsonschema/json.hpp"
#include "jsonschema/schema.hpp"

namespace {

std::string read_all(std::FILE* f) {
  std::string data;
  char buf[1 << 16];
  std::size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) data.append(buf, n);
  return data;
}

int run() {
  using jsonschema::Value;
  const std::string input = read_all(stdin);
  const Value doc = jsonschema::parse_json(input);
  if (!doc.is_object()) throw std::runtime_error("input must be a JSON object");
  const Value* schema = doc.find("schema");
  const Value* tests = doc.find("tests");
  if (!schema || !tests || !tests->is_array()) throw std::runtime_error("input needs \"schema\" and \"tests\"");

  std::vector<jsonschema::Remote> remotes;
  if (const Value* r = doc.find("remotes"); r && r->is_object()) {
    for (std::size_t i = 0; i < r->size(); ++i) remotes.emplace_back(r->keys()[i], r->items()[i]);
  }
  const jsonschema::Schema compiled = jsonschema::Schema::compile(*schema, std::move(remotes));

  std::string out;
  const Value null_value;
  for (const Value& test : tests->items()) {
    const Value* data = test.is_object() ? test.find("data") : nullptr;
    out += compiled.is_valid(data ? *data : null_value) ? "valid\n" : "invalid\n";
  }
  std::fwrite(out.data(), 1, out.size(), stdout);
  return 0;
}

void* thread_main(void* result) {
  int* status = static_cast<int*>(result);
  try {
    *status = run();
  } catch (const std::exception& e) {
    std::fprintf(stderr, "jsonschema-cli: %s\n", e.what());
    *status = 1;
  }
  return nullptr;
}

}  // namespace

int main() {
  // Schemas and instances can nest deeply and the evaluator recurses, so run on a thread with a large stack.
  int status = 1;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, std::size_t{1} << 30);
  pthread_t thread;
  if (pthread_create(&thread, &attr, thread_main, &status) != 0) {
    thread_main(&status);  // fall back to the main thread's stack
  } else {
    pthread_join(thread, nullptr);
  }
  std::fflush(stdout);
  return status;
}
