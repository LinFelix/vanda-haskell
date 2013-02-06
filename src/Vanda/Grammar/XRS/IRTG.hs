module Vanda.Grammar.XRS.IRTG where

import Data.Hashable ( Hashable (..) )
import Data.NTT
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU

import Vanda.Hypergraph.IntHypergraph
import qualified Vanda.Hypergraph.Tree as T


data StrictIntPair
  = SIP
    { _fst :: !Int
    , _snd :: !Int
    } deriving (Eq, Ord, Show)

data IRTG i
  = IRTG
    { rtg :: Hypergraph StrictIntPair i
    , initial :: Int
    , h1 :: V.Vector (T.Tree NTT)
    , h2 :: V.Vector (V.Vector NTT)
    }

data XRS
  = XRS
    { irtg :: IRTG Int
    , weights :: VU.Vector Double
    }

instance Hashable (V.Vector NTT) where
  hashWithSalt salt = hashWithSalt salt . V.toList
