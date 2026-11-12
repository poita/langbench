(ns scheme.core
  "Public API of the Scheme interpreter library.

  Quick start:

      (require '[scheme.core :as scheme])

      (scheme/run-string \"(display (+ 1 2)) (newline) (* 6 7)\")
      ;; => \"3\\n42\\n\"

      (let [interp (scheme/make-interpreter)]
        (scheme/eval-string interp \"(define (sq x) (* x x))\")
        (scheme/eval-string interp \"(sq 12)\"))   ; => 144

  Scheme values are represented as described in `scheme.types`: integers are
  `Long`s (or `scheme.number.Bignum` beyond 64 bits), strings are Strings,
  booleans are Booleans, and so on. Use `scheme.printer` to print them."
  (:require [scheme.analyzer :as analyzer]
            [scheme.primitives :as prims]
            [scheme.printer :as printer]
            [scheme.reader :as reader]
            [scheme.runtime :as rt]
            [scheme.types :as t])
  (:import [java.io StringWriter Writer]
           [java.util HashMap]))

(set! *warn-on-reflection* true)

(defrecord Interpreter [^HashMap global ^Writer out])

(defn make-interpreter
  "A fresh interpreter whose global environment holds the primitives of
  SPEC.md. `display` and `newline` write to `out` (default: `*out*`)."
  (^Interpreter [] (make-interpreter *out*))
  (^Interpreter [^Writer out]
   (let [g (HashMap.)]
     (prims/install! g out)
     (->Interpreter g out))))

(defn eval-datum
  "Evaluate one already-read datum in `interp` and return its value (`void?`
  values are `scheme.types/VOID`). Throws an exception for runtime errors; see
  `error-category`."
  [^Interpreter interp datum]
  (rt/force-value (.ev ^scheme.types.Node (analyzer/analyze (.global interp) datum false) nil)))

(defn eval-string
  "Evaluate every form in `src` in `interp`; return the value of the last
  (`scheme.types/VOID` if there are none)."
  [^Interpreter interp ^String src]
  (let [r (reader/reader src)]
    (loop [v t/VOID]
      (let [d (reader/read-datum r)]
        (if (identical? d reader/eof)
          v
          (recur (eval-datum interp d)))))))

(def error-category
  "The category keyword (:type-error, :arity-error, :unbound-variable,
  :division-by-zero, :user-error) of an exception thrown by evaluation, or nil
  if it is not a Scheme runtime error."
  t/error-category)

(defn run-program
  "Run the program text `src` the way the command-line tool does: evaluate the
  forms in order, writing the *write* form of each non-void value, plus
  anything the program displays, to `out`. On a runtime error writes
  `error: <category>` and stops. Returns nil on success, or the error
  category keyword. Malformed program text throws an exception satisfying
  `scheme.reader/syntax-error?` (after earlier forms have run)."
  [^String src ^Writer out]
  (let [interp (make-interpreter out)
        r (reader/reader src)]
    (try
      (loop []
        (let [d (reader/read-datum r)]
          (when-not (identical? d reader/eof)
            (let [v (eval-datum interp d)]
              (when-not (t/void? v)
                (.write out (printer/write-str v))
                (.write out "\n"))
              (recur)))))
      nil
      (catch clojure.lang.ExceptionInfo e
        (if-let [category (t/error-category e)]
          (do (.write out (str "error: " (name category) "\n"))
              category)
          (throw e))))))

(defn- call-on-big-stack
  "Run `f` on a thread with a large stack, so deep non-tail recursion works."
  [f]
  (let [result (promise)
        thread (Thread. nil
                        (fn [] (deliver result (try {:ok (f)}
                                                    (catch Throwable e {:error e}))))
                        "scheme"
                        (* 1024 1024 1024))]
    (.start thread)
    (let [{:keys [ok error]} @result]
      (if error (throw error) ok))))

(defn run-string
  "Run the program text `src` (see `run-program`) and return its complete
  output as a string. Runs on a large-stack thread."
  ^String [^String src]
  (let [out (StringWriter.)]
    (call-on-big-stack #(run-program src out))
    (.toString out)))

(defn run-program-big-stack
  "Like `run-program`, but on a thread with a 1 GiB stack so that non-tail
  recursion at least 10,000 deep works. Used by the command-line tool."
  [^String src ^Writer out]
  (call-on-big-stack #(run-program src out)))
