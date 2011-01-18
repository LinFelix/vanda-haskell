-- Copyright (c) 2010, Toni Dietze

module Demo where

import qualified Data.WTA as WTA
import qualified Parser.Negra as Negra
import qualified RuleExtraction as RE
import qualified StateSplit as SPG

import TestData.TestWTA

import Parser.ApplicativeParsec

import qualified Data.Tree as T

-- -------------------------------------------------------------------
-- WTA related


demoWTA1 = testWTAs !! 10


-- | Print an example WTA.
demo1_1
  = WTA.printWTA
  $ demoWTA1


-- | Generate some trees with the example WTA.
demo1_2 n
  = putStrLn
  . T.drawForest
  . fmap (fmap show)
  . take n
  . WTA.generate
  $ demoWTA1


-- | Generate some annotated trees with the example WTA.
demo1_3 n
  = putStrLn
  . T.drawForest
  . fmap (fmap show)
  . take n
  . WTA.generate'
  $ demoWTA1


-- | Weight some generated trees of the example WTA.
demo1_4 n
  = fmap (WTA.weightTree demoWTA1)
  . take n
  . WTA.generate
  $ demoWTA1

-- -------------------------------------------------------------------
-- Negra related


-- Satz 10 = Bild 2

-- | Apply a function to Negra test data.
demo2_help f
  = parseFromFile Negra.p_negra "Parser/corpus-sample.export"
  >>= either print f


-- | Show a sentence in Negra format.
demo2_1 i
  = demo2_help
  $ print
  . (!! i)


-- | Show a Tree for a Negra sentence.
demo2_2 i
  = demo2_help
  $ putStrLn
  . T.drawForest
  . fmap (fmap (show . fmap Negra.showSentenceData . fst . fst))
  . Negra.negraToForest
  . Negra.sData
  . (!! i)

-- -------------------------------------------------------------------
-- Rule extraction

demo3_1
  = demo2_help
  $ WTA.printWTA
  . RE.extractWTA
  . concatMap (
      fmap (fmap (maybe "ROOT" Negra.showSentenceData . fst . fst))
    . Negra.negraToForest
    . Negra.sData
  )


-- -------------------------------------------------------------------
-- State Split Grammars

demoWTA2 = WTA.create
        [ WTA.Transition 'l' 'f' ""   1
        , WTA.Transition 'l' 'q' ""   1
        , WTA.Transition 'n' 'f' "qf" 0.4
        , WTA.Transition 'n' 'f' "qq" 0.6
        ]
        [('f', 1)]

-- | Print demo WTA.
demo4_1
  = WTA.printWTA
  . SPG.initialize
  $ demoWTA2


-- | Split demo WTA.
demo4_2
  = WTA.printWTA
  . SPG.split 1
  . SPG.initialize
  $ demoWTA2


-- | Merge ('q', 0) and ('q', 1).
demo4_3
  = WTA.printWTA
  . SPG.merge m
  . SPG.split 1
  . SPG.initialize
  $ demoWTA2
  where
    m ('q', 1) = ('q', 0)
    m x        = x