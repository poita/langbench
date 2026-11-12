{-# LANGUAGE BangPatterns #-}

-- | The RGBA canvas, the anti-aliased scanline polygon filler, layer
-- compositing and the PPM encoder (SPEC §8.3 – §8.5).
--
-- The canvas stores colour channels already multiplied by alpha, which is
-- what the source-over recurrences of the specification produce.
--
-- Coverage is computed with 64 sub-scanlines per pixel row, using an
-- active-edge sweep: edges are sorted once, only sub-scanlines that have
-- active edges are visited, the active set is kept in x order by insertion
-- sort, and per-row coverage is accumulated per span in O(1) with a
-- difference array. The work for a fill is therefore proportional to the
-- edges, spans and pixels it touches, never to the whole canvas.
module Graphics.SVG.Raster.Canvas
  ( Canvas
  , canvasWidth
  , canvasHeight
  , newCanvas
  , FillRule (..)
  , fillPolygons
  , compositeLayer
  , readPixel
  , canvasToPPM
  , subScanlines
  ) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST)
import Data.Array.Base (unsafeAt, unsafeFreeze, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray)
import Data.Array.Unboxed (UArray, listArray)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (sortOn)
import Data.Word (Word8)

import Graphics.SVG.Raster.Geometry (Point (..))

-- | A mutable canvas of @width * height@ pixels, four 'Double's each
-- (premultiplied red, green, blue and alpha), initially all zero.
data Canvas s = Canvas
  { canvasWidth :: !Int
  , canvasHeight :: !Int
  , _canvasData :: !(STUArray s Int Double)
  }

-- | A fully transparent canvas.
newCanvas :: Int -> Int -> ST s (Canvas s)
newCanvas w h = Canvas w h <$> newArray (0, max 0 (4 * w * h - 1)) 0

-- | Read a pixel as @(r, g, b, a)@ (premultiplied).
readPixel :: Canvas s -> Int -> Int -> ST s (Double, Double, Double, Double)
readPixel (Canvas w _ d) x y = do
  let i = 4 * (y * w + x)
  (,,,) <$> unsafeRead d i <*> unsafeRead d (i + 1) <*> unsafeRead d (i + 2) <*> unsafeRead d (i + 3)

-- | The fill rule used to decide which points are inside.
data FillRule = NonZero | EvenOdd
  deriving (Eq, Show)

-- | Number of sub-scanlines per pixel row.
subScanlines :: Int
subScanlines = 64

data Edge = Edge
  { _eS0 :: !Int -- first sub-scanline covered
  , _eS1 :: !Int -- one past the last
  , _eDir :: !Int
  , _eX :: !Double -- x at y = eY
  , _eY :: !Double
  , _eSlope :: !Double -- dx/dy
  }

buildEdges :: Int -> [[Point]] -> [Edge]
buildEdges h polys = sortOn (\(Edge s0 _ _ _ _ _) -> s0) (concatMap polyEdges polys)
  where
    hs = fromIntegral (h * subScanlines) :: Double
    polyEdges [] = []
    polyEdges ps@(p0 : _) = catMaybesE (zipWith edge ps (drop 1 ps ++ [p0]))
    catMaybesE es = [e | Just e <- es]
    sc y = ceiling (max 0 (min hs (y * fromIntegral subScanlines - 0.5))) :: Int
    edge (Point x0 y0) (Point x1 y1)
      | bad x0 || bad y0 || bad x1 || bad y1 || y0 == y1 = Nothing
      | otherwise =
          let (xa, ya, xb, yb, dir) = if y0 < y1 then (x0, y0, x1, y1, 1) else (x1, y1, x0, y0, -1)
              s0 = sc ya
              s1 = sc yb
           in if s0 >= s1 then Nothing else Just (Edge s0 s1 dir xa ya ((xb - xa) / (yb - ya)))
    bad v = isNaN v || isInfinite v

