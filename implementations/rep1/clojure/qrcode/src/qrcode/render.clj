(ns qrcode.render
  "Text rendering of encoded symbols in the CLI's output format."
  (:require [qrcode.matrix :as matrix])
  (:import (qrcode.matrix Grid)))

(set! *warn-on-reflection* true)

(defn append-symbol!
  "Appends the textual form of `sym` (a result of `qrcode.core/encode`) to
  the StringBuilder `sb`:

      version <v> mask <m>
      <size rows of # and .>
      <empty line>"
  [^StringBuilder sb {:keys [version mask grid]}]
  (let [^Grid g grid
        n (.-size g)
        modules ^bytes (.-modules g)]
    (.append sb "version ")
    (.append sb (long version))
    (.append sb " mask ")
    (.append sb (long mask))
    (.append sb \newline)
    (dotimes [y n]
      (dotimes [x n]
        (.append sb (if (== 1 (aget modules (+ (* y n) x))) \# \.)))
      (.append sb \newline))
    (.append sb \newline)
    sb))

(defn ->text
  "The textual form of `sym` as a string."
  [sym]
  (str (append-symbol! (StringBuilder.) sym)))
