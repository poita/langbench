(ns protowire.schema
  "Parses the schema language into message descriptors.

  A schema is a map `{:messages {\"Name\" descriptor}}`. A message descriptor:

      {:name       \"Outer\"
       :fields     [field ...]        ; sorted by field number
       :by-number  {1 field ...}
       :by-name    {\"a\" field ...}}

  and a field:

      {:name \"c\" :key :c :number 3
       :type :int32            ; scalar keyword, or :message
       :kind :varint           ; :varint :fixed32 :fixed64 :string :bytes :message
       :repeated? true
       :packable? true         ; repeated numeric field
       :wire-type 0            ; wire type of one unpacked element
       :tag 24 :packed-tag 26  ; precomputed tag values
       :message <ref>}         ; for :message fields, a derefable reference to the descriptor"
  (:require [protowire.error :as err]
            [protowire.types :as types]))

(set! *warn-on-reflection* true)

(deftype MessageRef [type-name table]
  clojure.lang.IDeref
  (deref [_] (get @table type-name))
  Object
  (toString [_] (str "#message-ref " (pr-str type-name))))

;; Descriptors are cyclic for recursive messages, so refs print by name only.
(defmethod print-method MessageRef [^MessageRef r ^java.io.Writer w]
  (.write w (str r)))

(defn- ident-char? [^Character c]
  (let [x (int (.charValue c))]
    (or (and (>= x 48) (<= x 57)) (and (>= x 65) (<= x 90)) (and (>= x 97) (<= x 122)) (= x 95))))

(defn tokenize
  "Splits schema text into tokens: `{ } ; =` singly, other tokens as maximal
  runs of `[A-Za-z0-9_]`; whitespace separates."
  [^String text]
  (let [n (.length text)]
    (loop [i 0 out (transient [])]
      (if (>= i n)
        (persistent! out)
        (let [c (.charAt text i)]
          (cond
            (or (= c \space) (= c \tab) (= c \return) (= c \newline)) (recur (inc i) out)
            (or (= c \{) (= c \}) (= c \;) (= c \=)) (recur (inc i) (conj! out (str c)))
            (ident-char? c)
            (let [j (loop [j (inc i)]
                      (if (and (< j n) (ident-char? (.charAt text j))) (recur (inc j)) j))]
              (recur (long j) (conj! out (subs text i j))))
            :else (err/fail (str "unexpected character in schema: " (pr-str c)))))))))

(defn- parse-field-decls
  "Parses field declarations up to the closing brace; returns [fields rest]."
  [tokens]
  (loop [ts tokens fields []]
    (let [t (first ts)]
      (cond
        (nil? t) (err/fail "unterminated message body")
        (= t "}") [fields (rest ts)]
        :else
        (let [repeated? (= t "repeated")
              ts (if repeated? (rest ts) ts)
              [type fname eq num semi & more] ts]
          (when-not (and fname (= eq "=") num (= semi ";")
                         (re-matches #"[0-9]+" num))
            (err/fail (str "malformed field declaration near " (pr-str type))))
          (recur more (conj fields {:type-name type :name fname
                                    :number (Long/parseLong num) :repeated? repeated?})))))))

(defn- parse-messages
  "Returns a vector of {:name .. :fields [raw-field ...]}."
  [tokens]
  (loop [ts tokens out []]
    (if (empty? ts)
      out
      (let [[kw mname brace & more] ts]
        (when-not (and (= kw "message") mname (= brace "{"))
          (err/fail (str "expected message definition near " (pr-str kw))))
        (let [[fields rest-ts] (parse-field-decls more)]
          (recur rest-ts (conj out {:name mname :fields fields})))))))

(defn- build-field [table message-names {:keys [type-name name number repeated?]}]
  (let [scalar (get types/scalar-types type-name)
        _ (when-not (or scalar (contains? message-names type-name))
            (err/fail (str "unknown type " type-name)))
        kind (if scalar (:kind scalar) :message)
        wire-type (if scalar (:wire-type scalar) 2)]
    (cond-> {:name name :key (keyword name) :number number
             :type (if scalar (keyword type-name) :message)
             :kind kind :repeated? (boolean repeated?)
             :packable? (boolean (and repeated? (not= wire-type 2)))
             :wire-type wire-type
             :tag (bit-or (bit-shift-left number 3) wire-type)
             :packed-tag (bit-or (bit-shift-left number 3) 2)}
      (not scalar) (assoc :message (->MessageRef type-name table)))))

(defn parse
  "Parses schema `text` into a schema map (see the namespace docs). Throws a
  protowire error if the schema is not well-formed."
  [^String text]
  (let [messages (parse-messages (tokenize text))
        names (set (map :name messages))
        table (volatile! nil)
        descs (into {}
                    (map (fn [{:keys [name fields]}]
                           (let [fs (vec (sort-by :number (map #(build-field table names %) fields)))]
                             [name {:name name
                                    :fields fs
                                    :by-number (into {} (map (juxt :number identity)) fs)
                                    :by-name (into {} (map (juxt :name identity)) fs)}])))
                    messages)]
    (when (not= (count descs) (count messages))
      (err/fail "duplicate message name"))
    (vreset! table descs)
    {:messages descs}))

(defn message
  "Looks up the descriptor of message `name` in `schema`; throws if undefined."
  [schema name]
  (or (get-in schema [:messages name])
      (err/fail (str "unknown message " name))))

(defn field-message
  "Descriptor of the message type of message-typed field `field`."
  [field]
  @(:message field))
