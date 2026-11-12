(ns buildsys.eval
  "The KBL evaluator: a tree-walking interpreter over a chain of lexical
  scopes that turns build files into a list of build steps.

  [[evaluate]] is the entry point.  It returns `{:steps [...] :phonies ...
  :defaults [...]}`: the build's step list (in serial order), its phony
  targets (in declaration order) and its default target list."
  (:require [buildsys.builtins :as builtins]
            [buildsys.commands :as commands]
            [buildsys.error :as err]
            [buildsys.parser :as parser]
            [buildsys.path :as path]
            [buildsys.value :as v]
            [buildsys.vfs :as vfs]))

(set! *warn-on-reflection* true)

(def ^:private max-rule-depth 64)

;; ---------------------------------------------------------------------------
;; Scopes

(defn- new-scope [parent] {:vars (volatile! {}) :parent parent})

(defn- lookup [scope name]
  (loop [s scope]
    (when s
      (let [m @(:vars s)]
        (if (contains? m name)
          [(get m name)]
          (recur (:parent s)))))))

(defn- bind! [scope name value] (vswap! (:vars scope) assoc name value))

;; ---------------------------------------------------------------------------
;; Expressions

(declare eval-expr)

(defn- int-op [op l r]
  (case op
    "+" (unchecked-add (long l) (long r))
    "-" (unchecked-subtract (long l) (long r))
    "*" (unchecked-multiply (long l) (long r))
    "/" (if (zero? (long r)) (err/fail "E_DIV_ZERO") (quot (long l) (long r)))
    "%" (if (zero? (long r)) (err/fail "E_DIV_ZERO") (rem (long l) (long r)))))

(defn- eval-binop [ctx scope op l r]
  (case op
    "||" (let [a (v/expect-type "operator ||" "bool" boolean? (eval-expr ctx scope l))]
           (if a
             true
             (v/expect-type "operator ||" "bool" boolean? (eval-expr ctx scope r))))
    "&&" (let [a (v/expect-type "operator &&" "bool" boolean? (eval-expr ctx scope l))]
           (if a
             (v/expect-type "operator &&" "bool" boolean? (eval-expr ctx scope r))
             false))
    (let [a (eval-expr ctx scope l)
          b (eval-expr ctx scope r)
          site (str "operator " op)]
      (case op
        "==" (= a b)
        "!=" (not= a b)
        "<" (neg? (v/compare-values a b))
        "<=" (not (pos? (v/compare-values a b)))
        ">" (pos? (v/compare-values a b))
        ">=" (not (neg? (v/compare-values a b)))
        "++" (do (v/expect-type site "list" vector? a)
                 (v/expect-type site "list" vector? b)
                 (into a b))
        "~" (do (v/expect-type site "str" string? a)
                (v/expect-type site "str" string? b)
                (str a b))
        (do (v/expect-type site "int" integer? a)
            (v/expect-type site "int" integer? b)
            (int-op op a b))))))

