// Package buildsys is the engine of Kiln, an incremental build system driven
// by a simulated scheduler.
//
// A workspace (a vfs.FS) holds build files written in the Kiln Build Language
// (package kbl) and ordinary source files. Build evaluates the build files into
// a graph of steps (package graph), decides which steps are stale from the
// recorded state (package state), and runs them on simulated workers (package
// sched) using Kiln's built-in commands (package cmds). Nothing is ever run by
// a real shell, so every build is fully deterministic.
//
// Package session adds a scripting layer on top: a sequence of builds and
// workspace mutations that produces a textual log.
package buildsys
