(ns spreadsheet.core
  "An in-memory spreadsheet with incremental recalculation.

  A sheet is an immutable value. `set-cell` and `clear-cell` return a new
  sheet in which every formula cell's value is consistent with the edit; only
  the edited cell and the cells that (transitively) read it are re-evaluated.

      (-> (empty-sheet)
          (set-cell \"A1\" \"10\")
          (set-cell \"A2\" \"=A1*2\")
          (display \"A2\"))
      ;=> \"20\"

  Cell contents use the textual forms of the command language: a number
  literal (`42`, `-3.5`), a string literal in double quotes (`\"hello\"`) or a
  formula starting with `=` (`=SUM(A1:A9)`, `=IF(B1>0, \"pos\", \"neg\")`).

  Values (see `value`) are a double, a string, one of the error keywords
  `:error/div0`, `:error/ref`, `:error/cycle`, `:error/value`, or nil for an
  empty cell."
  (:require [spreadsheet.cell :as cell]
            [spreadsheet.eval :as eval]
            [spreadsheet.format :as fmt]
            [spreadsheet.graph :as graph]
            [spreadsheet.parser :as parser]))

(defn empty-sheet
  "Returns a sheet with no cells."
  []
  {:cells {}    ; id -> {:source str, :ast tree, :deps #{id}, :value v}
   :rdeps {}})  ; id -> #{ids of cells whose formulas read id}

(defn- name->id [cell-name]
  (or (cell/parse-ref cell-name)
      (throw (ex-info (str "Invalid cell name: " cell-name) {:cell cell-name}))))

(defn- update-rdeps [rdeps id old-deps new-deps]
  (let [rdeps (reduce (fn [m d]
                        (let [s (disj (get m d) id)]
                          (if (empty? s) (dissoc m d) (assoc m d s))))
                      rdeps (remove new-deps old-deps))]
    (reduce (fn [m d] (assoc m d (conj (get m d #{}) id)))
            rdeps (remove old-deps new-deps))))

(defn- recalculate
  "Re-evaluates the cells affected by a change to cell `id`."
  [{:keys [cells rdeps] :as sheet} id]
  (let [ids (graph/affected rdeps id)
        comps (graph/components ids #(:deps (get cells %)))
        cells'
        (persistent!
         (reduce
          (fn [cells [members cyclic?]]
            (if cyclic?
              (reduce (fn [cells m] (assoc! cells m (assoc (get cells m) :value :error/cycle)))
                      cells members)
              (let [m (first members)]
                (if-let [c (get cells m)]
                  (assoc! cells m (assoc c :value (let [v (eval/ev cells (:ast c))]
                                                    (if (nil? v) 0.0 v))))
                  cells))))
          (transient cells) comps))]
    (assoc sheet :cells cells')))

(defn set-cell
  "Returns `sheet` with the cell named `cell-name` (e.g. \"B7\") set to
  `content`, a number literal, string literal or formula as described in the
  namespace docstring. Content is assumed to be well formed."
  [sheet cell-name content]
  (let [id (name->id cell-name)
        {:keys [ast deps]} (parser/parse-content content)
        old-deps (get-in sheet [:cells id :deps] #{})]
    (-> sheet
        (update :rdeps update-rdeps id old-deps deps)
        (assoc-in [:cells id] {:source content :ast ast :deps deps :value nil})
        (recalculate id))))

(defn clear-cell
  "Returns `sheet` with the cell named `cell-name` emptied."
  [sheet cell-name]
  (let [id (name->id cell-name)
        old-deps (get-in sheet [:cells id :deps] #{})]
    (-> sheet
        (update :rdeps update-rdeps id old-deps #{})
        (update :cells dissoc id)
        (recalculate id))))

(defn value
  "The value of the cell named `cell-name`: a double, a string, an error
  keyword (`:error/div0`, `:error/ref`, `:error/cycle`, `:error/value`) or nil
  if the cell is empty."
  [sheet cell-name]
  (:value (get (:cells sheet) (name->id cell-name))))

(defn source
  "The content text last given to `set-cell` for `cell-name`, or nil."
  [sheet cell-name]
  (:source (get (:cells sheet) (name->id cell-name))))

(defn display
  "The displayed text of the cell named `cell-name` (\"\" if empty)."
  [sheet cell-name]
  (fmt/display (value sheet cell-name)))

(defn error?
  "True if `v` is an error value."
  [v]
  (keyword? v))

(defn dump
  "Returns a vector of `[cell-name displayed-value]` for every non-empty cell,
  in row-major order."
  [sheet]
  (mapv (fn [id] [(cell/id->name id) (fmt/display (:value (get (:cells sheet) id)))])
        (sort (keys (:cells sheet)))))
