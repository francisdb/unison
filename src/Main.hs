module Main where

import Control.Monad
import Unison.Syntax.Term as E
import Unison.Syntax.Type as T
import Unison.Type.Context as C
import Unison.Note as N
import Unison.Syntax.Var as V

identity :: E.Term
identity = E.lam1 $ \x -> x

expr :: E.Term
expr = identity

identityAnn = E.Ann identity (forall1 $ \x -> T.Arrow x x)

showType :: Either N.Note T.Type -> String
showType (Left err) = show err
showType (Right a) = show a

idType :: Type
idType = forall1 $ \x -> x

substIdType :: Type -> Type
substIdType (Forall v t) = subst t v (T.Universal (V.decr V.bound1))

main :: IO ()
-- main = putStrLn . show $ (idType, substIdType idType)
-- main = putStrLn . showCtx . snd $ extendUniversal C.empty
main = putStrLn . showType . join $ C.synthesizeClosed (const $ Left (note "fail")) identityAnn
