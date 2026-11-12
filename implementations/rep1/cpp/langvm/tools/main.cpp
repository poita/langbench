// Command-line tool: reads a Vellum module stream on stdin, compiles and runs
// it, and writes the program's output (or one diagnostic line) to stdout.
#include <pthread.h>

#include <iostream>
#include <iterator>
#include <string>

#include "langvm/langvm.h"

namespace {

struct Job {
  std::string source;
};

void* worker(void* p) {
  Job* job = static_cast<Job*>(p);
  langvm::execute(job->source, std::cout);
  std::cout.flush();
  return nullptr;
}

}  // namespace

int main() {
  std::ios::sync_with_stdio(false);
  Job job;
  job.source.assign(std::istreambuf_iterator<char>(std::cin), std::istreambuf_iterator<char>());

  // Deeply nested Vellum data (long linked lists) is compared and dropped
  // recursively in places, so run on a thread with a generous stack.
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, static_cast<size_t>(1) << 30);
  pthread_t th;
  if (pthread_create(&th, &attr, worker, &job) != 0) {
    worker(&job);
  } else {
    pthread_join(th, nullptr);
  }
  return 0;
}
