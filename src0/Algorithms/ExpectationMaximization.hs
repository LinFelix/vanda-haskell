-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) Matthias Büchse, Toni Dietze 2011
-- License     :  BSD-style
--
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

module Algorithms.ExpectationMaximization (
  forestEM,
  forestEMlist,
  forestEMstep,
  forestEMstepList,
  normalize
) where

import Algorithms.InsideOutsideWeights
import Data.Hypergraph
import Tools.Miscellaneous (mapSnd)
import Data.Maybe (fromJust)

import qualified Data.List as L
import qualified Data.Map as M

-- | Canonical iter function.
iter
  :: (a -> a) -- ^ function to be iterated
  -> (a -> a -> Int -> Bool) -- ^ stopping condition
  -> a        -- ^ initial value
  -> a        -- ^ value after iteration
iter = iter' 0 where
  iter' i f p a
    = let fa = f a
      in
        if p a fa i
        then fa
        else iter' (i+1) f p fa

-- | Execute the forest-EM algorithm, i.e., iterate the EM step.
forestEM
  :: (Converging w, RealFloat w, Ord i, Ord v)
  => [[i]]                -- ^ partition of the ids for normalization
  -> [(v, Hypergraph v l w j, w)]
                          -- ^ a list of training example derivation forests
  -> (Hyperedge v l w j -> i)
                          -- ^ function extracting the id from a 'Hyperedge'
  -> (w -> Int -> Bool)   -- ^ stopping cond. (delta-likelihood, no. of iter.)
  -> M.Map i w            -- ^ initial weight vector
  -> M.Map i w
forestEM part gs exId p i
  = snd $ iter (forestEMstep part gs exId) p' (0,i) where
    p' (l1,_) (l2,_) it = p (abs (l2-l1)) it

-- | Compute the list of EM estimates for a given corpus.
-- Use 'take' or '!!' to access a prefix or an element, respectively.
forestEMlist
  :: (Converging w, RealFloat w, Ord i, Ord v)
  => [[i]]                -- ^ partition of the ids for normalization
  -> [(v, Hypergraph v l w j, w)]
                          -- ^ a list of training example derivation forests
  -> (Hyperedge v l w j -> i)
                          -- ^ function extracting the id from a 'Hyperedge'
  -> M.Map i w            -- ^ initial weight vector
  -> [(w, M.Map i w)]     -- ^ list of (log-likelihood, estimate) pairs
forestEMlist part gs exId i
  = iterate (forestEMstep part gs exId) (0, i)

-- | Normalize a map according to a partition. Very similar to
-- relative-frequency estimation, only that the corpus is partitioned,
-- that is, it actually represents a bunch of corpora.
normalize
  :: (RealFloat w, Ord i)
  => [[i]]
  -> M.Map i w
  -> M.Map i w
normalize part m
  = M.fromList (concatMap handleClass part)
  where
    handleClass is
      | isInfinite factor = zip is ws
      | otherwise         = zip is (map (factor *) ws)
      where
        ws = map (\ i -> M.findWithDefault 0 i m) is
        factor = recip (sum ws)

-- | Do an EM-step. The arguments are as for 'forestEM', only without the
-- stopping condition.
forestEMstep
  :: (Converging w, RealFloat w, Ord i, Ord v)
  => [[i]]                -- ^ partition of the ids for normalization
  -> [(v, Hypergraph v l w j, w)]
                          -- ^ a list of training-example derivation forests
  -> (Hyperedge v l w j -> i)
                          -- ^ function extracting the id from a 'Hyperedge'
  -> (w, M.Map i w)       -- ^ log-likelihood and weight vector before...
  -> (w, M.Map i w)       -- ^ ... and after the step
forestEMstep part gs exId theta
  = mapSnd (normalize part)
  . foldl'Special
      (+)
      (L.foldl' (\ m (k, v) -> M.insertWith' (+) k v m))
      (0, M.empty)
  $ forestEMstepList gs exId theta where
    foldl'Special f g
      = L.foldl'
        (\ (x, y) (x', y', _, _) -> x `seq` y `seq` (f x x', g y y'))
    -- ( sum . fst . unzip $ list
    -- , normalize part $ M.fromListWith (+) (concat . snd . unzip $ list)
    -- )

-- | Compile a list of everything that is necessary to complete an EM step.
-- Each entry corresponds to a training example (a forest), and it consists of
-- the log-likelihood contribution of that forest, a list of id-weight pairs
-- for later id-specific summation, and the inner and outer vectors for
-- that forest (not strictly necessary for further processing, but nice for
-- documentation).
forestEMstepList
  :: (Converging w, Floating w, Ord i, Ord v)
  => [(v, Hypergraph v l w j, w)]
                          -- ^ a list of training-example derivation forests
  -> (Hyperedge v l w j -> i)
                          -- ^ function extracting the id from a 'Hyperedge'
  -> (w, M.Map i w)       -- ^ log-likelihood and weight vector prior to step
  -> [(w, [(i, w)], M.Map v w, M.Map v w)] -- ^ (see general info)
forestEMstepList gs exId (_,theta)
  = [
      ( w * log innerv0 -- contribution to log-likelihood
      , [ -- a list of id/weight pairs for upcoming id-specific summation
          ( exId e
          , factor
            * M.findWithDefault 0 (eHead e) outer
            * exweight e
            * (product [ M.findWithDefault 0 v inner | v <- eTail e ])
          )
        | e <- edges g -- for each hyperedge in the forest
        ]
      , inner -- for debug/documentation purposes (teaching)
      , outer -- for debug/documentation purposes (teaching)
      )
    | (v0, g, w) <- gs -- for each forest
    , let inner = inside exweight g -- compute inside weights
    , let outer = outside exweight inner v0 g -- compute outside weights
    , let innerv0 = fromJust $ M.lookup v0 inner -- inner of target node
    , let factor = w/innerv0 -- example-specific factor for id significance
    ] where
    exweight e = M.findWithDefault 0 (exId e) theta
