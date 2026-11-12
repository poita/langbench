{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Commonmark.Inline
-- Description : Phase 2 of the conversion: inline structure.
--
-- Parses the raw content of a paragraph or heading into 'Inline' nodes with
-- the delimiter stack / bracket stack / process-emphasis algorithm of
-- Appendix A of the CommonMark specification, as implemented by @cmark@.
--
-- Inline nodes live in unboxed arrays as a doubly linked sibling list, so
-- removing delimiter entries and wrapping a range of nodes in an emphasis,
-- link or image node are O(1) per entry or node.  Code-span search uses
-- cmark's backtick memo and process-emphasis uses the @openers_bottom@
-- bounds, so a whole block is parsed in time linear in its length.
module Commonmark.Inline
  ( parseInlines
  ) where

import Control.Monad (when)
import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STArray, STUArray, newArray)
import Data.Bits ((.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)

import Commonmark.Internal.Text
import Commonmark.Types

-- Node kinds
kText, kSoft, kHard, kCode, kEmph, kStrong, kLink, kImage :: Int
kText = 0
kSoft = 1
kHard = 2
kCode = 3
kEmph = 4
kStrong = 5
kLink = 6
kImage = 7

-- | An entry of the bracket stack: is it an image, its text node, and the
-- position just after its @[@.
data Bracket = Bracket !Bool !Int !Int

-- | All the mutable state of one inline parse.
data Env s = Env
  { eKind :: !(STUArray s Int Int)
  , eNext :: !(STUArray s Int Int)
  , ePrev :: !(STUArray s Int Int)
  , eFirst :: !(STUArray s Int Int)
  , eLast :: !(STUArray s Int Int)
  , eText :: !(STArray s Int ByteString)
  , eTitle :: !(STArray s Int (Maybe ByteString))
  , eCtr :: !(STUArray s Int Int) -- ^ 0: node count, 1: delimiter count, 2: backtick memo "scanned"
  , eBt :: !(STUArray s Int Int) -- ^ backtick memo @last[k]@
  , dChar :: !(STUArray s Int Int)
  , dOrig :: !(STUArray s Int Int)
  , dFlags :: !(STUArray s Int Int) -- ^ bit 0: can open, bit 1: can close
  , dNode :: !(STUArray s Int Int)
  , dPos :: !(STUArray s Int Int)
  , dPrev :: !(STUArray s Int Int)
  , dNext :: !(STUArray s Int Int)
  }

-- | Parse the content of a paragraph or heading into inline nodes.  Trailing
-- whitespace of the content is ignored.
parseInlines :: ByteString -> [Inline]
parseInlines raw
  | B.null s = []
  | otherwise = runST (parseST s)
  where
    s = B.dropWhileEnd isSpaceW raw

parseST :: forall s. ByteString -> ST s [Inline]
parseST s = do
  let n = B.length s
      cap = 2 * n + 8
  env <-
    Env
      <$> newArray (0, cap) 0
      <*> newArray (0, cap) 0
      <*> newArray (0, cap) 0
      <*> newArray (0, cap) 0
      <*> newArray (0, cap) 0
      <*> newArray (0, cap) B.empty
      <*> newArray (0, cap) Nothing
      <*> newArray (0, 3) 0
      <*> newArray (0, n + 2) 0
      <*> newArray (0, n + 2) 0
      <*> newArray (0, n + 2) 0
      <*> newArray (0, n + 2) 0
      <*> newArray (0, n + 2) 0
      <*> newArray (0, n + 2) 0
      <*> newArray (0, n + 2) 0
      <*> newArray (0, n + 2) 0
  unsafeWrite (eCtr env) 0 1 -- node 0 is the sentinel head of the top-level list
  (_, dtop) <- mainLoop env s 0 0 0 [] True
  _ <- processEmphasis env 0 dtop
  freezeList env =<< unsafeRead (eNext env) 0

-- ---------------------------------------------------------------------------
-- Node helpers

newNode :: Env s -> Int -> ByteString -> ST s Int
newNode env k t = do
  i <- unsafeRead (eCtr env) 0
  unsafeWrite (eCtr env) 0 (i + 1)
  unsafeWrite (eKind env) i k
  writeText env i t
  return i

writeText :: Env s -> Int -> ByteString -> ST s ()
writeText env i t = unsafeWriteBoxed (eText env) i t

unsafeWriteBoxed :: STArray s Int a -> Int -> a -> ST s ()
unsafeWriteBoxed = unsafeWrite

-- | Append a node after the tail @tl@ of the top-level list.
append :: Env s -> Int -> Int -> ST s ()
append env tl nd = do
  unsafeWrite (eNext env) tl nd
  unsafeWrite (ePrev env) nd tl

emitText :: Env s -> Int -> ByteString -> ST s Int
emitText env tl t = do
  nd <- newNode env kText t
  append env tl nd
  return nd

-- ---------------------------------------------------------------------------
-- Main loop

isSpecial :: Word8 -> Bool
isSpecial w =
  w == 10 || w == 96 || w == 92 || w == 38 || w == 60 || w == 42 || w == 95 || w == 91 || w == 93 || w == 33

mainLoop :: forall s. Env s -> ByteString -> Int -> Int -> Int -> [Bracket] -> Bool -> ST s (Int, Int)
mainLoop env s = go
  where
    n = B.length s
    at i = peekAt s i

    go :: Int -> Int -> Int -> [Bracket] -> Bool -> ST s (Int, Int)
    go !i !tl !dtop brs !lc
      | i >= n = return (tl, dtop)
      | otherwise = case BU.unsafeIndex s i of
          10 -> do
            let hard = i > 1 && BU.unsafeIndex s (i - 1) == 32 && BU.unsafeIndex s (i - 2) == 32
            nd <- newNode env (if hard then kHard else kSoft) B.empty
            append env tl nd
            let j = i + 1 + B.length (B.takeWhile isSpaceOrTab (B.drop (i + 1) s))
            go j nd dtop brs lc
          96 -> codeSpan i tl dtop brs lc
          92 -> do
            let nx = at (i + 1)
            if i + 1 < n && isPunctW nx
              then do
                nd <- emitText env tl (B.take 1 (B.drop (i + 1) s))
                go (i + 2) nd dtop brs lc
              else
                if i + 1 < n && nx == 10
                  then do
                    nd <- newNode env kHard B.empty
                    append env tl nd
                    go (i + 2) nd dtop brs lc
                  else do
                    nd <- emitText env tl (B.take 1 (B.drop i s))
                    go (i + 1) nd dtop brs lc
          38 -> case matchEntity s (i + 1) of
            Just (t, j) -> do
              nd <- emitText env tl t
              go j nd dtop brs lc
            Nothing -> do
              nd <- emitText env tl (B.take 1 (B.drop i s))
              go (i + 1) nd dtop brs lc
          60 -> case autolink s i of
            Just (dest, txt, j) -> do
              child <- newNode env kText txt
              nd <- newNode env kLink dest
              unsafeWrite (eFirst env) nd child
              unsafeWrite (eLast env) nd child
              append env tl nd
              go j nd dtop brs lc
            Nothing -> do
              nd <- emitText env tl (B.take 1 (B.drop i s))
              go (i + 1) nd dtop brs lc
          c
            | c == 42 || c == 95 -> delimRun i c tl dtop brs lc
          91 -> do
            nd <- emitText env tl (B.take 1 (B.drop i s))
            go (i + 1) nd dtop (Bracket False nd (i + 1) : brs) False
          33
            | at (i + 1) == 91 && i + 1 < n -> do
                nd <- emitText env tl (B.take 2 (B.drop i s))
                go (i + 2) nd dtop (Bracket True nd (i + 2) : brs) lc
            | otherwise -> do
                nd <- emitText env tl (B.take 1 (B.drop i s))
                go (i + 1) nd dtop brs lc
          93 -> closeBracket i tl dtop brs lc
          _ -> do
            let rest = B.drop i s
                run = maybe (B.length rest) id (B.findIndex isSpecial rest)
                j = i + run
                chunk0 = B.take run rest
                chunk = if j < n && BU.unsafeIndex s j == 10 then B.dropWhileEnd isSpaceW chunk0 else chunk0
            if B.null chunk
              then go j tl dtop brs lc
              else do
                nd <- emitText env tl chunk
                go j nd dtop brs lc

    -- Code spans, with cmark's backtick memo.
    codeSpan !i !tl !dtop brs !lc = do
      let rest = B.drop i s
          run = B.length (B.takeWhile (== 96) rest)
          p = i + run
      scanned <- unsafeRead (eCtr env) 2
      lastN <- if run <= n then unsafeRead (eBt env) run else return 0
      found <-
        if scanned /= 0 && lastN <= p
          then return Nothing
          else scan run p
      case found of
        Just st -> do
          let content = normalizeCode (B.take (st - p) (B.drop p s))
          nd <- newNode env kCode content
          append env tl nd
          go (st + run) nd dtop brs lc
        Nothing -> do
          nd <- emitText env tl (B.take run rest)
          go p nd dtop brs lc

    scan !run !q = do
      case B.elemIndex 96 (B.drop q s) of
        Nothing -> do
          unsafeWrite (eCtr env) 2 1
          return Nothing
        Just rel -> do
          let st = q + rel
              k = B.length (B.takeWhile (== 96) (B.drop st s))
          when (k <= n) $ unsafeWrite (eBt env) k st
          if k == run then return (Just st) else scan run (st + k)

    -- Emphasis delimiter runs.
    delimRun !i !c !tl !dtop brs !lc = do
      let run = B.length (B.takeWhile (== c) (B.drop i s))
          j = i + run
          before = if i == 0 then 10 else BU.unsafeIndex s (i - 1)
          after = if j >= n then 10 else BU.unsafeIndex s j
          wsB = isSpaceW before
          wsA = isSpaceW after
          puB = isPunctW before
          puA = isPunctW after
          leftF = not wsA && (not puA || wsB || puB)
          rightF = not wsB && (not puB || wsA || puA)
          (canOpen, canClose)
            | c == 42 = (leftF, rightF)
            | otherwise = (leftF && (not rightF || puB), rightF && (not leftF || puA))
      nd <- emitText env tl (B.take run (B.drop i s))
      if canOpen || canClose
        then do
          d <- unsafeRead (eCtr env) 1
          let d' = d + 1
          unsafeWrite (eCtr env) 1 d'
          unsafeWrite (dChar env) d' (fromIntegral c)
          unsafeWrite (dOrig env) d' run
          unsafeWrite (dFlags env) d' ((if canOpen then 1 else 0) .|. (if canClose then 2 else 0))
          unsafeWrite (dNode env) d' nd
          unsafeWrite (dPos env) d' j
          unsafeWrite (dPrev env) d' dtop
          unsafeWrite (dNext env) d' 0
          when (dtop /= 0) $ unsafeWrite (dNext env) dtop d'
          go j nd d' brs lc
        else go j nd dtop brs lc

    -- A closing bracket.
    closeBracket !i !tl !dtop brs !lc = case brs of
      [] -> plain
      (Bracket isImg onode bpos : rest)
        | not isImg && lc -> do
            nd <- emitText env tl "]"
            go (i + 1) nd dtop rest lc
        | otherwise -> case linkTail s (i + 1) of
            Nothing -> do
              nd <- emitText env tl "]"
              go (i + 1) nd dtop rest lc
            Just (rawDest, rawTitle, j) -> do
              let dest = unescapeBackslashes (decodeEntities (trimWs rawDest))
                  title = fmap (unescapeBackslashes . decodeEntities) rawTitle
              link <- newNode env (if isImg then kImage else kLink) dest
              unsafeWrite (eTitle env) link title
              first <- unsafeRead (eNext env) onode
              if tl == onode
                then do
                  unsafeWrite (eFirst env) link 0
                  unsafeWrite (eLast env) link 0
                else do
                  unsafeWrite (eFirst env) link first
                  unsafeWrite (eLast env) link tl
                  unsafeWrite (ePrev env) first 0
              unsafeWrite (eNext env) onode link
              unsafeWrite (ePrev env) link onode
              unsafeWrite (eNext env) link 0
              writeText env onode B.empty
              dtop' <- processEmphasis env bpos dtop
              go j link dtop' rest (if isImg then lc else True)
      where
        plain = do
          nd <- emitText env tl "]"
          go (i + 1) nd dtop brs lc

-- | Normalise the content of a code span.
normalizeCode :: ByteString -> ByteString
normalizeCode raw =
  let t = B.map (\w -> if w == 10 then 32 else w) raw
      m = B.length t
   in if m >= 2 && B.head t == 32 && B.last t == 32 && B.any (/= 32) t
        then B.take (m - 2) (B.drop 1 t)
        else t

-- ---------------------------------------------------------------------------
-- Process emphasis

-- | Run the process-emphasis algorithm over the delimiter entries with
-- position @>= bottom@, then drop them.  Returns the new top of the
-- delimiter stack.
processEmphasis :: forall s. Env s -> Int -> Int -> ST s Int
processEmphasis env bottom top = do
  (firstIn, before) <- findFirst top 0
  if firstIn == 0
    then return top
    else do
      ob <- newArray (0, 11) bottom :: ST s (STUArray s Int Int)
      runClosers ob firstIn
      when (before /= 0) $ unsafeWrite (dNext env) before 0
      return before
  where
    findFirst !d !lastIn
      | d == 0 = return (lastIn, 0)
      | otherwise = do
          p <- unsafeRead (dPos env) d
          if p >= bottom
            then do
              pr <- unsafeRead (dPrev env) d
              findFirst pr d
            else return (lastIn, d)

    removeEntry e = do
      p <- unsafeRead (dPrev env) e
      q <- unsafeRead (dNext env) e
      when (p /= 0) $ unsafeWrite (dNext env) p q
      when (q /= 0) $ unsafeWrite (dPrev env) q p

    runClosers :: STUArray s Int Int -> Int -> ST s ()
    runClosers ob = loop
      where
        loop 0 = return ()
        loop c = do
          fl <- unsafeRead (dFlags env) c
          if fl .&. 2 == 0
            then unsafeRead (dNext env) c >>= loop
            else do
              ch <- unsafeRead (dChar env) c
              orig <- unsafeRead (dOrig env) c
              let canOpen = fl .&. 1 /= 0
                  kind = (if ch == 95 then 6 else 0) + (if canOpen then 3 else 0) + orig `rem` 3
              bot <- unsafeRead ob kind
              start <- unsafeRead (dPrev env) c
              mo <- findOpener ch orig canOpen bot start
              case mo of
                Nothing -> do
                  p <- unsafeRead (dPos env) c
                  unsafeWrite ob kind p
                  nx <- unsafeRead (dNext env) c
                  when (not canOpen) $ removeEntry c
                  loop nx
                Just o -> do
                  onode <- unsafeRead (dNode env) o
                  cnode <- unsafeRead (dNode env) c
                  otxt <- unsafeRead (eText env) onode
                  ctxt <- unsafeRead (eText env) cnode
                  let olen = B.length otxt
                      clen = B.length ctxt
                      use = if olen >= 2 && clen >= 2 then 2 else 1
                  writeText env onode (B.take (olen - use) otxt)
                  writeText env cnode (B.drop use ctxt)
                  -- remove delimiters strictly between opener and closer
                  unsafeWrite (dNext env) o c
                  unsafeWrite (dPrev env) c o
                  -- wrap the nodes strictly between the two text nodes
                  a <- unsafeRead (eNext env) onode
                  e <- newNode env (if use == 2 then kStrong else kEmph) B.empty
                  if a == cnode
                    then do
                      unsafeWrite (eFirst env) e 0
                      unsafeWrite (eLast env) e 0
                    else do
                      b <- unsafeRead (ePrev env) cnode
                      unsafeWrite (eFirst env) e a
                      unsafeWrite (eLast env) e b
                      unsafeWrite (ePrev env) a 0
                      unsafeWrite (eNext env) b 0
                  unsafeWrite (eNext env) onode e
                  unsafeWrite (ePrev env) e onode
                  unsafeWrite (eNext env) e cnode
                  unsafeWrite (ePrev env) cnode e
                  when (olen - use == 0) $ removeEntry o
                  if clen - use == 0
                    then do
                      nx <- unsafeRead (dNext env) c
                      removeEntry c
                      loop nx
                    else loop c

    findOpener :: Int -> Int -> Bool -> Int -> Int -> ST s (Maybe Int)
    findOpener ch orig canOpen bot = go
      where
        go 0 = return Nothing
        go o = do
          p <- unsafeRead (dPos env) o
          if p < bot
            then return Nothing
            else do
              fl <- unsafeRead (dFlags env) o
              och <- unsafeRead (dChar env) o
              ook <-
                if fl .&. 1 /= 0 && och == ch
                  then do
                    oorig <- unsafeRead (dOrig env) o
                    let oCanClose = fl .&. 2 /= 0
                    return (not (canOpen || oCanClose) || orig `rem` 3 == 0 || (oorig + orig) `rem` 3 /= 0)
                  else return False
              if ook then return (Just o) else unsafeRead (dPrev env) o >>= go

-- ---------------------------------------------------------------------------
-- Links and autolinks

-- | Parse @(destination "title")@ starting at the index of the @(@.  Returns
-- the raw destination, the raw title (delimiters removed) and the index after
-- the closing parenthesis.
linkTail :: ByteString -> Int -> Maybe (ByteString, Maybe ByteString, Int)
linkTail s j
  | at j /= 40 || j >= n = Nothing
  | otherwise = do
      let p1 = skipWs (j + 1)
      (dest, p2) <- scanDest p1
      let p3 = skipWs p2
      if p3 > p2 && startsTitle (at p3) && p3 < n
        then do
          (title, p4) <- scanTitle p3
          let p5 = skipWs p4
          if p5 < n && at p5 == 41 then Just (dest, Just title, p5 + 1) else Nothing
        else
          if p3 < n && at p3 == 41 then Just (dest, Nothing, p3 + 1) else Nothing
  where
    n = B.length s
    at = peekAt s
    skipWs i = i + B.length (B.takeWhile isSpaceW (B.drop i s))
    startsTitle c = c == 34 || c == 39 || c == 40

    scanDest p
      | p < n && at p == 60 = pointy (p + 1)
      | otherwise = bare p p (0 :: Int)
      where
        pointy !i
          | i >= n = Nothing
          | otherwise = case BU.unsafeIndex s i of
              62 -> Just (B.take (i - p - 1) (B.drop (p + 1) s), i + 1)
              92 -> pointy (i + 2)
              10 -> Nothing
              60 -> Nothing
              _ -> pointy (i + 1)
        bare !st !i !nest
          | i >= n = Nothing
          | otherwise =
              let c = BU.unsafeIndex s i
               in if c == 92 && i + 1 < n && isPunctW (BU.unsafeIndex s (i + 1))
                    then bare st (i + 2) nest
                    else
                      if c == 40
                        then if nest + 1 > 32 then Nothing else bare st (i + 1) (nest + 1)
                        else
                          if c == 41
                            then if nest == 0 then done st i nest else bare st (i + 1) (nest - 1)
                            else if isSpaceW c then done st i nest else bare st (i + 1) nest
        done st i nest = if nest == 0 then Just (B.take (i - st) (B.drop st s), i) else Nothing

    -- The longest title match starting at the opening delimiter at p.
    scanTitle p =
      let open = at p
          close = if open == 40 then 41 else open
          go !i !lastClose
            | i >= n = finish lastClose
            | otherwise =
                let c = BU.unsafeIndex s i
                    escaped = BU.unsafeIndex s (i - 1) == 92 && i - 1 > p
                    forbidden = c == close || (open == 40 && c == 40)
                 in if not forbidden
                      then go (i + 1) lastClose
                      else
                        if escaped
                          then go (i + 1) (if c == close then i else lastClose)
                          else if c == close then finish i else finish lastClose
          finish e
            | e <= p = Nothing
            | otherwise = Just (B.take (e - p - 1) (B.drop (p + 1) s), e + 1)
       in go (p + 1) 0

-- | Try to match an autolink at the index of a @<@.  Returns the (raw)
-- destination, the text and the index after the @>@.
autolink :: ByteString -> Int -> Maybe (ByteString, ByteString, Int)
autolink s i = uri <|> email
  where
    n = B.length s
    start = i + 1
    rest = B.drop start s
    a <|> b = case a of Nothing -> b; _ -> a

    uri =
      let scheme = B.takeWhile (\w -> isAlnumW w || w == 46 || w == 43 || w == 45) rest
          k = B.length scheme
       in if k >= 2 && k <= 32 && isAlphaW (B.head scheme) && start + k < n && BU.unsafeIndex s (start + k) == 58
            then
              let body = B.takeWhile (\w -> w > 32 && w /= 60 && w /= 62) (B.drop (start + k + 1) s)
                  end = start + k + 1 + B.length body
               in if end < n && BU.unsafeIndex s end == 62
                    then
                      let inner = decodeEntities (B.take (end - start) rest)
                       in Just (inner, inner, end + 1)
                    else Nothing
            else Nothing

    isLocal w = isAlnumW w || B.elem w ".!#$%&'*+/=?^_`{|}~-"
    email =
      let local = B.takeWhile isLocal rest
          k = B.length local
          dstart = start + k + 1
       in if k >= 1 && start + k < n && BU.unsafeIndex s (start + k) == 64
            then case domain dstart of
              Just end ->
                let inner = decodeEntities (B.take (end - start) rest)
                 in Just (B.append "mailto:" inner, inner, end + 1)
              Nothing -> Nothing
            else Nothing

    -- domain labels; returns the index of the closing '>'
    domain p =
      let run = B.takeWhile (\w -> isAlnumW w || w == 45) (B.drop p s)
          k = B.length run
          q = p + k
       in if k >= 1 && k <= 63 && isAlnumW (B.head run) && isAlnumW (B.last run) && q < n
            then case BU.unsafeIndex s q of
              62 -> Just q
              46 -> domain (q + 1)
              _ -> Nothing
            else Nothing

-- ---------------------------------------------------------------------------
-- Freezing

freezeList :: Env s -> Int -> ST s [Inline]
freezeList env = go []
  where
    go acc 0 = return (coalesce (reverse acc))
    go acc nd = do
      x <- freezeNode env nd
      nx <- unsafeRead (eNext env) nd
      go (maybe acc (: acc) x) nx

-- | Merge adjacent text nodes.
coalesce :: [Inline] -> [Inline]
coalesce (Text a : Text b : rest) =
  let (more, rest') = spanTexts rest
   in coalesce (Text (B.concat (a : b : more)) : rest')
coalesce (x : rest) = x : coalesce rest
coalesce [] = []

spanTexts :: [Inline] -> ([ByteString], [Inline])
spanTexts (Text t : rest) = let (ts, r) = spanTexts rest in (t : ts, r)
spanTexts rest = ([], rest)

freezeNode :: Env s -> Int -> ST s (Maybe Inline)
freezeNode env nd = do
  k <- unsafeRead (eKind env) nd
  t <- unsafeRead (eText env) nd
  let kids = unsafeRead (eFirst env) nd >>= freezeList env
  if k == kText
    then return (if B.null t then Nothing else Just (Text t))
    else
      if k == kSoft
        then return (Just SoftBreak)
        else
          if k == kHard
            then return (Just LineBreak)
            else
              if k == kCode
                then return (Just (Code t))
                else do
                  cs <- kids
                  title <- unsafeRead (eTitle env) nd
                  return . Just $
                    if k == kEmph
                      then Emph cs
                      else
                        if k == kStrong
                          then Strong cs
                          else if k == kLink then Link t title cs else Image t title cs
