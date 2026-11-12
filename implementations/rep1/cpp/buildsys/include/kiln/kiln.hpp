// Umbrella header for the Kiln library.
//
// Typical use:
//
//   kiln::Vfs ws;
//   ws.write("main.kiln", "step { out \"out/a.txt\" cmd write(\"hi\\n\") }\n"
//                         "default \"out/a.txt\"\n");
//   kiln::BuildReport r = kiln::run_build(ws, {});
//
#pragma once

#include "kiln/build.hpp"
#include "kiln/builtins.hpp"
#include "kiln/commands.hpp"
#include "kiln/error.hpp"
#include "kiln/evaluator.hpp"
#include "kiln/glob.hpp"
#include "kiln/graph.hpp"
#include "kiln/hash.hpp"
#include "kiln/lexer.hpp"
#include "kiln/parser.hpp"
#include "kiln/path.hpp"
#include "kiln/scheduler.hpp"
#include "kiln/session.hpp"
#include "kiln/state.hpp"
#include "kiln/step.hpp"
#include "kiln/value.hpp"
#include "kiln/vfs.hpp"
