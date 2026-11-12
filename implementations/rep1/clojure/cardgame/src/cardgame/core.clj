(ns cardgame.core
  "Public API of the Spiremark rules engine.

  The simplest entry point is [[run-match]], which takes the text of a match
  file and returns the complete log, exactly as the command-line tool prints
  it:

      (require '[cardgame.core :as cg])
      (cg/run-match (slurp \"match.txt\"))

  For finer control, build a game with [[new-game]], feed it actions with
  [[submit!]], and read the log with [[output]]:

      (let [db (cg/load-cards \"data/cards.spire\")
            g  (cg/new-game db {:seed 1 :shuffle false :opening 0})]
        (cg/submit! g :A {:type :pass})
        (cg/inspect g :dump)
        (cg/output g))

  Games are mutable (an atom); everything else is data."
  (:require [clojure.string :as str]
            [cardgame.cards :as cards]
            [cardgame.sexpr :as sx]
            [cardgame.matchfile :as mf]
            [cardgame.engine :as engine]
            [cardgame.inspect :as inspect]
            [cardgame.state :as st]))

(defn load-cards
  "Load and validate the card database at `path`.  Returns the card table, or
  throws an exception for which [[bad-database?]] is true."
  [path]
  (cards/load-database path))

(defn parse-cards
  "Like [[load-cards]], but from the database text."
  [text]
  (cards/parse-database text))

(def bad-database? sx/bad-database?)

(defn new-game
  "Create a game over card table `db` and run it to the first decision point.
  `opts` may contain `:seed` (default 1), `:spire`, `:opening`, `:maxcap`,
  `:handmax`, `:turnlimit`, `:first` (`:A` or `:B`), `:shuffle` (boolean),
  `:caps` (`{:A n :B n}`), and `:zones`, a map such as
  `{:A {:deck [[\"CIN-001\" 3]] :hand [[\"CIN-003\" 1]]}}` (zones `:deck :hand
  :field :ash :rift`)."
  ([db] (new-game db {}))
  ([db opts]
   (engine/new-game (merge mf/default-config {:seed 1} opts) db)))

(defn submit!
  "Apply `action` from `player` (`:A` or `:B`).  Actions are maps:

      {:type :pass}                     {:type :concede}
      {:type :play :pos 1 :targets [#_tokens]}
      {:type :act :oid 5 :index 2 :targets []}
      {:type :attack :oids [3 4]}
      {:type :block :pairs [[6 3]]}     ; [blocker attacker]

  Targets are `:A`/`:B`, an oid, or `[:c cid]`.  Returns nil if the action
  was accepted, or an error keyword such as `:illegal-target`."
  [g player action]
  (engine/submit! g player action))

(defn inspect
  "Lines of an inspection block for game `g`: `:dump`, `:legal`, `:vault`, or
  `[:card id]`."
  [g what]
  (if (vector? what)
    (inspect/card-block g (second what))
    (case what
      :dump (inspect/dump-block g)
      :legal (inspect/legal-block g)
      :vault (inspect/vault-block g))))

(defn output
  "The log written so far, as a string."
  [g]
  (str (:out @g)))

(defn over?
  "True once the match has ended."
  [g]
  (boolean (:over @g)))

;; ---------------------------------------------------------------------------
;; Match files

(defn- unknown-card? [db cfg]
  (some (fn [[_ zs]] (some (fn [[_ entries]] (some (fn [[cid _]] (not (contains? db cid))) entries)) zs))
        (:zones cfg)))

(defn- emit-block! [g lines]
  (doseq [l lines] (st/emit-raw! g l)))

(defn- run-line! [g cfg line-no line]
  (when-let [parsed (mf/parse-line line)]
    (cond
      (:bad-syntax parsed) (st/emit-raw! g (str "ERR " line-no " bad-syntax"))
      (:directive parsed)
      (emit-block! g (case (:directive parsed)
                       :dump (inspect/dump-block g)
                       :legal (inspect/legal-block g)
                       :vault (inspect/vault-block g)
                       :card (inspect/card-block g (:id parsed))))
      :else
      (if-let [err (engine/submit! g (:player parsed) (:action parsed))]
        (st/emit-raw! g (str "ERR " line-no " " (name err)))
        (case (:trace cfg)
          :legal (emit-block! g (inspect/legal-block g))
          :state (emit-block! g (inspect/dump-block g))
          nil)))))

(defn run-match
  "Run the match file whose text is `text`; returns the full output (a
  String).  Fatal setup problems yield a single `FATAL ...` line."
  [text]
  (let [lines (mf/split-lines text)
        {:keys [cfg start error]} (mf/parse-setup lines)]
    (if error
      "FATAL bad-setup\n"
      (let [db (try (load-cards (:cards cfg))
                    (catch Exception e
                      (if (bad-database? e) ::bad (throw e))))]
        (cond
          (= db ::bad) "FATAL bad-database\n"
          (unknown-card? db cfg) "FATAL unknown-card\n"
          :else
          (let [g (new-game db cfg)]
            (doseq [i (range start (count lines))]
              (run-line! g cfg (inc i) (nth lines i)))
            (engine/finish! g)
            (output g)))))))
