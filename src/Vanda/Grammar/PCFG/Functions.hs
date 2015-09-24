module Vanda.Grammar.PCFG.Functions where

import Vanda.Grammar.PCFG.PCFG
import Vanda.Grammar.PCFG.Util
import Vanda.Hypergraph.Basic
import Vanda.Hypergraph
import Vanda.Algorithms.ExpectationMaximization
import Vanda.Algorithms.EarleyMonadic
import Vanda.Algorithms.Earley.WSA
import Vanda.Features hiding (product)
import Vanda.Corpus.Penn.Text
import Vanda.Corpus.TreeTerm
import Vanda.Corpus.SExpression
import qualified Data.Map as M
import qualified Data.Vector as V
import qualified Data.Vector.Generic as VG
import qualified Data.Set as S
import qualified Data.List as L
import qualified Data.Text.Lazy as T
import Control.Monad.State
import Data.Tree as T
import Debug.Trace


import qualified Control.Error
errorHere :: String -> String -> a
errorHere = Control.Error.errorHere "Vanda.Grammar.PCFG.Functions" 


-- * Treebank Extraktion
extractPCFG :: [Deriv String String] -> PCFG String String
extractPCFG l = let PCFG p s w = extractPCFG' l in 
                    PCFG p s (VG.convert (normalize (map snd . partition $ edgesEL p) (VG.convert w)))
                    
extractPCFG' :: [Deriv String String] -> PCFG String String
extractPCFG' l = let (edgelist,e) = runState (generateEdges (sentences2edges l) [] (terminals l)) V.empty in
  PCFG (mkHypergraph edgelist) (map (\ (x,y) -> (x,y / (fromIntegral $ length l))) $ generateStartSymbols l) e

generateStartSymbols :: [Deriv String String] -> [(String,Double)]
generateStartSymbols [] = []
generateStartSymbols ((DNode a _):rest) = insert a $ generateStartSymbols rest
generateStartSymbols ((DLeaf a  ):rest) = insert a $ generateStartSymbols rest

insert :: String -> [(String,Double)] -> [(String,Double)]
insert a [] = [(a,1.0)]
insert a ((b,w):rest) 
  | a == b = (b,w+1):rest
  | otherwise = (b,w) : (insert a rest)
  
terminals :: [Deriv String String] -> S.Set String
terminals [] = S.empty
terminals ((DNode a li):rest) = S.union (terminals li) (terminals rest)
terminals ((DLeaf a):rest) = S.insert a (terminals rest)

