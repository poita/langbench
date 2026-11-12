-- | Helpers for building throw-away repositories on disk in tests: loose
-- objects, packs with delta entries and refs.  Compression uses stored
-- DEFLATE blocks, which is enough for the reader under test.
module TestRepo
  ( zlibStored
  , looseFile
  , PackItem (..)
  , buildPack
  , withTempDir
  , writeLoose
  , writeFileAt
  , varintLE
  , copyAll
  , insertOp
  ) where

import Control.Exception (bracket)
import Data.Bits (Bits, shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (sortOn)
import Data.Word (Word8)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Temp (mkdtemp)

import Git.Inflate (adler32)
import Git.Object
import Git.Types

-- | A valid zlib stream made of stored blocks.
zlibStored :: BS.ByteString -> BS.ByteString
zlibStored bs = BS.concat ([BS.pack [0x78, 0x01]] ++ blocks bs ++ [be32 (adler32 bs)])
  where
    blocks s
      | BS.length s <= 65535 = [block 1 s]
      | otherwise = block 0 (BS.take 65535 s) : blocks (BS.drop 65535 s)
    block final s =
      let n = BS.length s
       in BS.concat [BS.pack [final, fromIntegral n, fromIntegral (n `shiftR` 8), fromIntegral (complementW n), fromIntegral (complementW n `shiftR` 8)], s]
    complementW n = 0xffff - n

be32 :: (Integral a, Bits a) => a -> BS.ByteString
be32 x = BS.pack [fromIntegral (x `shiftR` s) | s <- [24, 16, 8, 0]]

-- | The on-disk bytes of a loose object.
looseFile :: RawObject -> BS.ByteString
looseFile = zlibStored . storedForm

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir act = do
  tmp <- getTemporaryDirectory
  bracket (mkdtemp (tmp </> "gitrepo-test-")) removeDirectoryRecursive act

writeFileAt :: FilePath -> FilePath -> BS.ByteString -> IO ()
writeFileAt root rel bytes = do
  let p = root </> rel
  createDirectoryIfMissing True (takeDirectory p)
  BS.writeFile p bytes

-- | Write a loose object under @root/objects@ and return its id.
writeLoose :: FilePath -> RawObject -> IO ObjectId
writeLoose root o = do
  let oid = hashObject o
      hex = BC.unpack (objectIdToHex oid)
  writeFileAt root ("objects" </> take 2 hex </> drop 2 hex) (looseFile o)
  pure oid

-- | An entry of a pack to build.
data PackItem
  = Whole RawObject
  | OfsOf Int RawObject RawObject
    -- ^ @OfsOf i base target@: a delta against the item at position @i@
  | RefOf RawObject RawObject
    -- ^ @RefOf base target@: a delta against the object named by id

varintLE :: Int -> [Word8]
varintLE n
  | n < 128 = [fromIntegral n]
  | otherwise = fromIntegral (n .&. 127 .|. 128) : varintLE (n `shiftR` 7)

-- | A delta op copying the first @n@ bytes of the base.
copyAll :: Int -> BS.ByteString
copyAll n = BS.pack ([0xB0] ++ [fromIntegral n, fromIntegral (n `shiftR` 8)])

-- | A delta op inserting up to 127 literal bytes.
insertOp :: BS.ByteString -> BS.ByteString
insertOp s = BS.cons (fromIntegral (BS.length s)) s

-- | Build a @.pack@ and a matching version 2 @.idx@.  Each delta item
-- replaces @target@ with @base <> extra@-style content given by the caller:
-- the delta copies the whole base and appends the bytes of @target@ that
-- come after it, so @target@'s payload must start with @base@'s.
buildPack :: [PackItem] -> (BS.ByteString, BS.ByteString)
buildPack items = (pack, idx)
  where
    header = BS.concat [BC.pack "PACK", be32 (2 :: Int), be32 (length items)]
    encoded = go 12 [] items
    go _ _ [] = []
    go off offs (it : rest) =
      let (bytes, o) = encode off offs it
          next = off + BS.length bytes
       in (off, bytes, o) : go next (offs ++ [off]) rest
    offsetsList = [off | (off, _, _) <- encoded]
    encode off _ item = case item of
      Whole o -> (entry (typeNum (objectType o)) (BS.length (objectPayload o)) BS.empty (zlibStored (objectPayload o)), o)
      OfsOf i base target ->
        let d = mkDelta base target
            rel = off - offsetsList !! i
         in (entry 6 (BS.length d) (ofsEnc rel) (zlibStored d), target)
      RefOf base target ->
        let d = mkDelta base target
         in (entry 7 (BS.length d) (objectIdBytes (hashObject base)) (zlibStored d), target)
    pack = BS.concat (header : [b | (_, b, _) <- encoded] ++ [BS.replicate 20 0])
    objects = sortOn fst [(hashObject o, off) | (off, _, o) <- encoded]
    idx =
      BS.concat
        ( [BS.pack [0xff, 0x74, 0x4f, 0x63], be32 (2 :: Int)]
            ++ [be32 (length (filter ((<= b) . BS.head . objectIdBytes . fst) objects)) | b <- [0 .. 255 :: Word8]]
            ++ map (objectIdBytes . fst) objects
            ++ map (const (be32 (0 :: Int))) objects
            ++ map (be32 . snd) objects
            ++ [BS.replicate 40 0]
        )

typeNum :: ObjectType -> Int
typeNum TCommit = 1
typeNum TTree = 2
typeNum TBlob = 3
typeNum TTag = 4

entry :: Int -> Int -> BS.ByteString -> BS.ByteString -> BS.ByteString
entry ty size extra z = BS.concat [BS.pack (hdr size), extra, z]
  where
    hdr n
      | n < 16 = [fromIntegral (ty `shiftL` 4 .|. n)]
      | otherwise = fromIntegral (0x80 .|. ty `shiftL` 4 .|. (n .&. 15)) : more (n `shiftR` 4)
    more n
      | n < 128 = [fromIntegral n]
      | otherwise = fromIntegral (0x80 .|. (n .&. 127)) : more (n `shiftR` 7)

ofsEnc :: Int -> BS.ByteString
ofsEnc n = BS.pack (reverse (fromIntegral (n .&. 127) : rest (n `shiftR` 7)))
  where
    rest 0 = []
    rest m = fromIntegral (0x80 .|. ((m - 1) .&. 127)) : rest ((m - 1) `shiftR` 7)

mkDelta :: RawObject -> RawObject -> BS.ByteString
mkDelta base target =
  BS.concat
    [ BS.pack (varintLE (BS.length bp))
    , BS.pack (varintLE (BS.length tp))
    , copyAll (BS.length bp)
    , insertOp (BS.drop (BS.length bp) tp)
    ]
  where
    bp = objectPayload base
    tp = objectPayload target
