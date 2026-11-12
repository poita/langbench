(ns buildsys.session
  "Session scripts: parsing `session.txt` and running a session, producing the
  log and the final file system."
  (:require [buildsys.build :as build]
            [buildsys.vfs :as vfs]
            [clojure.string :as str]))

(set! *warn-on-reflection* true)

(defn- blank-or-comment?
  "True for a line that is empty or only spaces/tabs, or whose first
  non-blank byte is `#`."
  [^String l]
  (let [rest (subs l (count (take-while #{\space \tab} l)))]
    (or (.isEmpty rest) (.startsWith rest "#"))))

(defn- strip-blanks [^String l]
  (let [n (.length l)
        b (loop [i 0] (if (and (< i n) (#{\space \tab} (.charAt l i))) (recur (inc i)) i))
        e (loop [j n] (if (and (> j b) (#{\space \tab} (.charAt l (dec j)))) (recur (dec j)) j))]
    (subs l b e)))

(defn- words [^String l]
  (vec (remove empty? (str/split l #"[ \t]+"))))

(defn- parse-build [ws]
  (let [n (count ws)]
    (if (and (>= n 3) (= "-j" (nth ws (- n 2))))
      {:op :build :targets (subvec ws 1 (- n 2)) :workers (Long/parseLong (peek ws))}
      {:op :build :targets (subvec ws 1) :workers 1})))

(defn parse-session
  "Parse session script text (a byte string) into a vector of steps:

      {:op :build :targets [...] :workers n}
      {:op :create/:edit :path p :content c}
      {:op :delete/:touch :path p}
      {:op :clean}"
  [^String text]
  (let [lines (let [ls (.split text "\n" -1)]
                (if (and (pos? (alength ls)) (= "" (aget ls (dec (alength ls)))))
                  (vec (butlast ls))
                  (vec ls)))
        n (count lines)]
    (loop [i (Long/valueOf 0) out []]
      (if (>= i n)
        out
        (let [l (nth lines i)]
          (if (blank-or-comment? l)
            (recur (inc i) out)
            (let [ws (words (strip-blanks l))
                  op (first ws)]
              (case op
                "build" (recur (inc i) (conj out (parse-build ws)))
                ("create" "edit")
                (let [end (or (first (filter #(= "---" (nth lines %)) (range (inc i) n))) n)
                      body (subvec lines (inc i) end)]
                  (recur (inc end)
                         (conj out {:op (keyword op) :path (second ws)
                                    :content (apply str (map #(str % "\n") body))})))
                ("delete" "touch") (recur (inc i) (conj out {:op (keyword op) :path (second ws)}))
                "clean" (recur (inc i) (conj out {:op :clean}))
                (throw (ex-info (str "bad session line: " l) {:line l}))))))))))

(defn- header [n {:keys [op targets workers path]}]
  (str "step " n ": "
       (case op
         :build (str "build " (if (seq targets) (str/join " " targets) "(default)")
                     " -j " workers)
         :clean "clean"
         (str (name op) " " path))))

(defn- event-line [{:keys [kind start end worker target cmd]}]
  (case kind
    :hit (str "  hit " start " " target)
    (str "  " (name kind) " " start " " end " w" worker " " target " " cmd)))

(defn run-session
  "Run `steps` (from [[parse-session]]) against file system `vfs`.  Returns
  `{:log string :vfs vfs}`."
  [vfs steps]
  (let [log (StringBuilder.)
        emit (fn [s] (.append log ^String s) (.append log \newline))]
    (loop [vfs vfs steps (seq steps) n 1]
      (if-not steps
        {:log (str log) :vfs vfs}
        (let [{:keys [op path content targets workers] :as step} (first steps)]
          (emit (header n step))
          (recur
           (case op
             :build (let [r (build/build vfs (vec targets) workers)]
                      (run! (comp emit event-line) (:events r))
                      (emit (if (:error r)
                              (str "  error " (:error r))
                              (str "  ok ran=" (:ran r) " hit=" (:hits r) " time=" (:time r))))
                      (:vfs r))
             (:create :edit) (do (emit (str "  ok size=" (count content)))
                                 (vfs/write vfs path content))
             :delete (do (emit "  ok") (vfs/delete vfs path))
             :touch (do (emit "  ok") (vfs/touch vfs path))
             :clean (let [[v removed] (vfs/clean vfs)]
                      (run! #(emit (str "  remove " %)) removed)
                      (emit (str "  ok removed=" (count removed)))
                      v))
           (next steps)
           (inc n)))))))
