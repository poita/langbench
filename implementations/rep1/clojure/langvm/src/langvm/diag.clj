(ns langvm.diag
  "Compile-time diagnostics.

  A diagnostic is signalled by throwing an `ex-info` whose data carries
  `:langvm/diag true`, the error `:kind` (a keyword such as `:type-mismatch`)
  and a packed source `:pos`.  Positions are packed into one long
  (`line << 16 | col`) so that tokens and AST nodes stay small.")

(set! *warn-on-reflection* true)

(defn pos
  "Pack a 1-based `line` and `col` into a position."
  ^long [^long line ^long col]
  (bit-or (bit-shift-left line 16) (bit-and col 0xffff)))

(defn pos-line ^long [^long p] (bit-shift-right p 16))
(defn pos-col ^long [^long p] (bit-and p 0xffff))

(defn fail
  "Signal the compile error `kind` at position `p`."
  [kind p]
  (throw (ex-info (name kind) {:langvm/diag true :kind kind :pos p})))

(defn diagnostic?
  "True when `e` is an exception thrown by [[fail]]."
  [e]
  (boolean (and (instance? clojure.lang.ExceptionInfo e)
                (:langvm/diag (ex-data e)))))

(defn format-diag
  "Render a diagnostic exception as the one-line `error: ...` message."
  [e]
  (let [{:keys [kind pos]} (ex-data e)]
    (str "error: " (name kind) " at " (pos-line pos) ":" (pos-col pos))))
