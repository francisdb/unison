{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns      #-}


module Unison.Referent where

import           Data.Maybe             (fromMaybe)
import           Data.Text              (Text)
import qualified Data.Text              as Text
import           Data.Word              (Word64)
import           Prelude                hiding (read)
import           Unison.Hashable        (Hashable)
import qualified Unison.Hashable        as H
import           Unison.Reference       (Reference)
import qualified Unison.Reference       as R

import           Data.Bytes.Get
import           Data.Bytes.Put
import           Data.Bytes.Serial      (deserialize, serialize)
import           Data.Bytes.VarInt      (VarInt (..))
import           Data.ByteString        (ByteString)
import qualified Data.ByteString.Base58 as Base58
import           Data.Text.Encoding     (decodeUtf8, encodeUtf8)
import           Safe                   (readMay)

data Referent = Ref Reference | Con Reference Int
  deriving (Show, Ord, Eq)

type Pos = Word64
type Size = Word64

-- referentToTerm moved to Term.fromReferent
-- termToReferent moved to Term.toReferent

-- (c = compressible part, nc = non-compressible part)
splitSuffix :: Referent -> (String, Maybe String)
splitSuffix = \case
  Ref (R.Builtin t)   -> ("", Just ("#" <> Text.unpack t))
  Con (R.Builtin t) i -> ("", Just ("#" <> Text.unpack t <> "#" <> show i))
  Ref (R.DerivedId id) -> R.splitSuffix id
  Con (R.DerivedId id) i ->
    let (c, nc) = R.splitSuffix id
    in case nc of
      Nothing -> (c, Just ("#" <> show i))
      Just nc -> (c, Just (nc <> "#" <> show i))

showShort :: Int -> Referent -> String
showShort numHashChars r =
  let (c, nc) = splitSuffix r
  in "#" <> take numHashChars c <> fromMaybe "" nc

toString :: Referent -> String
toString = \case
  Ref r     -> show r
  Con r cid -> show r <> "#" <> show cid

isConstructor :: Referent -> Bool
isConstructor (Con _ _) = True
isConstructor _         = False

toReference :: Referent -> Reference
toReference = \case
  Ref r -> r
  Con r _i -> r

toTypeReference :: Referent -> Maybe Reference
toTypeReference = \case
  Con r _i -> Just r
  _ -> Nothing

-- Parses Asdf##Foo as Builtin Foo
-- Parses Asdf#abc123.2 as Derived 'abc123' 1 2
unsafeFromText :: Text -> Referent
unsafeFromText = either error id . fromText

-- examples:
-- `##Text.take` — builtins don’t have cycles
-- `##FileIO#3` — builtins can have suffixes, constructor 3
-- `#2tWjVAuc7` — term ref, no cycle
-- `#y9ycWkiC1.y9` — term ref, part of cycle
-- `#cWkiC1x89#1` — constructor
-- `#DCxrnCAPS.WD#0` — constructor of a type in a cycle
-- Anything to the left of the first # is ignored.
fromText :: Text -> Either String Referent
fromText t = case Text.split (=='#') t of
  [_, "", b]  -> Right $ Ref (R.Builtin b)
  [_, h]      -> Ref <$> getId h
  [_, h, c]   ->
    Con <$> getId h
        <*> fromMaybe (Left "couldn't parse cid") (readMay (Text.unpack c))
  _ -> bail
  where
  getId h = case Text.split (=='.') h of
    [hash]         -> Right $ R.derivedBase58 hash 0 1
    [hash, suffix] -> uncurry (R.derivedBase58 hash) <$> R.readSuffix suffix
    _              -> bail
  bail = Left . Text.unpack $ "couldn't parse a Referent from " <> t

showSuffix :: Pos -> Size -> String
showSuffix i n = Text.unpack . encode58 . runPutS $ put where
  encode58 = decodeUtf8 . Base58.encodeBase58 Base58.bitcoinAlphabet
  put = putLength i >> putLength n
  putLength = serialize . VarInt


readSuffix' :: Text -> Either String (Pos, Size)
readSuffix' t =
  runGetS get =<< (tagError . decode58) t where
  tagError = maybe (Left "base58 decoding error") Right
  decode58 :: Text -> Maybe ByteString
  decode58 = Base58.decodeBase58 Base58.bitcoinAlphabet . encodeUtf8
  get = (,) <$> getLength <*> getLength
  getLength = unVarInt <$> deserialize


instance Hashable Referent where
  tokens (Ref r) = [H.Tag 0] ++ H.tokens r
  tokens (Con r i) = [H.Tag 2] ++ H.tokens r ++ H.tokens (fromIntegral i :: Word64)
