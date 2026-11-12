{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Phase 1 of the Markdown conversion: the line-driven block parser.
--
-- This follows the algorithm of the reference implementation (cmark): each
-- line is matched against the chain of open blocks, new blocks are opened,
-- and the remainder of the line is added to the innermost open leaf block.
-- The tree is mutable while it is being built (inside 'ST') and is frozen
-- into the pure 'Block' type at the end.
module Sitegen.Markdown.Block
  ( parseBlocks
  ) where

import Control.Monad (forM, unless, when)
import Control.Monad.ST (ST, runST)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.STRef
import Data.Text (Text)
import qualified Data.Text as T

import Sitegen.Markdown.Escape (decodeEntities, isMdSpace, unescapeBackslashes)
import Sitegen.Markdown.Types

-- ---------------------------------------------------------------------------
-- Mutable tree

data ListData = ListData
  { ldOrdered :: !Bool
  , ldDelim :: !Char
  , ldStart :: !Int
  , ldMarkerOffset :: !Int
  , ldPadding :: !Int
  }

data Kind
  = KDoc
  | KQuote
  | KList !ListData
  | KItem !ListData
  | KPara
  | KHeading !Int !Bool
  | KFenced !Char !Int !Int
  | KIndented
  | KRule

data Node s = Node
  { nId :: !Int
  , nParent :: !(Maybe (Node s))
  , nStartLine :: !Int
  , nKind :: !(STRef s Kind)
  , nChildren :: !(STRef s [Node s]) -- ^ reversed
  , nOpen :: !(STRef s Bool)
  , nLastBlank :: !(STRef s Bool)
  , nChecked :: !(STRef s Bool)
  , nContent :: !(STRef s [Text]) -- ^ reversed chunks
  , nInfo :: !(STRef s Text)
  , nTight :: !(STRef s Bool)
  }

same :: Node s -> Node s -> Bool
same a b = nId a == nId b

data P s = P
  { pRoot :: !(Node s)
  , pCur :: !(STRef s (Node s))
  , pLine :: !(STRef s Int)
  , pCounter :: !(STRef s Int)
  }

newNode' :: P s -> Maybe (Node s) -> Kind -> ST s (Node s)
newNode' p = newNode (pCounter p) (pLine p)

newNode :: STRef s Int -> STRef s Int -> Maybe (Node s) -> Kind -> ST s (Node s)
newNode counter line parent kind = do
  i <- readSTRef counter
  writeSTRef counter (i + 1)
  ln <- readSTRef line
  Node i parent ln
    <$> newSTRef kind
    <*> newSTRef []
    <*> newSTRef True
    <*> newSTRef False
    <*> newSTRef False
    <*> newSTRef []
    <*> newSTRef T.empty
    <*> newSTRef False

-- ---------------------------------------------------------------------------
-- Line cursor

data Ln s = Ln
  { lArr :: !(UArray Int Char)
  , lLen :: !Int
  , lOff :: !(STRef s Int)
  , lCol :: !(STRef s Int)
  , lFns :: !(STRef s Int)
  , lFnsCol :: !(STRef s Int)
  , lPct :: !(STRef s Bool)
  , lBlank :: !(STRef s Bool)
  }

peekAt :: Ln s -> Int -> Char
peekAt l i
  | i >= 0 && i < lLen l = lArr l ! i
  | otherwise = '\n'

isSpTab :: Char -> Bool
isSpTab c = c == ' ' || c == '\t'

findFirstNonspace :: Ln s -> ST s ()
findFirstNonspace l = do
  off <- readSTRef (lOff l)
  col <- readSTRef (lCol l)
  let go !i !c = case peekAt l i of
        ' ' -> go (i + 1) (c + 1)
        '\t' -> go (i + 1) (c + 4 - c `mod` 4)
        ch -> (i, c, ch)
      (i', c', ch') = go off col
  writeSTRef (lFns l) i'
  writeSTRef (lFnsCol l) c'
  writeSTRef (lBlank l) (ch' == '\n')

getIndent :: Ln s -> ST s Int
getIndent l = (-) <$> readSTRef (lFnsCol l) <*> readSTRef (lCol l)

advanceOffset :: Ln s -> Int -> Bool -> ST s ()
advanceOffset l = go
  where
    go !count !columns
      | count <= 0 = pure ()
      | otherwise = do
          off <- readSTRef (lOff l)
          if off >= lLen l
            then pure ()
            else do
              col <- readSTRef (lCol l)
              if peekAt l off == '\t'
                then do
                  let toTab = 4 - col `mod` 4
                  if columns
                    then do
                      let part = toTab > count
                          adv = min count toTab
                      writeSTRef (lPct l) part
                      writeSTRef (lCol l) (col + adv)
                      unless part (writeSTRef (lOff l) (off + 1))
                      go (count - adv) columns
                    else do
                      writeSTRef (lPct l) False
                      writeSTRef (lCol l) (col + toTab)
                      writeSTRef (lOff l) (off + 1)
                      go (count - 1) columns
                else do
                  writeSTRef (lPct l) False
                  writeSTRef (lOff l) (off + 1)
                  writeSTRef (lCol l) (col + 1)
                  go (count - 1) columns

slice :: Ln s -> Int -> Int -> Text
slice l i j = T.pack [lArr l ! k | k <- [max 0 i .. min (lLen l) j - 1]]

-- | Append the rest of the line (plus a newline) to a node's content.
addLine :: Ln s -> Node s -> ST s ()
addLine l node = do
  pct <- readSTRef (lPct l)
  off <- readSTRef (lOff l)
  col <- readSTRef (lCol l)
  let (prefix, off')
        | pct = (T.replicate (4 - col `mod` 4) " ", off + 1)
        | otherwise = (T.empty, off)
  modifySTRef' (nContent node) (T.concat [prefix, slice l off' (lLen l), "\n"] :)

-- ---------------------------------------------------------------------------
-- Tree helpers

lastChild :: Node s -> ST s (Maybe (Node s))
lastChild n = do
  cs <- readSTRef (nChildren n)
  pure $ case cs of
    [] -> Nothing
    (c : _) -> Just c

lastChildIfOpen :: Node s -> ST s (Maybe (Node s))
lastChildIfOpen n = do
  mc <- lastChild n
  case mc of
    Nothing -> pure Nothing
    Just c -> do
      o <- readSTRef (nOpen c)
      pure (if o then Just c else Nothing)

canContain :: Kind -> Kind -> Bool
canContain parent child = case parent of
  KDoc -> notItem
  KQuote -> notItem
  KItem _ -> notItem
  KList _ -> isItem
  _ -> False
  where
    notItem = not isItem
    isItem = case child of KItem _ -> True; _ -> False

acceptsLines :: Kind -> Bool
acceptsLines k = case k of
  KPara -> True
  KHeading _ _ -> True
  KFenced {} -> True
  KIndented -> True
  _ -> False

isCodeKind :: Kind -> Bool
isCodeKind k = case k of
  KFenced {} -> True
  KIndented -> True
  _ -> False

addChild :: P s -> Node s -> Kind -> ST s (Node s)
addChild p parent kind = do
  pk <- readSTRef (nKind parent)
  if canContain pk kind
    then do
      child <- newNode' p (Just parent) kind
      modifySTRef' (nChildren parent) (child :)
      pure child
    else do
      mp <- finalize p parent
      case mp of
        Just up -> addChild p up kind
        Nothing -> addChild p (pRoot p) kind

-- | Close a block, computing whatever depends on its complete contents.
-- Returns the parent.
finalize :: P s -> Node s -> ST s (Maybe (Node s))
finalize _ b = do
  open <- readSTRef (nOpen b)
  when open $ do
    writeSTRef (nOpen b) False
    k <- readSTRef (nKind b)
    case k of
      KIndented -> do
        content <- T.concat . reverse <$> readSTRef (nContent b)
        writeSTRef (nContent b) [removeTrailingBlankLines content <> "\n"]
      KFenced {} -> do
        content <- T.concat . reverse <$> readSTRef (nContent b)
        let (firstLine, rest) = T.break (== '\n') content
            info = unescapeBackslashes (T.dropAround isMdSpace (decodeEntities firstLine))
        writeSTRef (nInfo b) info
        writeSTRef (nContent b) [T.drop 1 rest]
      KList _ -> do
        items <- reverse <$> readSTRef (nChildren b)
        t <- listIsTight items
        writeSTRef (nTight b) t
      _ -> pure ()
  pure (nParent b)

removeTrailingBlankLines :: Text -> Text
removeTrailingBlankLines t =
  let kept = T.dropWhileEnd (\c -> c == ' ' || c == '\t' || c == '\n') t
      remainder = T.drop (T.length kept) t
   in if T.null kept then T.empty else kept <> T.takeWhile (/= '\n') remainder

-- | cmark's tightness test, including its memoisation of the
-- "ends with a blank line" check.
listIsTight :: [Node s] -> ST s Bool
listIsTight = goItems
  where
    goItems [] = pure True
    goItems (item : rest) = do
      lb <- readSTRef (nLastBlank item)
      if lb && not (null rest)
        then pure False
        else do
          subs <- reverse <$> readSTRef (nChildren item)
          ok <- goSubs (not (null rest)) subs
          if ok then goItems rest else pure False
    goSubs _ [] = pure True
    goSubs itemHasNext (s : ss) = do
      let hasNext = not (null ss)
      bad <- if itemHasNext || hasNext then endsWithBlank s else pure False
      if bad then pure False else goSubs itemHasNext ss

endsWithBlank :: Node s -> ST s Bool
endsWithBlank n = do
  checked <- readSTRef (nChecked n)
  if checked
    then readSTRef (nLastBlank n)
    else do
      writeSTRef (nChecked n) True
      k <- readSTRef (nKind n)
      case k of
        KList _ -> descend
        KItem _ -> descend
        _ -> readSTRef (nLastBlank n)
  where
    descend = lastChild n >>= maybe (readSTRef (nLastBlank n)) endsWithBlank

-- ---------------------------------------------------------------------------
-- Line processing

-- | Parse a document into its block structure.
parseBlocks :: Text -> [Block]
parseBlocks input = runST $ do
  lineRef <- newSTRef 0
  counter <- newSTRef 0
  root <- newNode counter lineRef Nothing KDoc
  cur <- newSTRef root
  let p = P root cur lineRef counter
  mapM_ (processLine p) (T.lines input)
  closeAll p
  freezeChildren root

closeAll :: P s -> ST s ()
closeAll p = do
  cur <- readSTRef (pCur p)
  unless (same cur (pRoot p)) $ do
    mp <- finalize p cur
    writeSTRef (pCur p) (maybe (pRoot p) id mp)
    closeAll p
  _ <- finalize p (pRoot p)
  pure ()

processLine :: P s -> Text -> ST s ()
processLine p lineText = do
  modifySTRef' (pLine p) (+ 1)
  let n = T.length lineText
      arr = listArray (0, n - 1) (T.unpack lineText) :: UArray Int Char
  ln <- Ln arr n <$> newSTRef 0 <*> newSTRef 0 <*> newSTRef 0 <*> newSTRef 0
                 <*> newSTRef False <*> newSTRef False
  res <- checkOpenBlocks p ln
  case res of
    Nothing -> pure ()
    Just (lastMatched, allMatched) -> do
      container <- openNewBlocks p ln lastMatched
      addTextToContainer p ln container lastMatched allMatched

-- | Step 1: walk the chain of open blocks. Returns the last matched block and
-- whether every open block matched, or 'Nothing' if the line closed a fenced
-- code block and is fully consumed.
checkOpenBlocks :: P s -> Ln s -> ST s (Maybe (Node s, Bool))
checkOpenBlocks p ln = go (pRoot p)
  where
    go container = do
      mc <- lastChildIfOpen container
      case mc of
        Nothing -> pure (Just (container, True))
        Just child -> do
          findFirstNonspace ln
          k <- readSTRef (nKind child)
          indent <- getIndent ln
          blank <- readSTRef (lBlank ln)
          fns <- readSTRef (lFns ln)
          off <- readSTRef (lOff ln)
          let failed = pure (Just (container, False))
              continue = go child
          case k of
            KQuote
              | indent <= 3 && peekAt ln fns == '>' -> do
                  advanceOffset ln (fns + 1 - off) False
                  off' <- readSTRef (lOff ln)
                  when (isSpTab (peekAt ln off')) $ advanceOffset ln 1 True
                  continue
              | otherwise -> failed
            KItem ld
              | indent >= ldMarkerOffset ld + ldPadding ld -> do
                  advanceOffset ln (ldMarkerOffset ld + ldPadding ld) True
                  continue
              | blank -> do
                  hasKids <- not . null <$> readSTRef (nChildren child)
                  if hasKids
                    then advanceOffset ln (fns - off) False >> continue
                    else failed
              | otherwise -> failed
            KIndented
              | indent >= 4 -> advanceOffset ln 4 True >> continue
              | blank -> advanceOffset ln (fns - off) False >> continue
              | otherwise -> failed
            KFenced ch len foff -> do
              let matched
                    | indent <= 3 && peekAt ln fns == ch = scanCloseFence ln fns ch
                    | otherwise = 0
              if matched >= len
                then do
                  _ <- finalize p child
                  writeSTRef (pCur p) container
                  pure Nothing
                else do
                  let skip i = when (i > 0) $ do
                        o <- readSTRef (lOff ln)
                        when (isSpTab (peekAt ln o)) $ do
                          advanceOffset ln 1 True
                          skip (i - 1 :: Int)
                  skip foff
                  continue
            KHeading _ _ -> failed
            KPara
              | blank -> failed
              | otherwise -> continue
            _ -> continue

-- | Length of the closing fence run starting at @i@, or 0.
scanCloseFence :: Ln s -> Int -> Char -> Int
scanCloseFence ln i ch =
  let run = length (takeWhile (== ch) [peekAt ln k | k <- [i .. lLen ln - 1]])
      rest = [peekAt ln k | k <- [i + run .. lLen ln - 1]]
   in if run >= 3 && all isSpTab rest then run else 0

firstJustM :: [ST s (Maybe a)] -> ST s (Maybe a)
firstJustM [] = pure Nothing
firstJustM (m : ms) = do
  r <- m
  case r of
    Just _ -> pure r
    Nothing -> firstJustM ms

-- | Step 2: start new blocks.
openNewBlocks :: P s -> Ln s -> Node s -> ST s (Node s)
openNewBlocks p ln container0 = do
  cur <- readSTRef (pCur p)
  curKind <- readSTRef (nKind cur)
  let lazyStart = case curKind of KPara -> True; _ -> False
  loop container0 lazyStart
  where
    loop container maybeLazy = do
      ck <- readSTRef (nKind container)
      if isCodeKind ck
        then pure container
        else do
          findFirstNonspace ln
          indent <- getIndent ln
          fns <- readSTRef (lFns ln)
          blank <- readSTRef (lBlank ln)
          off <- readSTRef (lOff ln)
          let indented = indent >= 4
              c = peekAt ln fns
              isPara = case ck of KPara -> True; _ -> False
              tryQuote
                | not indented && c == '>' = do
                    advanceOffset ln (fns + 1 - off) False
                    off' <- readSTRef (lOff ln)
                    when (isSpTab (peekAt ln off')) $ advanceOffset ln 1 True
                    Just <$> addChild p container KQuote
                | otherwise = pure Nothing
              tryAtx
                | not indented && c == '#' = case scanAtxStart ln fns of
                    Just (level, matched) -> do
                      advanceOffset ln (fns + matched - off) False
                      Just <$> addChild p container (KHeading level False)
                    Nothing -> pure Nothing
                | otherwise = pure Nothing
              tryFence
                | not indented && (c == '`' || c == '~') = case scanOpenFence ln fns c of
                    Just run -> do
                      advanceOffset ln (fns + run - off) False
                      Just <$> addChild p container (KFenced c run (fns - off))
                    Nothing -> pure Nothing
                | otherwise = pure Nothing
              trySetext
                | not indented && isPara = case scanSetext ln fns of
                    Just lev -> do
                      writeSTRef (nKind container) (KHeading lev True)
                      advanceOffset ln (lLen ln - off) False
                      pure (Just container)
                    Nothing -> pure Nothing
                | otherwise = pure Nothing
              tryRule
                | not indented && scanThematicBreak ln fns =
                    do
                      node <- addChild p container KRule
                      advanceOffset ln (lLen ln - off) False
                      pure (Just node)
                | otherwise = pure Nothing
              tryItem
                | indent < 4 = case parseListMarker ln fns isPara of
                    Just (matched, ordered, delim, start) -> Just <$> openItem container indent fns off matched ordered delim start
                    Nothing -> pure Nothing
                | otherwise = pure Nothing
              tryIndented
                | indented && not maybeLazy && not blank = do
                    advanceOffset ln 4 True
                    Just <$> addChild p container KIndented
                | otherwise = pure Nothing
          r <- firstJustM [tryQuote, tryAtx, tryFence, trySetext, tryRule, tryItem, tryIndented]
          case r of
            Nothing -> pure container
            Just c' -> do
              k' <- readSTRef (nKind c')
              if acceptsLines k' then pure c' else loop c' False

    openItem container indent fns off matched ordered delim start = do
      advanceOffset ln (fns + matched - off) False
      saveOff <- readSTRef (lOff ln)
      saveCol <- readSTRef (lCol ln)
      savePct <- readSTRef (lPct ln)
      let spaces = do
            col <- readSTRef (lCol ln)
            o <- readSTRef (lOff ln)
            when (col - saveCol <= 5 && isSpTab (peekAt ln o)) $ do
              advanceOffset ln 1 True
              spaces
      spaces
      col <- readSTRef (lCol ln)
      o <- readSTRef (lOff ln)
      let i = col - saveCol
      padding <-
        if i >= 5 || i < 1 || o >= lLen ln
          then do
            writeSTRef (lOff ln) saveOff
            writeSTRef (lCol ln) saveCol
            writeSTRef (lPct ln) savePct
            when (i > 0) $ advanceOffset ln 1 True
            pure (matched + 1)
          else pure (matched + i)
      let ld = ListData ordered delim start indent padding
      ck <- readSTRef (nKind container)
      listNode <- case ck of
        KList old | ldOrdered old == ordered && ldDelim old == delim -> pure container
        _ -> addChild p container (KList ld)
      addChild p listNode (KItem ld)

scanAtxStart :: Ln s -> Int -> Maybe (Int, Int)
scanAtxStart ln i =
  let hashes = length (takeWhile (== '#') [peekAt ln k | k <- [i .. min (lLen ln - 1) (i + 6)]])
      after = i + hashes
      ws = length (takeWhile isSpTab [peekAt ln k | k <- [after .. lLen ln - 1]])
   in if hashes >= 1 && hashes <= 6 && (ws > 0 || after >= lLen ln)
        then Just (hashes, hashes + ws)
        else Nothing

scanOpenFence :: Ln s -> Int -> Char -> Maybe Int
scanOpenFence ln i c =
  let run = length (takeWhile (== c) [peekAt ln k | k <- [i .. lLen ln - 1]])
      rest = [peekAt ln k | k <- [i + run .. lLen ln - 1]]
   in if run >= 3 && (c == '~' || '`' `notElem` rest) then Just run else Nothing

scanSetext :: Ln s -> Int -> Maybe Int
scanSetext ln i =
  let c = peekAt ln i
      run = length (takeWhile (== c) [peekAt ln k | k <- [i .. lLen ln - 1]])
      rest = [peekAt ln k | k <- [i + run .. lLen ln - 1]]
   in if (c == '=' || c == '-') && run >= 1 && all isSpTab rest
        then Just (if c == '=' then 1 else 2)
        else Nothing

scanThematicBreak :: Ln s -> Int -> Bool
scanThematicBreak ln i =
  let c = peekAt ln i
      chars = [peekAt ln k | k <- [i .. lLen ln - 1]]
   in (c == '*' || c == '_' || c == '-')
        && all (\x -> x == c || isSpTab x) chars
        && length (filter (== c) chars) >= 3

-- | Recognise a list marker at @pos@. Returns the marker width, whether it is
-- ordered, its delimiter (bullet char or @.@/@)@) and its start number.
parseListMarker :: Ln s -> Int -> Bool -> Maybe (Int, Bool, Char, Int)
parseListMarker ln pos interrupts =
  let c = peekAt ln pos
      isWs x = x == ' ' || x == '\t' || x == '\n'
      restBlank q = all isSpTab [peekAt ln k | k <- [q .. lLen ln - 1]]
   in if c == '*' || c == '-' || c == '+'
        then
          let q = pos + 1
           in if isWs (peekAt ln q) && not (interrupts && restBlank q)
                then Just (1, False, c, 0)
                else Nothing
        else
          if c >= '0' && c <= '9'
            then
              let digits = takeWhile isDig (take 9 [peekAt ln k | k <- [pos .. lLen ln - 1]])
                  nd = length digits
                  q = pos + nd
                  d = peekAt ln q
                  start = foldl (\a x -> a * 10 + (fromEnum x - 48)) 0 digits
               in if (d == '.' || d == ')') && isWs (peekAt ln (q + 1))
                    && not (interrupts && (start /= 1 || restBlank (q + 1)))
                    then Just (nd + 1, True, d, start)
                    else Nothing
            else Nothing
  where
    isDig x = x >= '0' && x <= '9'

-- | Step 3: add the text of the line to the proper container.
addTextToContainer :: P s -> Ln s -> Node s -> Node s -> Bool -> ST s ()
addTextToContainer p ln container lastMatched allMatched = do
  findFirstNonspace ln
  blank <- readSTRef (lBlank ln)
  mlast <- lastChild container
  when blank $ maybe (pure ()) (\c -> writeSTRef (nLastBlank c) True) mlast
  ck <- readSTRef (nKind container)
  hasKids <- not . null <$> readSTRef (nChildren container)
  curLine <- readSTRef (pLine p)
  let lastLineBlank =
        blank && case ck of
          KQuote -> False
          KHeading _ _ -> False
          KRule -> False
          KFenced {} -> False
          KItem _ -> not (not hasKids && nStartLine container == curLine)
          _ -> True
  writeSTRef (nLastBlank container) lastLineBlank
  let clearUp n = case nParent n of
        Nothing -> pure ()
        Just par -> writeSTRef (nLastBlank par) False >> clearUp par
  clearUp container
  cur <- readSTRef (pCur p)
  curKind <- readSTRef (nKind cur)
  let curIsPara = case curKind of KPara -> True; _ -> False
      lazy = not allMatched && same container lastMatched && not blank && curIsPara
  if lazy
    then addLine ln cur
    else do
      let closeDown = do
            c <- readSTRef (pCur p)
            unless (same c lastMatched) $ do
              mp <- finalize p c
              writeSTRef (pCur p) (maybe (pRoot p) id mp)
              closeDown
      closeDown
      node <-
        case ck of
          KFenced {} -> addLine ln container >> pure container
          KIndented -> addLine ln container >> pure container
          _
            | blank -> pure container
            | otherwise -> case ck of
                KHeading _ False -> do
                  off <- readSTRef (lOff ln)
                  let chopped = chopTrailingHashtags ln
                  modifySTRef' (nContent container) (slice' ln off chopped :)
                  pure container
                KHeading _ True -> pure container
                KPara -> do
                  skipToNonspace
                  addLine ln container
                  pure container
                _ -> do
                  para <- addChild p container KPara
                  skipToNonspace
                  addLine ln para
                  pure para
      writeSTRef (pCur p) node
  where
    skipToNonspace = do
      fns <- readSTRef (lFns ln)
      off <- readSTRef (lOff ln)
      advanceOffset ln (fns - off) False
    slice' l i j = slice l i j

-- | The length of the line after removing trailing whitespace and an ATX
-- closing sequence (a run of @#@ preceded by a space or tab).
chopTrailingHashtags :: Ln s -> Int
chopTrailingHashtags ln =
  let rtrim n = if n > 0 && isMdSpace (lArr ln ! (n - 1)) then rtrim (n - 1) else n
      len1 = rtrim (lLen ln)
      back n = if n >= 0 && lArr ln ! n == '#' then back (n - 1) else n
      n' = back (len1 - 1)
   in if len1 > 0 && n' /= len1 - 1 && n' >= 0 && isSpTab (lArr ln ! n')
        then rtrim n'
        else len1

-- ---------------------------------------------------------------------------
-- Freezing

freezeChildren :: Node s -> ST s [Block]
freezeChildren n = do
  cs <- reverse <$> readSTRef (nChildren n)
  concat <$> forM cs (fmap (maybe [] pure) . freeze)

freeze :: Node s -> ST s (Maybe Block)
freeze n = do
  k <- readSTRef (nKind n)
  content <- T.concat . reverse <$> readSTRef (nContent n)
  case k of
    KDoc -> pure Nothing
    KQuote -> Just . BQuote <$> freezeChildren n
    KList ld -> do
      tight <- readSTRef (nTight n)
      items <- reverse <$> readSTRef (nChildren n)
      bodies <- forM items freezeChildren
      let ty = if ldOrdered ld then OrderedList (ldStart ld) else BulletList
      pure (Just (BList ty tight bodies))
    KItem _ -> Just . BQuote <$> freezeChildren n -- unreachable: items live in lists
    KPara -> pure (Just (BParagraph content))
    KHeading lev _ -> pure (Just (BHeading lev content))
    KFenced {} -> do
      info <- readSTRef (nInfo n)
      pure (Just (BCode info content))
    KIndented -> pure (Just (BCode T.empty content))
    KRule -> pure (Just BThematicBreak)

