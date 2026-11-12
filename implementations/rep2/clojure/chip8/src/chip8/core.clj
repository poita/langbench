(ns chip8.core
  "Public API of the CHIP-8 emulator library.

  Quick start:

      (require '[chip8.core :as chip8])
      (chip8/emulate \"60ff7001\\n2\")          ;=> the 34-line report
      (-> (chip8/run-rom [0x60 0xff] 1) chip8/snapshot :v first) ;=> 255

  Lower-level pieces: `chip8.machine` (state), `chip8.cpu` (stepping),
  `chip8.input` (parsing) and `chip8.render` (formatting)."
  (:require [chip8.cpu :as cpu]
            [chip8.input :as input]
            [chip8.machine :as machine]
            [chip8.render :as render]))

(defn run-rom
  "Loads `rom` (a collection or byte array of bytes) at 0x200, runs it for
  `cycles` cycles with the optional key `schedule` (`[[cycle mask] ...]`)
  and returns the resulting machine."
  ([rom cycles] (run-rom rom cycles []))
  ([rom cycles schedule]
   (cpu/run-cycles! (machine/new-machine rom) cycles schedule)))

(defn snapshot
  "Immutable map view of a machine; see `chip8.machine/snapshot`."
  [m]
  (machine/snapshot m))

(defn report
  "The 34-line textual report of a machine."
  [m]
  (render/report m))

(defn emulate
  "Takes the job text (ROM hex, cycles, optional key schedule) and returns
  the report text."
  [text]
  (let [{:keys [rom cycles schedule]} (input/parse-input text)]
    (render/report (run-rom rom cycles schedule))))