(defn- eval-index [ctx scope x i]
  (let [target (eval-expr ctx scope x)
        idx (eval-expr ctx scope i)]
    (v/expect-type "index" "int" integer? idx)
    (v/expect-type "index target" "str|list" #(or (string? %) (vector? %)) target)
    (let [n (count target)
          k (if (neg? idx) (+ n idx) idx)]
      (when-not (<= 0 k (dec n))
        (err/fail "E_ARG" "fn index: out of range"))
      (if (string? target)
        (subs target k (inc k))
        (nth target k)))))

(defn- eval-expr [ctx scope e]
  (case (nth e 0)
    :lit (nth e 1)
    :var (if-let [[x] (lookup scope (nth e 1))]
           x
           (err/fail "E_UNKNOWN_VAR" (nth e 1)))
    :interp (let [sb (StringBuilder.)]
              (doseq [p (nth e 1)]
                (.append sb ^String (if (string? p)
                                      p
                                      (v/to-text (eval-expr ctx scope p)))))
              (str sb))
    :list (mapv #(eval-expr ctx scope %) (nth e 1))
    :unop (let [op (nth e 1)
                a (eval-expr ctx scope (nth e 2))]
            (if (= op "!")
              (not (v/expect-type "operator !" "bool" boolean? a))
              (unchecked-negate (long (v/expect-type "operator -" "int" integer? a)))))
    :binop (eval-binop ctx scope (nth e 1) (nth e 2) (nth e 3))
    :index (eval-index ctx scope (nth e 1) (nth e 2))
    :call (let [fname (nth e 1)]
            (when-not (builtins/known? fname)
              (err/fail "E_UNKNOWN_FUNC" fname))
            (builtins/call ctx fname (mapv #(eval-expr ctx scope %) (nth e 2))))))

;; ---------------------------------------------------------------------------
;; Steps

(defn- check-target-ref!
  "Validate the shape of a target reference written in `in`, `after` or a
  phony dependency list."
  [^String s]
  (when-not (path/target-ref? s)
    (err/fail "E_BAD_PATH" s)))

(defn- validate-step
  "Validate a completed step map; returns the step with derived keys."
  [{:keys [cmd outs depfile ins afters] :as step}]
  (when-not cmd (err/fail "E_STEP_FIELD" "missing cmd"))
  (when (empty? outs) (err/fail "E_STEP_FIELD" "missing out"))
  (doseq [p (cond-> (vec outs) depfile (conj depfile))]
    (when-not (path/workspace-path? p) (err/fail "E_BAD_PATH" p))
    (when-not (path/generated? p) (err/fail "E_OUTPUT_PATH" p)))
  (doseq [r (concat ins afters)] (check-target-ref! r))
  (let [spec (commands/lookup (:name cmd))
        file-ins (vec (remove path/phony-ref? ins))
        [lo hi disp] (:inputs spec)
        m (count file-ins)]
    (when-not (and (<= lo m) (or (nil? hi) (<= m hi)))
      (err/fail "E_CMD_SHAPE" (str (:name cmd) ": expected inputs " disp ", got " m)))
    (when-not (= 1 (count outs))
      (err/fail "E_CMD_SHAPE" (str (:name cmd) ": expected outputs 1, got " (count outs))))
    (if (:depfile spec)
      (when-not depfile
        (err/fail "E_CMD_SHAPE" (str (:name cmd) ": depfile required")))
      (when depfile
        (err/fail "E_CMD_SHAPE" (str (:name cmd) ": depfile not allowed"))))
    (commands/validate-args (:name cmd) (:args cmd))
    (assoc step
           :cmd (:name cmd)
           :args (:args cmd)
           :file-ins file-ins
           :primary (first outs)
           :full-outs (cond-> (vec outs) depfile (conj depfile))
           :canon (commands/canonical (:name cmd) (:args cmd))
           :cost (or (:cost step) (:cost spec)))))

(defn- eval-cmd-field [ctx scope name arg-exprs]
  (let [spec (commands/lookup name)]
    (when-not spec (err/fail "E_UNKNOWN_CMD" name))
    (let [args (mapv #(eval-expr ctx scope %) arg-exprs)
          types (:params spec)]
      (when-not (= (count args) (count types))
        (err/fail "E_ARITY" (str "cmd " name ": expected " (count types) ", got " (count args))))
      (doseq [[i t a] (map vector (range) types args)]
        (case t
          :str (v/expect-type (str "cmd " name " argument " (inc i)) "str" string? a)
          :int (v/expect-type (str "cmd " name " argument " (inc i)) "int" integer? a)))
      {:name name :args args})))

(defn- exec-step [ctx scope fields]
  (let [step (reduce
              (fn [step [kind a b]]
                (let [site (str "field " (clojure.core/name kind))]
                  (case kind
                    :out (update step :outs into (v/strlist site (eval-expr ctx scope a)))
                    :in (update step :ins into (v/strlist site (eval-expr ctx scope a)))
                    :after (update step :afters into (v/strlist site (eval-expr ctx scope a)))
                    :cost (do (when (contains? step :cost)
                                (err/fail "E_STEP_FIELD" "duplicate cost"))
                              (let [c (v/expect-type site "int" integer? (eval-expr ctx scope a))]
                                (when (neg? c) (err/fail "E_ARG" "field cost: negative"))
                                (assoc step :cost c)))
                    :depfile (do (when (contains? step :depfile)
                                   (err/fail "E_STEP_FIELD" "duplicate depfile"))
                                 (assoc step :depfile
                                        (v/expect-type site "str" string?
                                                       (eval-expr ctx scope a))))
                    :cmd (do (when (:cmd step) (err/fail "E_STEP_FIELD" "duplicate cmd"))
                             (assoc step :cmd (eval-cmd-field ctx scope a b))))))
              {:outs [] :ins [] :afters []}
              fields)
        steps (:steps ctx)
        step (validate-step step)]
    (vswap! steps conj (assoc step :serial (long (count @steps))))))

;; ---------------------------------------------------------------------------
;; Statements

(declare exec-block exec-file)

(defn- exec-use [ctx scope rule-name args]
  (let [rule (get @(:rules ctx) rule-name)]
    (when-not rule (err/fail "E_UNKNOWN_RULE" rule-name))
    (when (>= (:depth ctx) max-rule-depth) (err/fail "E_RULE_RECURSION" rule-name))
    (let [vals (mapv (fn [[kind a b]]
                       (if (= kind :pos)
                         [:pos (eval-expr ctx scope a)]
                         [:kw a (eval-expr ctx scope b)]))
                     args)
          params (:params rule)
          positional (filterv #(= :pos (first %)) vals)
          inner (new-scope (:scope rule))
          pnames (set (map :name params))]
      (when (> (count positional) (count params))
        (err/fail "E_ARITY" (str "rule " rule-name ": expected " (count params)
                                 ", got " (count positional))))
      (doseq [[p [_ x]] (map vector params positional)]
        (bind! inner (:name p) x))
      (doseq [[kind kw x] (remove #(= :pos (first %)) vals)]
        (when-not (pnames kw)
          (err/fail "E_ARG" (str "rule " rule-name ": unknown argument " kw)))
        (when (contains? @(:vars inner) kw)
          (err/fail "E_ARG" (str "rule " rule-name ": duplicate argument " kw)))
        (bind! inner kw x))
      (let [inner-ctx (update ctx :depth inc)]
        (doseq [{:keys [name default]} params]
          (when-not (contains? @(:vars inner) name)
            (if default
              (bind! inner name (eval-expr inner-ctx inner default))
              (err/fail "E_ARG" (str "rule " rule-name ": missing argument " name)))))
        (exec-block inner-ctx inner (:body rule))))))

(defn- exec-include [ctx scope e]
  (let [p (v/expect-type "include path" "str" string? (eval-expr ctx scope e))]
    (when-not (path/workspace-path? p) (err/fail "E_BAD_PATH" p))
    (when-not (vfs/exists? (:vfs ctx) p) (err/fail "E_INCLUDE_MISSING" p))
    (when (some #{p} (:include-stack ctx)) (err/fail "E_INCLUDE_CYCLE" p))
    (exec-file ctx scope p)))

(defn- exec-stmt [ctx scope stmt]
  (case (nth stmt 0)
    :let (let [name (nth stmt 1)
               x (eval-expr ctx scope (nth stmt 2))]
           (when (contains? @(:vars scope) name) (err/fail "E_REDEFINE" name))
           (bind! scope name x))
    :set (let [name (nth stmt 1)
               x (eval-expr ctx scope (nth stmt 2))]
           (loop [s scope]
             (cond
               (nil? s) (err/fail "E_SET_UNDEFINED" name)
               (contains? @(:vars s) name) (bind! s name x)
               :else (recur (:parent s)))))
    :include (exec-include ctx scope (nth stmt 1))
    :abort (err/fail "E_ABORT"
                     (v/expect-type "abort message" "str" string?
                                    (eval-expr ctx scope (nth stmt 1))))
    :default (let [xs (v/strlist "default" (eval-expr ctx scope (nth stmt 1)))]
               (vswap! (:defaults ctx) into xs))
    :phony (let [name (nth stmt 1)
                 deps (v/strlist (str "phony " name) (eval-expr ctx scope (nth stmt 2)))]
             (doseq [d deps] (check-target-ref! d))
             (when (contains? @(:phonies ctx) name) (err/fail "E_DUP_PHONY" name))
             (vswap! (:phonies ctx) assoc name deps)
             (vswap! (:phony-order ctx) conj name))
    :use (exec-use ctx scope (nth stmt 1) (nth stmt 2))
    :when (let [[branches else-body] [(nth stmt 1) (nth stmt 2)]
                taken (loop [bs (seq branches)]
                        (when-let [[[c body] & more] bs]
                          (if (v/expect-type "when condition" "bool" boolean?
                                             (eval-expr ctx scope c))
                            body
                            (recur more))))]
            (if taken
              (exec-block ctx (new-scope scope) taken)
              (when else-body
                (exec-block ctx (new-scope scope) else-body))))
    :each (let [[_ idx-name name e body] stmt
                xs (v/expect-type "each subject" "list" vector? (eval-expr ctx scope e))]
            (doseq [[i x] (map-indexed vector xs)]
              (let [s (new-scope scope)]
                (when idx-name (bind! s idx-name (long i)))
                (bind! s name x)
                (exec-block ctx s body))))
    :rule (let [[_ name params body] stmt]
            (when (contains? @(:rules ctx) name) (err/fail "E_REDEFINE" name))
            (vswap! (:rules ctx) assoc name {:params params :body body :scope scope}))
    :step (exec-step ctx scope (nth stmt 1))))

(defn- exec-block [ctx scope stmts]
  (doseq [s stmts] (exec-stmt ctx scope s)))

(defn- exec-file
  "Parse (with caching) and run build file `p` in `scope`."
  [ctx scope p]
  (let [cache (:parse-cache ctx)
        text (vfs/content (:vfs ctx) p)
        ast (or (get @cache [p text])
                (let [a (parser/parse-file p text)]
                  (vswap! cache assoc [p text] a)
                  a))]
    (exec-block (update ctx :include-stack conj p) scope ast)))

(defn evaluate
  "Evaluate build file `main-path` of file system `vfs`, following includes.
  Returns `{:steps :phonies :phony-order :defaults}` where `:phonies` maps a
  phony name to its dependency strings and `:phony-order` lists the names in
  declaration order.  Throws a Kiln error on the first error encountered."
  [vfs main-path]
  (let [ctx {:vfs vfs
             :steps (volatile! [])
             :phonies (volatile! {})
             :phony-order (volatile! [])
             :rules (volatile! {})
             :defaults (volatile! [])
             :parse-cache (volatile! {})
             :include-stack []
             :depth 0}]
    (exec-file ctx (new-scope nil) main-path)
    {:steps @(:steps ctx)
     :phonies @(:phonies ctx)
     :phony-order @(:phony-order ctx)
     :defaults @(:defaults ctx)}))
