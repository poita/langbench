(ns chip8.cpu
  "Instruction fetch, decode and execution, and the timer tick.

  Every cycle the opcode is fetched from memory and decoded afresh; nothing
  is cached, so self-modifying programs behave correctly."
  (:require [chip8.display :as display]
            [chip8.font :as font]
            [chip8.machine :as machine :refer [PC I SP DT ST KEYS RNG]]
            [chip8.rng :as rng])
  (:import (chip8.machine Machine)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(defn- skip!
  "Advance PC past one instruction."
  [^longs r]
  (aset r PC (bit-and (+ (aget r PC) 2) 0xFFF)))

(defn- skip-if! [^longs r cond]
  (when cond (skip! r)))

(defn- op-0! [^Machine m ^long op]
  (let [^longs r (.-regs m)]
    (case op
      0x00E0 (display/clear! m)
      0x00EE (let [sp (dec (aget r SP))]
               (aset r SP sp)
               (aset r PC (aget ^ints (.-stack m) (bit-and sp 15))))
      nil)))

(defn- op-8! [^Machine m ^long op]
  (let [^ints v (.-v m)
        x (bit-and (bit-shift-right op 8) 0xF)
        y (bit-and (bit-shift-right op 4) 0xF)
        vx (aget v x)
        vy (aget v y)]
    (case (bit-and op 0xF)
      0x0 (aset v x vy)
      0x1 (aset v x (bit-or vx vy))
      0x2 (aset v x (bit-and vx vy))
      0x3 (aset v x (bit-xor vx vy))
      0x4 (let [sum (+ vx vy)]
            (aset v x (bit-and sum 0xFF))
            (aset v 0xF (if (> sum 255) 1 0)))
      0x5 (do (aset v x (bit-and (- vx vy) 0xFF))
              (aset v 0xF (if (>= vx vy) 1 0)))
      0x6 (do (aset v x (bit-shift-right vx 1))
              (aset v 0xF (bit-and vx 1)))
      0x7 (do (aset v x (bit-and (- vy vx) 0xFF))
              (aset v 0xF (if (>= vy vx) 1 0)))
      0xE (do (aset v x (bit-and (bit-shift-left vx 1) 0xFF))
              (aset v 0xF (bit-and (bit-shift-right vx 7) 1)))
      nil)))

(defn- op-f! [^Machine m ^long op]
  (let [^longs r (.-regs m)
        ^ints v (.-v m)
        ^ints mem (.-mem m)
        x (bit-and (bit-shift-right op 8) 0xF)
        vx (aget v x)]
    (case (bit-and op 0xFF)
      0x07 (aset v x (int (aget r DT)))
      0x0A (let [keys (aget r KEYS)]
             (if (zero? keys)
               (aset r PC (bit-and (- (aget r PC) 2) 0xFFF))
               (aset v x (int (Long/numberOfTrailingZeros keys)))))
      0x15 (aset r DT vx)
      0x18 (aset r ST vx)
      0x1E (aset r I (bit-and (+ (aget r I) vx) 0xFFFF))
      0x29 (aset r I (+ font/font-base (* (bit-and vx 0xF) font/glyph-size)))
      0x33 (let [i (aget r I)]
             (aset mem (bit-and i 0xFFF) (quot vx 100))
             (aset mem (bit-and (+ i 1) 0xFFF) (rem (quot vx 10) 10))
             (aset mem (bit-and (+ i 2) 0xFFF) (rem vx 10)))
      0x55 (let [i (aget r I)]
             (dotimes [k (inc x)]
               (aset mem (bit-and (+ i k) 0xFFF) (aget v k))))
      0x65 (let [i (aget r I)]
             (dotimes [k (inc x)]
               (aset v k (aget mem (bit-and (+ i k) 0xFFF)))))
      nil)))

(defn step!
  "Fetch and execute a single instruction on machine `m`. Does not apply key
  events or tick the timers; see `tick-timers!` and `chip8.core/run!`."
  [^Machine m]
  (let [^longs r (.-regs m)
        ^ints mem (.-mem m)
        pc (aget r PC)
        op (bit-or (bit-shift-left (aget mem pc) 8)
                   (aget mem (bit-and (+ pc 1) 0xFFF)))
        x (bit-and (bit-shift-right op 8) 0xF)
        y (bit-and (bit-shift-right op 4) 0xF)
        nn (bit-and op 0xFF)
        nnn (bit-and op 0xFFF)]
    (aset r PC (bit-and (+ pc 2) 0xFFF))
    (case (bit-shift-right op 12)
      0x0 (op-0! m op)
      0x1 (aset r PC nnn)
      0x2 (let [sp (aget r SP)]
            (aset ^ints (.-stack m) (bit-and sp 15) (int (aget r PC)))
            (aset r SP (inc sp))
            (aset r PC nnn))
      0x3 (skip-if! r (== (aget ^ints (.-v m) x) nn))
      0x4 (skip-if! r (not= (aget ^ints (.-v m) x) nn))
      0x5 (when (zero? (bit-and op 0xF))
            (skip-if! r (== (aget ^ints (.-v m) x) (aget ^ints (.-v m) y))))
      0x6 (aset ^ints (.-v m) x nn)
      0x7 (aset ^ints (.-v m) x (bit-and (+ (aget ^ints (.-v m) x) nn) 0xFF))
      0x8 (op-8! m op)
      0x9 (when (zero? (bit-and op 0xF))
            (skip-if! r (not= (aget ^ints (.-v m) x) (aget ^ints (.-v m) y))))
      0xA (aset r I nnn)
      0xB (aset r PC (bit-and (+ nnn (aget ^ints (.-v m) 0)) 0xFFF))
      0xC (let [s (rng/next-state (aget r RNG))]
            (aset r RNG s)
            (aset ^ints (.-v m) x (bit-and (rng/state->byte s) nn)))
      0xD (let [^ints v (.-v m)
                vf (display/draw-sprite! m (aget r I) (aget v x) (aget v y)
                                         (bit-and op 0xF))]
            (aset v 0xF (int vf)))
      0xE (let [k (bit-and (aget ^ints (.-v m) x) 0xF)
                down? (not (zero? (bit-and (bit-shift-right (aget r KEYS) k) 1)))]
            (case nn
              0x9E (skip-if! r down?)
              0xA1 (skip-if! r (not down?))
              nil))
      0xF (op-f! m op))
    nil))

(defn tick-timers!
  "Decrement the delay and sound timers, each stopping at zero."
  [^Machine m]
  (let [^longs r (.-regs m)]
    (when (pos? (aget r DT)) (aset r DT (dec (aget r DT))))
    (when (pos? (aget r ST)) (aset r ST (dec (aget r ST))))
    nil))
