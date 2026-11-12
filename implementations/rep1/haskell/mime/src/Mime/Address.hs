-- | Address-list parsing (RFC 5322 mailboxes and groups, leniently).
module Mime.Address
  ( Address (..)
  , parseAddressList
  ) where

import Data.List (intercalate)
import Data.Maybe (fromMaybe)

import Mime.EncodedWord (decodeDisplay, matchEncodedWord)
import Mime.Lexical

-- | One parsed address.
data Address = Address
  { addrDisplay :: String
  , addrSpec :: String
  }
  deriving (Eq, Show)

data Kind = Atom | Quoted | Literal | Encoded | Special
  deriving (Eq, Show)

data Token = Token
  { tKind :: Kind
  , tText :: String
  , tOff :: !Int
  , tSrc :: String -- ^ the input from the start of the token onwards
  }

isSpecialTok :: Char -> Token -> Bool
isSpecialTok c t = tKind t == Special && tText t == [c]

atomStop :: Char -> Bool
atomStop c = isBlank c || c `elem` "()<>[]@,:;.\"\\"

tokenize :: String -> [Token]
tokenize = go 0
  where
    go _ [] = []
    go !o s@(c : cs)
      | isBlank c = go (o + 1) cs
      | c == '(' = let (n, r) = skipComment cs in go (o + 1 + n) r
      | c == '"' = let (t, n, r) = quotedString cs in tok Quoted t (n + 1) r
      | c == '[' = let (t, n, r) = literal cs in tok Literal ('[' : t) (n + 1) r
      | Just (t, n, r) <- matchEncodedWord s = tok Encoded t n r
      | c `elem` "<>@,:;." = tok Special [c] 1 cs
      | c `elem` ")]\\" = tok Atom [c] 1 cs
      | otherwise = let (a, r) = break atomStop s in tok Atom a (length a) r
      where
        tok k t n r = Token k t o s : go (o + n) r
    -- domain literal body: runs to the next ']' (kept), backslash escapes kept
    literal [] = ([], 0 :: Int, [])
    literal (']' : r) = ("]", 1, r)
    literal ('\\' : x : r) = let (t, n, r') = literal r in ('\\' : x : t, n + 2, r')
    literal (x : r) = let (t, n, r') = literal r in (x : t, n + 1, r')

-- | Parse an address-list header value.
parseAddressList :: String -> [Address]
parseAddressList v = concatMap element (splitElements (tokenize v))

splitElements :: [Token] -> [[Token]]
splitElements = go (0 :: Int) []
  where
    go _ acc [] = [reverse acc]
    go d acc (t : r)
      | isSpecialTok '<' t = go (d + 1) (t : acc) r
      | isSpecialTok '>' t = go (max 0 (d - 1)) (t : acc) r
      | isSpecialTok ',' t, d == 0 = reverse acc : go d [] r
      | otherwise = go d (t : acc) r

element :: [Token] -> [Address]
element ts0 = case ts of
  [] -> []
  _ -> [fromMaybe fallback matched]
  where
    ts1 = case break (\t -> any (`isSpecialTok` t) "<@:") ts0 of
      (_, c : post) | isSpecialTok ':' c -> post
      _ -> ts0
    ts = case reverse ts1 of
      l : r | isSpecialTok ';' l -> reverse r
      _ -> ts1
    fallback = Address "" (concatMap tText ts)
    matched
      | any (isSpecialTok '<') ts = angle
      | otherwise = Address "" <$> addrSpecOf ts
    angle = case break (isSpecialTok '<') ts of
      (pre, lt : post) -> do
        i <- lastIndex (isSpecialTok '>') post
        spec <- addrSpecOf (take i post)
        let display = case pre of
              [] -> ""
              p : _ -> decodeDisplay (take (tOff lt - tOff p) (tSrc p))
        Just (Address display spec)
      _ -> Nothing

lastIndex :: (a -> Bool) -> [a] -> Maybe Int
lastIndex p xs = case [i | (i, x) <- zip [0 ..] xs, p x] of
  [] -> Nothing
  is -> Just (last is)

-- | Match @local [\@ domain]@ strictly and render it.
addrSpecOf :: [Token] -> Maybe String
addrSpecOf ts = do
  (local, rest) <- dotted (\t -> tKind t `elem` [Atom, Quoted]) ts
  case rest of
    [] -> Just (join local)
    at : r
      | isSpecialTok '@' at -> do
          dom <- domain r
          Just (join local ++ "@" ++ dom)
    _ -> Nothing
  where
    join = intercalate "." . map tText
    domain [l] | tKind l == Literal = Just (tText l)
    domain r = do
      (d, rest) <- dotted ((== Atom) . tKind) r
      if null rest then Just (join d) else Nothing

-- | A non-empty sequence of tokens satisfying the predicate separated by dots.
dotted :: (Token -> Bool) -> [Token] -> Maybe ([Token], [Token])
dotted p (t : r) | p t = Just (go [t] r)
  where
    go acc (d : t' : r') | isSpecialTok '.' d, p t' = go (t' : acc) r'
    go acc rest = (reverse acc, rest)
dotted _ _ = Nothing
