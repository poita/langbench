(ns inflate.tables
  "Constant tables from RFC 1951: base values and extra-bit counts of length and
  distance symbols, and the order of the code-length code lengths.")

(def ^"[I" length-base
  "Base match length of literal/length symbol `257 + i`."
  (int-array [3 4 5 6 7 8 9 10 11 13 15 17 19 23 27 31 35 43 51 59 67 83 99 115
              131 163 195 227 258]))

(def ^"[I" length-extra
  "Number of extra bits of literal/length symbol `257 + i`."
  (int-array [0 0 0 0 0 0 0 0 1 1 1 1 2 2 2 2 3 3 3 3 4 4 4 4 5 5 5 5 0]))

(def ^"[I" dist-base
  "Base distance of distance symbol `i`."
  (int-array [1 2 3 4 5 7 9 13 17 25 33 49 65 97 129 193 257 385 513 769 1025
              1537 2049 3073 4097 6145 8193 12289 16385 24577]))

(def ^"[I" dist-extra
  "Number of extra bits of distance symbol `i`."
  (int-array [0 0 0 0 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10 11 11 12 12 13 13]))

(def ^"[I" code-length-order
  "Order in which a dynamic block lists the code-length alphabet's lengths."
  (int-array [16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1 15]))
