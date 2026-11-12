-- |
-- Module      : Git.Object
-- Description : Parsing the stored form of git objects: commits, trees and tags.
module Git.Object
  ( -- * Raw objects
    RawObject (..)
  , storedForm
  , hashObject
  , parseStoredForm
    -- * Commits
  , Commit (..)
  , Ident (..)
  , parseCommit
  , commitSubject
    -- * Trees
  , TreeEntry (..)
  , parseTree
  , entryType
  , modeIsTree
    -- * Tags
  , Tag (..)
  , parseTag
  ) where

import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Maybe (fromMaybe)
import Data.Word (Word8)

import Git.SHA1 (sha1)
import Git.Types

-- | An object's type and payload (the bytes after the @\<type\> \<size\>\\0@ header).
data RawObject = RawObject
  { objectType :: !ObjectType
  , objectPayload :: !ByteString
  }
  deriving (Eq, Show)

-- | @\<type\> SP \<size\> NUL \<payload\>@, the form that is hashed.
storedForm :: RawObject -> ByteString
storedForm (RawObject t p) =
  BS.concat [objectTypeName t, BC.pack " ", BC.pack (show (BS.length p)), BS.singleton 0, p]

-- | The id an object is stored under: the SHA-1 of its 'storedForm'.
hashObject :: RawObject -> ObjectId
hashObject o = case objectIdFromBytes (sha1 (storedForm o)) of
  Just i -> i
  Nothing -> error "hashObject: digest is not 20 bytes"

-- | Parse the decompressed contents of a loose object.  The contents must
-- start with a type name, a space, a decimal size and a NUL, and the payload
-- must be exactly that long.
parseStoredForm :: ByteString -> Either String RawObject
parseStoredForm s = do
  let (tyName, r1) = BC.break (== ' ') s
  ty <- maybe (Left "unknown object type") Right (parseObjectType tyName)
  let (sizeDigits, r2) = BC.span (\c -> c >= '0' && c <= '9') (BS.drop 1 r1)
  if BS.null r1 || BS.null sizeDigits || BS.take 1 r2 /= BS.singleton 0
    then Left "malformed object header"
    else do
      let payload = BS.drop 1 r2
      if toInteger (BS.length payload) /= readDecimal sizeDigits
        then Left "object size mismatch"
        else Right (RawObject ty payload)

readDecimal :: ByteString -> Integer
readDecimal = BS.foldl' (\a c -> a * 10 + toInteger c - 48) 0

------------------------------------------------------------------------------
-- Commits

-- | The parsed part of an @author@ / @committer@ line.
data Ident = Ident
  { identName :: !ByteString
    -- ^ everything before the first @<@, trailing whitespace removed
  , identTimestamp :: !Integer
    -- ^ seconds since the epoch; 0 when absent
  }
  deriving (Eq, Show)

-- | A parsed commit.
data Commit = Commit
  { commitTree :: !(Maybe ObjectId)
  , commitParents :: [ObjectId]
  , commitAuthor :: !Ident
  , commitCommitter :: !Ident
  , commitMessage :: !ByteString
  }
  deriving (Eq, Show)

isSpaceW :: Word8 -> Bool
isSpaceW c = c == 32 || (c >= 9 && c <= 13)

rstrip :: ByteString -> ByteString
rstrip = BS.dropWhileEnd isSpaceW

