#include "scheme/stack.hpp"

#include <pthread.h>

#include <exception>

namespace scheme {

namespace {
struct Job {
  const std::function<void()>* fn;
  std::exception_ptr error;
};

void* trampoline(void* arg) {
  Job* job = static_cast<Job*>(arg);
  try {
    (*job->fn)();
  } catch (...) {
    job->error = std::current_exception();
  }
  return nullptr;
}
}  // namespace

void run_with_stack_size(std::size_t bytes, const std::function<void()>& fn) {
  Job job{&fn, nullptr};
  pthread_attr_t attr;
  pthread_t tid;
  bool started = false;
  if (pthread_attr_init(&attr) == 0) {
    if (pthread_attr_setstacksize(&attr, bytes) == 0 &&
        pthread_create(&tid, &attr, trampoline, &job) == 0)
      started = true;
    pthread_attr_destroy(&attr);
  }
  if (!started) {
    fn();
    return;
  }
  pthread_join(tid, nullptr);
  if (job.error) std::rethrow_exception(job.error);
}

}  // namespace scheme
