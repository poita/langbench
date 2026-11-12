// The stack virtual machine (SPEC.md section 16).
#pragma once

#include <ostream>
#include <string>
#include <string_view>

#include "bytecode.h"

namespace langvm {

// Thrown to unwind the VM on a runtime panic.
struct Panic {
  std::string message;
};

class VM {
 public:
  VM(const Program::Impl& program, std::ostream& out);
  ~VM();
  VM(const VM&) = delete;
  VM& operator=(const VM&) = delete;

  // Runs `main`; a panic is caught, reported on the stream, and returned.
  RunResult run();

  // ---- services for built-ins
  void write(const std::u32string& s);
  [[noreturn]] void panic(const std::string& message);
  // Calls a closure value from native code and returns its result.
  Value callValue(const Value& f, const Value* args, int n);
  Value call2(const Value& f, const Value& a, const Value& b) {
    Value args[2] = {a, b};
    return callValue(f, args, 2);
  }
  Value call1(const Value& f, const Value& a) { return callValue(f, &a, 1); }

 private:
  struct Frame {
    const CompiledFunction* fn;
    size_t pc;
    size_t base;
    size_t retBase;
    Value closure;
  };

  const Program::Impl& prog_;
  std::ostream& out_;
  std::string outBuf_;
  Value* stack_ = nullptr;
  size_t sp_ = 0;
  size_t cap_ = 0;
  std::vector<Frame> frames_;

  void flush();
  void reserve(size_t extra);
  void truncate(size_t newSp);
  void pushFrame(int func, size_t base, size_t retBase, const Value* closure);
  Value execute(size_t stopDepth);
};

}  // namespace langvm
