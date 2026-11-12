-- | The Codexa parser: line classification, the block stack, directive
-- attribute checking and the error precedence rules.
module Typeset.Parser
  ( parseDocument
  ) where

import Data.Char (isAlphaNum, isDigit)

import Typeset.Error
import Typeset.Parser.Inline
import Typeset.Settings (parseInteger, parseLength)
import Typeset.Syntax
import Typeset.Types

--------------------------------------------------------------------------
-- Parser monad

data Frame
  = FDoc Meta [String]
  | FQuote [Block]
  | FGroup BlockAttrs [Block]
  | FList ListKind [ListItem] (Maybe ItemOpen)
  | FTable Int [ColAlign] [TableElem]
  | FPre [String]
  | FFig Int (Maybe Int) [[CP]]

data ItemOpen = ItemOpen { ioText :: Inline, ioBlocks :: [Block] }

data PendKind = PendPara | PendItem

data Pend = Pend PendKind [[CP]]

data PS = PS
  { psStack    :: [Frame]
  , psTop      :: [Block]
  , psTopCount :: !Int
  , psFirstDoc :: Bool
  , psToc      :: Maybe (Maybe String)
  , psMeta     :: Meta
  , psPend     :: Maybe Pend
  , psNotes    :: !Int
  }

newtype P a = P { runP :: PS -> Either Error (a, PS) }

instance Functor P where
  fmap f (P g) = P $ \s -> case g s of
    Left e -> Left e
    Right (a, s') -> Right (f a, s')

