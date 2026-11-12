(ns spreadsheet.cli
  "Command-language interpreter: `set`, `get`, `clear` and `dump` commands,
  one per line, as specified for the command-line tool."
  (:require [clojure.string :as str]
            [spreadsheet.core :as core]))

(defn execute
  "Executes the command `line` against `sheet`. Returns `[sheet' output]`
  where `output` is a vector of output lines (possibly empty)."
  [sheet ^String line]
  (let [sp1 (.indexOf line " ")
        command (if (neg? sp1) line (subs line 0 sp1))]
    (case command
      "dump" [sheet (mapv (fn [[n v]] (str n " " v)) (core/dump sheet))]
      "get" [sheet [(core/display sheet (subs line (inc sp1)))]]
      "clear" [(core/clear-cell sheet (subs line (inc sp1))) []]
      "set" (let [sp2 (.indexOf line " " (int (inc sp1)))]
              [(core/set-cell sheet (subs line (inc sp1) sp2) (subs line (inc sp2))) []]))))

(defn run
  "Runs the sequence of command `lines` starting from an empty sheet, calling
  `emit` with each output line."
  [lines emit]
  (reduce (fn [sheet line]
            (let [[sheet' out] (execute sheet line)]
              (run! emit out)
              sheet'))
          (core/empty-sheet) lines))

(defn split-lines
  "Splits `text` on `\\n` only (a trailing newline does not add an empty line)."
  [^String text]
  (let [lines (str/split text #"\n" -1)]
    (if (= "" (peek lines)) (pop lines) lines)))
