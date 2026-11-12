(ns chip8.display
  "The 64x32 monochrome display: sprite drawing and text rendering."
  (:require [chip8.machine :as machine :refer [display-width display-height]])
  (:import (chip8.machine Machine)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(defn clear!
  "Turn every pixel off."
  [^Machine m]
  (java.util.Arrays/fill ^bytes (.-screen m) (byte 0))
  nil)

(defn draw-sprite!
  "XOR the `n`-row sprite stored at `addr` onto the display with its origin at
  (`x`, `y`). The origin is reduced modulo the display size and the sprite
  wraps at the edges. Returns 1 if any lit pixel was turned off, else 0."
  [^Machine m addr x y n]
  (let [addr (long addr)
        x (long x)
        y (long y)
        n (long n)
        ^bytes screen (.-screen m)
        ^ints mem (.-mem m)
        sx (bit-and x 63)
        sy (bit-and y 31)]
    (loop [row 0 vf 0]
      (if (< row n)
        (let [b (aget mem (bit-and (+ addr row) 0xFFF))
              py (bit-and (+ sy row) 31)
              vf (loop [bit 0 vf vf]
                   (if (< bit 8)
                     (if (zero? (bit-and (bit-shift-right b (- 7 bit)) 1))
                       (recur (inc bit) vf)
                       (let [idx (+ (* py 64) (bit-and (+ sx bit) 63))
                             old (aget screen idx)]
                         (aset screen idx (byte (bit-xor old 1)))
                         (recur (inc bit) (bit-or vf old))))
                     vf))]
          (recur (inc row) vf))
        vf))))

(defn row-string
  "Render display row `y` as a 64-character string of `#` and `.`."
  [^Machine m ^long y]
  (let [^bytes screen (.-screen m)
        sb (StringBuilder. (int display-width))]
    (dotimes [x display-width]
      (.append sb (if (== 1 (aget screen (+ (* y display-width) x))) \# \.)))
    (str sb)))

(defn render
  "Render the whole display as a vector of 32 strings."
  [^Machine m]
  (mapv #(row-string m %) (range display-height)))
