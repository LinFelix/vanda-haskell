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

module Vanda.Hypergraph.Binary () where

import Control.Applicative ( (<$>), (<*>) )
import qualified Data.Binary as B
import qualified Data.Vector as V

import Vanda.Hypergraph.Basic

instance (B.Binary v, B.Binary l, B.Binary i)
  => B.Binary (Hyperedge v l i) where
  put (Hyperedge t f l i) = do
    B.put t
    B.put $ V.toList f
    B.put l
    B.put i
  get = mkHyperedge <$> B.get <*> B.get <*> B.get <*> B.get

myGet :: (B.Binary v, B.Binary l, B.Binary i) => B.Get [Hyperedge v l i]
myGet = do
  es1 <- B.get
  if null es1
    then return []
    else
      do
        es2 <- myGet
        return $ es1 ++ es2

myPut
  :: forall v l i. (B.Binary v, B.Binary l, B.Binary i)
  => [Hyperedge v l i] -> B.Put
myPut [] = B.put ([] :: [Hyperedge v l i])
myPut es = do
  B.put (take 100 es)
  myPut (drop 100 es)

instance (B.Binary v, B.Binary l, B.Binary i)
  => B.Binary (EdgeList v l i) where
  put (EdgeList vs es) = do
    B.put vs
    myPut es
  get = EdgeList <$> B.get <*> myGet

