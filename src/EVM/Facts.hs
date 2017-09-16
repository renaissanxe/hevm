{-# Language PartialTypeSignatures #-}
{-# Language FlexibleInstances #-}
{-# Language ExtendedDefaultRules #-}
{-# Language NamedFieldPuns #-}
{-# Language PatternSynonyms #-}
{-# Language RecordWildCards #-}
{-# Language ScopedTypeVariables #-}
{-# Language ViewPatterns #-}

-- Converts between Ethereum contract states and simple trees of
-- texts.  Dumps and loads such trees as Git repositories (the state
-- gets serialized as commits with folders and files).
--
-- Example state file hierarchy:
--
--   /0123...abc/balance      says "0x500"
--   /0123...abc/code         says "60023429..."
--   /0123...abc/nonce        says "0x3"
--   /0123...abc/storage/0x1  says "0x1"
--   /0123...abc/storage/0x2  says "0x0"
--
-- This format could easily be serialized into any nested record
-- syntax, e.g. JSON.

module EVM.Facts
  ( File (..)
  , Fact (..)
  , Data (..)
  , Path (..)
  , apply
  , contractFacts
  , vmFacts
  , factToFile
  , fileToFact
  ) where

import EVM          (VM, Contract)
import EVM          (balance, nonce, storage, bytecode, env, contracts)
import EVM.Concrete (Concrete)
import EVM.Types    (Addr)

import qualified EVM as EVM
import qualified EVM.Machine as EVM

import Prelude hiding (Word)

import Control.Lens    (view, set, at, ix, (&))
import Data.ByteString (ByteString)
import Data.Monoid     ((<>))
import Data.Ord        (comparing)
import Data.Set        (Set)
import Text.Read       (readMaybe)

import qualified Data.ByteString.Base16 as BS16
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Map as Map
import qualified Data.Set as Set

type Word = EVM.Word Concrete

-- We treat everything as ASCII byte strings because
-- we only use hex digits (and the letter 'x').
type ASCII = ByteString

-- When using string literals, default to infer the ASCII type.
default (ASCII)

-- We use the word "fact" to mean one piece of serializable
-- information about the state.
--
-- Note that Haskell allows this kind of union of records.
-- It's convenient here, but typically avoided.
data Fact
  = BalanceFact { addr :: Addr, what :: Word }
  | NonceFact   { addr :: Addr, what :: Word }
  | StorageFact { addr :: Addr, what :: Word, which :: Word }
  | CodeFact    { addr :: Addr, blob :: ByteString }
  deriving (Eq, Show)

-- A fact path means something like "/0123...abc/storage/0x1",
-- or alternatively "contracts['0123...abc'].storage['0x1']".
data Path = Path [ASCII] ASCII
  deriving (Eq, Ord, Show)

-- A fact data is the content of a file.  We encapsulate it
-- with a newtype to make it easier to change the representation
-- (to use bytestrings, some sum type, or whatever).
newtype Data = Data { dataASCII :: ASCII }
  deriving (Eq, Ord, Show)

-- We use the word "file" to denote a serialized value at a path.
data File = File { filePath :: Path, fileData :: Data }
  deriving (Eq, Ord, Show)

class AsASCII a where
  dump :: a -> ASCII
  load :: ASCII -> Maybe a

instance AsASCII Addr where
  dump = Char8.pack . show
  load = readMaybe . Char8.unpack

instance AsASCII (EVM.Word Concrete) where
  dump = Char8.pack . show
  load = readMaybe . Char8.unpack

instance AsASCII ByteString where
  dump x = BS16.encode x <> "\n"
  load x =
    case BS16.decode . mconcat . BS.split 10 $ x of
      (y, "") -> Just y
      _       -> Nothing

contractFacts :: Addr -> Contract Concrete -> [Fact]
contractFacts a x = storageFacts a x ++
  [ BalanceFact a (view balance x)
  , NonceFact   a (view nonce x)
  , CodeFact    a (view bytecode x)
  ]

storageFacts :: Addr -> Contract Concrete -> [Fact]
storageFacts a x = map f (Map.toList (view storage x))
  where
    f :: (Word, Word) -> Fact
    f (k, v) = StorageFact
      { addr  = a
      , what  = fromIntegral v
      , which = fromIntegral k
      }

vmFacts :: VM Concrete -> Set Fact
vmFacts vm = Set.fromList $ do
  (k, v) <- Map.toList (view (env . contracts) vm)
  contractFacts k v

-- Somewhat stupidly, this function demands that for each contract,
-- the code fact for that contract comes before the other facts for
-- that contract.  This is an incidental thing because right now we
-- always initialize contracts starting with the code (to calculate
-- the code hash and so on).
--
-- Therefore, we need to make sure to sort the fact set in such a way.
apply1 :: VM Concrete -> Fact -> VM Concrete
apply1 vm fact =
  case fact of
    CodeFact    {..} ->
      vm & set (env . contracts . at addr) (Just (EVM.initialContract blob))
    StorageFact {..} ->
      vm & set (env . contracts . ix addr . storage . at which) (Just what)
    BalanceFact {..} ->
      vm & set (env . contracts . ix addr . balance) what
    NonceFact   {..} ->
      vm & set (env . contracts . ix addr . nonce) what

-- Sort facts in the right order for `apply1` to work.
instance Ord Fact where
  compare = comparing f
    where
    f :: Fact -> (Int, Addr, Word)
    f (CodeFact a _)      = (0, a, 0)
    f (BalanceFact a _)   = (1, a, 0)
    f (NonceFact a _)     = (2, a, 0)
    f (StorageFact a _ x) = (3, a, x)

-- Applies a set of facts to a VM.
apply :: VM Concrete -> Set Fact -> VM Concrete
apply vm =
  -- The set's ordering is relevant; see `apply1`.
  foldl apply1 vm

factToFile :: Fact -> File
factToFile fact = case fact of
  StorageFact {..} -> mk ["storage"] (dump which) what
  BalanceFact {..} -> mk []          "balance"    what
  NonceFact   {..} -> mk []          "nonce"      what
  CodeFact    {..} -> mk []          "code"       blob
  where
    mk :: AsASCII a => [ASCII] -> ASCII -> a -> File
    mk prefix base a =
      File (Path (dump (addr fact) : prefix) base)
           (Data $ dump a)

-- This lets us easier pattern match on serialized things.
-- Uses language extensions: `PatternSynonyms` and `ViewPatterns`.
pattern Load :: AsASCII a => a -> ASCII
pattern Load x <- (load -> Just x)

fileToFact :: File -> Maybe Fact
fileToFact = \case
  File (Path [Load a] "code")    (Data (Load x))
    -> Just (CodeFact a x)
  File (Path [Load a] "balance") (Data (Load x))
    -> Just (BalanceFact a x)
  File (Path [Load a] "nonce")   (Data (Load x))
    -> Just (NonceFact a x)
  File (Path [Load a, "storage"] (Load x)) (Data (Load y))
    -> Just (StorageFact a y x)
  _
    -> Nothing