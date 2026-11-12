(ns buildsys.session
  "Session scripts: parsing `session.txt`, driving builds and workspace
  mutations, and writing the log."
  (:require [buildsys.build :as build]
            [buildsys.vfs :as vfs]
            [clojure.string :as str]))

;; ---------------------------------------------------------------- parsing

(defn- blank? [^String line] (every? #(or (= % \space) (= % \tab)) line))

(defn- trim-st [^String s]
  (let [n (.length s)
        a (loop [i 0] (if (and (< i n) (#{\space \tab} (.charAt s i))) (recur (inc i)) i))
        b (loop [j n] (if (and (> j a) (#{\space \tab} (.charAt s (dec j)))) (recur (dec j)) j))]
    (subs s a b)))

(defn- words [^String s] (vec (remove empty? (str/split s #"[ \t]+"))))

(defn- parse-build [ws]
  (let [args (vec (rest ws))
        n (count args)]
    (if (and (>= n 2) (= "-j" (nth args (- n 2))))
      {:op :build :targets (subvec args 0 (- n 2)) :jobs (Long/parseLong (nth args (dec n)))}
      {:op :build :targets args :jobs 1})))

(defn parse
  "Parses session text (a byte string) into a vector of step maps
  `{:op :build|:create|:edit|:delete|:touch|:clean ...}`."
  [^String text]
  (let [lines (vec (str/split text #"\n" -1))
        n (count lines)]
    (loop [i 0 out []]
      (if (>= i n)
        out
        (let [raw (nth lines i)
              line (trim-st raw)]
          (cond
            (or (blank? raw) (.startsWith line "#")) (recur (inc i) out)
            :else
            (let [ws (words line)
                  op (keyword (first ws))]
              (case op
                :build (recur (inc i) (conj out (parse-build ws)))
                (:create :edit)
                (let [end (loop [j (inc i)] (if (or (>= j n) (= "---" (nth lines j))) j (recur (inc j))))
                      body (subvec lines (inc i) (min end n))]
                  (recur (inc end)
                         (conj out {:op op :path (nth ws 1)
                                    :content (apply str (map #(str % "\n") body))})))
                (:delete :touch) (recur (inc i) (conj out {:op op :path (nth ws 1)}))
                :clean (recur (inc i) (conj out {:op :clean}))))))))))

;; ----------------------------------------------------------------- running

(defn- header [n step]
  (str "step " n ": "
       (case (:op step)
         :build (str "build " (if (seq (:targets step)) (str/join " " (:targets step)) "(default)")
                     " -j " (:jobs step))
         :clean "clean"
         (str (name (:op step)) " " (:path step)))))

(defn- event-line [{:keys [kind start end worker target command]}]
  (case kind
    :hit (str "  hit " start " " target)
    (str "  " (name kind) " " start " " end " w" worker " " target " " command)))

(defn- run-step
  "Executes one session step.  Returns [vfs' lines] where lines are the
  event and result lines (without the header)."
  [vfs step]
  (case (:op step)
    :build (let [r (build/run-build vfs (:targets step) (:jobs step))]
             [(:vfs r)
              (concat (map event-line (:events r))
                      [(if (:ok? r)
                         (str "  ok ran=" (:ran r) " hit=" (:hits r) " time=" (:time r))
                         (str "  error " (:error r)))])])
    (:create :edit) [(vfs/put vfs (:path step) (:content step))
                     [(str "  ok size=" (count (:content step)))]]
    :delete [(vfs/delete vfs (:path step)) ["  ok"]]
    :touch [(vfs/touch vfs (:path step)) ["  ok"]]
    :clean (let [doomed (filterv #(or (= % vfs/state-path) (vfs/generated-path? %)) (keys vfs))]
             [(reduce vfs/delete vfs doomed)
              (concat (map #(str "  remove " %) doomed)
                      [(str "  ok removed=" (count doomed))])])))

(defn run
  "Runs session `steps` against workspace `vfs`.  Returns
  {:vfs final-workspace :log log-text} (both byte strings)."
  [vfs steps]
  (let [sb (StringBuilder.)]
    (loop [vfs vfs steps (seq steps) n 1]
      (if-not steps
        {:vfs vfs :log (str sb)}
        (let [step (first steps)
              [vfs' lines] (run-step vfs step)]
          (.append sb (header n step)) (.append sb \newline)
          (doseq [l lines] (.append sb ^String l) (.append sb \newline))
          (recur vfs' (next steps) (inc n)))))))
