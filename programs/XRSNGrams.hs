{-# LANGUAGE RecordWildCards #-}
module Main where

import System.Environment ( getArgs )
import qualified Data.Text.IO as TIO
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU

import qualified Vanda.Grammar.XRS.Functions as IF
import qualified Vanda.Grammar.XRS.IRTG as I
import qualified Vanda.Grammar.NGrams.Functions as LM
import qualified Vanda.Algorithms.IntersectWithNGram as IS
import qualified Vanda.Hypergraph.IntHypergraph as HI
import qualified Vanda.Grammar.LM as LM
import qualified Vanda.Token as TK

main
  :: IO ()
main = do
  args <- getArgs
  case args of
    ["-f", fMapFile, "-z", zhgFile, "-l", lmFile] -> do
      irtg1 <- IF.loadIRTG (zhgFile ++ ".bhg.gz")
      ws    <- IF.loadWeights (zhgFile ++ ".weights.gz")
      fa    <- IF.loadTokenArray fMapFile
      fm    <- IF.loadTokenMap fMapFile
      lm    <- LM.loadNGrams lmFile
      let irtg  = I.XRS irtg1 (VU.generate (V.length ws) (ws V.!))
      let irtg' = IS.relabel (TK.getToken fm . LM.getText lm)
                . IS.intersect lm
                . IS.relabel (LM.indexOf lm . TK.getString fa)
                $ irtg
      TIO.putStr . T.pack . show $ irtg
      TIO.putStr . T.pack $ "\n"
      TIO.putStr . T.pack . show $ irtg'
      TIO.putStr . T.pack $ "\n"