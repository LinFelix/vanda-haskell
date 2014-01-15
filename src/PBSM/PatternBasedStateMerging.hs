{-# LANGUAGE ScopedTypeVariables #-}

module PBSM.PatternBasedStateMerging where


import PBSM.Types

import Prelude hiding (any)

import Control.Arrow
import Data.Foldable (any)
import Data.Function (on)
import Data.List (foldl', maximumBy, partition)
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Tree

import Test.QuickCheck

-- import Debug.Trace


forestToGrammar :: Ord t => Forest t -> RTG (SForest t) t
forestToGrammar corpus
  = rtg (map S.singleton corpus)
  $ concatMap go corpus
  where
    go :: Tree t -> [Rule (S.Set (Tree t)) t]
    go t@(Node x ts)
      = Rule (S.singleton t) x (map S.singleton ts)
      : concatMap go ts


unknownTerminals :: Ord t => RTG n t -> Tree t -> S.Set (t, Int)
unknownTerminals g tree
  = terminalsTrees S.\\ terminalsG
  where
    terminalsG
      = S.fromList $ map (\ (_, t, i) -> (t, i)) $ M.keys $ ruleM g
    terminalsTrees
      = S.fromList $ flattenWithRank tree
    flattenWithRank (Node x ts)
      = (x, length ts) : concatMap flattenWithRank ts


generalize
  :: forall n t. (Ord n, Ord t)
  => ([n] -> n) -> RTG n t -> [Tree t] -> RTG n t
generalize merger = foldl' step
  where
    step :: RTG n t -> Tree t -> RTG n t
    step g t
      | not $ S.null nS' = g
      | S.null nS = step (descend merger g t (initialS g)) t
      | otherwise = g{initialS = S.insert (head $ S.toList nS) (initialS g)}
      where
        nS = derivable g t
        nS' = S.intersection nS $ initialS g


derivable :: forall n t. (Ord n, Ord t) => RTG n t -> Tree t -> S.Set n
derivable g = foldTree step
  where
    foldTree :: (a -> [b] -> b) -> Tree a -> b
    foldTree f = go where go (Node x ts) = f x (map go ts)

    step :: t -> [S.Set n] -> S.Set n
    step t nSs
      = M.keysSet
      $ M.filter (any $ and . zipWith (flip S.member) nSs)
      $ M.findWithDefault M.empty (t, length nSs) rM

    -- | memoization
    rM :: M.Map (t, Int) (M.Map n (S.Set [n]))
    rM = ruleM' g


derivableIncomplete
  :: forall e n t. (Evaluation e, Ord n, Ord t)
  => RTG n t -> Tree t -> TotalMap n (Tree (n, Either (Tree t) t), e)
derivableIncomplete g = go
  where
    go :: Tree t -> TotalMap n (Tree (n, Either (Tree t) t), e)
    go t@(Node terminal ts)
      = TotalMap
          (\ n -> (Node (n, Left t) [], evalFail))
          ( M.mapWithKey (\ n
            -> maximumBy (compare `on` snd)
              . map
                ( first (Node (n, Right terminal))
                . second evalStep
                . unzip
                . zipWith (flip lookupTM) (map go ts)
                )
              . S.toList
              )
            $ M.findWithDefault M.empty (terminal, length ts) rM
          )

    -- | memoization
    rM :: M.Map (t, Int) (M.Map n (S.Set [n]))
    rM = ruleM' g


data TotalMap k a = TotalMap (k -> a) (M.Map k a)

lookupTM :: Ord k => k -> TotalMap k a -> a
lookupTM k (TotalMap d m) = M.findWithDefault (d k) k m


class Ord e => Evaluation e where
  evalFail :: e
  evalStep :: [e] -> e


data Eval = Eval !Int !Int deriving (Eq, Ord, Read, Show)

instance Evaluation Eval where
  evalFail = Eval 0 (-1)
  evalStep = foldl' plus (Eval 1 0)
    where
      (Eval x1 y1) `plus` (Eval x2 y2) = Eval (x1 + x2) (y1 + y2)


descend
  :: forall n t. (Ord n, Ord t)
  => ([n] -> n) -> RTG n t -> Tree t -> S.Set n -> RTG n t
descend merger g t nS
  = if null underivableTrees
    then merge merger g merges
    else descend merger g (head underivableTrees) (nonterminalS g)
  where
    holes :: [(n, Tree t, S.Set n)]
    holes
      = [ (n, t', derivable g t')
        | let d = fst
                $ maximumBy ((compare :: Eval -> Eval -> Ordering) `on` snd)
                $ map (`lookupTM` derivableIncomplete g t)
                $ S.toList nS
        , (n, Left t') <- flatten d
        ]

    underivableTrees :: [Tree t]
    underivableTrees = [t' | (_, t', nS') <- holes, S.null nS']

    merges :: [[n]]
    merges = [n : S.toList nS' | (n, _, nS') <- holes]


merge :: (Ord n, Ord t) => ([n] -> n) -> RTG n t -> [[n]] -> RTG n t
merge merger g nss
  = mapNonterminals mapState g
  where
    mapState q = M.findWithDefault q q mapping
    mapping
      = M.fromList
          [ (x, merged)
          | xs <- map S.toList $ unionOverlaps $ map S.fromList nss
          , let merged = merger xs
          , x <- xs
          ]


unionOverlaps :: Ord a => [S.Set a] -> [S.Set a]
unionOverlaps [] = []
unionOverlaps (x : xs)
  = case partition (S.null . S.intersection x) xs of
      (ys, []) -> x : unionOverlaps ys
      (ys, zs) -> unionOverlaps (S.unions (x : zs) : ys)


-- QuickCheck Tests ----------------------------------------------------------

prop_generalizeCounting :: Property
prop_generalizeCounting
  = forAll (fmap abs arbitrarySizedIntegral) $ \ inc ->
      let grammar1 = forestToGrammar [linearTrees !! inc]
          grammar2 = generalize S.unions grammar1 [linearTrees !! (2 * inc)]
      in not $ S.null
      $ S.intersection (initialS grammar2)
      $ derivable grammar2
      $ linearTrees !! (3 * inc)
  where
    linearTrees = Node "a" [] : map (\ t -> Node "g" [t]) linearTrees


instance Arbitrary Eval where
  arbitrary = uncurry Eval `fmap` arbitrary
  shrink (Eval x y) = map (uncurry Eval) $ shrink (x, y)


prop_Evaluation :: Evaluation e => [[e]] -> Property
prop_Evaluation ess
  = not (any null ess)
  ==> evalStep (map maximum ess) == maximum (map evalStep $ sequence ess)