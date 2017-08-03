-----------------------------------------------------------------------------
-- |
-- Module      :  ActiveParser
-- Copyright   :  (c) Thomas Ruprecht 2017
-- License     :  Redistribution and use in source and binary forms, with
--                or without modification, is ONLY permitted for teaching
--                purposes at Technische Universität Dresden AND IN
--                COORDINATION with the Chair of Foundations of Programming.
--
-- Maintainer  :  thomas.ruprecht@tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
--
-- This module provides two functions for parsing words using the active
-- parsing algorithm by Burden and Ljunglöf.
-- 'weightedParse' uses a 'WPMCFG' to find a list of all possible
-- derivation trees ordered by minimal cost / maximum probability. The
-- rules' weigthts need to be instances of "Data.Semiring" and 'Weight'.
-- 'parse' uses an unweighted 'PMCFG' to find a list of derivation trees
-- ordered by least rule applications.
--
-- The parsing algorithm uses active and passive items to represent
-- possible subwords generated by a certain non-terminal. Whereas active
-- items represent an incomplete derivation (not all terminals of a rule 
-- are compared to the terminals of the word or not all non-terminals in 
-- the rule were replaced by valid subwords), passive items represent a full
-- rule application and thus a valid possible subword generated by rule.
-- To find all valid rule applications that generate a subword,
-- there are 3 different types of deductive rules applied until a
-- passive item is generated of the grammar's rule:
--
-- * prediction: An empty active item is generated by a grammar rule.
-- * completion: An unknown variable is replaced by a range of a
-- generated range component of a passive item if its terminal fits the
-- composition variable. After this step, all components of the inserted
-- passive items are stored to complete later components of this variable.
-- * conversion: If there are no symbols left to substitute by a range in
-- the current component, the active item is converted into a passive one
-- by converting the list of ranges into a range vector.
--
-- After the first two rules, all following components of the composition
-- function are processed (terminals are replaced with fitting ranges in
-- the word, known variables' components are replaced with stored ranges,
-- empty composition components are skipped) until we meed an unknown
-- variable. Thus, each active item needs to be completed with a passive
-- item in the next step.
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}


module Vanda.Grammar.PMCFG.ActiveParser
    ( parse
    , parse'
    ) where

import Data.Converging (Converging)
import Data.Hashable (Hashable(hashWithSalt))
import Data.Maybe (mapMaybe, maybeToList, catMaybes)
import Data.Range
import Data.Semiring
import Data.Tree (Tree)
import Data.Weight
import Vanda.Grammar.PMCFG

import qualified Data.MultiHashMap  as MMap
import qualified Data.IntMap        as IMap
import qualified Data.HashMap.Lazy  as Map
import qualified Data.HashSet       as Set
import qualified Vanda.Grammar.PMCFG.Chart as C


data Item nt t wt = Passive nt Rangevector (C.Backtrace nt t wt) wt
                  | Active (Rule nt t) wt [Range] (Function t) (IMap.IntMap Rangevector) wt


