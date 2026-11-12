// typeinfer command-line tool: reads a program on stdin, prints one line per
// declaration on stdout. See README.md.
#include <pthread.h>

#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <iterator>
#include <string>

#include "typeinfer/typeinfer.hpp"

namespace {

struct Job {
    std::string input;
    std::string output;
    int status = 0;
};

void* run(void* arg) {
    Job& job = *static_cast<Job*>(arg);
    typeinfer::Session session;
    try {
        session.check(job.input, [&](typeinfer::DeclResult&& r) {
            job.output += r.to_string();
            job.output += '\n';
        });
    } catch (const typeinfer::ParseError& e) {
        std::fprintf(stderr, "typeinfer: parse error: %s\n", e.what());
        job.status = 1;
    }
    return nullptr;
}

}  // namespace

int main() {
    std::ios::sync_with_stdio(false);
    Job job;
    job.input.assign(std::istreambuf_iterator<char>(std::cin), std::istreambuf_iterator<char>());

    // The inference passes recurse on expression and type depth (thousands of
    // levels), so run them on a thread with a generous stack.
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_t thread;
    bool started = pthread_attr_setstacksize(&attr, std::size_t(1) << 29) == 0 &&
                   pthread_create(&thread, &attr, run, &job) == 0;
    if (started) {
        pthread_join(thread, nullptr);
    } else {
        run(&job);
    }
    std::fwrite(job.output.data(), 1, job.output.size(), stdout);
    return job.status;
}
