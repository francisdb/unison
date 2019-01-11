{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Unison.TypePrinter where

import           Data.Maybe            (isJust)
import           Data.String           (fromString)
import qualified Data.Text             as Text
import           Unison.Names          (Name)
import           Unison.PrettyPrintEnv (PrettyPrintEnv)
import qualified Unison.PrettyPrintEnv as PrettyPrintEnv
import           Unison.Reference      (pattern Builtin)
import           Unison.Type
import           Unison.Util.Pretty    (ColorText, Pretty)
import qualified Unison.Util.Pretty    as PP
import           Unison.Var            (Var)
import qualified Unison.Var            as Var

{- Explanation of precedence handling

   We illustrate precedence rules as follows.

     >=10
       10f 10x

   This example shows that a type application f x is enclosed in parentheses
   whenever the ambient precedence around it is >= 10, and that when printing
   its two components, an ambient precedence of 10 is used in both places.

   The pretty-printer uses the following rules for printing types.

     >=10
       10f 10x
       { 0e } 10t

     >=0
       0a -> 0b

-}

pretty :: Var v => PrettyPrintEnv -> Int -> AnnotatedType v a -> Pretty String
-- p is the operator precedence of the enclosing context (a number from 0 to
-- 11, or -1 to avoid outer parentheses unconditionally).  Function
-- application has precedence 10.
pretty n p tp = case tp of
  Var' v     -> l $ Text.unpack (Var.name v)
  Ref' r     -> l $ Text.unpack (PrettyPrintEnv.typeName n r)
  Cycle' _ _ -> l $ "error" -- TypeParser does not currently emit Cycle
  Abs' _     -> l $ "error" -- TypeParser does not currently emit Abs
  Ann' _ _   -> l $ "error" -- TypeParser does not currently emit Ann
  App' (Ref' (Builtin "Sequence")) x ->
    PP.group $ l "[" <> pretty n 0 x <> l "]"
  Tuple' [x] -> PP.parenthesizeIf (p >= 10) $ "Pair" `PP.hang` PP.spaced
    [pretty n 10 x, "()"]
  Tuple' xs  -> PP.parenthesizeCommas $ map (pretty n 0) xs
  Apps' f xs -> PP.parenthesizeIf (p >= 10) $ pretty n 9 f `PP.hang` PP.spaced
    (pretty n 10 <$> xs)
  Effect1' e t ->
    PP.parenthesizeIf (p >= 10) $ pretty n 9 e <> l " " <> pretty n 10 t
  Effects' es         -> effects (Just es)
  ForallNamed' v body -> if (p < 0)
    then pretty n p body
    else
      paren True
      $         ("∀ " <> l (Text.unpack (Var.name v)) <> ".")
      `PP.hang` pretty n (-1) body
  t@(Arrow' _ _) -> case (ungeneralizeEffects t) of
    EffectfulArrows' (Ref' UnitRef) rest -> arrows True True rest
    EffectfulArrows' fst rest ->
      PP.parenthesizeIf (p >= 0) $ pretty n 0 fst <> arrows False False rest
    _ -> l "error"
  _ -> l "error"
 where
  effects Nothing   = mempty
  effects (Just es) = PP.group $ "{" <> PP.commas (pretty n 0 <$> es) <> "}"
  arrow delay first mes =
    (if first then mempty else PP.softbreak <> l "->")
      <> (if delay then (if first then l "'" else l " '") else mempty)
      <> effects mes
      <> if (isJust mes) || (not delay) && (not first) then l " " else mempty

  arrows delay first [(mes, Ref' UnitRef)] = arrow delay first mes <> l "()"
  arrows delay first ((mes, Ref' UnitRef) : rest) =
    arrow delay first mes <> (parenNoGroup delay $ arrows True True rest)
  arrows delay first ((mes, arg) : rest) =
    arrow delay first mes
      <> (  parenNoGroup (delay && (not $ null rest))
         $  pretty n 0 arg
         <> arrows False False rest
         )
  arrows False False [] = mempty
  arrows False True  [] = mempty  -- not reachable
  arrows True  _     [] = mempty  -- not reachable

  paren True  s = PP.group $ l "(" <> s <> l ")"
  paren False s = PP.group s

  parenNoGroup True  s = l "(" <> s <> l ")"
  parenNoGroup False s = s

  -- parenNest useParen contents = PP.Nest "  " $ paren useParen contents

  l = PP.lit

  -- b = Breakable

pretty' :: Var v => Maybe Int -> PrettyPrintEnv -> AnnotatedType v a -> String
pretty' (Just width) n t = PP.render width $ pretty n (-1) t
pretty' Nothing      n t = PP.render maxBound $ pretty n (-1) t

prettySignatures
  :: Var v
  => PrettyPrintEnv
  -> [(Name, AnnotatedType v a)]
  -> Pretty ColorText
prettySignatures env ts = PP.column2
  [ (PP.text name, ":" <> PP.map fromString (prettyType typ))
  | (name, typ) <- ts
  ]
  where prettyType typ = PP.hang "" (pretty env (-1) typ)

prettyDataHeader :: Name -> Pretty ColorText
prettyDataHeader name = PP.bold "type " <> PP.text name

prettyEffectHeader :: Name -> Pretty ColorText
prettyEffectHeader name = PP.bold "ability " <> PP.text name
