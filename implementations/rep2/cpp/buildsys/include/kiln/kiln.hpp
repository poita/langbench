// Umbrella header for the Kiln library.
//
//   kiln::Vfs vfs = kiln::Vfs::loadDirectory("workspace-dir", "session.txt");
//   std::string log = kiln::runSession(vfs, session_text);
//
// Individual modules (lexer, parser, interpreter, graph, state, scheduler) can
// also be used on their own.
#pragma once

#include "kiln/ast.hpp"
#include "kiln/builtins.hpp"
#include "kiln/commands.hpp"
#include "kiln/engine.hpp"
#include "kiln/error.hpp"
#include "kiln/glob.hpp"
#include "kiln/graph.hpp"
#include "kiln/hash.hpp"
#include "kiln/interp.hpp"
#include "kiln/lexer.hpp"
#include "kiln/parser.hpp"
#include "kiln/path.hpp"
#include "kiln/plan.hpp"
#include "kiln/session.hpp"
#include "kiln/state.hpp"
#include "kiln/value.hpp"
#include "kiln/vfs.hpp"
