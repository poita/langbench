(ns langvm.core
  "Public API of the Vellum compiler and virtual machine.

  The whole pipeline is available as one call, [[execute]], or in stages:

      (-> source compile-source (run-compiled out))

  A *source* is a module stream (SPEC section 2): `@module name` header lines
  each followed by that module's text."
  (:require [langvm.check :as check]
            [langvm.compile :as compile]
            [langvm.diag :as diag]
            [langvm.lexer :as lexer]
            [langvm.parser :as parser]
            [langvm.program :as program]
            [langvm.source :as source]
            [langvm.stdlib :as stdlib]
            [langvm.vm :as vm]))

(set! *warn-on-reflection* true)

(def ^:private compiler-stack-bytes
  "Stack size of the thread that runs the front end: deeply nested programs
  recurse deeply in the parser, checker and compiler."
  (* 512 1024 1024))

(defn- with-big-stack
  "Call `f` on a fresh thread with a large stack and return its result,
  rethrowing anything it throws."
  [f]
  (let [result (promise)
        thread (Thread. nil
                        (bound-fn []
                          (deliver result (try {:value (f)} (catch Throwable e {:error e}))))
                        "langvm-compile" compiler-stack-bytes)]
    (.start thread)
    (.join thread)
    (let [{:keys [value error]} @result]
      (if error (throw error) value))))

(defn parse-source
  "Run passes 0 to 2: split `text` into modules, lex and parse each.  Returns
  a vector of `{:name :items}` or throws a diagnostic (see `langvm.diag`)."
  [text]
  (let [mods (source/split-modules text)
        toks (mapv #(lexer/lex (:lines %)) mods)]
    (mapv (fn [m ts] {:name (:name m) :items (parser/parse-module ts)}) mods toks)))

(defn check-source
  "Run passes 0 to 4.  Returns `{:program prog :bodies typed-bodies}` or throws
  a diagnostic."
  [text]
  (with-big-stack
    (fn []
      (let [modules (parse-source text)
            prog (program/build modules stdlib/signatures)
            bodies (check/check-program prog)]
        {:program prog :bodies bodies}))))

(defn compile-source
  "Compile `text` to a bytecode program, or throw a diagnostic."
  [text]
  (with-big-stack
    (fn []
      (let [{:keys [program bodies]} (check-source text)]
        (compile/compile-program program bodies)))))

(defn run-compiled
  "Run a compiled program, writing its output to the `java.io.OutputStream`
  `out`.  Returns nil, or the panic message when the program panicked (the
  `panic: ...` line has already been written to `out`)."
  [compiled ^java.io.OutputStream out]
  (when-let [msg (vm/run compiled out)]
    (.write out (.getBytes (str "panic: " msg "\n") java.nio.charset.StandardCharsets/UTF_8))
    msg))

(defn execute
  "Compile and run `text`, writing everything the tool should print to `out`
  (program output, a panic line, or a single diagnostic line).  Returns
  `:ok`, `:panic` or `:error`."
  [text ^java.io.OutputStream out]
  (let [compiled (try (compile-source text)
                      (catch clojure.lang.ExceptionInfo e
                        (if (diag/diagnostic? e)
                          (do (.write out (.getBytes (str (diag/format-diag e) "\n")
                                                     java.nio.charset.StandardCharsets/UTF_8))
                              nil)
                          (throw e))))]
    (cond
      (nil? compiled) :error
      (run-compiled compiled out) :panic
      :else :ok)))

(defn run-string
  "Convenience for tests and the REPL: execute `text` and return the output as
  a string."
  [text]
  (let [out (java.io.ByteArrayOutputStream.)]
    (execute text out)
    (.toString out "UTF-8")))
