(ns chip8.test-util
  "Helpers for building ROMs and running them in tests."
  (:require [chip8.core :as core]
            [chip8.machine :as machine]))

(defn rom
  "Turn a sequence of 16-bit opcodes into a ROM byte vector."
  [& opcodes]
  (vec (mapcat (fn [op] [(bit-shift-right op 8) (bit-and op 0xFF)]) opcodes)))

(defn run-ops
  "Run opcodes for `cycles` cycles (default: one per opcode); returns the
  machine."
  ([ops] (run-ops ops (count ops)))
  ([ops cycles] (run-ops ops cycles []))
  ([ops cycles schedule]
   (core/run (apply rom ops) cycles schedule)))

(defn v
  "Value of register Vx after running."
  [m x]
  (get (:v (machine/snapshot m)) x))

(defn reg [m k] (get (machine/snapshot m) k))