generateEdges :: [(String,[String])] -> [Hyperedge String [Either Int String] Int] -> S.Set String -> State (V.Vector Double) [Hyperedge String [Either Int String] Int]
generateEdges [] l _ = return l
generateEdges ((to,b):rest) l t = 
  let (frm,lbl) = split b t 0
      (c,id) = contains to frm lbl l in 
    if not c then do
          v <- get
          put (V.snoc v 1)
          generateEdges rest ((mkHyperedge to frm lbl (V.length v)):l) t
          else do
          v <- get
          put (v V.// [(id,(v V.! id) + 1)])
          generateEdges rest l t

split :: [String] -> S.Set String -> Int -> ([String],[Either Int String])
split [] _ _ = ([],[])
split (x:xs) t i
  | S.member x t = let (a,b) = split xs t i in (a,(Right x):b)
  | otherwise = let (a,b) = split xs t (i + 1) in (x:a,(Left i):b)
                    

sentences2edges :: [Deriv String String] -> [(String,[String])]
sentences2edges [] = []
sentences2edges ((DNode a subtrees):rest) = (a,map (root) subtrees) : sentences2edges subtrees ++ sentences2edges rest
sentences2edges ((DLeaf a) : rest) = sentences2edges rest

contains :: String -> [String] -> [Either Int String] -> [Hyperedge String [Either Int String] Int] -> (Bool,Int)
contains a b l [] = (False,0)
contains a b l (c:cs)
  | equals a b l c = (True,ident c)
  | otherwise = contains a b l cs
  
equals :: String -> [String] -> [Either Int String] -> Hyperedge String [Either Int String] Int -> Bool
equals to [] l (Nullary to' label _) = to == to' && label == l
equals to [from] l (Unary to' from' label _) = to == to' && from == from' && label == l
equals to [from1,from2] l (Binary to' from1' from2' label _) = to == to' && from1 == from1' && from2 == from2' && label == l
equals to from l (Hyperedge to' from' label _) = to == to' && (V.fromList from) == from' && label == l
equals _ _ _ _ = False
          
          


-- Schnitt Grammatik + String

intersect :: (Ord a, Show a) => PCFG a String -> String -> PCFG (Int,a,Int) String
intersect p s = let (el,w) = earley' (productions p) label (fromList 1 $ words s) (map fst $ startsymbols p) in
                    PCFG (mapLabels (mapHEi fst) el) (map (\(x,y) -> ((0,x,(length (words s))),y)) $ startsymbols p) (weights p)
                    


-- EM Algorithmus

train :: PCFG String String -> [String] -> String
train = undefined


-- * n best derivations
data Deriv a b 
  = DNode a [Deriv a b] | DLeaf b deriving Show
  
root :: Deriv a a -> a
root (DLeaf x) = x
root (DNode x _) = x

derivToTree :: Deriv a a -> Tree a
derivToTree (DLeaf x) = T.Node x []
derivToTree (DNode x l) = T.Node x (map derivToTree l)

treeToDeriv :: Tree a -> Deriv a a
treeToDeriv (Node x li) 
  | length li == 0 = DLeaf x
  | otherwise      = DNode x (map treeToDeriv li)


bestDerivsAsString :: (PennFamily a, Ord a) => PCFG a a -> Int -> String
bestDerivsAsString p n = T.unpack . unparsePenn . map (derivToTree . fst) $ bestDerivations p n

bestDerivations :: (Ord nonterminalType, Eq terminalType) => PCFG nonterminalType terminalType -> Int -> [(Deriv nonterminalType terminalType,Double)]
bestDerivations pcfg n = map (\ c -> (extractDerivation $ deriv c, weight c)) candidates
  where candidates = take n . merge $ map (\ (x,y) -> map (scale y) (bmap M.! x)) (startsymbols pcfg)
        bmap = bests (productions pcfg) (defaultFeature $ weights pcfg) (V.singleton 1.0)

extractDerivation :: Tree (Hyperedge v [Either Int a] Int) -> Deriv v a
extractDerivation (T.Node he rest) = DNode (to he) (zipHE he rest)
  where zipHE :: Hyperedge v [Either Int a] Int -> [Tree (Hyperedge v [Either Int a] Int)] -> [Deriv v a]
        zipHE (Nullary _ label _) _ = map (either (errorHere "extractDerivation" "Nullary edge has invalid label") DLeaf) label
        zipHE (Unary _ _ label _) [next] = map (either (\ _ -> extractDerivation next) DLeaf) label
        zipHE (Binary _ _ _ label _) next = map (either (\ x -> extractDerivation $ V.fromList next V.! (x-1)) DLeaf) label
        zipHE (Hyperedge _ _ label _) next = map (either (\ x -> extractDerivation $ V.fromList next V.! (x-1)) DLeaf) label
        zipHE _ _ = errorHere "extractDerivation" "Pattern not matched"

scale :: Double -> Candidate v l i x -> Candidate v l i x
scale d c = c{weight = weight c * d}

merge :: [[Candidate v l i x]] -> [Candidate v l i x]
merge = foldl merge' []

merge' :: [Candidate v l i x] -> [Candidate v l i x] -> [Candidate v l i x]
merge' [] l = l
merge' l [] = l
merge' (c1:r1) (c2:r2)
  | weight c1 >= weight c2 = c1 : (merge' r1 (c2:r2))
  | otherwise              = c2 : (merge' (c1:r1) r2)

defaultFeature :: V.Vector Double -> Feature [Either Int a] Int Double
defaultFeature v = Feature p f
  where p _ i xs = (v V.! i) * product xs
        f x = V.singleton x