{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Phase 2 of the Markdown conversion: parsing the raw content of a
-- paragraph or heading into inline elements.
--
-- Mirrors cmark: a left-to-right scan with a delimiter stack for emphasis and
-- a bracket stack for links and images. Nodes live in a mutable doubly linked
-- list so that wrapping and removal cost O(1) per node moved.
module Sitegen.Markdown.Inline
  ( parseInlines
  ) where

import Control.Monad (unless, when)
import Control.Monad.ST (ST, runST)
import Data.Array.ST (STUArray, newArray, readArray, writeArray)
import Data.Array.Unboxed (UArray, listArray, (!))
import qualified Data.IntMap.Strict as IM
import Data.STRef
import Data.Text (Text)
import qualified Data.Text as T

import Sitegen.Markdown.Escape
import Sitegen.Markdown.Types

-- ---------------------------------------------------------------------------
-- Mutable inline nodes

data IKind
  = IText !Text
  | ISoft
  | IHard
  | ICode !Text
  | IEmph
  | IStrong
  | ILink !Text !(Maybe Text)
  | IImage !Text !(Maybe Text)

data INode s = INode
  { inId :: !Int
  , inKind :: !(STRef s IKind)
  , inPrev :: !(STRef s (Maybe (INode s)))
  , inNext :: !(STRef s (Maybe (INode s)))
  , inFirst :: !(STRef s (Maybe (INode s)))
  , inLast :: !(STRef s (Maybe (INode s)))
  }

data Delim s = Delim
  { dChar :: !Char
  , dLen :: !Int
  , dOpen :: !Bool
  , dClose :: !Bool
  , dNode :: !(INode s)
  , dPos :: !Int
  , dPrev :: !(STRef s (Maybe (Delim s)))
  , dNext :: !(STRef s (Maybe (Delim s)))
  }

data Bracket s = Bracket
  { bImage :: !Bool
  , bNode :: !(INode s)
  , bPos :: !Int
  }

data S s = S
  { sArr :: !(UArray Int Char)
  , sLen :: !Int
  , sPos :: !(STRef s Int)
  , sRoot :: !(INode s)
  , sCounter :: !(STRef s Int)
  , sTop :: !(STRef s (Maybe (Delim s)))
  , sBrackets :: !(STRef s [Bracket s])
  , sLinkClosed :: !(STRef s Bool)
  , sTicks :: !(STRef s (IM.IntMap Int))
  , sScanned :: !(STRef s Bool)
  }

newINode :: STRef s Int -> IKind -> ST s (INode s)
newINode counter k = do
  i <- readSTRef counter
  writeSTRef counter (i + 1)
  INode i <$> newSTRef k <*> newSTRef Nothing <*> newSTRef Nothing
    <*> newSTRef Nothing <*> newSTRef Nothing

sameI :: INode s -> INode s -> Bool
sameI a b = inId a == inId b

-- | Append a node to the end of the root's child list.
append :: S s -> INode s -> ST s ()
append s n = do
  let root = sRoot s
  l <- readSTRef (inLast root)
  case l of
    Nothing -> writeSTRef (inFirst root) (Just n)
    Just x -> do
      writeSTRef (inNext x) (Just n)
      writeSTRef (inPrev n) (Just x)
  writeSTRef (inLast root) (Just n)

emit :: S s -> IKind -> ST s (INode s)
emit s k = do
  n <- newINode (sCounter s) k
  append s n
  pure n

-- ---------------------------------------------------------------------------

-- | Parse the raw content of a paragraph or heading.
parseInlines :: Text -> [Inline]
parseInlines raw = runST $ do
  let content = T.dropWhileEnd isMdSpace raw
      n = T.length content
      arr = listArray (0, n - 1) (T.unpack content) :: UArray Int Char
  counter <- newSTRef 0
  root <- newINode counter IEmph
  s <-
    S arr n <$> newSTRef 0 <*> pure root <*> pure counter <*> newSTRef Nothing
      <*> newSTRef [] <*> newSTRef True <*> newSTRef IM.empty <*> newSTRef False
  mainLoop s
  processEmphasis s 0
  freezeList (inFirst root)

mainLoop :: S s -> ST s ()
mainLoop s = do
  pos <- readSTRef (sPos s)
  when (pos < sLen s) $ do
    case sArr s ! pos of
      '\n' -> handleNewline s pos
      '`' -> handleBackticks s pos
      '\\' -> handleBackslash s pos
      '&' -> handleEntity s pos
      '<' -> handlePointy s pos
      '*' -> handleDelim s pos
      '_' -> handleDelim s pos
      '[' -> handleOpenBracket s pos
      '!' -> handleBang s pos
      ']' -> handleCloseBracket s pos
      _ -> handlePlain s pos
    mainLoop s

sliceA :: S s -> Int -> Int -> Text
sliceA s i j = T.pack [sArr s ! k | k <- [i .. j - 1]]

charAt :: S s -> Int -> Char
charAt s i = if i >= 0 && i < sLen s then sArr s ! i else '\0'

setPos :: S s -> Int -> ST s ()
setPos s = writeSTRef (sPos s)

emitText :: S s -> Text -> ST s (INode s)
emitText s t = emit s (IText t)

isSpecial :: Char -> Bool
isSpecial c = c `elem` ("\n`\\&<*_[]!" :: String)

handlePlain :: S s -> Int -> ST s ()
handlePlain s pos = do
  let end = go (pos + 1)
      go !i = if i < sLen s && not (isSpecial (sArr s ! i)) then go (i + 1) else i
      t0 = sliceA s pos end
      t = if end < sLen s && sArr s ! end == '\n' then T.dropWhileEnd isMdSpace t0 else t0
  _ <- emitText s t
  setPos s end

handleNewline :: S s -> Int -> ST s ()
handleNewline s pos = do
  let hard = pos > 1 && charAt s (pos - 1) == ' ' && charAt s (pos - 2) == ' '
  _ <- emit s (if hard then IHard else ISoft)
  let skip !i = if i < sLen s && (sArr s ! i == ' ' || sArr s ! i == '\t') then skip (i + 1) else i
  setPos s (skip (pos + 1))

handleBackslash :: S s -> Int -> ST s ()
handleBackslash s pos
  | isAsciiPunct next = emitText s (T.singleton next) >> setPos s (pos + 2)
  | next == '\n' = emit s IHard >> setPos s (pos + 2)
  | otherwise = emitText s "\\" >> setPos s (pos + 1)
  where
    next = charAt s (pos + 1)

handleEntity :: S s -> Int -> ST s ()
handleEntity s pos =
  case matchEntity (sliceA s (pos + 1) (min (sLen s) (pos + 11))) of
    Just (t, n) -> emitText s t >> setPos s (pos + 1 + n)
    Nothing -> emitText s "&" >> setPos s (pos + 1)

-- ---------------------------------------------------------------------------
-- Code spans

handleBackticks :: S s -> Int -> ST s ()
handleBackticks s pos = do
  let runEnd = goRun pos
      goRun !i = if i < sLen s && sArr s ! i == '`' then goRun (i + 1) else i
      n = runEnd - pos
      p = runEnd
  found <- findClosing s n p
  case found of
    Nothing -> emitText s (sliceA s pos p) >> setPos s p
    Just start -> do
      let body = T.map (\c -> if c == '\n' then ' ' else c) (sliceA s p start)
          trimmed
            | T.length body >= 2 && T.head body == ' ' && T.last body == ' '
                && T.any (/= ' ') body = T.init (T.tail body)
            | otherwise = body
      _ <- emit s (ICode trimmed)
      setPos s (start + n)

-- | Find the start of the next backtick run of length exactly @n@ at or after
-- @p@, using cmark's memo of the last position seen for each run length.
findClosing :: S s -> Int -> Int -> ST s (Maybe Int)
findClosing s n p = do
  scanned <- readSTRef (sScanned s)
  ticks <- readSTRef (sTicks s)
  if scanned && IM.findWithDefault 0 n ticks <= p
    then pure Nothing
    else scan p
  where
    scan !i = do
      let skipNon !j = if j < sLen s && sArr s ! j /= '`' then skipNon (j + 1) else j
          j0 = skipNon i
      if j0 >= sLen s
        then writeSTRef (sScanned s) True >> pure Nothing
        else do
          let runEnd !j = if j < sLen s && sArr s ! j == '`' then runEnd (j + 1) else j
              j1 = runEnd j0
              k = j1 - j0
          modifySTRef' (sTicks s) (IM.insert k j0)
          if k == n then pure (Just j0) else scan j1

-- ---------------------------------------------------------------------------
-- Autolinks

handlePointy :: S s -> Int -> ST s ()
handlePointy s pos =
  case scanAutolink s (pos + 1) of
    Just (dest, label, end) -> do
      lnk <- emit s (ILink dest Nothing)
      child <- newINode (sCounter s) (IText label)
      writeSTRef (inFirst lnk) (Just child)
      writeSTRef (inLast lnk) (Just child)
      setPos s end
    Nothing -> emitText s "<" >> setPos s (pos + 1)

-- | Try both autolink forms right after a @<@. Returns destination, label and
-- the position after the closing @>@.
scanAutolink :: S s -> Int -> Maybe (Text, Text, Int)
scanAutolink s i = uri `orElse` email
  where
    orElse (Just x) _ = Just x
    orElse Nothing y = y
    isAl c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    isAlnum c = isAl c || (c >= '0' && c <= '9')
    schemeCh c = isAlnum c || c == '.' || c == '+' || c == '-'
    spanFrom p f = let go !j = if j < sLen s && f (sArr s ! j) then go (j + 1) else j in go p
    uri
      | isAl (charAt s i) =
          let e = spanFrom i schemeCh
              len = e - i
           in if len >= 2 && len <= 32 && charAt s e == ':'
                then
                  let u = spanFrom (e + 1) (\c -> c > ' ' && c /= '<' && c /= '>')
                   in if charAt s u == '>' && u < sLen s
                        then
                          let raw = decodeEntities (sliceA s i u)
                           in Just (raw, raw, u + 1)
                        else Nothing
                else Nothing
      | otherwise = Nothing
    localCh c = isAlnum c || c `elem` (".!#$%&'*+/=?^_`{|}~-" :: String)
    email =
      let e = spanFrom i localCh
       in if e > i && charAt s e == '@' && e < sLen s
            then case domain (e + 1) of
              Just end | charAt s end == '>' && end < sLen s ->
                let addr = decodeEntities (sliceA s i end)
                 in Just ("mailto:" <> addr, addr, end + 1)
              _ -> Nothing
            else Nothing
    domain p = do
      q <- label p
      moreLabels q
    moreLabels q
      | charAt s q == '.' && q < sLen s = label (q + 1) >>= moreLabels
      | otherwise = Just q
    label p =
      let e = spanFrom p (\c -> isAlnum c || c == '-')
          len = e - p
       in if len >= 1 && len <= 63 && isAlnum (sArr s ! p) && isAlnum (sArr s ! (e - 1))
            then Just e
            else Nothing

-- ---------------------------------------------------------------------------
-- Delimiter runs and emphasis

isPunctOrSpace :: Char -> Bool
isPunctOrSpace c = isMdSpace c || isAsciiPunct c

handleDelim :: S s -> Int -> ST s ()
handleDelim s pos = do
  let c = sArr s ! pos
      runEnd = goRun pos
      goRun !i = if i < sLen s && sArr s ! i == c then goRun (i + 1) else i
      n = runEnd - pos
      before = if pos == 0 then '\n' else sArr s ! (pos - 1)
      after = if runEnd >= sLen s then '\n' else sArr s ! runEnd
      leftFlanking = not (isMdSpace after) && (not (isAsciiPunct after) || isPunctOrSpace before)
      rightFlanking = not (isMdSpace before) && (not (isAsciiPunct before) || isPunctOrSpace after)
      (canOpen, canClose)
        | c == '*' = (leftFlanking, rightFlanking)
        | otherwise =
            ( leftFlanking && (not rightFlanking || isAsciiPunct before)
            , rightFlanking && (not leftFlanking || isAsciiPunct after)
            )
  node <- emitText s (T.replicate n (T.singleton c))
  when (canOpen || canClose) $ do
    top <- readSTRef (sTop s)
    prev <- newSTRef top
    next <- newSTRef Nothing
    let d = Delim c n canOpen canClose node runEnd prev next
    case top of
      Just t -> writeSTRef (dNext t) (Just d)
      Nothing -> pure ()
    writeSTRef (sTop s) (Just d)
  setPos s runEnd

-- | Remove a delimiter entry from the stack.
removeDelim :: S s -> Delim s -> ST s ()
removeDelim s d = do
  p <- readSTRef (dPrev d)
  nx <- readSTRef (dNext d)
  case p of
    Just x -> writeSTRef (dNext x) nx
    Nothing -> pure ()
  case nx of
    Just x -> writeSTRef (dPrev x) p
    Nothing -> writeSTRef (sTop s) p

-- | cmark's process_emphasis over the entries at or above @bottom@.
processEmphasis :: S s -> Int -> ST s ()
processEmphasis s bottom = do
  openersBottom <- newArray (0, 11) bottom :: ST s (STUArray s Int Int)
  top <- readSTRef (sTop s)
  first <- lowest top
  loop openersBottom first
  -- drop every entry at or above the bottom
  top' <- readSTRef (sTop s)
  newTop <- dropAbove top'
  writeSTRef (sTop s) newTop
  case newTop of
    Just t -> writeSTRef (dNext t) Nothing
    Nothing -> pure ()
  where
    lowest Nothing = pure Nothing
    lowest (Just d)
      | dPos d < bottom = pure Nothing
      | otherwise = climb d
    climb d = do
      p <- readSTRef (dPrev d)
      case p of
        Just q | dPos q >= bottom -> climb q
        _ -> pure (Just d)
    dropAbove Nothing = pure Nothing
    dropAbove (Just d)
      | dPos d >= bottom = readSTRef (dPrev d) >>= dropAbove
      | otherwise = pure (Just d)
    kindIx c = (if dChar c == '*' then 0 else 6) + (if dOpen c then 3 else 0) + (dLen c `mod` 3)
    loop _ Nothing = pure ()
    loop ob (Just closer)
      | dClose closer = do
          let ix = kindIx closer
          lim <- readArray ob ix
          mo <- findOpener closer lim
          case mo of
            Just opener -> do
              next <- insertEmph s opener closer
              loop ob next
            Nothing -> do
              writeArray ob ix (dPos closer)
              nxt <- readSTRef (dNext closer)
              unless (dOpen closer) $ removeDelim s closer
              loop ob nxt
      | otherwise = readSTRef (dNext closer) >>= loop ob
    findOpener closer lim = readSTRef (dPrev closer) >>= walk
      where
        walk Nothing = pure Nothing
        walk (Just o)
          | dPos o < lim = pure Nothing
          | dOpen o && dChar o == dChar closer
              && (not ((dOpen closer || dClose o) && dLen closer `mod` 3 /= 0
                        && (dLen o + dLen closer) `mod` 3 == 0)) = pure (Just o)
          | otherwise = readSTRef (dPrev o) >>= walk

-- | Wrap the nodes between a matched opener and closer in emphasis. Returns
-- the next closer to examine.
insertEmph :: S s -> Delim s -> Delim s -> ST s (Maybe (Delim s))
insertEmph s opener closer = do
  let on = dNode opener
      cn = dNode closer
  ot <- textOf on
  ct <- textOf cn
  let use = if T.length ot >= 2 && T.length ct >= 2 then 2 else 1 :: Int
      ot' = T.dropEnd use ot
      ct' = T.drop use ct
  writeSTRef (inKind on) (IText ot')
  writeSTRef (inKind cn) (IText ct')
  -- discard the entries strictly between opener and closer
  writeSTRef (dNext opener) (Just closer)
  writeSTRef (dPrev closer) (Just opener)
  -- wrap the nodes strictly between the two text nodes
  emph <- newINode (sCounter s) (if use == 2 then IStrong else IEmph)
  firstBetween <- readSTRef (inNext on)
  lastBetween <- readSTRef (inPrev cn)
  case firstBetween of
    Just f | not (sameI f cn) -> do
      writeSTRef (inFirst emph) (Just f)
      writeSTRef (inLast emph) lastBetween
      writeSTRef (inPrev f) Nothing
      case lastBetween of
        Just l -> writeSTRef (inNext l) Nothing
        Nothing -> pure ()
    _ -> pure ()
  writeSTRef (inNext on) (Just emph)
  writeSTRef (inPrev emph) (Just on)
  writeSTRef (inNext emph) (Just cn)
  writeSTRef (inPrev cn) (Just emph)
  when (T.null ot') $ removeDelim s opener
  if T.null ct'
    then do
      nxt <- readSTRef (dNext closer)
      removeDelim s closer
      pure nxt
    else pure (Just closer)

textOf :: INode s -> ST s Text
textOf n = do
  k <- readSTRef (inKind n)
  pure $ case k of
    IText t -> t
    _ -> T.empty

-- ---------------------------------------------------------------------------
-- Brackets, links and images

handleOpenBracket :: S s -> Int -> ST s ()
handleOpenBracket s pos = do
  node <- emitText s "["
  modifySTRef' (sBrackets s) (Bracket False node (pos + 1) :)
  writeSTRef (sLinkClosed s) False
  setPos s (pos + 1)

handleBang :: S s -> Int -> ST s ()
handleBang s pos
  | charAt s (pos + 1) == '[' = do
      node <- emitText s "!["
      modifySTRef' (sBrackets s) (Bracket True node (pos + 2) :)
      setPos s (pos + 2)
  | otherwise = emitText s "!" >> setPos s (pos + 1)

handleCloseBracket :: S s -> Int -> ST s ()
handleCloseBracket s pos = do
  let after = pos + 1
  brs <- readSTRef (sBrackets s)
  linkClosed <- readSTRef (sLinkClosed s)
  case brs of
    [] -> literal after
    (op : rest)
      | not (bImage op) && linkClosed -> do
          writeSTRef (sBrackets s) rest
          literal after
      | otherwise -> case parseLinkTail s after of
          Nothing -> do
            writeSTRef (sBrackets s) rest
            literal after
          Just (dest, title, end) -> do
            let kind = if bImage op then IImage dest title else ILink dest title
            lnk <- newINode (sCounter s) kind
            -- move everything after the opener's text node into the link
            let on = bNode op
            kids <- readSTRef (inNext on)
            lastNode <- readSTRef (inLast (sRoot s))
            case kids of
              Just k -> do
                writeSTRef (inFirst lnk) (Just k)
                writeSTRef (inLast lnk) lastNode
                writeSTRef (inPrev k) Nothing
              Nothing -> pure ()
            writeSTRef (inKind on) (IText T.empty)
            writeSTRef (inNext on) (Just lnk)
            writeSTRef (inPrev lnk) (Just on)
            writeSTRef (inLast (sRoot s)) (Just lnk)
            processEmphasis s (bPos op)
            writeSTRef (sBrackets s) rest
            unless (bImage op) $ writeSTRef (sLinkClosed s) True
            setPos s end
  where
    literal after = emitText s "]" >> setPos s after

-- | Parse @(destination "title")@ following a closing bracket at @pos@.
-- Returns the cleaned destination, title and the position after the @)@.
parseLinkTail :: S s -> Int -> Maybe (Text, Maybe Text, Int)
parseLinkTail s pos
  | charAt s pos /= '(' || pos >= sLen s = Nothing
  | otherwise = do
      let p1 = skipSp (pos + 1)
      (dest, endUrl) <- scanUrl p1
      let startTitle = skipSp endUrl
          (title, endTitle)
            | startTitle == endUrl = (Nothing, startTitle)
            | otherwise = case scanTitle startTitle of
                Just e -> (Just (cleanDestination (sliceA s (startTitle + 1) (e - 1))), e)
                Nothing -> (Nothing, startTitle)
          endAll = skipSp endTitle
      if endAll < sLen s && sArr s ! endAll == ')'
        then Just (cleanDestination (T.dropAround isMdSpace dest), title, endAll + 1)
        else Nothing
  where
    skipSp !i = if i < sLen s && isMdSpace (sArr s ! i) then skipSp (i + 1) else i
    scanUrl p
      | p < sLen s && sArr s ! p == '<' = angle (p + 1)
      | otherwise = bare p p (0 :: Int)
      where
        angle !i
          | i >= sLen s = Nothing
          | c == '>' = Just (sliceA s (p + 1) i, i + 1)
          | c == '\\' = angle (i + 2)
          | c == '\n' || c == '<' = Nothing
          | otherwise = angle (i + 1)
          where
            c = sArr s ! i
    bare start !i !nest
      | i >= sLen s = Nothing
      | c == '\\' && i + 1 < sLen s && isAsciiPunct (sArr s ! (i + 1)) = bare start (i + 2) nest
      | c == '(' = if nest + 1 > 32 then Nothing else bare start (i + 1) (nest + 1)
      | c == ')' = if nest == 0 then done else bare start (i + 1) (nest - 1)
      | isMdSpace c = done
      | otherwise = bare start (i + 1) nest
      where
        c = sArr s ! i
        done = if nest /= 0 then Nothing else Just (sliceA s start i, i)
    -- the longest title in which the closing delimiter occurs only after a
    -- backslash
    scanTitle st =
      let open = sArr s ! st
          close = if open == '(' then ')' else open
       in if open == '"' || open == '\'' || open == '('
            then titleEnd open close (st + 1) Nothing
            else Nothing
    titleEnd open close !i cand
      | i >= sLen s = fmap (+ 1) cand
      | c == close =
          if prevBackslash then titleEnd open close (i + 1) (Just i) else Just (i + 1)
      | open == '(' && c == '(' =
          if prevBackslash then titleEnd open close (i + 1) cand else fmap (+ 1) cand
      | otherwise = titleEnd open close (i + 1) cand
      where
        c = sArr s ! i
        prevBackslash = i > 0 && sArr s ! (i - 1) == '\\'

-- ---------------------------------------------------------------------------
-- Freezing

freezeList :: STRef s (Maybe (INode s)) -> ST s [Inline]
freezeList ref = readSTRef ref >>= go
  where
    go Nothing = pure []
    go (Just n) = do
      i <- freezeNode n
      rest <- readSTRef (inNext n) >>= go
      pure (i : rest)

freezeNode :: INode s -> ST s Inline
freezeNode n = do
  k <- readSTRef (inKind n)
  case k of
    IText t -> pure (Str t)
    ISoft -> pure SoftBreak
    IHard -> pure HardBreak
    ICode t -> pure (Code t)
    IEmph -> Emph <$> freezeList (inFirst n)
    IStrong -> Strong <$> freezeList (inFirst n)
    ILink d t -> Link d t <$> freezeList (inFirst n)
    IImage d t -> Image d t <$> freezeList (inFirst n)