instance Applicative P where
  pure a = P $ \s -> Right (a, s)
  P f <*> P g = P $ \s -> case f s of
    Left e -> Left e
    Right (h, s') -> case g s' of
      Left e -> Left e
      Right (a, s'') -> Right (h a, s'')

instance Monad P where
  P g >>= f = P $ \s -> case g s of
    Left e -> Left e
    Right (a, s') -> runP (f a) s'

gets :: (PS -> a) -> P a
gets f = P $ \s -> Right (f s, s)

modify :: (PS -> PS) -> P ()
modify f = P $ \s -> Right ((), f s)

throwAt :: Int -> Int -> ErrorCode -> P a
throwAt l c code = P $ \_ -> Left (Error DocumentFile l c code)

liftE :: Either Error a -> P a
liftE e = P $ \s -> fmap (\a -> (a, s)) e

--------------------------------------------------------------------------
-- Entry point

-- | Parse the text of @document.cdx@.
parseDocument :: String -> Either Error Doc
parseDocument txt =
  let ls = lines txt
      n = length ls
      st0 = PS [] [] 0 False Nothing emptyMeta Nothing 0
      prog = mapM_ (uncurry procLine) (zip [1 ..] ls) >> finishDoc (n + 1)
  in fmap fst (runP prog st0)

finishDoc :: Int -> P Doc
finishDoc endLine = do
  flushPend
  st <- gets psStack
  case st of
    (_ : _) -> throwAt endLine 1 MissingEnd
    [] -> do
      meta <- gets psMeta
      toc <- gets psToc
      bs <- gets psTop
      return (Doc meta toc (reverse bs))

--------------------------------------------------------------------------
-- Line processing

isBlank :: String -> Bool
isBlank = all (== ' ')

procLine :: Int -> String -> P ()
procLine ln raw = do
  stack <- gets psStack
  case stack of
    (FPre ls : rest)
      | dropWhile (== ' ') (reverse (dropWhile (== ' ') (reverse raw))) == "@end" -> do
          modify (\s -> s { psStack = rest })
          attach (BPre (reverse ls))
      | otherwise ->
          modify (\s -> s { psStack = FPre (reverse (dropWhile (== ' ') (reverse raw)) : ls) : rest })
    _ | isBlank raw -> flushPend
      | otherwise ->
          let lead = length (takeWhile (== ' ') raw)
          in if take 1 (drop lead raw) == "@"
               then directive ln raw lead
               else textLine ln raw lead

-- | Mark the start of a top-level block.
noteTopStart :: P ()
noteTopStart = modify $ \s -> case psStack s of
  [] -> s { psTopCount = psTopCount s + 1 }
  _ -> s

-- | Add a finished block to the innermost open container.
attach :: Block -> P ()
attach b = modify $ \s -> case psStack s of
  [] -> s { psTop = b : psTop s }
  (f : rest) -> s { psStack = addTo f : rest }
  where
    addTo f = case f of
      FQuote bs -> FQuote (b : bs)
      FGroup a bs -> FGroup a (b : bs)
      FList k is (Just io) -> FList k is (Just io { ioBlocks = b : ioBlocks io })
      other -> other

-- | Scan and attach the pending paragraph or item text.
flushPend :: P ()
flushPend = do
  mp <- gets psPend
  case mp of
    Nothing -> return ()
    Just (Pend kind ls) -> do
      modify (\s -> s { psPend = Nothing })
      n <- gets psNotes
      (nodes, n') <- liftE (scanInline True n (joinLines (reverse ls)))
      modify (\s -> s { psNotes = n' })
      case kind of
        PendPara -> attach (BPara nodes)
        PendItem -> modify $ \s -> case psStack s of
          (FList k is (Just io) : rest) -> s { psStack = FList k is (Just io { ioText = nodes }) : rest }
          _ -> s

textLine :: Int -> String -> Int -> P ()
textLine ln raw lead = do
  stack <- gets psStack
  let col = lead + 1
      cps = charsAt ln col (drop lead raw)
  case stack of
    (FDoc meta seen : rest) -> metaLine ln raw lead meta seen rest
    (FTable cols als es : rest) -> do
      cells <- return (splitCells cps)
      if length cells /= cols
        then throwAt ln 1 CellCount
        else do
          n <- gets psNotes
          parsed <- liftE (mapM (fmap fst . scanInline False n) cells)
          modify (\s -> s { psStack = FTable cols als (TRow parsed : es) : rest })
    (FFig h w caps : rest) ->
      modify (\s -> s { psStack = FFig h w (cps : caps) : rest })
    (FList _ _ Nothing : _) -> throwAt ln col TextNotAllowed
    _ -> do
      mp <- gets psPend
      case mp of
        Just (Pend k ls) -> modify (\s -> s { psPend = Just (Pend k (cps : ls)) })
        Nothing -> do
          noteTopStart
          modify (\s -> s { psPend = Just (Pend PendPara [cps]) })

-- | Split a table row into cells.  A backslash consumes the next character.
splitCells :: [CP] -> [[CP]]
splitCells = go []
  where
    go cur [] = [reverse cur]
    go cur (c@(CP '\\' _ _) : d : r) = go (d : c : cur) r
    go cur (CP '|' _ _ : r) = reverse cur : go [] r
    go cur (c : r) = go (c : cur) r

metaLine :: Int -> String -> Int -> Meta -> [String] -> [Frame] -> P ()
metaLine ln raw lead meta seen rest = do
  let body = drop lead raw
      (key, r1) = span isKeyChar body
      r2 = dropWhile (`elem` " \t") r1
  case r2 of
    ('=' : v) | not (null key) -> do
      let val = trimBoth v
      if key `notElem` ["title", "author", "date"] then throwAt ln (lead + 1) UnknownMeta
      else if key `elem` seen then throwAt ln (lead + 1) DuplicateMeta
      else do
        let meta' = case key of
              "title" -> meta { metaTitle = val }
              "author" -> meta { metaAuthor = val }
              _ -> meta { metaDate = val }
        modify (\s -> s { psStack = FDoc meta' (key : seen) : rest })
    _ -> throwAt ln (lead + 1) BadSyntax
  where
    isKeyChar c = (c >= 'a' && c <= 'z') || isDigit c || c == '-'
    trimBoth = reverse . dropWhile (`elem` " \t") . reverse . dropWhile (`elem` " \t")

--------------------------------------------------------------------------
-- Directives

data Dir
  = DDoc | DToc | DHeading Int Bool | DQuote | DBlock | DUl | DOl | DLi
  | DTable | DHrule | DPre | DFig | DRule | DVspace | DNewpage | DEnd
  deriving (Eq)

dirOf :: String -> Maybe Dir
dirOf n = case n of
  "@doc" -> Just DDoc
  "@toc" -> Just DToc
  "@h1" -> h 1 False; "@h2" -> h 2 False; "@h3" -> h 3 False; "@h4" -> h 4 False
  "@h1*" -> h 1 True; "@h2*" -> h 2 True; "@h3*" -> h 3 True; "@h4*" -> h 4 True
  "@q" -> Just DQuote
  "@block" -> Just DBlock
  "@ul" -> Just DUl
  "@ol" -> Just DOl
  "@li" -> Just DLi
  "@table" -> Just DTable
  "@hrule" -> Just DHrule
  "@pre" -> Just DPre
  "@fig" -> Just DFig
  "@rule" -> Just DRule
  "@vspace" -> Just DVspace
  "@newpage" -> Just DNewpage
  "@end" -> Just DEnd
  _ -> Nothing
  where h l s = Just (DHeading l s)

allowedAttrs :: Dir -> [String]
allowedAttrs d = case d of
  DToc -> ["title"]
  DBlock -> ["align", "indent", "right-indent", "font", "size", "leading"]
  DOl -> ["start"]
  DTable -> ["cols", "align"]
  DFig -> ["height", "width"]
  DVspace -> ["height"]
  _ -> []

requiredAttrs :: Dir -> [String]
requiredAttrs d = case d of
  DTable -> ["cols"]
  DFig -> ["height"]
  DVspace -> ["height"]
  _ -> []

-- | A lexed attribute token.
data Attr = Attr { aName :: String, aVal :: String, aValCol :: Int }

isNameChar, isBareChar :: Char -> Bool
isNameChar c = (c < '\128' && isAlphaNum c) || c == '-'
isBareChar c = (c < '\128' && isAlphaNum c) || c `elem` ".+-%"

-- | Step 1: read the attribute tokens left to right.
lexAttrs :: [String] -> Int -> String -> Either (ErrorCode, Int) [Attr]
lexAttrs allowed = go []
  where
    go seen col s =
      let (sp, s') = span (== ' ') s
          col' = col + length sp
      in case s' of
        [] -> Right (reverse seen)
        _ ->
          let (nm, r) = span isNameChar s'
          in case r of
            ('=' : r2) | not (null nm) ->
              if nm `notElem` allowed || nm `elem` map aName seen
                then Left (BadAttribute, col')
                else
                  let vcol = col' + length nm + 1
                  in case r2 of
                    ('"' : q) -> case break (== '"') q of
                      (v, '"' : after)
                        | endsOk after -> go (Attr nm v vcol : seen) (vcol + length v + 2) after
                      _ -> Left (BadAttributeValue, vcol)
                    _ -> let (v, after) = span isBareChar r2
                         in if null v || not (endsOk after)
                              then Left (BadAttributeValue, vcol)
                              else go (Attr nm v vcol : seen) (vcol + length v) after
            _ -> Left (BadAttribute, col')
    endsOk after = case after of
      [] -> True
      (' ' : _) -> True
      _ -> False

-- | Step 4: shape and range of one attribute value.
validAttr :: Dir -> Attr -> Bool
validAttr d (Attr nm v _) = case (d, nm) of
  (DBlock, "align") -> v `elem` ["justify", "left", "right", "center"]
  (DBlock, "indent") -> lenIn 0 big
  (DBlock, "right-indent") -> lenIn 0 big
  (DBlock, "font") -> v `elem` ["serif", "sans", "mono"]
  (DBlock, "size") -> lenIn 1000 200000
  (DBlock, "leading") -> lenIn 1000 big
  (DOl, "start") -> intIn 1 100000
  (DTable, "cols") -> intIn 1 20
  (DTable, "align") -> all (`elem` "lrc") v
  (DFig, _) -> lenIn 0 big
  (DVspace, _) -> lenIn 0 big
  _ -> True
  where
    big = maxBound `div` 4
    lenIn lo hi = maybe False (\n -> n >= lo && n <= hi) (parseLength v)
    intIn lo hi = maybe False (\n -> n >= lo && n <= hi) (parseInteger v)

directive :: Int -> String -> Int -> P ()
directive ln raw lead = do
  flushPend
  let atCol = lead + 1
      s = drop lead raw
      name = takeWhile (/= ' ') s
      afterName = drop (length name) s
      nameEnd = atCol + length name
  dir <- maybe (throwAt ln atCol UnknownBlock) return (dirOf name)
  case dir of
    DHeading lvl star -> do
      placement ln atCol dir
      let rest = dropWhile (== ' ') afterName
          col = nameEnd + (length afterName - length rest)
      n <- gets psNotes
      (nodes, _) <- liftE (scanInline False n (charsAt ln col rest))
      noteTopStart
      attach (BHeading lvl star nodes)
    DLi -> do
      placement ln atCol dir
      let rest = dropWhile (== ' ') afterName
          col = nameEnd + (length afterName - length rest)
      modify $ \st -> case psStack st of
        (FList k is cur : more) ->
          st { psStack = FList k (closeItem cur is) (Just (ItemOpen [] [])) : more
             , psPend = Just (Pend PendItem [charsAt ln col rest]) }
        _ -> st
    _ -> do
      attrs <- case lexAttrs (allowedAttrs dir) nameEnd afterName of
        Left (code, col) -> throwAt ln col code
        Right as -> return as
      case [r | r <- requiredAttrs dir, r `notElem` map aName attrs] of
        (_ : _) -> throwAt ln atCol MissingAttribute
        [] -> return ()
      placement ln atCol dir
      case [a | a <- attrs, not (validAttr dir a)] of
        (a : _) -> throwAt ln (aValCol a) BadAttributeValue
        [] -> return ()
      let attr k = [a | a <- attrs, aName a == k]
          cols = case attr "cols" of (a : _) -> maybe 1 id (parseInteger (aVal a)); _ -> 1
      case (dir, attr "align") of
        (DTable, a : _) | length (aVal a) /= cols -> throwAt ln (aValCol a) BadAttributeValue
        _ -> return ()
      act dir attrs

closeItem :: Maybe ItemOpen -> [ListItem] -> [ListItem]
closeItem Nothing is = is
closeItem (Just io) is = ListItem (ioText io) (reverse (ioBlocks io)) : is

-- | Step 3: is the directive allowed where it appears?
placement :: Int -> Int -> Dir -> P ()
placement ln col dir = do
  st <- gets psStack
  topCount <- gets psTopCount
  firstDoc <- gets psFirstDoc
  toc <- gets psToc
  let ordinary = case st of
        [] -> True
        (FQuote _ : _) -> True
        (FGroup _ _ : _) -> True
        (FList _ _ (Just _) : _) -> True
        _ -> False
      notAllowed = throwAt ln col BlockNotAllowed
      ok = return ()
  case dir of
    DEnd -> if null st then throwAt ln col UnexpectedEnd else ok
    DDoc -> if null st && topCount == 0 then ok else notAllowed
    DToc -> case toc of
      Just _ -> if ordinary then throwAt ln col DuplicateToc else notAllowed
      Nothing -> if null st && (topCount == 0 || (topCount == 1 && firstDoc)) then ok else notAllowed
    DLi -> case st of
      (FList _ _ _ : _) -> ok
      _ -> notAllowed
    DHrule -> case st of
      (FTable _ _ _ : _) -> ok
      _ -> notAllowed
    _ -> if ordinary then ok else notAllowed

-- | Perform a directive whose checks have passed.
act :: Dir -> [Attr] -> P ()
act dir attrs = case dir of
  DDoc -> do
    noteTopStart
    modify (\s -> s { psStack = FDoc emptyMeta [] : psStack s, psFirstDoc = True })
  DToc -> do
    noteTopStart
    modify (\s -> s { psToc = Just (aVal <$> get1 "title") })
  DQuote -> open (FQuote [])
  DBlock -> open (FGroup (BlockAttrs
    { baAlign = (\a -> case aVal a of
                    "justify" -> Justify; "left" -> AlignLeft; "right" -> AlignRight; _ -> AlignCenter)
                  <$> get1 "align"
    , baIndent = get1 "indent" >>= len
    , baRightIndent = get1 "right-indent" >>= len
    , baFont = (\a -> case aVal a of "serif" -> Serif; "sans" -> Sans; _ -> Mono) <$> get1 "font"
    , baSize = get1 "size" >>= len
    , baLeading = get1 "leading" >>= len }) [])
  DUl -> open (FList Unordered [] Nothing)
  DOl -> open (FList (Ordered (maybe 1 id (get1 "start" >>= int))) [] Nothing)
  DTable -> do
    let cols = maybe 1 id (get1 "cols" >>= int)
        als = case get1 "align" of
          Just a -> map (\c -> case c of 'l' -> ColLeft; 'r' -> ColRight; _ -> ColCenter) (aVal a)
          Nothing -> replicate cols ColLeft
    open (FTable cols als [])
  DHrule -> modify $ \s -> case psStack s of
    (FTable c a es : rest) -> s { psStack = FTable c a (THRule : es) : rest }
    _ -> s
  DPre -> open (FPre [])
  DFig -> open (FFig (maybe 0 id (get1 "height" >>= len)) (get1 "width" >>= len) [])
  DRule -> noteTopStart >> attach BRule
  DVspace -> noteTopStart >> attach (BVSpace (maybe 0 id (get1 "height" >>= len)))
  DNewpage -> noteTopStart >> attach BNewPage
  DEnd -> closeFrame
  _ -> return ()
  where
    get1 k = case [a | a <- attrs, aName a == k] of (a : _) -> Just a; [] -> Nothing
    len a = parseLength (aVal a)
    int a = parseInteger (aVal a)
    open f = noteTopStart >> modify (\s -> s { psStack = f : psStack s })

-- | Close the innermost open block (and its open item, if any).
closeFrame :: P ()
closeFrame = do
  st <- gets psStack
  case st of
    [] -> return ()
    (f : rest) -> do
      modify (\s -> s { psStack = rest })
      case f of
        FDoc meta _ -> modify (\s -> s { psMeta = meta })
        FQuote bs -> attach (BQuote (reverse bs))
        FGroup a bs -> attach (BGroup a (reverse bs))
        FList k is cur -> attach (BList k (reverse (closeItem cur is)))
        FTable c a es -> attach (BTable c a (reverse es))
        FPre ls -> attach (BPre (reverse ls))
        FFig h w caps -> do
          n <- gets psNotes
          (nodes, _) <- liftE (scanInline False n (joinLines (reverse caps)))
          attach (BFig h w nodes)
