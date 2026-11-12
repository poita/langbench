(ns svgraster.buf
  "A growable buffer of primitive doubles, used to accumulate polyline
  vertices without boxing.")

(set! *warn-on-reflection* true)

(definterface IDoubleBuf
  (^void add [^double v])
  (^long size [])
  (^doubles toArray []))

(deftype DoubleBuf [^:unsynchronized-mutable ^doubles arr
                    ^:unsynchronized-mutable ^long n]
  IDoubleBuf
  (add [_ v]
    (when (== n (alength arr))
      (set! arr (java.util.Arrays/copyOf arr (int (* 2 n)))))
    (aset arr (int n) v)
    (set! n (inc n)))
  (size [_] n)
  (toArray [_] (java.util.Arrays/copyOf arr (int n))))

(defn double-buf
  "Creates an empty buffer."
  ^DoubleBuf []
  (DoubleBuf. (double-array 64) 0))

(defn add-point!
  "Appends the point (x, y) to `buf`."
  [^DoubleBuf buf ^double x ^double y]
  (.add buf x)
  (.add buf y)
  nil)

(defn size
  "Number of doubles stored in `buf`."
  ^long [^DoubleBuf buf]
  (.size buf))

(defn ->array
  "Returns a fresh double[] holding the contents of `buf`."
  ^doubles [^DoubleBuf buf]
  (.toArray buf))