instance (Eq nt, Eq t) => Eq (Item nt t wt) where
  (Active r _ rs fs completions _) == (Active r' _ rs' fs' completions' _) 
    =  r           == r' 
    && rs          == rs' 
    && completions == completions'
    && fs          == fs'
  (Passive a rv bt _ ) == (Passive a' rv' bt' _) 
    = a   == a'
    && rv == rv' 
    && bt == bt'
  _ == _ = False


instance (Hashable nt, Hashable t) => Hashable (Item nt t wt) where
  salt `hashWithSalt` (Passive a rho _ _) 
    = salt `hashWithSalt` a `hashWithSalt` rho
  salt `hashWithSalt` (Active r _ rhos _ _ _) 
    = salt `hashWithSalt` r `hashWithSalt` rhos


instance (Show nt, Show t) => Show (Item nt t wt) where
  show (Passive a rv _ _)
    = "[Passive] " ++ show a ++ " → " ++ show rv
  show (Active r _ rv f _ _)
    = "[Active] " ++ show r ++ "\n" 
    ++ "current status: " ++ show (reverse rv) ++ " • " ++ prettyPrintComposition f


-- | Container with two charts.
type Container nt t wt = ( C.Chart nt t wt
                         , MMap.MultiMap nt (Item nt t wt)
                         , Set.HashSet nt
                         )


-- | Top-level function to parse a word using a PMCFG.
-- Uses weightedParse with additive costs for each rule, s.t. the number of rule applications is minimized.
parse :: forall nt t wt.(Hashable nt, Hashable t, Eq t, Ord wt, Weight wt, Ord nt, Converging wt) 
      => WPMCFG nt wt t 
      -> Int
      -> Int
      -> [t]
      -> [Tree (Rule nt t)]
parse g bw tops w = parse' (prepare g w) bw tops w

parse' :: forall nt t wt.(Hashable nt, Hashable t, Eq t, Ord wt, Weight wt, Ord nt, Converging wt) 
       => (MMap.MultiMap nt (Rule nt t, wt), Map.HashMap nt (wt,wt), [nt])
       -> Int
       -> Int
       -> [t]
       -> [Tree (Rule nt t)]
parse' (rmap, iow, s') bw tops w
  = C.parseTrees tops s' (singleton $ entire w)
  $ (\ (e, _, _) -> e)
  $ C.chartify (C.empty, MMap.empty, nset) update rules bw tops
    where
      nset = Set.fromList $ filter (not . (`elem` s')) $ Map.keys rmap
      
      rules = initialPrediction w (s' >>= (`MMap.lookup` rmap)) iow
              : predictionRule w rmap iow
              : [completionRule w iow]

      update :: Container nt t wt -> Item nt t wt -> (Container nt t wt, Bool)
      update (p, a, n) (Passive nta rho bt iw)
        = case C.insert p nta rho bt iw of
               (p', isnew) -> ((p', a, n), isnew)
      update (p, a, n) item@(Active (Rule ((_, as),_)) _ _ ((Var i _:_):_) _ _)
        = ((p, MMap.insert (as !! i) item a, (as !! i) `Set.delete` n), True)
      update (p, a, n) _ = ((p, a, n), True)


-- | Prediction rule for rules of initial nonterminals.
initialPrediction :: forall nt t wt. (Hashable nt, Eq nt, Semiring wt, Eq t) 
                  => [t]
                  -> [(Rule nt t, wt)]
                  -> Map.HashMap nt (wt, wt)
                  -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
initialPrediction word srules ios 
  = Left $ catMaybes 
      [ convert (Active r w rho' f' IMap.empty inside, inside) 
      | (r@(Rule ((_, as), f)), w) <- srules
      , (rho', f') <- completeKnownTokens word IMap.empty [Epsilon] f
      , let inside = w <.> foldl (<.>) one (map (fst . (ios Map.!)) as)
      ]


predictionRule :: forall nt t wt. (Weight wt, Eq nt, Hashable nt, Eq t) 
               => [t]
               -> MMap.MultiMap nt (Rule nt t, wt)
               -> Map.HashMap nt (wt, wt)
               -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
predictionRule word rs ios = Right app
  where
    app :: Item nt t wt
        -> Container nt t wt 
        -> [(Item nt t wt, wt)]
    app (Active (Rule ((_, as), _)) w _ ((Var i _:_):_) _ _) (_, _, inits)
      = catMaybes 
        [ convert (Active r' w rho'' f'' IMap.empty inside, inside <.> outside)
        | let a = as !! i
        , a `Set.member` inits
        , (r'@(Rule ((a', as'), f')), w') <- MMap.lookup a rs
        , (rho'', f'') <- completeKnownTokens word IMap.empty [Epsilon] f'
        , let inside = w' <.> foldl (<.>) one (map (fst . (ios Map.!)) as')
              outside = snd $ ios Map.! a'
        ]
    app _ _ = []


convert :: (Item nt t wt, wt) -> Maybe (Item nt t wt, wt)
convert (Active r w rs [] completions inside, heuristic)
  = case fromList $ reverse rs of
         Nothing -> Nothing
         Just rv -> let rvs = IMap.elems completions
                        (Rule ((a, _), _)) = r
                    in Just (Passive a rv (C.Backtrace r w rvs) inside, heuristic)
convert i@(Active _ _ rs _ _ _, _)
  | isNonOverlapping rs = Just i
  | otherwise = Nothing
convert _ = Nothing

completeKnownTokens :: (Eq t)
                    => [t] 
                    -> IMap.IntMap Rangevector 
                    -> [Range] 
                    -> Function t 
                    -> [([Range], Function t)]
completeKnownTokens _ _ rs [[]] = [(rs, [])]
completeKnownTokens w m rs ([]:fs) = completeKnownTokens w m (Epsilon:rs) fs
completeKnownTokens w m (r:rs) ((T t:fs):fss) 
  = [ (r':rs, fs:fss)
    | r' <- mapMaybe (safeConc r) $ singletons t w
    ] >>= uncurry (completeKnownTokens w m)
completeKnownTokens w m (r:rs) ((Var i j:fs):fss) 
  = case i `IMap.lookup` m of
         Just rv -> case safeConc r (rv ! j) of
                         Just r' -> completeKnownTokens w m (r':rs) (fs:fss)
                         Nothing -> []
         Nothing -> [(r:rs, (Var i j:fs):fss)]
completeKnownTokens _ _ _ _ = []
    

completionRule :: forall nt t wt. (Hashable nt, Eq nt, Eq t, Weight wt) 
               => [t]
               -> Map.HashMap nt (wt, wt)
               -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
completionRule word ios = Right app
  where
    app :: Item nt t wt -> Container nt t wt -> [(Item nt t wt, wt)]
    app active@(Active (Rule ((_, as), _)) _ _ ((Var i _:_):_) _ _) (ps, _, _) 
      = [ consequence
        | passive <- C.lookupWith Passive ps (as !! i)
        , consequence <- consequences active passive
        ]
    app passive@(Passive a _ _ _) (_, acts, _)
      = [ consequence
        | active <- MMap.lookup a acts
        , consequence <- consequences active passive
        ]
    app _ _ = []

    consequences :: Item nt t wt -> Item nt t wt -> [(Item nt t wt, wt)]
    consequences (Active r w (range:rho) ((Var i j:fs):fss) c aiw) (Passive a rv _ piw)
      = catMaybes
        [ convert (Active r w rho' f' c' inside, inside <.> outside)
        | range' <- maybeToList $ safeConc range (rv ! j)
        , let c' = IMap.insert i rv c
              inside = aiw <.> (piw </> fst (ios Map.! a))
              outside = snd $ ios Map.! a
        , (rho', f') <- completeKnownTokens word c' (range':rho) (fs:fss)
        ]
    consequences _ _ = []
