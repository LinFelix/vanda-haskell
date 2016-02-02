{-# LANGUAGE LambdaCase, RecordWildCards, ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.CBSM.CountBasedStateMerging
-- Copyright   :  (c) Technische Universität Dresden 2014
-- License     :  Redistribution and use in source and binary forms, with
--                or without modification, is ONLY permitted for teaching
--                purposes at Technische Universität Dresden AND IN
--                COORDINATION with the Chair of Foundations of Programming.
--
-- Maintainer  :  Toni.Dietze@tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

module Vanda.CBSM.CountBasedStateMerging
( Rule(..)
, CRTG(..)
, MergeTree(..)
, forestToGrammar
, Info(..)
, initialInfo
, cbsm
, normalizeLklhdByMrgdStates
, toHypergraph
, asBackwardStar
, bests
, cbsmStep2
, refineRanking
, mergeRanking
, enrichRanking
, ruleEquivalenceClasses
, forwardStar
, bidiStar
, likelihoodDelta
, saturateMerge
, sortedCartesianProductWith
, sortedCartesianProductWith'
) where


import qualified Control.Error
import           Data.Maybe.Extra (nothingIf)
import           Vanda.CBSM.Dovetailing
import           Vanda.CBSM.Merge (Merge)
import qualified Vanda.CBSM.Merge as Merge
import qualified Vanda.Features as F
import qualified Vanda.Hypergraph as H
import           Vanda.Util.Histogram (histogram)
import           Vanda.Util.Tree as T

import           Control.Applicative ((<*>), (<$>))
import           Control.Arrow ((***), first, second)
import           Control.Monad.State.Lazy
import           Control.Parallel.Strategies
import qualified Data.Binary as B
import           Data.List (foldl', groupBy, sortBy)
import           Data.List.Extra (minimaBy)
import           Data.Function (on)
import qualified Data.Map.Lazy as ML
import           Data.Map.Strict (Map, (!))
import qualified Data.Map.Strict as M
import           Data.Maybe
import           Data.Ord (comparing, Down(..))
import qualified Data.Set as S
import           Data.Set (Set)
import           Data.Tree
import           Data.Tuple (swap)
import qualified Data.Vector as V
import           Numeric.Log (Log(..))

import Debug.Trace


errorHere :: String -> String -> a
errorHere = Control.Error.errorHere "Vanda.CBSM.CountBasedStateMerging"


data Rule s t = Rule
  { to    :: !s
  , from  :: ![s]
  , label :: !t
  } deriving (Eq, Ord)

instance (Show s, Show t) => Show (Rule s t) where
  show Rule{..} = "Rule " ++ show to ++ " " ++ show from ++ " " ++ show label

instance (B.Binary v, B.Binary l) => B.Binary (Rule v l) where
  put (Rule x y z) = B.put x >> B.put y >> B.put z
  get = Rule <$> B.get <*> B.get <*> B.get


-- | Count RTG
data CRTG v l = CRTG
  { cntRule  :: !(Map (Rule v l) Int)
  , cntState :: !(Map v Int)
  , cntInit  :: !(Map v Int)
  } deriving Show

instance (B.Binary v, B.Binary l) => B.Binary (CRTG v l) where
  put (CRTG x y z) = B.put x >> B.put y >> B.put z
  get = CRTG <$> B.get <*> B.get <*> B.get


rules :: CRTG v l -> [Rule v l]
rules = M.keys . cntRule


type ForwardStar v l = Map v (Map l [Rule v l])


forwardStar :: (Ord v, Ord l) => [Rule v l] -> ForwardStar v l
forwardStar
  = fmap (M.fromListWith (++)) . M.fromListWith (++) . concatMap step
  where
    step r@(Rule _ vs l)
      = map (\ v -> (v, [(l, [r])]))
      $ (S.toList . S.fromList) vs


-- | bidirectional star: finding rules with state
type BidiStar v l = Map v [Rule v l]


bidiStar :: (Ord v, Ord l) => [Rule v l] -> BidiStar v l
bidiStar = M.fromListWith (++) . concatMap step
  where
    step r@(Rule v vs _)
      = map (\ v' -> (v', [r]))
      $ (S.toList . S.fromList) (v : vs)


{-
fromList :: (Ord s, Ord t) => [Rule s t] -> RTG s t
fromList = unions . concatMap step
  where
    step r@(Rule v vs l _) = singletonBW v l r : map (\ v' -> singletonFW v' l r) vs
    singletonBW v l r = M.singleton v $ M.singleton l (S.singleton r :-> S.empty)
    singletonFW v l r = M.singleton v $ M.singleton l (S.empty :-> S.singleton r)
    union = M.unionWith (M.unionWith unionRuleSets)
    unions = foldl' union M.empty
-}
{-
unionRuleSets
  :: (Ord l, Ord v) => RuleSets v l -> RuleSets v l -> RuleSets v l
unionRuleSets (bw1 :-> fw1) (bw2 :-> fw2)
  = (S.union bw1 bw2 :-> S.union fw1 fw2)
-}

toHypergraph
  :: (H.Hypergraph h, Ord v) => CRTG v l -> (h v l Double, Map v Double)
  -- not the most general type: Double is specific
toHypergraph CRTG{..}
  = ( H.mkHypergraph
      $ map (\ (Rule{..}, count) -> (H.mkHyperedge to from label
                       (fromIntegral count / fromIntegral (cntState M.! to))))
      $ M.toList cntRule
    , M.map (((1 / (fromIntegral $ sum $ M.elems cntInit)) *) . fromIntegral)
            cntInit
    )


bests :: (Ord v, Eq l) => CRTG v l -> [(Double, H.Derivation v l Double)]
bests g
  = mergesBy (comparing (Down . fst))
  $ M.elems
  $ M.intersectionWith (\ w' -> map (\ (F.Candidate w d _) -> (w' * w, d))) ini
