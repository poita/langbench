{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Commonmark.Block
-- Description : Phase 1 of the conversion: block structure.
--
-- A line-by-line block parser in the style of @cmark@ (and Appendix A of the
-- CommonMark specification).  Each line is matched against the chain of open
-- blocks, new blocks are opened, and the remainder of the line is added to
-- the innermost open leaf.  The work per line is O(depth) plus the number of
-- bytes the scanners actually examine.
--
-- The tree is built with mutable nodes in 'ST' (so that closing a block, the
-- \"last line blank\" flags used for list tightness, and lazy continuation
-- behave exactly like the reference implementation), and frozen into the pure
-- 'Block' type at the end.
module Commonmark.Block
  ( parseBlocks
  ) where

import Control.Monad (forM, forM_, when)
import Control.Monad.ST (ST, runST)
import Data.Bits (complement, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Unsafe as BU
import Data.STRef
import Data.Word (Word8)

import Commonmark.Internal.Text
import Commonmark.Types

-- ---------------------------------------------------------------------------
-- Mutable block tree

data Kind
  = KDoc
  | KQuote
  | -- | ordered?, delimiter byte (bullet char, or @.@ / @)@), start number
    KList !Bool !Word8 !Int
  | -- | marker offset, padding
    KItem !Int !Int
  | KPara
  | KHeading !Int
  | KThematic
  | KIndented
  | -- | fence char, fence length, fence offset
    KFenced !Word8 !Int !Int

data Node s = Node
  { nKind :: !(STRef s Kind)
  , nParent :: !(Maybe (Node s))
  , nChildren :: !(STRef s [Node s]) -- ^ in reverse order: the head is the last child
  , nFlags :: !(STRef s Int)
  , nContent :: !(STRef s [ByteString]) -- ^ in reverse order
  , nStartLine :: !Int
  }

instance Eq (Node s) where
  a == b = nFlags a == nFlags b

fOpen, fLastBlank, fChecked, fTight :: Int
fOpen = 1
fLastBlank = 2
fChecked = 4
fTight = 8

getFlag :: Node s -> Int -> ST s Bool
getFlag n f = (\x -> x .&. f /= 0) <$> readSTRef (nFlags n)

setFlag :: Node s -> Int -> Bool -> ST s ()
setFlag n f v = modifySTRef' (nFlags n) (\x -> if v then x .|. f else x .&. complement f)

newNode :: Maybe (Node s) -> Kind -> Int -> ST s (Node s)
newNode parent k line = do
  kr <- newSTRef k
  ch <- newSTRef []
  fl <- newSTRef fOpen
  co <- newSTRef []
  return (Node kr parent ch fl co line)

isCodeKind :: Kind -> Bool
isCodeKind KIndented = True
isCodeKind (KFenced {}) = True
isCodeKind _ = False

isParaKind :: Kind -> Bool
isParaKind KPara = True
isParaKind _ = False

-- | Can a block of kind @child@ be a child of a block of kind @parent@?
canContain :: Kind -> Kind -> Bool
canContain parent child = case parent of
  KDoc -> notItem
  KQuote -> notItem
  KItem {} -> notItem
  KList {} -> case child of KItem {} -> True; _ -> False
  _ -> False
  where
    notItem = case child of KItem {} -> False; _ -> True

appendLine :: Node s -> ByteString -> ST s ()
appendLine n line = modifySTRef' (nContent n) (\cs -> newline : line : cs)

newline :: ByteString
newline = B.singleton 10

-- ---------------------------------------------------------------------------
-- Line cursor

-- | Position within the current line: byte offset, column (tabs expanded to
-- multiples of 4) and whether the tab at @offset@ is partially consumed.
data Cur = Cur {cOff :: !Int, cCol :: !Int, _cTab :: !Bool}

-- | Offset and column of the first non-space/tab character at or after the cursor.
findNonspace :: ByteString -> Cur -> (Int, Int)
findNonspace ln (Cur off0 col0 _) = go off0 col0
  where
    n = B.length ln
    go !off !col
      | off >= n = (off, col)
      | otherwise = case BU.unsafeIndex ln off of
          32 -> go (off + 1) (col + 1)
          9 -> go (off + 1) (col + 4 - col `rem` 4)
          _ -> (off, col)

-- | Advance by a number of bytes (not columns).
advanceChars :: ByteString -> Cur -> Int -> Cur
advanceChars ln (Cur off0 col0 _) cnt0 = go off0 col0 cnt0
  where
    n = B.length ln
    go !off !col !cnt
      | cnt <= 0 || off >= n = Cur off col False
      | BU.unsafeIndex ln off == 9 = go (off + 1) (col + 4 - col `rem` 4) (cnt - 1)
      | otherwise = go (off + 1) (col + 1) (cnt - 1)

-- | Advance by a number of columns; a tab may be partially consumed.
advanceCols :: ByteString -> Cur -> Int -> Cur
advanceCols ln (Cur off0 col0 pt0) cnt0 = go off0 col0 pt0 cnt0
  where
    n = B.length ln
    go !off !col !pt !cnt
      | cnt <= 0 || off >= n = Cur off col pt
      | BU.unsafeIndex ln off == 9 =
          let toTab = 4 - col `rem` 4
              partial = toTab > cnt
              adv = min cnt toTab
           in go (if partial then off else off + 1) (col + adv) partial (cnt - adv)
      | otherwise = go (off + 1) (col + 1) False (cnt - 1)

-- | The rest of the line, with a partially consumed tab replaced by spaces.
restOf :: ByteString -> Cur -> ByteString
restOf ln (Cur off col pt)
  | pt = B.append (B.replicate (4 - col `rem` 4) 32) (B.drop (off + 1) ln)
  | otherwise = B.drop off ln

-- ---------------------------------------------------------------------------
-- Pure scanners (each works from a position, at cost proportional to what it examines)

-- | @#{1,6}@ followed by spaces/tabs or end of line.  Returns the level and
-- the offset after the hashes and all following spaces/tabs.
atxStart :: ByteString -> Int -> Maybe (Int, Int)
atxStart ln p =
  let hashes = B.length (B.takeWhile (== 35) (B.take 7 (B.drop p ln)))
      q = p + hashes
   in if hashes >= 1 && hashes <= 6 && (q >= B.length ln || isSpaceOrTab (BU.unsafeIndex ln q))
        then Just (hashes, q + B.length (B.takeWhile isSpaceOrTab (B.drop q ln)))
        else Nothing

-- | An opening code fence at the position: fence byte and run length.
fenceStart :: ByteString -> Int -> Maybe (Word8, Int)
fenceStart ln p
  | c == 96 || c == 126 =
      let run = B.length (B.takeWhile (== c) (B.drop p ln))
       in if run >= 3 && (c == 126 || B.notElem 96 (B.drop (p + run) ln))
            then Just (c, run)
            else Nothing
  | otherwise = Nothing
  where
    c = peekAt ln p

-- | A setext underline: a run of @=@ or @-@ followed only by spaces/tabs.
setextLevel :: ByteString -> Int -> Maybe Int
setextLevel ln p
  | c == 61 || c == 45 =
      let rest = B.drop p ln
          run = B.length (B.takeWhile (== c) rest)
       in if B.all isSpaceOrTab (B.drop run rest) then Just (if c == 61 then 1 else 2) else Nothing
  | otherwise = Nothing
  where
    c = peekAt ln p

-- | Three or more of the same of @*@, @_@, @-@, interleaved with spaces/tabs.
isThematic :: ByteString -> Int -> Bool
isThematic ln p
  | c == 42 || c == 95 || c == 45 = go p (0 :: Int)
  | otherwise = False
  where
    c = peekAt ln p
    n = B.length ln
    go !i !cnt
      | i >= n = cnt >= 3
      | otherwise =
          let x = BU.unsafeIndex ln i
           in if x == c then go (i + 1) (cnt + 1) else if isSpaceOrTab x then go (i + 1) cnt else False

-- | A list marker at the position: (ordered?, delimiter byte, start number, marker width).
-- @interrupts@ is true when the marker would interrupt a paragraph.
listMarker :: ByteString -> Int -> Bool -> Maybe (Bool, Word8, Int, Int)
listMarker ln p interrupts
  | c == 42 || c == 43 || c == 45 = finish False c 0 1
  | isDigitW c =
      let digits = B.takeWhile isDigitW (B.take 10 (B.drop p ln))
          k = B.length digits
          d = peekAt ln (p + k)
       in if k <= 9 && (d == 46 || d == 41)
            then finish True d (B.foldl' (\a x -> a * 10 + fromIntegral x - 48) 0 digits) (k + 1)
            else Nothing
  | otherwise = Nothing
  where
    c = peekAt ln p
    finish ordered delim start w =
      let after = p + w
          nxt = peekAt ln after
          okSpace = after >= B.length ln || isSpaceOrTab nxt
          nonBlankRest = B.any (not . isSpaceOrTab) (B.drop after ln)
       in if not okSpace
            then Nothing
            else
              if interrupts && (not nonBlankRest || (ordered && start /= 1))
                then Nothing
                else Just (ordered, delim, start, w)

-- | Does the rest of the line from the position close a fence of the given
-- character and minimum length?
closesFence :: ByteString -> Int -> Word8 -> Int -> Bool
closesFence ln p c len =
  let rest = B.drop p ln
      run = B.length (B.takeWhile (== c) rest)
   in run >= len && B.all isSpaceOrTab (B.drop run rest)

-- | Remove an optional closing sequence from the content of an ATX heading.
chopTrailingHashes :: ByteString -> ByteString
chopTrailingHashes s0 =
  let s = B.dropWhileEnd isSpaceW s0
      n = B.length s
   in if n == 0 || BU.unsafeIndex s (n - 1) /= 35
        then s
        else
          let body = B.dropWhileEnd (== 35) s
              m = B.length body
           in if m == 0
                then B.empty
                else
                  if isSpaceOrTab (BU.unsafeIndex body (m - 1))
                    then B.dropWhileEnd isSpaceW body
                    else s

-- ---------------------------------------------------------------------------
-- Parser

data P s = P
  { pRoot :: Node s
  , pTip :: STRef s (Node s)
  }

-- | Parse the block structure of a document.  Paragraph and heading content
-- is returned as raw text (the lines joined with newlines); see
-- 'Commonmark.Inline.parseInlines'.
--
-- The input is the whole document as UTF-8 with LF line endings.
parseBlocks :: ByteString -> [Block ByteString]
parseBlocks input = runST $ do
  root <- newNode Nothing KDoc 0
  tip <- newSTRef root
  let p = P root tip
  forM_ (zip [1 ..] (BC.lines input)) $ \(i, ln) -> processLine p i ln
  closeAll p
  kids <- reverse <$> readSTRef (nChildren root)
  concat <$> mapM convert kids

closeAll :: P s -> ST s ()
closeAll p = do
  t <- readSTRef (pTip p)
  let go n
        | n == pRoot p = () <$ finalize n
        | otherwise = finalize n >>= go
  go t

-- | Close a block, returning its parent (or itself for the document).
finalize :: Node s -> ST s (Node s)
finalize n = do
  setFlag n fOpen False
  k <- readSTRef (nKind n)
  case k of
    KList {} -> do
      t <- listIsTight n
      setFlag n fTight t
    _ -> return ()
  return (maybe n id (nParent n))

-- | The tight/loose test of cmark, memoisation included.
listIsTight :: Node s -> ST s Bool
listIsTight list = do
  items <- reverse <$> readSTRef (nChildren list)
  goItems items
  where
    goItems [] = return True
    goItems (it : rest) = do
      blank <- getFlag it fLastBlank
      if blank && not (null rest)
        then return False
        else do
          kids <- reverse <$> readSTRef (nChildren it)
          ok <- goKids (not (null rest)) kids
          if ok then goItems rest else return False
    goKids _ [] = return True
    goKids hasNext (c : cs)
      | hasNext || not (null cs) = do
          b <- endsWithBlank c
          if b then return False else goKids hasNext cs
      | otherwise = goKids hasNext cs

endsWithBlank :: Node s -> ST s Bool
endsWithBlank n = do
  checked <- getFlag n fChecked
  if checked
    then getFlag n fLastBlank
    else do
      setFlag n fChecked True
      k <- readSTRef (nKind n)
      kids <- readSTRef (nChildren n)
      case (k, kids) of
        (KList {}, lastChild : _) -> endsWithBlank lastChild
        (KItem {}, lastChild : _) -> endsWithBlank lastChild
        _ -> getFlag n fLastBlank

addChild :: Node s -> Kind -> Int -> ST s (Node s)
addChild parent kind line = do
  pk <- readSTRef (nKind parent)
  if canContain pk kind
    then do
      child <- newNode (Just parent) kind line
      modifySTRef' (nChildren parent) (child :)
      return child
    else do
      up <- finalize parent
      addChild up kind line

data Step1 s
  = FenceClosed
  | Matched (Node s) Cur

-- | Process one line.
processLine :: P s -> Int -> ByteString -> ST s ()
processLine p lineNo ln = do
  tip0 <- readSTRef (pTip p)
  tipKind0 <- readSTRef (nKind tip0)
  r <- continueOpen p ln
  case r of
    FenceClosed -> return ()
    Matched lastMatched cur1 -> do
      (container, cur2) <- openNew ln lineNo lastMatched cur1 (isParaKind tipKind0)
      addText p ln lineNo tip0 lastMatched container cur2

-- | Step 1: walk down the chain of open blocks, matching continuation lines.
continueOpen :: P s -> ByteString -> ST s (Step1 s)
continueOpen p ln = go (pRoot p) (Cur 0 0 False)
  where
    len = B.length ln
    go container cur = do
      kids <- readSTRef (nChildren container)
      case kids of
        [] -> return (Matched container cur)
        (c : _) -> do
          open <- getFlag c fOpen
          if not open
            then return (Matched container cur)
            else do
              k <- readSTRef (nKind c)
              let (nnOff, nnCol) = findNonspace ln cur
                  indent = nnCol - cCol cur
                  blank = nnOff >= len
              case k of
                KQuote
                  | indent <= 3 && peekAt ln nnOff == 62 ->
                      let cur1 = advanceChars ln cur (nnOff + 1 - cOff cur)
                          cur2 =
                            if isSpaceOrTab (peekAt ln (cOff cur1)) then advanceCols ln cur1 1 else cur1
                       in go c cur2
                  | otherwise -> return (Matched container cur)
                KItem m pad
                  | indent >= m + pad -> go c (advanceCols ln cur (m + pad))
                  | blank -> do
                      has <- not . null <$> readSTRef (nChildren c)
                      if has
                        then go c (advanceChars ln cur (nnOff - cOff cur))
                        else return (Matched container cur)
                  | otherwise -> return (Matched container cur)
                KList {} -> go c cur
                KIndented
                  | indent >= 4 -> go c (advanceCols ln cur 4)
                  | blank -> go c (advanceChars ln cur (nnOff - cOff cur))
                  | otherwise -> return (Matched container cur)
                KFenced fc fl fo
                  | indent <= 3 && peekAt ln nnOff == fc && closesFence ln nnOff fc fl -> do
                      parent <- finalize c
                      writeSTRef (pTip p) parent
                      return FenceClosed
                  | otherwise ->
                      let eat !i cu
                            | i > 0 && isSpaceOrTab (peekAt ln (cOff cu)) = eat (i - 1 :: Int) (advanceCols ln cu 1)
                            | otherwise = cu
                       in go c (eat fo cur)
                KHeading _ -> return (Matched container cur)
                KThematic -> go c cur
                KPara
                  | blank -> return (Matched container cur)
                  | otherwise -> go c cur
                KDoc -> return (Matched container cur)

-- | Step 2: open new blocks.
openNew :: ByteString -> Int -> Node s -> Cur -> Bool -> ST s (Node s, Cur)
openNew ln lineNo = loop
  where
    len = B.length ln
    loop container cur maybeLazy = do
      kind <- readSTRef (nKind container)
      if isCodeKind kind
        then return (container, cur)
        else do
          let (nnOff, nnCol) = findNonspace ln cur
              indent = nnCol - cCol cur
              c = peekAt ln nnOff
              indented = indent >= 4
              blank = nnOff >= len
              toEnd = advanceChars ln cur (len - cOff cur)
          case () of
            _
              | not indented && c == 62 -> do
                  let cur1 = advanceChars ln cur (nnOff + 1 - cOff cur)
                      cur2 = if isSpaceOrTab (peekAt ln (cOff cur1)) then advanceCols ln cur1 1 else cur1
                  child <- addChild container KQuote lineNo
                  loop child cur2 False
              | not indented, Just (lvl, endOff) <- atxStart ln nnOff -> do
                  child <- addChild container (KHeading lvl) lineNo
                  return (child, advanceChars ln cur (endOff - cOff cur))
              | not indented, Just (fc, run) <- fenceStart ln nnOff -> do
                  child <- addChild container (KFenced fc run (nnOff - cOff cur)) lineNo
                  return (child, advanceChars ln cur (nnOff + run - cOff cur))
              | not indented, isParaKind kind, Just lvl <- setextLevel ln nnOff -> do
                  writeSTRef (nKind container) (KHeading lvl)
                  return (container, toEnd)
              | not indented, isThematic ln nnOff -> do
                  child <- addChild container KThematic lineNo
                  return (child, toEnd)
              | indent < 4, Just (ordered, delim, start, w) <- listMarker ln nnOff (isParaKind kind) -> do
                  let cur1 = advanceChars ln cur (nnOff + w - cOff cur)
                      saveCol = cCol cur1
                      skip cu
                        | cCol cu - saveCol <= 5 && isSpaceOrTab (peekAt ln (cOff cu)) = skip (advanceCols ln cu 1)
                        | otherwise = cu
                      cur2 = skip cur1
                      i = cCol cur2 - saveCol
                      (padding, cur3)
                        | i >= 5 || i < 1 || cOff cur2 >= len = (w + 1, if i > 0 then advanceCols ln cur1 1 else cur1)
                        | otherwise = (w + i, cur2)
                  list <- case kind of
                    KList o d _ | o == ordered && d == delim -> return container
                    _ -> addChild container (KList ordered delim start) lineNo
                  item <- addChild list (KItem indent padding) lineNo
                  loop item cur3 False
              | indented && not blank && not maybeLazy -> do
                  child <- addChild container KIndented lineNo
                  return (child, advanceCols ln cur 4)
              | otherwise -> return (container, cur)

-- | Step 3: add the text of the line to the appropriate container.
addText :: P s -> ByteString -> Int -> Node s -> Node s -> Node s -> Cur -> ST s ()
addText p ln lineNo tip0 lastMatched container cur = do
  let (nnOff, _) = findNonspace ln cur
      blank = nnOff >= B.length ln
  kind <- readSTRef (nKind container)
  kids <- readSTRef (nChildren container)
  when blank $ case kids of
    (k : _) -> setFlag k fLastBlank True
    [] -> return ()
  let notCounted = case kind of
        KQuote -> True
        KHeading _ -> True
        KThematic -> True
        KFenced {} -> True
        KItem {} -> null kids && nStartLine container == lineNo
        _ -> False
  setFlag container fLastBlank (blank && not notCounted)
  let clearUp n = case nParent n of
        Nothing -> return ()
        Just par -> setFlag par fLastBlank False >> clearUp par
  clearUp container
  tipKind <- readSTRef (nKind tip0)
  if tip0 /= lastMatched && container == lastMatched && not blank && isParaKind tipKind
    then appendLine tip0 (restOf ln cur) -- lazy continuation
    else do
      closeBelow tip0
      final <-
        if isCodeKind kind
          then appendLine container (restOf ln cur) >> return container
          else
            if blank
              then return container
              else case kind of
                KPara -> appendLine container (B.drop nnOff ln) >> return container
                KHeading _ -> do
                  modifySTRef' (nContent container) (chopTrailingHashes (B.drop nnOff ln) :)
                  return container
                _ -> do
                  para <- addChild container KPara lineNo
                  appendLine para (B.drop nnOff ln)
                  return para
      writeSTRef (pTip p) final
  where
    closeBelow n
      | n == lastMatched = return ()
      | otherwise = do
          par <- finalize n
          if par == n then return () else closeBelow par

-- ---------------------------------------------------------------------------
-- Freezing the tree

convert :: Node s -> ST s [Block ByteString]
convert node = do
  k <- readSTRef (nKind node)
  kids <- reverse <$> readSTRef (nChildren node)
  case k of
    KDoc -> concat <$> mapM convert kids
    KQuote -> (\bs -> [BlockQuote (concat bs)]) <$> mapM convert kids
    KList ordered _ start -> do
      tight <- getFlag node fTight
      items <- forM kids $ \it -> do
        ics <- reverse <$> readSTRef (nChildren it)
        concat <$> mapM convert ics
      return [List (if ordered then OrderedList start else BulletList) tight items]
    KItem {} -> concat <$> mapM convert kids
    KPara -> (\c -> [Paragraph c]) <$> content
    KHeading l -> (\c -> [Heading l c]) <$> content
    KThematic -> return [ThematicBreak]
    KIndented -> do
      c <- content
      return [CodeBlock B.empty (trimIndented c)]
    KFenced {} -> do
      c <- content
      let (infoLine, rest) = B.break (== 10) c
          info = unescapeBackslashes (trimWs (decodeEntities infoLine))
      return [CodeBlock info (B.drop 1 rest)]
  where
    content = B.concat . reverse <$> readSTRef (nContent node)

-- | Remove trailing blank lines from the content of an indented code block.
trimIndented :: ByteString -> ByteString
trimIndented s =
  let isBlankW w = w == 32 || w == 9 || w == 10
      end = B.length (B.dropWhileEnd isBlankW s)
      tailPart = B.drop end s
      cut = maybe (B.length tailPart) id (B.elemIndex 10 tailPart)
   in B.snoc (B.take (end + cut) s) 10
