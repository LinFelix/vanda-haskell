{-# OPTIONS_GHC -fno-warn-incomplete-record-updates #-}

-- (c) 2016 Tobias Denkinger <Tobias.Denkinger@tu-dresden.de>
--
-- Technische Universität Dresden / Faculty of Computer Science / Institute
-- of Theoretical Computer Science / Chair of Foundations of Programming
--
-- Redistribution and use in source and binary forms, with or without
-- modification, is ONLY permitted for teaching purposes at Technische
-- Universität Dresden AND IN COORDINATION with the Chair of Foundations
-- of Programming.
-- ---------------------------------------------------------------------------

module Vanda.Grammar.PMCFG.Main
  ( main
  , mainArgs
  , cmdArgs
  , Args ()
  ) where

import Codec.Compression.GZip (compress, decompress)
import qualified Data.Binary as B
import qualified Data.ByteString.Lazy as BS
import qualified Data.Text.Lazy.IO as TIO
import qualified Data.Text.Lazy as T
import Data.Tree (drawTree)
import Data.Interner
import System.Console.CmdArgs.Explicit
import System.Console.CmdArgs.Explicit.Misc
import Control.Exception.Base (evaluate)

import Vanda.Corpus.Negra.Text (parseNegra)
import Vanda.Grammar.PMCFG.Functions (extractFromNegra, extractFromNegraAndBinarize)
import Vanda.Grammar.XRS.LCFRS.Binarize (binarizeNaively, binarizeByAdjacency, binarizeHybrid)

import Vanda.Grammar.PMCFG (WPMCFG (..), prettyPrintWPMCFG, integerize, deintegerize, pos, posTab, prepare)
--import qualified Vanda.Grammar.PMCFG.Parse as UnweightedAutomaton
import qualified Vanda.Grammar.PMCFG.CYKParser as CYK
import qualified Vanda.Grammar.PMCFG.NaiveParser as Naive
import qualified Vanda.Grammar.PMCFG.ActiveParser as Active
import Data.Weight (probabilistic, cost)
import Control.Arrow
import Data.Maybe (catMaybes)

import System.TimeIt
import System.Timeout
import Numeric (showFFloat)

data Args
  = Help String
  | Extract
    { argGrammar :: FilePath
    , flagBinarize :: Bool
    , flagStrategy :: BinarizationStrategy
    }
  | Parse
    { flagAlgorithm :: ParsingAlgorithm
    , argGrammar :: FilePath
    , unweighted :: Bool
    , flagOutput :: ParsingOutput
    , beamwidth :: Int
    , maxAmount :: Int
    , iTimeout :: Int
    }
  deriving Show

data BinarizationStrategy = Naive | Optimal | Hybrid Int deriving (Eq, Show)

data ParsingAlgorithm = UnweightedAutomaton | CYK | NaiveActive | Active deriving (Eq, Show, Read)
data ParsingOutput = POS | Derivation deriving (Eq, Show, Read)


cmdArgs :: Mode Args
cmdArgs
  = modes "pmcfg" (Help $ defaultHelp cmdArgs) "algorithms for weighted parallel multiple context-free grammars"
  [ (modeEmpty $ Extract undefined False undefined)
    { modeNames = ["extract"]
    , modeHelp = "Reads of a wPMCFG from a NeGra corpus."
    , modeArgs = ( [ flagArgGrammar{argRequire = True}], Nothing )
    , modeGroupFlags = toGroup [flagNoneBinarize,  flagNoneNaive, flagNoneOptimal, flagReqHybrid]
    }
  , (modeEmpty $ Parse Active undefined False Derivation 1000 1 (-1))
    { modeNames = ["parse"]
    , modeHelp = "Parses, given a (w)PMCFG, each in a sequence of sentences."
    , modeArgs = ( [ flagArgGrammar{argRequire = True} ], Nothing )
    , modeGroupFlags = toGroup  [ flagAlgorithmOption
                                , flagDisplayOption
                                , flagUseWeights
                                , flagBeamwidth
                                , flagMax
                                , flagTimeout
                                ]
    }
  ]
  where
    -- grammar file as argument, needed in both cases
    flagArgGrammar
      = flagArg (\ a x -> Right x{argGrammar = a}) "GRAMMAR FILE"
    -- extraction options
    flagNoneBinarize
      = flagNone ["b", "binarize", "binarise"] (\ x -> x{flagBinarize = True}) "binarize the extracted grammar"
    flagNoneNaive
      = flagNone ["n", "naive"] (\ x -> x{flagStrategy = Naive}) "use naive binarization"
    flagNoneOptimal
      = flagNone ["o", "optimal"] (\ x -> x{flagStrategy = Optimal}) "use optimal binarization (i.e., minimize the maximal fanout of the resulting PLCFRS)"
    flagReqHybrid
      = flagReq ["h", "hybrid"] (\ a x -> Right x{flagStrategy = Hybrid $ read a})
          "BOUND"
          "binarize rules up to rank BOUND optimally and the rest naively"
    -- parsing options
    flagAlgorithmOption
      = flagReq ["algorithm", "a"] (\ a x -> Right x{flagAlgorithm = read a}) "CYK/NaiveActive/Active" "solution algorithm, default is 'Active'"
    flagDisplayOption
      = flagReq ["print"] (\ a x -> Right x{flagOutput = read a}) "POS/Derivation" "display solutions POS tags or full derivation (default)"
    flagBeamwidth
      = flagReq ["beam-width", "bw"] (\ a x -> Right x{beamwidth = read a}) "number" "beam width: limits the number of items held in memory"
    flagMax
      = flagReq ["results", "ts"] (\ a x -> Right x{maxAmount = read a}) "number" "limits the maximum amount of output parse trees"
    flagUseWeights
      = flagBool ["u", "unweighted"] (\ b x -> x{unweighted = b}) "use an unweighted parsing algorithm"
    flagTimeout
      = flagReq ["timeout", "t"] (\ a x -> Right x{iTimeout = read a}) "number" "limits the maximum parsing time in seconds"


main :: IO ()
main = processArgs (populateHelpMode Help cmdArgs) >>= mainArgs


mainArgs :: Args -> IO ()
mainArgs (Help cs) = putStr cs
mainArgs (Extract outfile False _)
  = do
      corpus <- TIO.getContents
      let pmcfg = extractFromNegra $ parseNegra corpus :: WPMCFG String Double String
      BS.writeFile outfile . compress $ B.encode pmcfg
      writeFile (outfile ++ ".readable") $ prettyPrintWPMCFG pmcfg
mainArgs (Extract outfile True strategy)
  = do
      corpus <- TIO.getContents
      let s = case strategy of Naive -> binarizeNaively
                               Optimal -> binarizeByAdjacency
                               Hybrid b -> binarizeHybrid b
      let pmcfg = extractFromNegraAndBinarize s $ parseNegra corpus :: WPMCFG String Double String
      BS.writeFile outfile . compress $ B.encode pmcfg
      writeFile (outfile ++ ".readable") $ prettyPrintWPMCFG pmcfg
mainArgs (Parse algorithm grFile uw display bw trees itime)
  = do
      wpmcfg <- B.decode . decompress <$> BS.readFile grFile :: IO (WPMCFG String Double String)
      let (WPMCFG inits wrs, nti, ti) = integerize wpmcfg
      _ <- evaluate wrs
      corpus <- TIO.getContents
      
      let pok _ [] = "Could not find any derivation.\n"
          pok showfunc xs = showfunc xs
          show' = case display of
                       POS -> let prefix splitchar = T.unpack . head . T.split (== splitchar) . T.pack
                                  showtabline (h, vs) = h  ++ foldl (\ s  v -> s ++ "\t" ++ prefix '_' v) "" vs
                              in unlines . fmap showtabline . posTab . catMaybes . fmap pos
                       Derivation -> concatMap (drawTree . fmap show)
      
      flip mapM_ (T.lines corpus)
        $ \ sentence -> do let intSent = (snd . internListPreserveOrder ti . map T.unpack . T.words) $ sentence
                           (filtertime, parse) <- if uw
                                                    then do let urs = WPMCFG inits $ map (second $ const $ cost (1 :: Int)) wrs
                                                            (filtertime', urs') <- timeItT (return $! prepare urs intSent)
                                                            return (filtertime', case algorithm of CYK -> CYK.parse' urs'
                                                                                                   NaiveActive -> Naive.parse' urs'
                                                                                                   Active -> Active.parse' urs'
                                                                                                   UnweightedAutomaton -> error "not implemented")
                                                                                                   --UnweightedAutomaton -> UnweightedAutomaton.parse urs
                                                    else do let wrs' = WPMCFG inits $ map (second probabilistic) wrs
                                                            (filtertime', wrs'') <- timeItT (return $! prepare wrs' intSent)
                                                            return (filtertime', case algorithm of CYK -> CYK.parse' wrs''
                                                                                                   NaiveActive -> Naive.parse' wrs''
                                                                                                   Active -> Active.parse' wrs''
                                                                                                   UnweightedAutomaton -> error "not implemented")
                           (parsetime, mParseTrees) <- timeItT $ timeout (itime*1000000) (return $! parse bw trees intSent)
                           let parseTrees = case mParseTrees of
                                                 Nothing -> []
                                                 Just ts -> ts
                           putStrLn $ showFFloat Nothing filtertime ""
                           putStrLn $ showFFloat Nothing parsetime ""
                           (putStrLn . pok show' . map (deintegerize (nti, ti))) $ parseTrees
 