--   $ M.map (map (\ (F.Candidate w d _) -> (w, d)))
  $ H.bests (asBackwardStar hg) feature (V.singleton 1)
  where
    (hg, ini) = toHypergraph g
    feature = F.Feature (\ _ i xs -> i * product xs) V.singleton


asBackwardStar :: H.BackwardStar v l i -> H.BackwardStar v l i
asBackwardStar = id


-- | Merge sorted lists to a single sorted list.
mergesBy :: (a -> a -> Ordering) -> [[a]] -> [a]
mergesBy cmp = foldl (mergeBy cmp) []


-- | Merge two sorted lists to a single sorted list.
mergeBy :: (a -> a -> Ordering) -> [a] -> [a] -> [a]
mergeBy cmp xs@(x:xs') ys@(y:ys')
  = case x `cmp` y of
      GT ->  y : mergeBy cmp xs  ys'
      _  ->  x : mergeBy cmp xs' ys
mergeBy _ [] ys = ys
mergeBy _ xs [] = xs


{-
data ShowTree a
  = a :< [ShowTree a]
  | L a
  deriving (Eq, Ord, Show)

showTree   (x `Node` []) = L x
showTree   (x `Node` ts) = x :<     map showTree   ts
unshowTree (L x        ) = x `Node` []
unshowTree (x :<     ts) = x `Node` map unshowTree ts
-}

newtype OrdTree a = OrdTree (Tree a) deriving Eq


unOrdTree :: OrdTree t -> Tree t
unOrdTree (OrdTree t) = t


instance Ord a => Ord (OrdTree a) where
  compare (OrdTree (Node x1 ts1)) (OrdTree (Node x2 ts2))
    = case compare x1 x2 of
        EQ -> compare (map OrdTree ts1) (map OrdTree ts2)
        o -> o


instance Show a => Show (OrdTree a) where
  showsPrec d (OrdTree (Node x [])) = showsPrec d x
  showsPrec _ (OrdTree (Node x ts)) = showsPrec 11 x . showsPrec 11 (map OrdTree ts)
--   show (OrdTree (Node x [])) = stripQuotes (show x)
--   show (OrdTree (Node x ts)) = stripQuotes (show x) ++ show (map OrdTree ts)

instance (B.Binary a) => B.Binary (OrdTree a) where
  put (OrdTree x) = B.put x
  get = OrdTree <$> B.get


