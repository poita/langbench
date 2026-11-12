(ns buildsys.eval
  "The tree-walking evaluator: runs parsed build files over a chain of lexical
  scopes and produces the step list, phony table and default targets.

  `evaluate` is the entry point.  The evaluation context is a map of mutable
  accumulators (volatiles) plus the workspace snapshot `glob` reads."
  (:require [buildsys.errors :as e]
            [buildsys.value :as v]
            [buildsys.vfs :as vfs]
            [buildsys.builtins :as builtins]
            [buildsys.commands :as commands]
            [buildsys.parser :as parser]))

(set! *warn-on-reflection* true)

(def ^:private max-rule-depth 64)

;; ------------------------------------------------------------------ scopes

(defn- new-scope [parent] {:vars (volatile! {}) :parent parent})

(defn- lookup [scope ^String name]
  (loop [s scope]
    (when s
      (let [m @(:vars s)]
        (if (contains? m name)
          [(get m name)]
          (recur (:parent s)))))))

;; ------------------------------------------------------------- expressions

(declare ev)

(defn- ev-call [ctx scope name arg-exprs]
  (when-not (builtins/known? name) (e/fail! "E_UNKNOWN_FUNC" name))
  (let [args (mapv #(ev ctx scope %) arg-exprs)]
    (builtins/call (:vfs ctx) name args)))

(defn- ev-index [ctx scope xe ie]
  (let [x (ev ctx scope xe)
        i (ev ctx scope ie)]
    (v/expect-int! "index" i)
    (when-not (or (string? x) (vector? x)) (v/type-error! "index target" "str|list" x))
    (let [n (count x) i (long i) j (if (neg? i) (+ n i) i)]
      (when-not (and (<= 0 j) (< j n)) (e/fail! "E_ARG" "fn index: out of range"))
      (if (string? x) (subs x j (inc j)) (nth x j)))))

(defn- ev-binary [op a b]
  (let [site (str "operator " op)]
    (case op
      ("==" "!=") (let [eq (= a b)] (if (= op "==") eq (not eq)))
      ("<" "<=" ">" ">=")
      (let [c (v/compare-values a b)]
        (case op "<" (neg? c) "<=" (<= c 0) ">" (pos? c) ">=" (>= c 0)))
      "++" (do (v/expect-list! site a) (v/expect-list! site b) (into a b))
      "~" (do (v/expect-str! site a) (v/expect-str! site b) (str a b))
      (do (v/expect-int! site a) (v/expect-int! site b)
          (let [a (long a) b (long b)]
            (case op
              "+" (unchecked-add a b)
              "-" (unchecked-subtract a b)
              "*" (unchecked-multiply a b)
              ("/" "%") (do (when (zero? b) (e/fail! "E_DIV_ZERO"))
                            (if (= op "/") (quot a b) (rem a b)))))))))

(defn- ev-interp [ctx scope parts]
  (let [sb (StringBuilder.)]
    (doseq [p parts]
      (.append sb ^String (if (string? p) p (v/->text (ev ctx scope p)))))
    (str sb)))

(defn- ev [ctx scope expr]
  (case (nth expr 0)
    :const (nth expr 1)
    :var (let [name (nth expr 1)]
           (if-let [[val] (lookup scope name)] val (e/fail! "E_UNKNOWN_VAR" name)))
    :interp (ev-interp ctx scope (nth expr 1))
    :list (mapv #(ev ctx scope %) (nth expr 1))
    :or (let [a (v/expect-bool! "operator ||" (ev ctx scope (nth expr 1)))]
          (if a true (v/expect-bool! "operator ||" (ev ctx scope (nth expr 2)))))
    :and (let [a (v/expect-bool! "operator &&" (ev ctx scope (nth expr 1)))]
           (if a (v/expect-bool! "operator &&" (ev ctx scope (nth expr 2))) false))
    :bin (let [a (ev ctx scope (nth expr 2))
               b (ev ctx scope (nth expr 3))]
           (ev-binary (nth expr 1) a b))
    :un (let [x (ev ctx scope (nth expr 2))]
          (if (= "!" (nth expr 1))
            (not (v/expect-bool! "operator !" x))
            (unchecked-negate (long (v/expect-int! "operator -" x)))))
    :index (ev-index ctx scope (nth expr 1) (nth expr 2))
    :call (ev-call ctx scope (nth expr 1) (nth expr 2))))

;; -------------------------------------------------------------------- steps

(defn- reference-ok?
  "True for `@` + identifier-shaped phony name, or a workspace path."
  [^String s]
  (if (.startsWith s "@")
    (boolean (re-matches #"[A-Za-z_][A-Za-z0-9_]*" (subs s 1)))
    (vfs/valid-path? s)))

(defn- check-references! [refs]
  (doseq [r refs] (when-not (reference-ok? r) (e/fail! "E_BAD_PATH" r))))

(defn- validate-step!
  "Closing-brace validation of a step under construction."
  [{:keys [cmd outs depfile ins afters] :as step}]
  (when-not cmd (e/fail! "E_STEP_FIELD" "missing cmd"))
  (when (empty? outs) (e/fail! "E_STEP_FIELD" "missing out"))
  (doseq [p (if depfile (conj outs depfile) outs)]
    (when-not (vfs/valid-path? p) (e/fail! "E_BAD_PATH" p))
    (when-not (vfs/generated-path? p) (e/fail! "E_OUTPUT_PATH" p)))
  (check-references! ins)
  (check-references! afters)
  (let [file-ins (vec (remove #(.startsWith ^String % "@") ins))]
    (commands/check-shape! (:name cmd) (count file-ins) (count outs) (some? depfile))
    (commands/check-args! (:name cmd) (:args cmd))
    file-ins))

(defn- exec-field [ctx scope step field]
  (let [expr (:expr field)]
    (case (:f field)
      :out (update step :outs into (v/expect-strlist! "field out" (ev ctx scope expr)))
      :in (update step :ins into (v/expect-strlist! "field in" (ev ctx scope expr)))
      :after (update step :afters into (v/expect-strlist! "field after" (ev ctx scope expr)))
      :cost (do (when (some? (:cost step)) (e/fail! "E_STEP_FIELD" "duplicate cost"))
                (let [c (v/expect-int! "field cost" (ev ctx scope expr))]
                  (when (neg? (long c)) (e/fail! "E_ARG" "field cost: negative"))
                  (assoc step :cost c)))
      :depfile (do (when (some? (:depfile step)) (e/fail! "E_STEP_FIELD" "duplicate depfile"))
                   (assoc step :depfile (v/expect-str! "field depfile" (ev ctx scope expr))))
      :cmd (let [{:keys [name args]} field]
             (when (:cmd step) (e/fail! "E_STEP_FIELD" "duplicate cmd"))
             (when-not (commands/known? name) (e/fail! "E_UNKNOWN_CMD" name))
             (let [vals (mapv #(ev ctx scope %) args)
                   types (:args (commands/table name))]
               (when-not (= (count vals) (count types))
                 (e/fail! "E_ARITY" (str "cmd " name ": expected " (count types) ", got " (count vals))))
               (dotimes [i (count vals)]
                 (let [t (nth types i) x (nth vals i)]
                   (when-not (if (= t :str) (string? x) (integer? x))
                     (v/type-error! (str "cmd " name " argument " (inc i)) (commands/type-token t) x))))
               (assoc step :cmd {:name name :args vals}))))))

(defn- exec-step [ctx scope {:keys [fields]}]
  (let [step (reduce #(exec-field ctx scope %1 %2)
                     {:outs [] :ins [] :afters [] :cost nil :depfile nil :cmd nil}
                     fields)
        file-ins (validate-step! step)
        {:keys [name args]} (:cmd step)]
    (vswap! (:steps ctx)
            (fn [steps]
              (conj steps
                    {:serial   (count steps)
                     :outs     (:outs step)
                     :depfile  (:depfile step)
                     :outputs  (if (:depfile step) (conj (:outs step) (:depfile step)) (:outs step))
                     :primary  (nth (:outs step) 0)
                     :ins      (:ins step)
                     :file-ins file-ins
                     :afters   (:afters step)
                     :cost     (long (or (:cost step) (:cost (commands/table name))))
                     :cmd-name name
                     :cmd-args args
                     :cmd-str  (commands/canonical name args)})))))

;; -------------------------------------------------------------- statements

(declare exec-stmts)

(defn- bind-rule-args! [ctx scope rule arg-vals kw-vals]
  (let [{:keys [name params]} rule
        vars (:vars scope)
        pnames (mapv first params)
        npos (count arg-vals)]
    (when (> npos (count params))
      (e/fail! "E_ARITY" (str "rule " name ": expected " (count params) ", got " npos)))
    (dotimes [i npos] (vswap! vars assoc (nth pnames i) (nth arg-vals i)))
    (doseq [[k val] kw-vals]
      (when-not (some #{k} pnames)
        (e/fail! "E_ARG" (str "rule " name ": unknown argument " k)))
      (when (contains? @vars k)
        (e/fail! "E_ARG" (str "rule " name ": duplicate argument " k)))
      (vswap! vars assoc k val))
    (doseq [[p dflt] params]
      (when-not (contains? @vars p)
        (if dflt
          (vswap! vars assoc p (ev ctx scope dflt))
          (e/fail! "E_ARG" (str "rule " name ": missing argument " p)))))))

(defn- exec-use [ctx scope depth {:keys [name pos kw]}]
  (let [rule (get @(:rules ctx) name)]
    (when-not rule (e/fail! "E_UNKNOWN_RULE" name))
    (when (>= depth max-rule-depth) (e/fail! "E_RULE_RECURSION" name))
    (let [arg-vals (mapv #(ev ctx scope %) pos)
          kw-vals (mapv (fn [[k x]] [k (ev ctx scope x)]) kw)
          inner (new-scope (:scope rule))]
      (bind-rule-args! ctx inner rule arg-vals kw-vals)
      (exec-stmts ctx inner (:body rule) (inc depth)))))

(defn- exec-include [ctx scope depth expr]
  (let [path (v/expect-str! "include path" (ev ctx scope expr))]
    (when-not (vfs/valid-path? path) (e/fail! "E_BAD_PATH" path))
    (when-not (vfs/exists? (:vfs ctx) path) (e/fail! "E_INCLUDE_MISSING" path))
    (when (some #{path} @(:include-stack ctx)) (e/fail! "E_INCLUDE_CYCLE" path))
    (let [stmts (parser/parse-file path (vfs/content (:vfs ctx) path))]
      (vswap! (:include-stack ctx) conj path)
      (exec-stmts ctx scope stmts depth)
      (vswap! (:include-stack ctx) pop))))

(defn- exec-phony [ctx scope {:keys [name expr]}]
  (let [deps (v/expect-strlist! (str "phony " name) (ev ctx scope expr))]
    (check-references! deps)
    (when (contains? @(:phony-names ctx) name) (e/fail! "E_DUP_PHONY" name))
    (vswap! (:phony-names ctx) conj name)
    (vswap! (:phonies ctx) conj {:name name :deps deps})))

(defn- exec-stmt [ctx scope depth stmt]
  (case (:op stmt)
    :let (let [val (ev ctx scope (:expr stmt)) vars (:vars scope)]
           (when (contains? @vars (:name stmt)) (e/fail! "E_REDEFINE" (:name stmt)))
           (vswap! vars assoc (:name stmt) val))
    :set (let [val (ev ctx scope (:expr stmt))
               target (loop [s scope]
                        (cond (nil? s) nil
                              (contains? @(:vars s) (:name stmt)) s
                              :else (recur (:parent s))))]
           (when-not target (e/fail! "E_SET_UNDEFINED" (:name stmt)))
           (vswap! (:vars target) assoc (:name stmt) val))
    :include (exec-include ctx scope depth (:expr stmt))
    :abort (e/fail! "E_ABORT" (v/expect-str! "abort message" (ev ctx scope (:expr stmt))))
    :default (let [xs (v/expect-strlist! "default" (ev ctx scope (:expr stmt)))]
               (vswap! (:defaults ctx) into xs))
    :phony (exec-phony ctx scope stmt)
    :when (let [{:keys [branches otherwise]} stmt
                taken (loop [bs branches]
                        (when-let [[[c body] & more] (seq bs)]
                          (if (v/expect-bool! "when condition" (ev ctx scope c))
                            body
                            (recur more))))
                body (or taken otherwise)]
            (when body (exec-stmts ctx (new-scope scope) body depth)))
    :each (let [xs (v/expect-list! "each subject" (ev ctx scope (:expr stmt)))]
            (dotimes [i (count xs)]
              (let [inner (new-scope scope)]
                (when (:idx stmt) (vswap! (:vars inner) assoc (:idx stmt) (long i)))
                (vswap! (:vars inner) assoc (:name stmt) (nth xs i))
                (exec-stmts ctx inner (:body stmt) depth))))
    :rule (let [name (:name stmt)]
            (when (contains? @(:rules ctx) name) (e/fail! "E_REDEFINE" name))
            (vswap! (:rules ctx) assoc name {:name name :params (:params stmt)
                                             :body (:body stmt) :scope scope}))
    :use (exec-use ctx scope depth stmt)
    :step (exec-step ctx scope stmt)))

(defn- exec-stmts [ctx scope stmts depth]
  (doseq [s stmts] (exec-stmt ctx scope depth s)))

;; ------------------------------------------------------------------ driver

(defn evaluate
  "Evaluates build file `main-path` (and everything it includes) against
  workspace `vfs`.  Returns {:steps [...] :phonies [...] :defaults [...]}."
  [vfs main-path]
  (let [ctx {:vfs vfs
             :steps (volatile! []) :phonies (volatile! []) :phony-names (volatile! #{})
             :rules (volatile! {}) :defaults (volatile! []) :include-stack (volatile! [main-path])}
        stmts (parser/parse-file main-path (vfs/content vfs main-path))]
    (exec-stmts ctx (new-scope nil) stmts 0)
    {:steps @(:steps ctx) :phonies @(:phonies ctx) :defaults @(:defaults ctx)}))
