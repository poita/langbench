(ns buildsys.path
  "Workspace paths and target-reference shapes.")

(def ^:private component-re #"[A-Za-z0-9_.+\-]{1,255}")
(def ^:private ident-re #"[A-Za-z_][A-Za-z0-9_]*")

(defn workspace-path?
  "True when `s` is a valid workspace path: 1-1024 bytes, `/`-separated
  components of 1-255 characters from `[A-Za-z0-9_.+-]`, none of them `.` or
  `..`."
  [s]
  (and (string? s)
       (<= 1 (count s) 1024)
       (let [comps (.split ^String s "/" -1)]
         (every? (fn [^String c]
                   (and (re-matches component-re c)
                        (not= c ".")
                        (not= c "..")))
                 comps))))

(defn identifier?
  "True when `s` matches `[A-Za-z_][A-Za-z0-9_]*`."
  [s]
  (boolean (and (string? s) (re-matches ident-re s))))

(defn phony-ref?
  "True when the target reference `s` begins with `@`."
  [^String s]
  (and (pos? (.length s)) (= \@ (.charAt s 0))))

(defn target-ref?
  "True when `s` is a well-formed target reference: `@` followed by an
  identifier, or a workspace path."
  [^String s]
  (if (phony-ref? s)
    (identifier? (subs s 1))
    (workspace-path? s)))

(defn first-component
  "The first `/`-separated component of `p`."
  [^String p]
  (let [i (.indexOf p "/")]
    (if (neg? i) p (subs p 0 i))))

(defn generated?
  "True when `p` lies in the reserved `out` tree."
  [p]
  (= "out" (first-component p)))
