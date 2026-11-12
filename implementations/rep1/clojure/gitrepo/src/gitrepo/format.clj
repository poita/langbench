(ns gitrepo.format
  "The textual output of each query, as byte arrays (see SPEC.md)."
  (:require [gitrepo.hex :as hex]
            [gitrepo.quote :as quote]))

(set! *warn-on-reflection* true)

(defn octal6
  "`mode` in octal, zero-padded to six digits."
  ^String [^long mode]
  (let [s (Long/toOctalString mode)]
    (if (< (.length s) 6) (str (subs "000000" (.length s)) s) s)))

(defn- finish ^bytes [^StringBuilder sb] (hex/latin1-bytes (.toString sb)))

(defn rev-parse [id] (hex/latin1-bytes (str id "\n")))

(defn count-objects [{:keys [loose in-pack packs]}]
  (hex/latin1-bytes (str "loose: " loose "\nin-pack: " in-pack "\npacks: " packs "\n")))

(defn log [commits]
  (let [sb (StringBuilder.)]
    (doseq [{:keys [id author subject]} commits]
      (doto sb
        (.append ^String id) (.append " ") (.append ^String (:name author)) (.append " ")
        (.append (str (:timestamp author))) (.append " ") (.append ^String subject)
        (.append "\n")))
    (finish sb)))

(defn ls-tree [entries]
  (let [sb (StringBuilder.)]
    (doseq [{:keys [mode type id name]} entries]
      (doto sb
        (.append (octal6 mode)) (.append " ") (.append (clojure.core/name type)) (.append " ")
        (.append ^String id) (.append "\t") (.append (quote/quote-path name)) (.append "\n")))
    (finish sb)))

(defn diff [changes]
  (let [sb (StringBuilder.)]
    (doseq [{:keys [path status mode1 mode2 id1 id2]} changes]
      (doto sb
        (.append ":") (.append (octal6 mode1)) (.append " ") (.append (octal6 mode2)) (.append " ")
        (.append ^String id1) (.append " ") (.append ^String id2) (.append " ")
        (.append (name status)) (.append "\t") (.append (quote/quote-path path)) (.append "\n")))
    (finish sb)))

(defn cat-file [{:keys [type size ^bytes data]}]
  (let [header (hex/latin1-bytes (str (name type) " " size "\n"))
        out (byte-array (+ (alength header) (alength data)))]
    (System/arraycopy header 0 out 0 (alength header))
    (System/arraycopy data 0 out (alength header) (alength data))
    out))
