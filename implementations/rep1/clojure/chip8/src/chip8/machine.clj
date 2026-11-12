(ns chip8.machine
  "The CHIP-8 machine model: a mutable, fixed-size state container.

  Memory, registers, stack and display are primitive arrays; the scalar
  registers (PC, I, SP, DT, ST, key mask and RNG state) live in a single
  `long-array` addressed by the index constants below. All mutation is done
  through the functions in this namespace and in `chip8.cpu`."
  (:require [chip8.font :as font]
            [chip8.rng :as rng]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def memory-size 4096)
(def rom-start 0x200)
(def max-rom-size (- memory-size rom-start))
(def display-width 64)
(def display-height 32)
(def stack-depth 16)

;; Indices into the scalar register array.
(def ^:const PC 0)
(def ^:const I 1)
(def ^:const SP 2)
(def ^:const DT 3)
(def ^:const ST 4)
(def ^:const KEYS 5)
(def ^:const RNG 6)

(defrecord Machine [^ints mem        ; 4096 ints, each 0-255
                    ^ints v          ; V0..VF
                    ^ints stack      ; 16 return addresses
                    ^bytes screen    ; 64*32 pixels, row-major, 0 or 1
                    ^longs regs])    ; PC I SP DT ST KEYS RNG

(defn make-machine
  "Create a fresh machine with the font installed and `rom` (a sequence of
  byte values 0-255) loaded at 0x200. Throws if the ROM does not fit."
  ^Machine [rom]
  (let [rom (vec rom)]
    (when (> (count rom) max-rom-size)
      (throw (ex-info "ROM too large" {:size (count rom) :max max-rom-size})))
    (let [mem (int-array memory-size)
          regs (long-array 7)]
      (doseq [[k b] (map-indexed vector font/font-bytes)]
        (aset mem (+ font/font-base (long k)) (int b)))
      (doseq [[k b] (map-indexed vector rom)]
        (aset mem (+ rom-start (long k)) (bit-and (long b) 0xFF)))
      (aset regs PC rom-start)
      (aset regs RNG rng/seed)
      (->Machine mem
                 (int-array 16)
                 (int-array stack-depth)
                 (byte-array (* display-width display-height))
                 regs))))

(defn set-keys!
  "Set the held-key state to the 16-bit `mask` (bit k = key k is down)."
  [^Machine m ^long mask]
  (aset ^longs (.-regs m) KEYS (bit-and mask 0xFFFF)))

(defn reg
  "Read scalar register `idx` (one of PC, I, SP, DT, ST, KEYS, RNG)."
  ^long [^Machine m ^long idx]
  (aget ^longs (.-regs m) idx))

(defn snapshot
  "An immutable summary of the CPU state as a map:
  `{:pc :i :sp :dt :st :v [..16 values..]}`."
  [^Machine m]
  {:pc (reg m PC) :i (reg m I) :sp (reg m SP)
   :dt (reg m DT) :st (reg m ST)
   :v (vec (map long (.-v m)))})

(defn pixels
  "The display as a vector of 32 rows, each a vector of 64 booleans."
  [^Machine m]
  (let [^bytes s (.-screen m)]
    (vec (for [y (range display-height)]
           (vec (for [x (range display-width)]
                  (= 1 (aget s (+ (* y display-width) x)))))))))
