(ns chip8.render
  "Formatting of machine state as the 34-line text report."
  (:require [chip8.machine :as m :refer [reg-pc reg-i reg-sp reg-dt reg-st]])
  (:import (chip8.machine Machine)))

(set! *warn-on-reflection* true)

(defn- hex [n width]
  (let [s (Long/toHexString n)]
    (str (apply str (repeat (- width (count s)) \0)) s)))

(defn display-lines
  "The display as 32 strings of 64 characters, `#` lit and `.` unlit."
  [^Machine m]
  (let [^ints disp (.-display m)]
    (mapv (fn [row]
            (let [sb (StringBuilder.)]
              (dotimes [col m/display-width]
                (.append sb (if (zero? (aget disp (+ (* (long row) m/display-width) col))) \. \#)))
              (str sb)))
          (range m/display-height))))

(defn status-line
  "The `PC=... I=... SP=... DT=... ST=...` line."
  [^Machine m]
  (let [^longs r (.-regs m)]
    (str "PC=" (hex (aget r reg-pc) 4)
         " I=" (hex (aget r reg-i) 4)
         " SP=" (aget r reg-sp)
         " DT=" (hex (aget r reg-dt) 2)
         " ST=" (hex (aget r reg-st) 2))))

(defn registers-line
  "The `V=xx xx ...` line."
  [^Machine m]
  (str "V=" (apply str (interpose " " (map #(hex % 2) (.-v m))))))

(defn report
  "The full output: 32 display rows, the status line and the register line,
  each terminated by a newline."
  [^Machine m]
  (str (apply str (map #(str % "\n") (display-lines m)))
       (status-line m) "\n"
       (registers-line m) "\n"))
