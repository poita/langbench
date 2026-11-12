-- | The fixed constants of the Tessera format (SPEC §5.2).
module Tessera.Constants
  ( pageSize
  , maxKey
  , maxIndexKey
  , maxInline
  , ovfPayload
  , maxDoc
  , maxDepth
  , btreeHeader
  , capacity
  , minFill
  , maxIndexes
  , maxPath
  , maxPathSegments
  , walLimit
  , maxLimit
  ) where

-- | Bytes per page.
pageSize :: Int
pageSize = 1024

-- | Maximum primary key length in bytes.
maxKey :: Int
maxKey = 128

-- | Maximum index key length in bytes.
maxIndexKey :: Int
maxIndexKey = 128

-- | Document bytes held inline in a primary leaf cell.
maxInline :: Int
maxInline = 192

-- | Document bytes held in one overflow page.
ovfPayload :: Int
ovfPayload = 1012

-- | Maximum serialised document length.
maxDoc :: Int
maxDoc = 65536

-- | Maximum value nesting depth.
maxDepth :: Int
maxDepth = 32

-- | Bytes of page header on a B+tree page.
btreeHeader :: Int
btreeHeader = 16

-- | Payload bytes available on a B+tree page.
capacity :: Int
capacity = 1008

-- | Payload size below which a deletion triggers rebalancing.
minFill :: Int
minFill = 336

-- | Number of index directory slots.
maxIndexes :: Int
maxIndexes = 16

-- | Maximum field path text length.
maxPath :: Int
maxPath = 30

-- | Maximum number of segments in a field path.
maxPathSegments :: Int
maxPathSegments = 8

-- | Log size that triggers an automatic checkpoint.
walLimit :: Int
walLimit = 262144

-- | Largest accepted @limit@ argument.
maxLimit :: Int
maxLimit = 2147483647
