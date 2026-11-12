(ns chip8.cpu
  "The fetch-decode-execute interpreter.

  Every cycle fetches the opcode from memory at PC, decodes and executes it,
  and ticks the timers; nothing is cached or pre-decoded."
  (:require [chip8.font :as font]
            [chip8.machine :as m :refer [reg-pc reg-i reg-sp reg-dt reg-st
                                         reg-rng reg-keys reg-cycles]])
  (:import (chip8.machine Machine)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(defmacro ^:private reg [regs k] `(aget ~regs ~k))
(defmacro ^:private set-reg! [regs k val] `(aset ~regs ~k (long ~val)))
(defmacro ^:private set-v! [v i val] `(aset ~v (int ~i) (unchecked-int ~val)))
(defmacro ^:private skip! [regs]
  `(aset ~regs reg-pc (bit-and (+ (aget ~regs reg-pc) 2) 0xFFF)))

(defn- next-random!
  "Advances the LCG and returns the next random byte."
  ^long [^longs regs]
  (let [s (bit-and (+ (* (aget regs reg-rng) 1103515245) 12345) 0xFFFFFFFF)]
    (aset regs reg-rng s)
    (bit-and (bit-shift-right s 16) 0xFF)))

(defn- draw! [^Machine m ^long x ^long y ^long n]
  (let [^ints mem (.-mem m) ^ints v (.-v m) ^longs regs (.-regs m) ^ints disp (.-display m)
        sx (bit-and (aget v x) 63)
        sy (bit-and (aget v y) 31)
        i (reg regs reg-i)]
    (loop [row 0 hit 0]
      (if (< row n)
        (let [b (aget mem (bit-and (+ i row) 0xFFF))
              py (bit-and (+ sy row) 31)
              hit (long (loop [bit 0 hit hit]
                    (if (< bit 8)
                      (if (zero? (bit-and (bit-shift-right b (- 7 bit)) 1))
                        (recur (inc bit) hit)
                        (let [idx (+ (* py 64) (bit-and (+ sx bit) 63))
                              old (aget disp idx)]
                          (aset disp idx (bit-xor old 1))
                          (recur (inc bit) (bit-or hit old))))
                      hit)))]
          (recur (inc row) hit))
        (set-v! v 0xF hit)))))

(defn- exec-alu!
  "Opcodes 8XYN."
  [^Machine m ^long x ^long y ^long n]
  (let [^ints v (.-v m)
        vx (aget v x)
        vy (aget v y)]
    (case n
      0 (set-v! v x vy)
      1 (set-v! v x (bit-or vx vy))
      2 (set-v! v x (bit-and vx vy))
      3 (set-v! v x (bit-xor vx vy))
      4 (let [sum (+ vx vy)]
          (set-v! v x (bit-and sum 0xFF))
          (set-v! v 0xF (if (> sum 255) 1 0)))
      5 (do (set-v! v x (bit-and (- vx vy) 0xFF))
            (set-v! v 0xF (if (>= vx vy) 1 0)))
      6 (do (set-v! v x (bit-shift-right vx 1))
            (set-v! v 0xF (bit-and vx 1)))
      7 (do (set-v! v x (bit-and (- vy vx) 0xFF))
            (set-v! v 0xF (if (>= vy vx) 1 0)))
      0xE (do (set-v! v x (bit-and (bit-shift-left vx 1) 0xFF))
              (set-v! v 0xF (bit-and (bit-shift-right vx 7) 1)))
      nil)))

(defn- exec-f!
  "Opcodes FXNN."
  [^Machine m ^long x ^long nn]
  (let [^ints v (.-v m) ^longs regs (.-regs m) ^ints mem (.-mem m)
        vx (aget v x)]
    (case nn
      0x07 (set-v! v x (reg regs reg-dt))
      0x0A (let [keys (reg regs reg-keys)]
             (if (zero? keys)
               (set-reg! regs reg-pc (bit-and (- (reg regs reg-pc) 2) 0xFFF))
               (set-v! v x (Long/numberOfTrailingZeros keys))))
      0x15 (set-reg! regs reg-dt vx)
      0x18 (set-reg! regs reg-st vx)
      0x1E (set-reg! regs reg-i (bit-and (+ (reg regs reg-i) vx) 0xFFFF))
      0x29 (set-reg! regs reg-i (+ font/font-address (* (bit-and vx 0xF) font/glyph-size)))
      0x33 (let [i (reg regs reg-i)]
             (aset mem (bit-and i 0xFFF) (unchecked-int (quot vx 100)))
             (aset mem (bit-and (+ i 1) 0xFFF) (unchecked-int (rem (quot vx 10) 10)))
             (aset mem (bit-and (+ i 2) 0xFFF) (unchecked-int (rem vx 10))))
      0x55 (let [i (reg regs reg-i)]
             (dotimes [k (inc x)]
               (aset mem (bit-and (+ i k) 0xFFF) (aget v k))))
      0x65 (let [i (reg regs reg-i)]
             (dotimes [k (inc x)]
               (aset v k (aget mem (bit-and (+ i k) 0xFFF)))))
      nil)))

(defn- execute!
  "Fetches and executes one instruction."
  [^Machine m]
  (let [^ints mem (.-mem m) ^ints v (.-v m) ^longs regs (.-regs m)
        pc (reg regs reg-pc)
        op (bit-or (bit-shift-left (aget mem pc) 8)
                   (aget mem (bit-and (+ pc 1) 0xFFF)))
        x (bit-and (bit-shift-right op 8) 0xF)
        y (bit-and (bit-shift-right op 4) 0xF)
        n (bit-and op 0xF)
        nn (bit-and op 0xFF)
        nnn (bit-and op 0xFFF)]
    (set-reg! regs reg-pc (bit-and (+ pc 2) 0xFFF))
    (case (bit-shift-right op 12)
      0 (case op
          0x00E0 (java.util.Arrays/fill ^ints (.-display m) 0)
          0x00EE (let [sp (dec (reg regs reg-sp))]
                   (set-reg! regs reg-sp sp)
                   (set-reg! regs reg-pc (aget ^ints (.-stack m) sp)))
          nil)
      1 (set-reg! regs reg-pc nnn)
      2 (let [sp (reg regs reg-sp)]
          (aset ^ints (.-stack m) sp (unchecked-int (reg regs reg-pc)))
          (set-reg! regs reg-sp (inc sp))
          (set-reg! regs reg-pc nnn))
      3 (when (== (aget v x) nn) (skip! regs))
      4 (when (not= (aget v x) nn) (skip! regs))
      5 (when (and (zero? n) (== (aget v x) (aget v y))) (skip! regs))
      6 (set-v! v x nn)
      7 (set-v! v x (bit-and (+ (aget v x) nn) 0xFF))
      8 (exec-alu! m x y n)
      9 (when (and (zero? n) (not= (aget v x) (aget v y))) (skip! regs))
      0xA (set-reg! regs reg-i nnn)
      0xB (set-reg! regs reg-pc (bit-and (+ nnn (aget v 0)) 0xFFF))
      0xC (set-v! v x (bit-and (next-random! regs) nn))
      0xD (draw! m x y n)
      0xE (case nn
            0x9E (when-not (zero? (bit-and (bit-shift-right (reg regs reg-keys) (bit-and (aget v x) 0xF)) 1))
                   (skip! regs))
            0xA1 (when (zero? (bit-and (bit-shift-right (reg regs reg-keys) (bit-and (aget v x) 0xF)) 1))
                   (skip! regs))
            nil)
      0xF (exec-f! m x nn))
    nil))

(defn step!
  "Executes one full cycle on `m`: fetch, decode, execute, then the timer
  tick if the number of completed cycles is now a multiple of 8. Key state
  is not touched; use `chip8.machine/set-keys!` beforehand. Returns `m`."
  [^Machine m]
  (execute! m)
  (let [^longs regs (.-regs m)
        done (inc (reg regs reg-cycles))]
    (set-reg! regs reg-cycles done)
    (when (zero? (bit-and done 7))
      (let [dt (reg regs reg-dt) st (reg regs reg-st)]
        (when (pos? dt) (set-reg! regs reg-dt (dec dt)))
        (when (pos? st) (set-reg! regs reg-st (dec st))))))
  m)

(defn run-cycles!
  "Runs `m` for exactly `cycles` cycles. `schedule` is a seq of
  `[cycle mask]` pairs in strictly increasing cycle order; each is applied
  just before its cycle executes. Events are consumed in order, O(1) per
  cycle. Returns `m`."
  [^Machine m ^long cycles schedule]
  (let [events (long-array (map first schedule))
        masks (long-array (map second schedule))
        n-events (alength events)]
    (loop [c 0 e 0]
      (when (< c cycles)
        (let [e (if (and (< e n-events) (== c (aget events e)))
                  (do (m/set-keys! m (aget masks e)) (inc e))
                  e)]
          (step! m)
          (recur (inc c) e)))))
  m)