-- | Split a commit or tag payload into its headers and its message.
-- Continuation lines (starting with a space) are dropped; when there is no
-- empty line the message is empty.
splitHeaders :: ByteString -> ([(ByteString, ByteString)], ByteString)
splitHeaders = go []
  where
    go acc bs
      | BS.null bs = (reverse acc, BS.empty)
      | otherwise =
          let (line, rest) = BS.break (== 10) bs
              rest' = BS.drop 1 rest
           in if BS.null line
                then (reverse acc, rest')
                else
                  if BS.head line == 32
                    then go acc rest'
                    else
                      let (k, v) = BS.break (== 32) line
                       in go ((k, BS.drop 1 v) : acc) rest'

lastHeader :: String -> [(ByteString, ByteString)] -> Maybe ByteString
lastHeader k hs = case [v | (k', v) <- hs, k' == BC.pack k] of
  [] -> Nothing
  vs -> Just (last vs)

-- | Parse a commit payload.  Fails on a @tree@ or @parent@ header that is not
-- a 40-digit id.
parseCommit :: ByteString -> Either String Commit
parseCommit payload = do
  let (hs, msg) = splitHeaders payload
  tree <- case lastHeader "tree" hs of
    Nothing -> Right Nothing
    Just v -> maybe (Left "bad tree header") (Right . Just) (objectIdFromHex v)
  parents <- mapM (maybe (Left "bad parent header") Right . objectIdFromHex) [v | (k, v) <- hs, k == BC.pack "parent"]
  let ident k = maybe (Ident BS.empty 0) parseIdent (lastHeader k hs)
  pure (Commit tree parents (ident "author") (ident "committer") msg)

parseIdent :: ByteString -> Ident
parseIdent line =
  case BC.break (== '<') line of
    (name, rest)
      | BS.null rest -> Ident (rstrip line) 0
      | otherwise ->
          let afterGt = BS.drop 1 (BC.dropWhile (/= '>') rest)
              noSpace = BC.dropWhile (== ' ') afterGt
              noSign = if BS.take 1 noSpace `elem` [BC.pack "+", BC.pack "-"] then BS.drop 1 noSpace else noSpace
              digits = BC.takeWhile (\c -> c >= '0' && c <= '9') noSign
           in Ident (rstrip name) (readDecimal digits)

-- | The subject of a commit: the first paragraph of the message, with each
-- line stripped and the lines joined by single spaces.
commitSubject :: Commit -> ByteString
commitSubject c =
  let ls = map rstrip (BS.split 10 (commitMessage c))
      para = takeWhile (not . BS.null) (dropWhile BS.null ls)
   in BS.intercalate (BC.pack " ") para

------------------------------------------------------------------------------
-- Trees

-- | One entry of a tree.
data TreeEntry = TreeEntry
  { entryMode :: !Int
    -- ^ the mode as a number (e.g. @0o100644@)
  , entryName :: !ByteString
  , entryId :: !ObjectId
  }
  deriving (Eq, Show)

-- | Is the mode that of a subtree?
modeIsTree :: Int -> Bool
modeIsTree m = m .&. 0o170000 == 0o040000

-- | The object type an entry points at, decided by the high bits of its mode.
entryType :: TreeEntry -> ObjectType
entryType e = case entryMode e .&. 0o170000 of
  0o040000 -> TTree
  0o160000 -> TCommit
  _ -> TBlob

-- | Parse a tree payload, keeping the stored order.
parseTree :: ByteString -> Either String [TreeEntry]
parseTree bs
  | BS.null bs = Right []
  | otherwise = do
      let (modeS, r1) = BS.break (== 32) bs
          (name, r2) = BS.break (== 0) (BS.drop 1 r1)
          raw = BS.take 20 (BS.drop 1 r2)
      if BS.null r1 || BS.null r2 || BS.length raw /= 20 || BS.null modeS
        || not (BS.all (\c -> c >= 48 && c <= 55) modeS)
        then Left "malformed tree entry"
        else do
          oid <- maybe (Left "bad id") Right (objectIdFromBytes raw)
          let mode = BS.foldl' (\a c -> a * 8 + fromIntegral c - 48) 0 modeS
          rest <- parseTree (BS.drop 21 r2)
          Right (TreeEntry mode name oid : rest)

------------------------------------------------------------------------------
-- Tags

-- | The headers of a tag object that matter here.
data Tag = Tag
  { tagTarget :: !ObjectId
  , tagTargetType :: !(Maybe ByteString)
  , tagName :: !ByteString
  }
  deriving (Eq, Show)

-- | Parse a tag payload; fails without a valid @object@ header.
parseTag :: ByteString -> Either String Tag
parseTag payload = do
  let (hs, _) = splitHeaders payload
  target <- maybe (Left "tag without object header") Right (lastHeader "object" hs >>= objectIdFromHex)
  pure (Tag target (lastHeader "type" hs) (fromMaybe BS.empty (lastHeader "tag" hs)))
