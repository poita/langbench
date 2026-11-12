// The 132 built-in functions (SPEC.md section 15).
#pragma once

#include <string>

#include "value.h"

namespace langvm {

class VM;

// Native implementation: `args` points at the argument values on the VM stack
// (copy anything needed across a callback into the VM, which may move the stack).
using BuiltinFn = Value (*)(VM& vm, Value* args);

struct BuiltinDef {
  const char* name;
  BuiltinFn fn;
};

// Index of the built-in called `name`, or -1.
int builtinIndex(const std::string& name);
const BuiltinDef& builtinAt(int index);
int builtinCount();

// Vellum source text declaring every built-in's signature (bodies empty). It is
// parsed with the ordinary front end, so signatures are checked like user code.
const char* builtinSignatureSource();

}  // namespace langvm
