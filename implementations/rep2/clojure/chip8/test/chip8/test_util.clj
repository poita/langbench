(ns chip8.test-util
  "Helpers shared by the tests."
  (:require [chip8.core :as core]))

(defn words->rom
  "Turns a seq of 16-bit opcodes into a vector of big-endian bytes."
  [ops]
  (vec (mapcat (fn [op] [(bit-and (bit-shift-right op 8) 0xFF) (bit-and op 0xFF)]) ops)))

(defn run-ops
  "Runs the opcodes for `cycles` cycles and returns the snapshot."
  ([ops cycles] (run-ops ops cycles []))
  ([ops cycles schedule]
   (core/snapshot (core/run-rom (words->rom ops) cycles schedule))))