-- | Fill the union/interior of the polygons (each implicitly closed) with
-- the given colour (channels in @[0,1]@) and paint opacity, compositing
-- source-over onto the canvas.
fillPolygons :: forall s. Canvas s -> FillRule -> (Double, Double, Double) -> Double -> [[Point]] -> ST s ()
fillPolygons (Canvas w h dat) rule (cr, cg, cb) pa polys
  | pa <= 0 = pure ()
  | otherwise = when (n > 0) $ do
      act <- newArray (0, n - 1) 0 :: ST s (STUArray s Int Int)
      xs <- newArray (0, n - 1) 0 :: ST s (STUArray s Int Double)
      acc <- newArray (0, w + 1) 0 :: ST s (STUArray s Int Double)
      dif <- newArray (0, w + 1) 0 :: ST s (STUArray s Int Double)
      sweep act xs acc dif
  where
    edges = buildEdges h polys
    n = length edges
    eS0, eS1, eDir :: UArray Int Int
    eS0 = listArray (0, n - 1) [a | Edge a _ _ _ _ _ <- edges]
    eS1 = listArray (0, n - 1) [a | Edge _ a _ _ _ _ <- edges]
    eDir = listArray (0, n - 1) [a | Edge _ _ a _ _ _ <- edges]
    eX, eY, eSl :: UArray Int Double
    eX = listArray (0, n - 1) [a | Edge _ _ _ a _ _ <- edges]
    eY = listArray (0, n - 1) [a | Edge _ _ _ _ a _ <- edges]
    eSl = listArray (0, n - 1) [a | Edge _ _ _ _ _ a <- edges]
    wD = fromIntegral w :: Double
    inside :: Int -> Bool
    inside wn = case rule of
      NonZero -> wn /= 0
      EvenOdd -> odd wn

    sweep :: STUArray s Int Int -> STUArray s Int Double -> STUArray s Int Double -> STUArray s Int Double -> ST s ()
    sweep act xs acc dif = loop 0 0 0 (-1) w (-1)
      where
        loop :: Int -> Int -> Int -> Int -> Int -> Int -> ST s ()
        loop !s0 !ne !na !row !lo !hi
          | na == 0 && ne >= n = flush row lo hi
          | otherwise = do
              let s = if na == 0 then max s0 (unsafeAt eS0 ne) else s0
                  row' = s `quot` subScanlines
              (lo1, hi1) <-
                if row' /= row
                  then flush row lo hi >> pure (w, -1)
                  else pure (lo, hi)
              -- add edges that start at or before this sub-scanline
              let addNew !k
                    | k < n && unsafeAt eS0 k <= s = unsafeWrite act (na + k - ne) k >> addNew (k + 1)
                    | otherwise = pure k
              ne' <- addNew ne
              let na1 = na + (ne' - ne)
                  ys = (fromIntegral s + 0.5) / fromIntegral subScanlines :: Double
                  -- drop finished edges, compute crossings
                  compact !k !m
                    | k >= na1 = pure m
                    | otherwise = do
                        e <- unsafeRead act k
                        if unsafeAt eS1 e > s
                          then do
                            unsafeWrite act m e
                            unsafeWrite xs m (unsafeAt eX e + (ys - unsafeAt eY e) * unsafeAt eSl e)
                            compact (k + 1) (m + 1)
                          else compact (k + 1) m
              m <- compact 0 0
              insertionSort act xs m
              (lo2, hi2) <- spans act xs acc dif m lo1 hi1
              loop (s + 1) ne' m row' lo2 hi2

        spans act' xs' acc' dif' m lo0 hi0 = go 0 (0 :: Int) 0 lo0 hi0
          where
            go !k !wn !startX !lo !hi
              | k >= m = pure (lo, hi)
              | otherwise = do
                  e <- unsafeRead act' k
                  x <- unsafeRead xs' k
                  let wn' = wn + unsafeAt eDir e
                      was = inside wn
                      now = inside wn'
                  if not was && now
                    then go (k + 1) wn' x lo hi
                    else
                      if was && not now
                        then do
                          (lo', hi') <- addSpan acc' dif' startX x lo hi
                          go (k + 1) wn' startX lo' hi'
                        else go (k + 1) wn' startX lo hi

        addSpan acc' dif' xa0 xb0 lo hi = do
          let xa = max 0 xa0
              xb = min wD xb0
          if xb <= xa
            then pure (lo, hi)
            else do
              let ia = floor xa :: Int
                  ib = floor xb :: Int
              if ia == ib
                then addTo acc' ia (xb - xa)
                else do
                  addTo acc' ia (fromIntegral (ia + 1) - xa)
                  addTo acc' ib (xb - fromIntegral ib)
                  addTo dif' (ia + 1) 1
                  addTo dif' ib (-1)
              pure (min lo ia, max hi (min (w - 1) ib))

        addTo arr i v = unsafeRead arr i >>= \o -> unsafeWrite arr i (o + v)

        flush row lo hi = when (row >= 0 && lo <= hi) $ do
          let base = row * w
              go !i !run
                | i > hi = unsafeWrite dif (hi + 1) 0
                | otherwise = do
                    d <- unsafeRead dif i
                    a <- unsafeRead acc i
                    unsafeWrite dif i 0
                    unsafeWrite acc i 0
                    let run' = run + d
                        cov = (a + run') / fromIntegral subScanlines
                        alpha = min 1 (pa * cov)
                    when (alpha > 0) $ blend ((base + i) * 4) alpha
                    go (i + 1) run'
          go lo 0

        blend !p !alpha = do
          let k = 1 - alpha
          r <- unsafeRead dat p
          g <- unsafeRead dat (p + 1)
          b <- unsafeRead dat (p + 2)
          a <- unsafeRead dat (p + 3)
          unsafeWrite dat p (cr * alpha + r * k)
          unsafeWrite dat (p + 1) (cg * alpha + g * k)
          unsafeWrite dat (p + 2) (cb * alpha + b * k)
          unsafeWrite dat (p + 3) (alpha + a * k)

-- | Sort the first @m@ crossings by x, moving edge ids and x values together.
insertionSort :: STUArray s Int Int -> STUArray s Int Double -> Int -> ST s ()
insertionSort act xs m = outer 1
  where
    outer !i
      | i >= m = pure ()
      | otherwise = do
          x <- unsafeRead xs i
          e <- unsafeRead act i
          inner i x e
          outer (i + 1)
    inner !j !x !e
      | j == 0 = place 0 x e
      | otherwise = do
          px <- unsafeRead xs (j - 1)
          if px > x
            then do
              pe <- unsafeRead act (j - 1)
              unsafeWrite xs j px
              unsafeWrite act j pe
              inner (j - 1) x e
            else place j x e
    place j x e = unsafeWrite xs j x >> unsafeWrite act j e

-- | @compositeLayer dst src o@ composites the layer @src@ onto @dst@ with
-- group opacity @o@ (SPEC §8.4).
compositeLayer :: Canvas s -> Canvas s -> Double -> ST s ()
compositeLayer (Canvas w h dst) (Canvas _ _ src) o = go 0
  where
    total = w * h
    go !i
      | i >= total = pure ()
      | otherwise = do
          let p = 4 * i
          sa <- unsafeRead src (p + 3)
          when (sa > 0) $ do
            let k = 1 - sa * o
            forM_ [0 .. 3] $ \c -> do
              s <- unsafeRead src (p + c)
              d <- unsafeRead dst (p + c)
              unsafeWrite dst (p + c) (s * o + d * k)
          go (i + 1)

-- | Composite over opaque white and encode as a binary PPM (SPEC §2, §8.5).
canvasToPPM :: forall s. Canvas s -> ST s BS.ByteString
canvasToPPM (Canvas w h dat) = do
  frozen <- unsafeFreeze dat :: ST s (UArray Int Double)
  let byte :: Int -> Word8
      byte j =
        let (px, c) = j `quotRem` 3
            a = unsafeAt frozen (4 * px + 3)
            v = unsafeAt frozen (4 * px + c) + (1 - a)
         in floor (max 0 (min 1 v) * 255 + 0.5)
      body = fst (BS.unfoldrN (w * h * 3) (\j -> Just (byte j, j + 1)) 0)
      header = BC.pack ("P6\n" ++ show w ++ " " ++ show h ++ "\n255\n")
  pure (header <> body)