{-
stripQuotes :: String -> String
stripQuotes cs@[_]                           = cs
stripQuotes cs@('"' : cs') | last cs' == '"' = init cs'
stripQuotes cs                               = cs


data Term a = Lit a
            | a :++ a
            | Term a :+ Term a
            | Term a :* Term a deriving (Read, Show)
infixl 6 :+
infixl 7 :*
infixl 5 :++

x1, x2 :: Term Int
x1 = Lit 1 :+ Lit 2 :* Lit 3
x2 = Lit 4 :* Lit 5 :+ Lit 6
x3 = OrdTree $ Node x1 [Node x2 [], Node x1 [Node x2 []]]
x4 = OrdTree $ Node x1 []
x5 = x4 :++ x4


instance Read a => Read (OrdTree a) where
  readsPrec d = readParen False $ \ cs0 ->
      [ (OrdTree (Node x (map unpack ts)), cs2)
      | (x , cs1) <- readsPrec d cs0
      , (ts, cs2) <- case lex cs1 of
                      ("(", _) : _ -> readsPrec 11 cs1
                      ("[", _) : _ -> readsPrec 11 cs1
                      _ ->  [([], cs1)]
      ]
    where unpack (OrdTree t) = t
-}

forestToGrammar
  :: Ord l
  => [Tree l]
  -> (CRTG Int l, Map Int (Tree l))
forestToGrammar corpus
  = ( CRTG
        (M.mapKeys toRule cntTrees)
        (M.mapKeysMonotonic (ints M.!) cntTrees)
        (M.mapKeysMonotonic (ints M.!) $ histogram $ map OrdTree corpus)
    , M.map unOrdTree $ M.fromAscList $ map swap $ M.toAscList $ ints
    )
  where
    cntTrees = histogram $ map OrdTree $ concatMap T.subTrees corpus
    ints = snd $ M.mapAccum (\ i _ -> (i + 1, i)) 0 $ cntTrees
    toRule t@(OrdTree (Node x ts))
      = Rule (ints M.! t) (map ((ints M.!) . OrdTree) ts) x


(****) :: (a -> b -> c) -> (d -> e -> f) -> (a, d) -> (b, e) -> (c, f)
f **** g = \ (xf, xg) (yf, yg) -> (f xf yf, g xg yg)
--       = uncurry (***) . (f *** g)
--(****) = ((uncurry (***) .) .) . (***)


-- cbsm :: CRTG v l -> [CRTG v l]
-- cbsm = iterate cbsmStep

-- cbsmStep :: CRTG v l -> CRTG v l



type MergeHistory v = Map v (MergeTree v)

data MergeTree v
  = State v Int              -- ^ state and count before any merge
  | Merge Int [MergeTree v]  -- ^ iteration and merged states


instance B.Binary a => B.Binary (MergeTree a) where
  put (State x i ) = B.putWord8 0 >> B.put x >> B.put i
  put (Merge i xs) = B.putWord8 1 >> B.put i >> B.put xs
  get = do ctor <- B.getWord8
           case ctor of
             0 -> State <$> B.get <*> B.get
             1 -> Merge <$> B.get <*> B.get
             _ -> errorHere "get/MergeTree" "invalid binary data"


instance Functor MergeTree where
  fmap f (State v i ) = State (f v) i
  fmap f (Merge i xs) = Merge i (fmap (fmap f) xs)


data Info v = Info
  { infoIteration :: !Int
  , infoMergePairs :: !Int
  , infoBeamWidth :: !Int
  , infoBeamIndex :: !Int
  , infoCandidateIndex :: !Int
  , infoMerge :: !(Merge v)
  , infoMergedRules :: !Int
  , infoMergedStates :: !Int
  , infoMergedInitials :: !Int
  , infoLikelihoodDelta :: !(Log Double)
  , infoEvaluation :: !(Log Double)
  , infoEvaluations :: ![Log Double]
  , infoEquivalentBeamIndizes :: ![Int]
  , infoMergeTreeMap :: !(MergeHistory v)
  }


instance (B.Binary v, Ord v) => B.Binary (Info v) where
  put (Info a b c d e f g h i j k l m n)
    = B.put a >> B.put b >> B.put c >> B.put d >> B.put e
   >> B.put f >> B.put g >> B.put h >> B.put i >> B.put j
   >> B.put k >> B.put l >> B.put m >> B.put n
  get = Info
    <$> B.get <*> B.get <*> B.get <*> B.get <*> B.get
    <*> B.get <*> B.get <*> B.get <*> B.get <*> B.get
    <*> B.get <*> B.get <*> B.get <*> B.get


initialInfo :: Map v Int -> Info v
initialInfo
  = Info 0 0 0 0 0 Merge.empty 0 0 0 1 1 [] []
  . M.mapWithKey State


cbsm
  :: (Ord v, Ord l)
  => [Set v]
  -> ((Int, Int, Int) -> Log Double -> Log Double)
  -> Int
  ->  (CRTG v l, Info v)
  -> [(CRTG v l, Info v)]
cbsm = cbsmGo M.empty


cbsmGo
  :: (Ord v, Ord l)
  => Map (v, v) (Merge v)
  -> [Set v]
  -> ((Int, Int, Int) -> Log Double -> Log Double)
  -> Int
  ->  (CRTG v l, Info v)
  -> [(CRTG v l, Info v)]
cbsmGo cache mergeGroups evaluate beamWidth prev@(g, info@Info{..})
  = (prev :)
  $ seq g
  $ seq info
  $ let n = infoIteration + 1
        likelihoodDelta' = likelihoodDelta g
        (mergePairs, cands)
          = sum *** processMergePairs
          $ unzip
          $ map (compileMergePairs $ cntState g) mergeGroups
        processMergePairs
          = take beamWidth  -- TODO: Group?
          . zipWith
              ( \ i (j, mv, m)
               -> let (l, sizes) = likelihoodDelta' m
                  in (i, j, mv, m, sizes, l, evaluate sizes l)
              ) [1 ..]
          . map (untilRight $ liftSat $ saturateMergeStep $ forwardStar $ rules g)
          . zipWith (\ j (mv, m) -> (j, mv, m)) [1 ..]
          . map ( \ (_, ((v1, _), (v2, _)))
                 -> (,) (v1, v2)
                  $ saturateMergeInit
                  $ ML.findWithDefault
                      (Merge.fromLists [[v1, v2]])
                      (v1, v2)
                      cache
                )
          . foldr1 (mergeSortedLists (comparing fst))
        liftSat f (x, y, m) = case f m of
          Left  l -> Left  (x, y, l)
          Right r -> Right (x, y, r)
        minimalCands
          = minimaBy (comparing (Down . (\ (_, _, _, _, _, _, x) -> x))) cands
        (indB, indC, mrgV, mrg, (mrgR, mrgS, mrgI), lklhdD, evaluation)
          = head minimalCands
        apply = Merge.apply mrg
        cache'
          = ML.map (Merge.applyMergeToMerge mrg)
          $ ML.mapKeysWith Merge.union (apply *** apply)
          $ ML.fromList
          $ map (\ (_, _, mv, m, _, _, _) -> (mv, m)) cands
        info'
          = Info n mergePairs beamWidth
                 indB indC mrg mrgR mrgS mrgI lklhdD evaluation
                 (map (\ (_, _, _, _, _, _, x) -> x) cands)
                 (map (\ (i, _, _, _, _, _, _) -> i) minimalCands)
          $ M.map (\ case [x] -> x; xs -> Merge n xs)
          $ mergeKeysWith (++) mrg
          $ M.map (: []) infoMergeTreeMap
    in if null cands
       then []
       else cbsmGo cache' mergeGroups evaluate beamWidth
                   (mergeCRTG mrg g, info')
--   = g
--   : ( g `seq` case refineRanking $ enrichRanking $ mergeRanking g of
--         ((_, ((v1, _), (v2, _))), _) : _
--           -> let g' = flip mergeCRTG g
--                     $ saturateMerge (forwardStar (rules g)) (Merge.fromLists [[v1, v2]])
--             in cbsm g'
--         _ -> []
--     )

compileMergePairs
  :: Ord v => Map v Int -> Set v -> (Int, [(Int, ((v, Int), (v, Int)))])
compileMergePairs cntM grpS
  = n `seq` (n, sortedCartesianProductWith' ((+) `on` snd) vs (tail vs))
  where n     = let s = M.size cntM' in s * (s - 1) `div` 2
        vs    = sortBy (comparing snd) (M.toList cntM')
        cntM' = M.intersection cntM (M.fromSet (const ()) grpS)


mergeSortedLists :: (a -> a -> Ordering) -> [a] -> [a] -> [a]
mergeSortedLists cmp = merge
  where
    merge xs@(x : xs') ys@(y : ys')
      = case x `cmp` y of
          GT -> y : merge xs  ys'
          _  -> x : merge xs' ys
    merge [] ys         = ys
    merge xs []         = xs


normalizeLklhdByMrgdStates :: (Int, Int, Int) -> Log Double -> Log Double
normalizeLklhdByMrgdStates (_, mrgS, _) (Exp l)
  = Exp (l / fromIntegral mrgS)  -- = Exp l ** recip (fromIntegral mrgS)



cbsmStep2 :: (Ord v, Ord l) => CRTG v l -> CRTG v l
cbsmStep2 g
  = flip mergeCRTG g
  $ (\ ((_, ((v1, _), (v2, _))) : _) -> saturateMerge (forwardStar (rules g)) (Merge.fromLists [[v1, v2]]))
  $ fst $ mergeRanking g


cbsmStep1
  :: (Ord v, Ord l)
  => CRTG v l
  -> [((Int, ((v, Int), (v, Int))), ([[v]], (Log Double, (Int, Int, Int))))]
cbsmStep1 g
  = map (\ x@(_, ((v1, _), (v2, _))) ->
        (,) x
      $ let mrg = saturateMerge (forwardStar (rules g)) (Merge.fromLists [[v1, v2]]) in
        (map S.toList $ Merge.equivalenceClasses mrg, likelihoodDelta g mrg)
      )
  $ fst $ mergeRanking g


refineRanking
  :: Eq a
  => [((a, b), (c, (Log Double, (Int, Int, Int))))]
  -> [((a, b), (c, (Log Double, (Int, Int, Int))))]
refineRanking
  = concatMap (sortBy (comparing (Down . snd . snd)))
  . groupBy ((==) `on` fst . fst)


enrichRanking
  :: (Ord v, Ord l)
  => ([(a, ((v, b), (v, c)))], CRTG v l)
  -> [((a, ((v, b), (v, c))), (Merge v, (Log Double, (Int, Int, Int))))]
enrichRanking (xs, g)
  = map (\ x@(_, ((v1, _), (v2, _))) ->
          ( x
          , let mrg = satMrg $ Merge.fromLists [[v1, v2]] in
            (mrg, lklhdDelta mrg)
        ) )
  $ xs
  where lklhdDelta = likelihoodDelta g
        satMrg = saturateMerge (forwardStar (rules g))


mergeRanking :: CRTG v l -> ([(Int, ((v, Int), (v, Int)))], CRTG v l)
mergeRanking g
  = (sortedCartesianProductWith' ((+) `on` snd) vs (tail vs), g)
    -- ToDo: instead of (+) maybe use states part of likelihood
  where
    vs = sortBy (comparing snd) (M.toList (cntState g))



saturateMerge
  :: forall s t
  .  (Ord s, Ord t)
  => ForwardStar s t
  -> Merge s  -- ^ merges (must be an equivalence relation)
  -> Merge s
saturateMerge g mrgs
  = untilRight (saturateMergeStep g) (saturateMergeInit mrgs)


saturateMergeInit mrgs = (Merge.elemS mrgs, mrgs)


saturateMergeStep
  :: (Ord s, Ord t)
  => ForwardStar s t
  -> (Set s, Merge s)
  -> Either (Set s, Merge s) (Merge s)
saturateMergeStep g (todo, mrgs)
  = case S.minView (S.map (Merge.apply mrgs) todo) of
      Nothing      -> Right mrgs
      Just (s, sS) -> Left
        $ foldl' step (sS, mrgs)
        $ concatMap
          ( filter ((2 <=) . S.size)
          . M.elems
          . M.fromListWith S.union
          . map (\ Rule{..} -> ( map (Merge.apply mrgs) from
                               , S.singleton (Merge.apply mrgs to)))
          )
        $ M.elems
        $ M.unionsWith (flip (++))  -- bring together rules with same terminal
        $ M.elems
        $ M.intersection g
        $ M.fromSet (const ())
        $ fromMaybe (errorHere "saturateMergeStep" "")
        $ Merge.equivalenceClass s mrgs
  where
    step (s, m) mrg = let s' = S.insert (S.findMin mrg) s
                          m' = Merge.insert mrg m
                      in s' `seq` m' `seq` (s', m')


traceShow' :: Show a => [Char] -> a -> a
traceShow' cs x = trace (cs ++ ": " ++ show x) x


putFst :: Monad m => s1 -> StateT (s1, s2) m ()
putFst x = modify (\ (_, y) -> (x, y))
-- putSnd y = modify (\ (x, _) -> (x, y))


-- | Lazily calculate the Cartesian product of two lists sorted by a score
-- calculated from the elements. /The following precondition must hold:/
-- For a call with arguments @f@, @[x1, …, xm]@, and @[y1, …, yn]@ for every
-- @xi@ and for every @yj@, @yk@ with @j <= k@: @f xi yj <= f xi yk@ must
-- hold, and analogously for @xi@, @xj@, and @yk@.
sortedCartesianProductWith
  :: Ord c
  => (a -> b -> c)  -- ^ calculates a score
  -> [a]
  -> [b]
  -> [(c, (a, b))]  -- ^ Cartesian product ('snd') sorted by score ('fst')
sortedCartesianProductWith
  = sortedCartesianProductWithInternal (\ _ _ -> True)


-- | The same as 'sortedCartesianProductWith', but only pairs @(xi, yj)@ with
-- @i <= j@ are returned.
sortedCartesianProductWith'
  :: Ord c => (a -> b -> c) -> [a] -> [b] -> [(c, (a, b))]
sortedCartesianProductWith'
  = sortedCartesianProductWithInternal (<=)


sortedCartesianProductWithInternal
  :: forall a b c . Ord c
  => (Int -> Int -> Bool)  -- ^ filter combinations
  -> (a -> b -> c)  -- ^ calculates a score
  -> [a]
  -> [b]
  -> [(c, (a, b))]  -- ^ Cartesian product ('snd') sorted by score ('fst')
sortedCartesianProductWithInternal (?) (>+<) (x0 : xs0) (y0 : ys0)
  = go1 $ M.singleton (x0 >+< y0) (M.singleton (0, 0) ((x0, y0), (xs0, ys0)))
  where
    go1 :: Map c (Map (Int, Int) ((a, b), ([a], [b]))) -> [(c, (a, b))]
    go1 = maybe [] go2 . M.minViewWithKey

    go2
      :: (    (c, Map (Int, Int) ((a, b), ([a], [b])))
         , Map c (Map (Int, Int) ((a, b), ([a], [b]))) )
      -> [(c, (a, b))]
    go2 ((mini, srcM), m)
      = map ((,) mini . fst) (M.elems srcM)
      ++ go1 ( M.alter (nothingIf M.null . flip M.difference srcM =<<) mini
             $ M.foldrWithKey' adjust m srcM )

    adjust
      ::            (Int, Int)
      ->                       ((a, b), ([a], [b]))
      -> Map c (Map (Int, Int) ((a, b), ([a], [b])))
      -> Map c (Map (Int, Int) ((a, b), ([a], [b])))
    adjust _ (_, ([], [])) = id
    adjust (i, j) ((x1, _), ([], y2 : ys2))
      = insert i (j + 1) x1 y2 [] ys2
    adjust (i, j) ((_, y1), (x2 : xs2, []))
      = insert (i + 1) j x2 y1 xs2 []
    adjust (i, j) ((x1, y1), (xs1@(x2 : xs2), ys1@(y2 : ys2)))
      = insert i (j + 1) x1 y2 xs1 ys2
      . insert (i + 1) j x2 y1 xs2 ys1

    insert
      ::             Int->Int -> a->b -> [a]->[b]
      -> Map c (Map (Int, Int) ((a, b), ([a], [b])))
      -> Map c (Map (Int, Int) ((a, b), ([a], [b])))
    insert i j x y xs ys | i ? j = M.insertWith M.union (x >+< y)
                                 $ M.singleton (i, j) ((x, y), (xs, ys))
    insert _ _ _ _ _  _          = id

sortedCartesianProductWithInternal _ _ _ _ = []


likelihoodDelta :: (Ord l, Ord v) => CRTG v l -> Merge v -> (Log Double, (Int, Int, Int))
likelihoodDelta g@CRTG{..} = \ mrgs ->
  let (rw, rc) = productAndSum  -- rules
               $ map ( (\ (pr, su, si) -> (p su / pr, si))
                     . productPAndSumAndSize
                     . map (cntRule M.!)
                     )
               $ M.elems
               $ ruleEquivalenceClasses bidiStar' mrgs
      (vw, vc) = productAndSum  -- states
               $ map ( (\ (pr, su, si) -> (pr / p su, si))
                     . productPAndSumAndSize
                     . map (getCnt cntState)
                     . S.toList
                     )
               $ Merge.equivalenceClasses mrgs

      (iw, ic) = productAndSum  -- initial states
               $ map ( (\ (pr, su, si) -> (p su / pr, si))
                     . productPAndSumAndSize
                     . M.elems
                     )
               $ filter ((1 <) . M.size)
               $ map (M.intersection cntInit . M.fromSet (const ()))
               $ Merge.equivalenceClasses mrgs
  in (rw * vw * iw, (rc, vc, ic))
  where
    bidiStar' = bidiStar (rules g)

    -- | power with itself
    p :: Int -> Log Double
    p n = Exp (x * log x)  -- = Exp (log (x ** x))
      where x = fromIntegral n

    productAndSum :: [(Log Double, Int)] -> (Log Double, Int)
    productAndSum = foldl' step (1, 0)
      where step (a1, a2) (b1, b2) = strictPair (a1 * b1) (a2 + b2)

    productPAndSumAndSize :: [Int] -> (Log Double, Int, Int)
    productPAndSumAndSize = foldl' step (1, 0, -1)
      where step (a1, a2, a3) b = strictTriple (a1 * p b) (a2 + b) (succ a3)

    strictPair :: a -> b -> (a, b)
    strictPair x y = x `seq` y `seq` (x, y)

    strictTriple :: a -> b -> c -> (a, b, c)
    strictTriple x y z = x `seq` y `seq` z `seq` (x, y, z)

    getCnt m k = M.findWithDefault 0 k m


ruleEquivalenceClasses
  :: (Ord l, Ord v) => BidiStar v l -> Merge v -> Map (Rule v l) [Rule v l]
ruleEquivalenceClasses g mrgs
  = M.filter notSingle
  $ M.fromListWith (++)
  $ map (\ r -> (mergeRule mrgs r, [r]))
  $ (S.toList . S.fromList)
  $ concat
  $ M.elems
  $ M.intersection g (Merge.forward mrgs)
  where
    notSingle [_] = False
    notSingle  _  = True


mergeRule :: Ord v => Merge v -> Rule v l -> Rule v l
mergeRule mrgs Rule{..} = Rule (mrg to) (map mrg from `using` evalList rseq) label
  where mrg = Merge.apply mrgs


mergeRuleMaybe :: Ord v => Merge v -> Rule v l -> Maybe (Rule v l)
mergeRuleMaybe mrgs Rule{..}
  = if any isJust (to' : from')
    then Just (Rule (fromMaybe to to') (zipWith fromMaybe from from') label)
    else Nothing
  where mrg = Merge.applyMaybe mrgs
        to' = mrg to
        from' = map mrg from


mergeCRTG :: (Ord l, Ord v) => Merge v -> CRTG v l -> CRTG v l
mergeCRTG mrgs CRTG{..}
  = CRTG
      (mapSomeKeysWith (+) (mergeRuleMaybe mrgs) cntRule)
      (mergeKeysWith (+) mrgs cntState)
      (mergeKeysWith (+) mrgs cntInit)


-- | Similar to 'M.mapKeysWith', but optimized for merging, because many keys
-- are left unchanged.
mergeKeysWith
  :: Ord k => (a -> a -> a) -> Merge k -> M.Map k a -> M.Map k a
mergeKeysWith (?) mrgs
  = uncurry (M.unionWith (?))
  . first (M.mapKeysWith (?) (Merge.apply mrgs))
  . M.partitionWithKey (\ k _ -> Merge.member k mrgs)


-- | Similar to 'M.mapKeysWith', but keys mapped to 'Nothing' are left
-- unchanged. If every key is mapped to 'Nothing', runtime is in /O(n)/.
mapSomeKeysWith
  :: Ord k => (a -> a -> a) -> (k -> Maybe k) -> Map k a -> Map k a
mapSomeKeysWith (?) f m
  = M.unionWith (?) unchanged
  $ M.mapKeysWith
      (?)
      (fromMaybe (errorHere "mapSomeKeysWith" "unexpected pattern") . f)
      todo
  where
    p k _ = isNothing (f k)
    (unchanged, todo) = M.partitionWithKey p m


whileM :: Monad m => m Bool -> m a -> m ()
whileM cond act = do
  b <- cond
  case b of
    True  -> act >> whileM cond act
    False -> return ()
