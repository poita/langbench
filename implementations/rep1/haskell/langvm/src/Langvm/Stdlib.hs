-- | The implementations of the built-in functions (SPEC.md section 15).
module Langvm.Stdlib
  ( Runtime (..)
  , execBuiltin
  , isHigherOrder
  ) where

import Control.Monad
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.IO (IOArray, newArray_)
import Data.Bits (complement, countLeadingZeros, countTrailingZeros, popCount, shiftR, (.&.))
import Data.Char (chr, isDigit, ord)
import Data.Word (Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Numeric (showHex)

import Langvm.Builtin
import Langvm.Collections
import Langvm.Number
import Langvm.SmallArray
import Langvm.Value

-- | What built-ins need from the machine: output and calling closures.
data Runtime = Runtime
  { rtOut :: Str -> IO ()
  , rtCall :: Value -> [Value] -> IO Value
  }

foreign import ccall unsafe "math.h floor" c_floor :: Double -> Double
foreign import ccall unsafe "math.h ceil" c_ceil :: Double -> Double
foreign import ccall unsafe "math.h trunc" c_trunc :: Double -> Double
foreign import ccall unsafe "math.h round" c_round :: Double -> Double
foreign import ccall unsafe "math.h fmod" c_fmod :: Double -> Double -> Double

-- | Built-ins that call back into the machine (and so may grow its stack).
isHigherOrder :: Builtin -> Bool
isHigherOrder b = b `elem`
  [BListMap, BListFilter, BListFold, BListAny, BListAll, BListFind, BListFindIndex, BSortBy]

type Args = IOArray Int Value

bad :: IO a
bad = error "langvm: ill-typed built-in call"

gInt :: Args -> Int -> IO Int
gInt a i = unsafeRead a i >>= \v -> case v of VInt n -> return n; _ -> bad
{-# INLINE gInt #-}

gFloat :: Args -> Int -> IO Double
gFloat a i = unsafeRead a i >>= \v -> case v of VFloat n -> return n; _ -> bad

gChar :: Args -> Int -> IO Char
gChar a i = unsafeRead a i >>= \v -> case v of VChar n -> return n; _ -> bad
{-# INLINE gChar #-}

gStr :: Args -> Int -> IO Str
gStr a i = unsafeRead a i >>= \v -> case v of VStr n -> return n; _ -> bad
{-# INLINE gStr #-}

gList :: Args -> Int -> IO ListObj
gList a i = unsafeRead a i >>= \v -> case v of VList n -> return n; _ -> bad
{-# INLINE gList #-}

gMap :: Args -> Int -> IO MapObj
gMap a i = unsafeRead a i >>= \v -> case v of VMap n -> return n; _ -> bad

str :: String -> Value
str = VStr . strFromString

someV :: Value -> Value
someV v = VEnum 0 0 (fieldsArray [v])

noneV :: Value
noneV = VEnum 0 1 emptyA

optV :: Maybe Value -> Value
optV = maybe noneV someV

isAsciiSpace :: Char -> Bool
isAsciiSpace c = c == ' ' || (c >= '\t' && c <= '\r')

-- | Run a built-in: its arguments are the stack entries from the given index.
execBuiltin :: Runtime -> Builtin -> Args -> Int -> IO Value
execBuiltin rt b a base = case b of
  -- output and panicking
  BPrint -> do s <- gStr a base; rtOut rt s; rtOut rt (strFromString "\n"); return VUnit
  BEmit -> do s <- gStr a base; rtOut rt s; return VUnit
  BPanic -> do s <- gStr a base; panic (strToString s)
  -- integers
  BIntMin -> return (VInt minBound)
  BIntMax -> return (VInt maxBound)
  BAbsI -> int1 abs
  BMinI -> int2 min
  BMaxI -> int2 max
  BSignI -> int1 signum
  BCmpI -> int2 (\x y -> if x < y then -1 else if x == y then 0 else 1)
  BDivFloor -> do
    x <- gInt a base; y <- gInt a (base + 1)
    when (y == 0) (panic "divide by zero")
    return (VInt (if y == -1 then negate x else x `div` y))
  BModFloor -> do
    x <- gInt a base; y <- gInt a (base + 1)
    when (y == 0) (panic "modulo by zero")
    return (VInt (if y == -1 then 0 else x `mod` y))
  BPowI -> do
    x <- gInt a base; e <- gInt a (base + 1)
    when (e < 0) (panic "negative exponent")
    return (VInt (powLoop x e))
  BGcdI -> int2 (\x y -> fromInteger (gcd (toInteger x) (toInteger y)))
  BPopCount -> int1 popCount
  BClz -> int1 countLeadingZeros
  BCtz -> int1 countTrailingZeros
  BToFloat -> do x <- gInt a base; return (VFloat (fromIntegral x))
  BShowInt -> do x <- gInt a base; return (str (show x))
  BShowIntRadix -> do
    x <- gInt a base; r <- gInt a (base + 1)
    when (r < 2 || r > 36) (panic "radix out of range")
    let m = abs (toInteger x)
    return (str ((if x < 0 then "-" else "") ++ showIntRadixText r m))
  BParseInt -> do
    s <- gStr a base
    return (optV (VInt <$> parseIntRadixS 10 (strToString s)))
  BParseIntRadix -> do
    s <- gStr a base; r <- gInt a (base + 1)
    when (r < 2 || r > 36) (panic "radix out of range")
    return (optV (VInt <$> parseIntRadixS r (strToString s)))
  -- floats
  BSqrtF -> flt1 sqrt
  BAbsF -> flt1 (\x -> castWord64ToDouble (castDoubleToWord64 x .&. complement 0x8000000000000000))
  BFloorF -> flt1 c_floor
  BCeilF -> flt1 c_ceil
  BTruncF -> flt1 c_trunc
  BRoundF -> flt1 c_round
  BMinF -> do
    x <- gFloat a base; y <- gFloat a (base + 1)
    return (VFloat (if cmpF x y <= 0 then x else y))
  BMaxF -> do
    x <- gFloat a base; y <- gFloat a (base + 1)
    return (VFloat (if cmpF x y >= 0 then x else y))
  BFmodF -> do x <- gFloat a base; y <- gFloat a (base + 1); return (VFloat (c_fmod x y))
  BPowF -> do
    x <- gFloat a base; n <- gInt a (base + 1)
    when (n == minBound) (panic "negative exponent")
    return (VFloat (if n < 0 then 1 / powF x (negate n) else powF x n))
  BIsNanF -> do x <- gFloat a base; return (VBool (isNaN x))
  BIsInfF -> do x <- gFloat a base; return (VBool (isInfinite x))
  BCmpF -> do x <- gFloat a base; y <- gFloat a (base + 1); return (VInt (cmpF x y))
  BTruncToInt -> do
    x <- gFloat a base
    when (isNaN x || isInfinite x || x >= 9.223372036854775808e18 || x < -9.223372036854775808e18)
      (panic "float out of integer range")
    return (VInt (truncate x))
  BShowFloat -> do x <- gFloat a base; return (str (showFloatAt' 6 x))
  BShowFloatAt -> do
    x <- gFloat a base; d <- gInt a (base + 1)
    when (d < 0 || d > 17) (panic "digits out of range")
    return (str (showFloatAt' d x))
  BFloatBits -> do x <- gFloat a base; return (VInt (fromIntegral (castDoubleToWord64 x)))
  BFloatFromBits -> do
    n <- gInt a base
    return (VFloat (castWord64ToDouble (fromIntegral n :: Word64)))
  BParseFloat -> do s <- gStr a base; return (optV (VFloat <$> parseFloatS (strToString s)))
  BInfF -> return (VFloat (1 / 0))
  BNanF -> return (VFloat (castWord64ToDouble 0x7ff8000000000000))
  BPiF -> return (VFloat (castWord64ToDouble 4614256656552045848))
  -- bools and chars
  BShowBool -> do
    v <- unsafeRead a base
    return (case v of VBool True -> str "true"; _ -> str "false")
  BOrd -> do c <- gChar a base; return (VInt (ord c))
  BChr -> do
    n <- gInt a base
    when (n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF)) (panic "invalid char code")
    return (VChar (chr n))
  BIsDigit -> chr1 (\c -> c >= '0' && c <= '9')
  BIsAlpha -> chr1 isAlphaA
  BIsAlnum -> chr1 (\c -> isAlphaA c || (c >= '0' && c <= '9'))
  BIsSpace -> chr1 isAsciiSpace
  BIsUpper -> chr1 (\c -> c >= 'A' && c <= 'Z')
  BIsLower -> chr1 (\c -> c >= 'a' && c <= 'z')
  BToUpperC -> do c <- gChar a base; return (VChar (toUpperA c))
  BToLowerC -> do c <- gChar a base; return (VChar (toLowerA c))
  BCmpC -> do
    x <- gChar a base; y <- gChar a (base + 1)
    return (VInt (case compare x y of LT -> -1; EQ -> 0; GT -> 1))
  BShowChar -> do c <- gChar a base; return (VStr (strFromList 1 [c]))
  BQuoteChar -> do c <- gChar a base; return (str ("'" ++ concatMap (escapeChar '\'') [c] ++ "'"))
  -- strings
  BStrLen -> do s <- gStr a base; return (VInt (strLength s))
  BCharAt -> do
    s <- gStr a base; i <- gInt a (base + 1)
    when (i < 0 || i >= strLength s) (panic "index out of bounds")
    return (VChar (strAt s i))
  BSubstr -> do
    s <- gStr a base; f <- gInt a (base + 1); t <- gInt a (base + 2)
    when (f < 0 || f > t || t > strLength s) (panic "index out of bounds")
    return (VStr (strSlice s f t))
  BStrCat -> do x <- gStr a base; y <- gStr a (base + 1); return (VStr (strConcat x y))
  BStrRepeat -> do
    s <- gStr a base; n <- gInt a (base + 1)
    when (n < 0) (panic "negative count")
    return (VStr (strFromString (concat (replicate n (strToString s)))))
  BStrIndexOf -> do
    s <- gStr a base; sub <- gStr a (base + 1)
    return (VInt (maybe (-1) id (firstOcc s sub)))
  BStrLastIndexOf -> do
    s <- gStr a base; sub <- gStr a (base + 1)
    return (VInt (maybe (-1) id (lastOcc s sub)))
  BStrContains -> do
    s <- gStr a base; sub <- gStr a (base + 1)
    return (VBool (maybe False (const True) (firstOcc s sub)))
  BStartsWith -> do s <- gStr a base; p <- gStr a (base + 1); return (VBool (matchAt s p 0))
  BEndsWith -> do
    s <- gStr a base; p <- gStr a (base + 1)
    return (VBool (strLength p <= strLength s && matchAt s p (strLength s - strLength p)))
  BStrSplit -> do
    s <- gStr a base; sep <- gStr a (base + 1)
    when (strLength sep == 0) (panic "empty separator")
    l <- listFromList (map VStr (splitStr s sep))
    return (VList l)
  BStrJoin -> do
    parts <- gList a base; sep <- gStr a (base + 1)
    ps <- listToList parts
    let strs = [s | VStr s <- ps]
        sepS = strToString sep
        joined = concat (zipWith (++) ("" : repeat sepS) (map strToString strs))
    return (str joined)
  BStrReplace -> do
    s <- gStr a base; f <- gStr a (base + 1); t <- gStr a (base + 2)
    when (strLength f == 0) (panic "empty separator")
    return (VStr (replaceStr s f t))
  BTrim -> do s <- gStr a base; return (VStr (trimStr True True s))
  BTrimLeft -> do s <- gStr a base; return (VStr (trimStr True False s))
  BTrimRight -> do s <- gStr a base; return (VStr (trimStr False True s))
  BUpper -> do s <- gStr a base; return (VStr (mapStr toUpperA s))
  BLower -> do s <- gStr a base; return (VStr (mapStr toLowerA s))
  BStrCmp -> do
    x <- gStr a base; y <- gStr a (base + 1)
    return (VInt (case strCompare x y of LT -> -1; EQ -> 0; GT -> 1))
  BChars -> do
    s <- gStr a base
    l <- listFromList [VChar (strAt s i) | i <- [0 .. strLength s - 1]]
    return (VList l)
  BStrOfChars -> do
    l <- gList a base
    vs <- listToList l
    return (VStr (strFromString [c | VChar c <- vs]))
  BStrReverse -> do s <- gStr a base; return (VStr (strFromString (reverse (strToString s))))
  BQuoteStr -> do
    s <- gStr a base
    return (str ("\"" ++ concatMap (escapeChar '"') (strToString s) ++ "\""))
  BPadLeft -> pad True
  BPadRight -> pad False
  -- lists
  BListNew -> VList <$> newList 4
  BListLen -> do l <- gList a base; VInt <$> listLength l
  BPush -> do l <- gList a base; v <- unsafeRead a (base + 1); listPush l v; return VUnit
  BPop -> do
    l <- gList a base
    n <- listLength l
    when (n == 0) (panic "empty list")
    listPop l
  BInsert -> do
    l <- gList a base; i <- gInt a (base + 1); v <- unsafeRead a (base + 2)
    n <- listLength l
    when (i < 0 || i > n) (panic "index out of bounds")
    listInsert l i v
    return VUnit
  BRemoveAt -> do
    l <- gList a base; i <- gInt a (base + 1)
    n <- listLength l
    when (i < 0 || i >= n) (panic "index out of bounds")
    listRemoveAt l i
  BClear -> do l <- gList a base; listClear l; return VUnit
  BListRepeat -> do
    v <- unsafeRead a base; n <- gInt a (base + 1)
    when (n < 0) (panic "negative count")
    VList <$> listFromList (replicate n v)
  BListConcat -> do
    x <- gList a base; y <- gList a (base + 1)
    xs <- listToList x; ys <- listToList y
    VList <$> listFromList (xs ++ ys)
  BSlice -> do
    l <- gList a base; f <- gInt a (base + 1); t <- gInt a (base + 2)
    n <- listLength l
    when (f < 0 || f > t || t > n) (panic "index out of bounds")
    VList <$> listSlice l f t
  BListCopy -> do l <- gList a base; xs <- listToList l; VList <$> listFromList xs
  BReverseList -> do l <- gList a base; xs <- listToList l; VList <$> listFromList (reverse xs)
  BListFirst -> do
    l <- gList a base
    n <- listLength l
    when (n == 0) (panic "empty list")
    listRead l 0
  BListLast -> do
    l <- gList a base
    n <- listLength l
    when (n == 0) (panic "empty list")
    listRead l (n - 1)
  BListMap -> do
    l <- gList a base; f <- unsafeRead a (base + 1)
    out <- newList 4
    let go i = do
          n <- listLength l
          when (i < n) $ do
            x <- listRead l i
            y <- rtCall rt f [x]
            listPush out y
            go (i + 1)
    go 0
    return (VList out)
  BListFilter -> do
    l <- gList a base; f <- unsafeRead a (base + 1)
    out <- newList 4
    let go i = do
          n <- listLength l
          when (i < n) $ do
            x <- listRead l i
            r <- rtCall rt f [x]
            case r of VBool True -> listPush out x; _ -> return ()
            go (i + 1)
    go 0
    return (VList out)
  BListFold -> do
    l <- gList a base; z <- unsafeRead a (base + 1); f <- unsafeRead a (base + 2)
    let go i acc = do
          n <- listLength l
          if i < n then do
            x <- listRead l i
            acc' <- rtCall rt f [acc, x]
            go (i + 1) acc'
          else return acc
    go 0 z
  BListAny -> do
    l <- gList a base; f <- unsafeRead a (base + 1)
    let go i = do
          n <- listLength l
          if i < n then do
            x <- listRead l i
            r <- rtCall rt f [x]
            case r of VBool True -> return True; _ -> go (i + 1)
          else return False
    VBool <$> go 0
  BListAll -> do
    l <- gList a base; f <- unsafeRead a (base + 1)
    let go i = do
          n <- listLength l
          if i < n then do
            x <- listRead l i
            r <- rtCall rt f [x]
            case r of VBool True -> go (i + 1); _ -> return False
          else return True
    VBool <$> go 0
  BListFind -> do
    (i, x) <- findIdx
    return (if i < 0 then noneV else someV x)
  BListFindIndex -> do
    (i, _) <- findIdx
    return (VInt i)
  BListIndexOf -> do
    l <- gList a base; x <- unsafeRead a (base + 1)
    VInt <$> indexOfEq l x
  BListContains -> do
    l <- gList a base; x <- unsafeRead a (base + 1)
    i <- indexOfEq l x
    return (VBool (i >= 0))
  BListZip -> do
    x <- gList a base; y <- gList a (base + 1)
    nx <- listLength x; ny <- listLength y
    ps <- forM [0 .. min nx ny - 1] $ \i -> do
      p <- listRead x i
      q <- listRead y i
      return (VTuple (fieldsArray [p, q]))
    VList <$> listFromList ps
  BListFlatten -> do
    outer <- gList a base
    out <- newList 4
    let go i = do
          n <- listLength outer
          when (i < n) $ do
            inner <- listRead outer i
            case inner of
              VList il -> do
                m <- listLength il
                forM_ [0 .. m - 1] $ \j -> listRead il j >>= listPush out
              _ -> return ()
            go (i + 1)
    go 0
    return (VList out)
  BSortBy -> do
    l <- gList a base; f <- unsafeRead a (base + 1)
    sortByImpl rt l f
  -- maps
  BMapNew -> VMap <$> newMap
  BMapLen -> do m <- gMap a base; VInt <$> mapSize m
  BMapHas -> do
    m <- gMap a base; k <- unsafeRead a (base + 1)
    r <- mapLookup m k
    return (VBool (maybe False (const True) r))
  BMapGet -> do
    m <- gMap a base; k <- unsafeRead a (base + 1)
    optV <$> mapLookup m k
  BMapGetOr -> do
    m <- gMap a base; k <- unsafeRead a (base + 1); d <- unsafeRead a (base + 2)
    maybe d id <$> mapLookup m k
  BMapSet -> do
    m <- gMap a base; k <- unsafeRead a (base + 1); v <- unsafeRead a (base + 2)
    mapInsert m k v
    return VUnit
  BMapDel -> do
    m <- gMap a base; k <- unsafeRead a (base + 1)
    VBool <$> mapDelete m k
  BKeysOf -> do m <- gMap a base; es <- mapEntries m; VList <$> listFromList (map fst es)
  BValuesOf -> do m <- gMap a base; es <- mapEntries m; VList <$> listFromList (map snd es)
  BPairsOf -> do
    m <- gMap a base
    es <- mapEntries m
    VList <$> listFromList [VTuple (fieldsArray [k, v]) | (k, v) <- es]
  BMapClear -> do m <- gMap a base; mapClearAll m; return VUnit
  BMapCopy -> do m <- gMap a base; VMap <$> mapCopyObj m
  -- option, result, tuples
  BIsSome -> variantIs 0 0
  BIsNone -> variantIs 0 1
  BUnwrap -> do
    v <- unsafeRead a base
    case v of
      VEnum _ 0 p -> return (indexA p 0)
      _ -> panic "unwrap of None"
  BUnwrapOr -> do
    v <- unsafeRead a base; d <- unsafeRead a (base + 1)
    case v of
      VEnum _ 0 p -> return (indexA p 0)
      _ -> return d
  BIsOk -> variantIs 1 0
  BIsErr -> variantIs 1 1
  BUnwrapOk -> do
    v <- unsafeRead a base
    case v of
      VEnum _ 0 p -> return (indexA p 0)
      _ -> panic "unwrap of Err"
  BUnwrapErr -> do
    v <- unsafeRead a base
    case v of
      VEnum _ 1 p -> return (indexA p 0)
      _ -> panic "unwrap of Ok"
  BFst -> do v <- unsafeRead a base; case v of VTuple p -> return (indexA p 0); _ -> bad
  BSnd -> do v <- unsafeRead a base; case v of VTuple p -> return (indexA p 1); _ -> bad
  BFmt -> do
    t <- gStr a base; args <- gList a (base + 1)
    vs <- listToList args
    r <- either panic (return . str) (formatTemplate (strToString t) [strToString s | VStr s <- vs])
    return r
  where
    int1 f = do x <- gInt a base; return (VInt (f x))
    int2 f = do x <- gInt a base; y <- gInt a (base + 1); return (VInt (f x y))
    flt1 f = do x <- gFloat a base; return (VFloat (f x))
    chr1 f = do c <- gChar a base; return (VBool (f c))
    variantIs d i = do
      v <- unsafeRead a base
      return (VBool (case v of VEnum d' j _ -> d' == d && j == i; _ -> False))
    pad left = do
      s <- gStr a base; w <- gInt a (base + 1); c <- gChar a (base + 2)
      when (w < 0) (panic "negative count")
      let n = strLength s
      if n >= w then return (VStr s) else do
        let fill = replicate (w - n) c
            body = strToString s
        return (str (if left then fill ++ body else body ++ fill))
    findIdx = do
      l <- gList a base; f <- unsafeRead a (base + 1)
      let go i = do
            n <- listLength l
            if i < n then do
              x <- listRead l i
              r <- rtCall rt f [x]
              case r of VBool True -> return (i, x); _ -> go (i + 1)
            else return (-1, VUnit)
      go 0
    indexOfEq l x = do
      let go i = do
            n <- listLength l
            if i < n then do
              y <- listRead l i
              e <- valueEq y x
              if e then return i else go (i + 1)
            else return (-1)
      go 0

-- Helpers ------------------------------------------------------------------------------

isAlphaA :: Char -> Bool
isAlphaA c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

toUpperA, toLowerA :: Char -> Char
toUpperA c = if c >= 'a' && c <= 'z' then chr (ord c - 32) else c
toLowerA c = if c >= 'A' && c <= 'Z' then chr (ord c + 32) else c

mapStr :: (Char -> Char) -> Str -> Str
mapStr f s = strFromList (strLength s) [f (strAt s i) | i <- [0 .. strLength s - 1]]

powLoop :: Int -> Int -> Int
powLoop x n = go 1 x n
  where
    go r _ 0 = r
    go r bs k =
      let r' = if k .&. 1 == 1 then r * bs else r
          k' = k `shiftR` 1
      in if k' > 0 then go r' (bs * bs) k' else r'

-- | @powF@ for a non-negative exponent: the loop of section 15.3.
powF :: Double -> Int -> Double
powF x n = go 1 x n
  where
    go :: Double -> Double -> Int -> Double
    go r _ 0 = r
    go r bs k =
      let r' = if k .&. 1 == 1 then r * bs else r
          k' = k `shiftR` 1
      in if k' > 0 then go r' (bs * bs) k' else r'

cmpF :: Double -> Double -> Int
cmpF x y
  | isNaN x = if isNaN y then 0 else 1
  | isNaN y = -1
  | x < y = -1
  | x > y = 1
  | otherwise = 0

showFloatAt' :: Int -> Double -> String
showFloatAt' d x
  | isNaN x = "nan"
  | isInfinite x = if x > 0 then "inf" else "-inf"
  | otherwise = showFixed d x

digitVal :: Char -> Maybe Int
digitVal c
  | c >= '0' && c <= '9' = Just (ord c - 48)
  | c >= 'a' && c <= 'z' = Just (ord c - 87)
  | c >= 'A' && c <= 'Z' = Just (ord c - 55)
  | otherwise = Nothing

parseIntRadixS :: Int -> String -> Maybe Int
parseIntRadixS radix s0 = do
  (neg, ds) <- case s0 of
    ('+' : r) -> Just (False, r)
    ('-' : r) -> Just (True, r)
    r -> Just (False, r)
  when (null ds) Nothing
  vals <- mapM (\c -> do d <- digitVal c; if d < radix then Just d else Nothing) ds
  let v = foldl (\acc d -> acc * toInteger radix + toInteger d) 0 vals
      v' = if neg then negate v else v
  if v' < toInteger (minBound :: Int) || v' > toInteger (maxBound :: Int)
    then Nothing else Just (fromInteger v')

parseFloatS :: String -> Maybe Double
parseFloatS s0 = do
  let (neg, s1) = case s0 of
        ('+' : r) -> (False, r)
        ('-' : r) -> (True, r)
        r -> (False, r)
      (ip, s2) = span isDigit s1
      (fp, hasDot, s3) = case s2 of
        ('.' : r) -> let (f, r') = span isDigit r in (f, True, r')
        _ -> ("", False, s2)
  when (null ip && null fp) Nothing
  when (null ip && not hasDot) Nothing
  (ex, rest) <- case s3 of
    (e : r) | e == 'e' || e == 'E' ->
      let (sg, r1) = case r of
            ('+' : x) -> (1, x)
            ('-' : x) -> (-1, x)
            x -> (1 :: Integer, x)
          (ds, r2) = span isDigit r1
      in if null ds then Nothing else Just (sg * read ds, r2)
    _ -> Just (0, s3)
  unless (null rest) Nothing
  let mant = read ('0' : ip ++ fp) :: Integer
      v = decimalToDouble mant (ex - toInteger (length fp))
  return (if neg then negate v else v)

-- | Position of the first occurrence of @sub@ in @s@.
firstOcc :: Str -> Str -> Maybe Int
firstOcc s sub = go 0
  where
    n = strLength s
    m = strLength sub
    go i | i + m > n = Nothing
         | matchAt s sub i = Just i
         | otherwise = go (i + 1)

lastOcc :: Str -> Str -> Maybe Int
lastOcc s sub = go (strLength s - strLength sub)
  where
    go i | i < 0 = Nothing
         | matchAt s sub i = Just i
         | otherwise = go (i - 1)

-- | Does @p@ occur in @s@ at index @i@ (caller guarantees the range)?
matchAt :: Str -> Str -> Int -> Bool
matchAt s p i = strLength p + i <= strLength s && go 0
  where
    m = strLength p
    go j | j >= m = True
         | strAt s (i + j) /= strAt p j = False
         | otherwise = go (j + 1)

splitStr :: Str -> Str -> [Str]
splitStr s sep = go 0 0
  where
    n = strLength s
    m = strLength sep
    go start i
      | i + m > n = [strSlice s start n]
      | matchAt s sep i = strSlice s start i : go (i + m) (i + m)
      | otherwise = go start (i + 1)

replaceStr :: Str -> Str -> Str -> Str
replaceStr s from to = strFromString (go 0)
  where
    n = strLength s
    m = strLength from
    toS = strToString to
    go i
      | i >= n = []
      | matchAt s from i = toS ++ go (i + m)
      | otherwise = strAt s i : go (i + 1)

trimStr :: Bool -> Bool -> Str -> Str
trimStr left right s = strSlice s lo hi
  where
    n = strLength s
    lo = if left then length (takeWhile (isAsciiSpace . strAt s) [0 .. n - 1]) else 0
    hi = if right
           then n - length (takeWhile (isAsciiSpace . strAt s) [n - 1, n - 2 .. lo])
           else n

escapeChar :: Char -> Char -> String
escapeChar quote c
  | c == '\\' = "\\\\"
  | c == quote = ['\\', c]
  | c == '\n' = "\\n"
  | c == '\r' = "\\r"
  | c == '\t' = "\\t"
  | ord c < 0x20 || ord c == 0x7f = "\\u{" ++ showHex (ord c) "}"
  | otherwise = [c]

-- | Section 15.9.
formatTemplate :: String -> [String] -> Either String String
formatTemplate tmpl args = go tmpl args (0 :: Int) []
  where
    nargs = length args
    go [] _ count acc
      | count == nargs = Right (concat (reverse acc))
      | otherwise = Left "bad format"
    go ('{' : '{' : r) as c acc = go r as c ("{" : acc)
    go ('{' : '}' : r) as c acc = case as of
      (x : xs) -> go r xs (c + 1) (x : acc)
      [] -> go r [] (c + 1) acc
    go ('{' : _) _ _ _ = Left "bad format"
    go ('}' : '}' : r) as c acc = go r as c ("}" : acc)
    go ('}' : _) _ _ _ = Left "bad format"
    go (ch : r) as c acc = go r as c ([ch] : acc)

-- | The merge sort of section 15.6.
sortByImpl :: Runtime -> ListObj -> Value -> IO Value
sortByImpl rt l f = do
  elems <- listToList l
  let n = length elems
  if n <= 1 then VList <$> listFromList elems else do
    src0 <- newArray_ (0, n - 1) :: IO (IOArray Int Value)
    dst0 <- newArray_ (0, n - 1) :: IO (IOArray Int Value)
    forM_ (zip [0 ..] elems) $ \(i, v) -> unsafeWrite src0 i v
    let outer src dst width
          | width >= n = return src
          | otherwise = do
              runs src dst width 0
              outer dst src (width * 2)
        runs src dst width i
          | i >= n = return ()
          | otherwise = do
              let mid = min (i + width) n
                  hi = min (i + 2 * width) n
              merge src dst mid hi i mid i
              runs src dst width (i + 2 * width)
        merge src dst mid hi = go
          where
            go p q k
              | p < mid && q < hi = do
                  x <- unsafeRead src p
                  y <- unsafeRead src q
                  r <- rtCall rt f [x, y]
                  case r of
                    VInt c | c <= 0 -> unsafeWrite dst k x >> go (p + 1) q (k + 1)
                    _ -> unsafeWrite dst k y >> go p (q + 1) (k + 1)
              | p < mid = do
                  x <- unsafeRead src p
                  unsafeWrite dst k x
                  go (p + 1) q (k + 1)
              | q < hi = do
                  y <- unsafeRead src q
                  unsafeWrite dst k y
                  go p (q + 1) (k + 1)
              | otherwise = return ()
    res <- outer src0 dst0 1
    vs <- mapM (unsafeRead res) [0 .. n - 1]
    VList <$> listFromList vs
