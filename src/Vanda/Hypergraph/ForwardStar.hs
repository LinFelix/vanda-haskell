-- (c) 2012 Matthias Büchse <Matthias.Buechse@tu-dresden.de>
--
-- Technische Universität Dresden / Faculty of Computer Science / Institute
-- of Theoretical Computer Science / Chair of Foundations of Programming
--
-- Redistribution and use in source and binary forms, with or without
-- modification, is ONLY permitted for teaching purposes at Technische
-- Universität Dresden AND IN COORDINATION with the Chair of Foundations
-- of Programming.
-- ---------------------------------------------------------------------------

-- |
-- Maintainer  :  Matthias Buechse
-- Stability   :  unknown
-- Portability :  portable
--
-- This module makes 'ForwardStar' a 'Hypergraph' instance.
module Vanda.Hypergraph.ForwardStar
  ( module Vanda.Hypergraph.Basic
  , edgeCount
  , filterEdges
  , fromEdgeList
  , mapLabels
  , mapNodes
  , memoize
  , toEdgeList
  ) where

import Control.Arrow ( (***) )
import qualified Data.Array as A
import qualified Data.Ix as Ix
import qualified Data.Set as S
import qualified Data.Map as M

import Vanda.Hypergraph.Basic

edgeCount :: Ix.Ix v => ForwardStar v l i -> Int
edgeCount (ForwardStar sts lst f _)
  = (length lst+) $ sum $ map (length . f) (S.toList sts)

filterEdges
  :: (Hyperedge v l i -> Bool) -> ForwardStar v l i -> ForwardStar v l i
filterEdges p (ForwardStar vs lst f _)
  = ForwardStar vs (filter p lst) (filter p . f) False

fromEdgeList :: Ord v => EdgeList v l i -> ForwardStar v l i
fromEdgeList (EdgeList vs es) = ForwardStar vs lst (a M.!) True
  where
    lst = [ e | e <- es, null (from e) ]
    lst' = [ (v, [e])
           | e <- es
           , let from' = from e
           , not . null $ from'
           , v <- S.toList . S.fromList $ from'
           ]
    a = M.union 
        (M.fromListWith (++) lst')
        (M.fromList $ zip (S.toList vs) $ repeat [])
        --A.accumArray (flip (:)) [] (nodesR es) lst'

mapLabels
  :: (Hyperedge v l i -> Hyperedge v l' i')
  -> ForwardStar v l i
  -> ForwardStar v l' i'
mapLabels g (ForwardStar vs lst f _)
  = ForwardStar vs (map g lst) (map g . f) False

mapNodes
  :: (Ix.Ix v, Ix.Ix v')
  => (v -> v') -> ForwardStar v l i -> ForwardStar v' l i
mapNodes g (ForwardStar vs lst f _)
  = ForwardStar vs' (map (mapHE g) lst) (a M.!) True
  where
    vs' = S.fromList $ map g $ S.toList vs --  (g *** g) vs
    a = M.fromListWith (++) [ (g v, map (mapHE g) (f v)) | v <- S.toList vs ]
        -- A.array vs' [ (g v, map (mapHE g) (f v)) | v <- S.toList vs ]

memoize :: Ix.Ix v => ForwardStar v l i -> ForwardStar v l i
memoize fs@(ForwardStar vs lst f mem)
  | mem = fs -- idempotent
  | otherwise = ForwardStar vs lst (a M.!) True
  where
    a = M.fromListWith (++) [ (v, f v) | v <- S.toList vs ]
        -- A.array vs [ (v, f v) | v <- Ix.range vs ]

toEdgeList :: Ix.Ix v => ForwardStar v l i -> EdgeList v l i
toEdgeList (ForwardStar vs lst f _)
  = EdgeList vs $ lst ++ concatMap f (S.toList vs)


