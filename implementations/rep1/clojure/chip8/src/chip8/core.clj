(ns chip8.core
  "Public API of the CHIP-8 emulator library.

  Typical use:

      (require '[chip8.core :as chip8])
      (let [m (chip8/run rom-bytes 1000 [[10 0x0001]])]
        (println (chip8/format-state m)))

  `run` is the main entry point; `make-machine`, `step!` and `run!` give
  finer control. Machines are mutable: `run!` and `step!` modify them in
  place."
  (:refer-clojure :exclude [run!])
  (:require [chip8.cpu :as cpu]
            [chip8.display :as display]
            [chip8.input :as input]
            [chip8.machine :as machine]
            [clojure.string :as str])
  (:import (chip8.machine Machine)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def make-machine
  "`(make-machine rom)` creates a machine with `rom` (byte values) loaded at
  0x200. See `chip8.machine/make-machine`."
  machine/make-machine)

(def step!
  "`(step! m)` executes one instruction (no key events, no timer tick)."
  cpu/step!)

(def snapshot
  "`(snapshot m)` returns `{:pc :i :sp :dt :st :v}` as plain data."
  machine/snapshot)

(def pixels
  "`(pixels m)` returns the display as 32 rows of 64 booleans."
  machine/pixels)

(defn run!
  "Execute exactly `cycles` instruction cycles on machine `m`, applying the
  key `schedule` (a vector of `[cycle mask]` pairs in strictly increasing
  cycle order) and ticking the timers every 8th cycle. Returns `m`."
  [^Machine m ^long cycles schedule]
  (let [events (vec schedule)
        n-events (count events)
        ev-cycle (long-array (map first events))
        ev-mask (long-array (map second events))]
    (loop [c 0 e 0]
      (when (< c cycles)
        (let [e (long (loop [e e]
                  (if (and (< e n-events) (<= (aget ev-cycle e) c))
                    (do (machine/set-keys! m (aget ev-mask e))
                        (recur (inc e)))
                    e)))]
          (cpu/step! m)
          (when (zero? (bit-and (inc c) 7))
            (cpu/tick-timers! m))
          (recur (inc c) e))))
    m))

(defn run
  "Build a machine from `rom` (a sequence of byte values), run it for
  `cycles` cycles with the optional key `schedule`, and return it."
  ([rom cycles] (run rom cycles []))
  ([rom cycles schedule]
   (run! (machine/make-machine rom) cycles schedule)))

(defn- hex [^long n ^long width]
  (let [s (Long/toHexString n)]
    (str (str/join (repeat (max 0 (- width (count s))) \0)) s)))

(defn format-state
  "Format machine `m` as the 34-line text report: the display, the CPU line
  and the register line. Every line ends with a newline."
  [^Machine m]
  (let [{:keys [pc i sp dt st v]} (machine/snapshot m)]
    (str (str/join (map #(str % "\n") (display/render m)))
         "PC=" (hex pc 4) " I=" (hex i 4) " SP=" sp
         " DT=" (hex dt 2) " ST=" (hex st 2) "\n"
         "V=" (str/join " " (map #(hex % 2) v)) "\n")))

(defn run-text
  "Run the emulator on the textual input `text` (see the input format in the
  README) and return the 34-line report as a string."
  [text]
  (let [{:keys [rom cycles keys]} (input/parse-input text)]
    (format-state (run rom cycles keys))))
