{-# Language BangPatterns #-}
{-# Language LambdaCase #-}
{-# Language OverloadedStrings #-}
{-# Language Strict #-}
{-# Language StrictData #-}
{-# Language RankNTypes #-}
{-# Language TupleSections #-}
{-# Language PatternSynonyms #-}
{-# Language ViewPatterns #-}
{-# Language ScopedTypeVariables #-}
{-# Language DoAndIfThenElse #-}


module Unison.Runtime.Rt1 where

import Control.Monad (foldM, join, when)
import Control.Monad.IO.Class (liftIO)
import Data.Bifunctor (second)
import Data.Foldable (for_, toList)
import Data.IORef
import Data.Int (Int64)
import Data.Map (Map)
import Data.Text (Text)
import Data.Traversable (for)
import Data.Vector (Vector)
import Data.Word (Word64)
import Unison.Runtime.IR (pattern CompilationEnv, pattern Req)
import Unison.Runtime.IR hiding (CompilationEnv, IR, Req, Value, Z)
import Unison.Symbol (Symbol)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import qualified Data.Vector.Mutable as MV
import qualified Unison.Codebase.CodeLookup as CL
import qualified Unison.DataDeclaration as DD
import qualified Unison.Reference as R
import qualified Unison.Runtime.IR as IR
import qualified Unison.Term as Term
import qualified Unison.Var as Var

-- import qualified Unison.TermPrinter as TP
-- import qualified Unison.Util.Pretty as P
-- import Debug.Trace
import Unison.Util.Monoid (intercalateMap)

type CompilationEnv = IR.CompilationEnv ExternalFunction Continuation
type IR = IR.IR ExternalFunction Continuation
type Req = IR.Req ExternalFunction Continuation
type Value = IR.Value ExternalFunction Continuation
type Z = IR.Z ExternalFunction Continuation
type Size = Int
type Stack = MV.IOVector Value

-- The number of stack elements referenced by an IR
type NeededStack = Int

data Continuation
  = WrapHandler Value Continuation
  | One NeededStack Size Stack IR
  | Chain Symbol Continuation Continuation

instance Show Continuation where
  show _c = "<continuation>"

instance External Continuation where
  decompileExternal k = runDS $ Term.lam() paramName <$> go [paramName] k
    where
    paramName = Var.freshIn (used k) (Var.named "result")
    used c = case c of
      One _ _ _ ir -> boundVarsIR ir
      WrapHandler _ k -> used k
      Chain s k1 k2 -> Set.insert s (used k1 <> used k2)
    go :: [Symbol] -> Continuation -> DS (Term Symbol)
    go env k = case k of
      WrapHandler h k -> Term.handle() <$> decompileImpl h <*> go env k
      One _needed size m ir -> do
        captured <- fmap Map.fromList . for (toList (freeSlots ir)) $ \i ->
          (i,) <$> liftIO (at size (LazySlot i) m)
        decompileIR env (specializeIR captured ir)
      Chain s k1 k2 -> do
        k1 <- go env k1
        Term.let1' False [(s, k1)] <$> go (s:env) k2

-- Wrap a `handle h` around the continuation inside the `Req`.
-- Ex: `k = x -> x + 1` becomes `x -> handle h in x + 1`.
wrapHandler :: Value -> Req -> Req
wrapHandler h (Req r cid args k) = Req r cid args (WrapHandler h k)

-- Appends `k2` to the end of the `k` continuation
-- Ex: if `k` is `x -> x + 1` and `k2` is `y -> y + 4`,
-- this produces a continuation `x -> let r1 = x + 1; r1 + 4`.
appendCont :: Symbol -> Req -> Continuation -> Req
appendCont v (Req r cid args k) k2 = Req r cid args (Chain v k k2)

data ExternalFunction =
  ExternalFunction R.Reference (Size -> Stack -> IO Value)
instance External ExternalFunction where
  decompileExternal (ExternalFunction r _) = pure $ Term.ref () r

-- This function converts `Z` to a `Value`.
-- A bunch of variants follow.
at :: Size -> Z -> Stack -> IO Value
at size i m = case i of
  Val v -> force v
  Slot i ->
    -- the top of the stack is slot 0, at index size - 1
    force =<< MV.read m (size - i - 1)
  LazySlot i ->
    MV.read m (size - i - 1)
  External (ExternalFunction _ e) -> e size m

ati :: Size -> Z -> Stack -> IO Int64
ati size i m = at size i m >>= \case
  I i -> pure i
  v -> fail $ "type error, expecting I, got " <> show v

atn :: Size -> Z -> Stack -> IO Word64
atn size i m = at size i m >>= \case
  N i -> pure i
  v -> fail $ "type error, expecting N, got " <> show v

atf :: Size -> Z -> Stack -> IO Double
atf size i m = at size i m >>= \case
  F i -> pure i
  v -> fail $ "type error, expecting F, got " <> show v

atb :: Size -> Z -> Stack -> IO Bool
atb size i m = at size i m >>= \case
  B b -> pure b
  v -> fail $ "type error, expecting B, got " <> show v

att :: Size -> Z -> Stack -> IO Text
att size i m = at size i m >>= \case
  T t -> pure t
  v -> fail $ "type error, expecting T, got " <> show v

ats :: Size -> Z -> Stack -> IO (Vector Value)
ats size i m = at size i m >>= \case
  Sequence v -> pure v
  v -> fail $ "type error, expecting Sequence, got: " <> show v

atd :: Size -> Z -> Stack -> IO (R.Reference, ConstructorId, [Value])
atd size i m = at size i m >>= \case
  Data r id vs -> pure (r, id, vs)
  v -> fail $ "type error, expecting Data, got " <> show v

push :: Size -> Value -> Stack -> IO Stack
push size v s0 = do
  s1 <-
    if size >= MV.length s0
    then do
      -- increase the size to fit
      s1 <- MV.grow s0 (size `max` 128)
      -- traceM $ "Grew stack size to: " <> show (MV.length s1)
      pure s1
    else pure s0
  MV.write s1 size v
  pure s1

-- Values passed to pushMany* are already in stack order:
-- the first Value is deeper on the resulting stack than the final Value
pushMany :: Foldable f
  => Size -> f Value -> Stack -> IO (Size, Stack)
pushMany size values m = do
  m <- ensureSize (size + length values) m
  let pushArg :: Size -> Value -> IO Size
      pushArg size' val = do
        MV.write m size' val
        pure (size' + 1)
  newSize <- foldM pushArg size values
  pure (newSize, m)

pushManyZ :: Foldable f => Size -> f Z -> Stack -> IO (Size, Stack)
pushManyZ size zs m = do
  m <- ensureSize (size + length zs) m
  let pushArg size' z = do
        val <- at size z m -- variable lookup uses current size
        MV.write m size' val
        pure (size' + 1)
  size2 <- foldM pushArg size zs
  pure (size2, m)

ensureSize :: Size -> Stack -> IO Stack
ensureSize size m =
  if (size >= MV.length m) then MV.grow m size
  else pure m

force :: Value -> IO Value
force (Ref _ _ r) = readIORef r >>= force
force v = pure v

data Result
  = RRequest Req
  | RMatchFail {- maybe add more info here. -}
  | RDone Value
  deriving Show

done :: Value -> IO Result
done v = pure (RDone v)

arity :: Value -> Int
arity (Lam n _ _) = n
arity _ = 0

-- Creates a `CompilationEnv` by pulling out all the constructor arities for
-- types that are referenced by the given term, `t`.
compilationEnv :: Monad m
  => CL.CodeLookup m Symbol a
  -> Term.AnnotatedTerm Symbol a
  -> m CompilationEnv
compilationEnv env t = do
  let typeDeps = Term.referencedDataDeclarations t
              <> Term.referencedEffectDeclarations t
  arityMap <- fmap (Map.fromList . join) . for (toList typeDeps) $ \case
    r@(R.DerivedId id) -> do
      decl <- CL.getTypeDeclaration env id
      case decl of
        Nothing -> error $ "no type declaration for " <> show id -- pure []
        Just (Left ad) -> pure $
          let arities = DD.constructorArities $ DD.toDataDecl ad
          in [ ((r, i), arity) | (arity, i) <- arities `zip` [0..] ]
        Just (Right dd) -> pure $
          let arities = DD.constructorArities dd
          in [ ((r, i), arity) | (arity, i) <- arities `zip` [0..] ]
    _ -> pure []
  let cenv = CompilationEnv mempty arityMap

    -- deps = Term.dependencies t
  -- this would rely on haskell laziness for compilation, needs more thought
  --compiledTerms <- fmap (Map.fromList . join) . for (toList deps) $ \case
  --  r@(R.DerivedId id) -> do
  --    o <- CL.getTerm env id
  --    case o of
  --      Nothing -> pure []
  --      Just e -> pure [(r, compile cenv (Term.amap (const ()) e))]
  --  _ -> pure []
  pure $ builtinCompilationEnv <> cenv

builtinCompilationEnv :: CompilationEnv
builtinCompilationEnv = CompilationEnv (builtinsMap <> IR.builtins) mempty
 where
  builtins :: [(Text, Int, Size -> Stack -> IO Value)]
  builtins =
    [ mk2 "Text.++"   att att (pure . T) (<>)
    , mk2 "Text.take" atn att (pure . T) (Text.take . fromIntegral)
    , mk2 "Text.drop" atn att (pure . T) (Text.drop . fromIntegral)
    , mk2 "Text.=="   att att (pure . B) (==)
    , mk2 "Text.!="   att att (pure . B) (/=)
    , mk2 "Text.<="   att att (pure . B) (<=)
    , mk2 "Text.>="   att att (pure . B) (>=)
    , mk2 "Text.>"    att att (pure . B) (>)
    , mk2 "Text.<"    att att (pure . B) (<)
    , mk1 "Text.size" att (pure . N) (fromIntegral . Text.length)

    , mk2 "Sequence.at" atn ats (pure . IR.maybeToOptional)
      $ flip (Vector.!?)
      . fromIntegral
    , mk2 "Sequence.cons" at  ats (pure . Sequence) (Vector.cons)
    , mk2 "Sequence.snoc" ats at  (pure . Sequence) (Vector.snoc)
    , mk2 "Sequence.take" atn ats (pure . Sequence) (Vector.take . fromIntegral)
    , mk2 "Sequence.drop" atn ats (pure . Sequence) (Vector.drop . fromIntegral)
    , mk2 "Sequence.++"   ats ats (pure . Sequence) (<>)
    , mk1 "Sequence.size"  ats (pure . N) (fromIntegral . Vector.length)

    , mk1 "Float.ceiling"  atf (pure . I) ceiling
    , mk1 "Float.floor"    atf (pure . I) floor
    , mk1 "Float.round"    atf (pure . I) round
    , mk1 "Float.truncate" atf (pure . I) truncate

    , mk2 "Debug.watch" att at id (\t v -> putStrLn (Text.unpack t) *> pure v)
    ]

  builtinsMap :: Map R.Reference IR
  builtinsMap = Map.fromList
    [ (R.Builtin name, makeIR arity name ir) | (name, arity, ir) <- builtins ]
  makeIR arity name =
    Leaf
      . Val
      . Lam arity (underapply name)
      . Leaf
      . External
      . ExternalFunction (R.Builtin name)
  underapply name = FormClosure (Term.ref () $ R.Builtin name) []
  mk1
    :: Text
    -> (Size -> Z -> Stack -> IO a)
    -> (b -> IO Value)
    -> (a -> b)
    -> (Text, Int, Size -> Stack -> IO Value)
  mk1 name getA mkB f =
    ( name
    , 1
    , \size stack -> do
      a <- getA size (Slot 0) stack
      mkB $ f a
    )
  mk2
    :: Text
    -> (Size -> Z -> Stack -> IO a)
    -> (Size -> Z -> Stack -> IO b)
    -> (c -> IO Value)
    -> (a -> b -> c)
    -> (Text, Int, Size -> Stack -> IO Value)
  mk2 name getA getB mkC f =
    ( name
    , 2
    , \size stack -> do
      a <- getA size (Slot 1) stack
      b <- getB size (Slot 0) stack
      mkC $ f a b
    )

run :: (R.Reference -> ConstructorId -> [Value] -> IO Value)
    -> CompilationEnv
    -> IR
    -> IO Result
run ioHandler env ir = do
  let -- pir = prettyIR mempty pexternal pcont
      -- pvalue = prettyValue mempty pexternal pcont
      -- pcont _k = "<continuation>" -- TP.prettyTop mempty <$> decompileExternal k
      -- if we had a PrettyPrintEnv, we could use that here
      -- pexternal (ExternalFunction r _) = P.shown r
  -- traceM $ "Running this program"
  -- traceM $ P.render 80 (pir ir)
  supply <- newIORef 0
  m0 <- MV.new 256
  MV.set m0 (T "uninitialized")
  let
    fresh :: IO Int
    fresh = atomicModifyIORef' supply (\n -> (n + 1, n))

    -- TODO:
    -- go :: (MonadReader Size m, MonadState Stack m, MonadIO m) => IR -> m Result
    go :: Size -> Stack -> IR -> IO Result
    go size m ir = do
     -- stackStuff <- traverse (MV.read m) [0..size-1]
     -- traceM $ "stack: " <> show stackStuff
     -- traceM $ "ir: " <> show ir
     -- traceM ""
     case ir of
      Leaf (Val v) -> done v
      Leaf slot -> done =<< at size slot m
      If c t f -> atb size c m >>= \case
        True -> go size m t
        False -> go size m f
      And i j -> atb size i m >>= \case
        True -> go size m j
        False -> done (B False)
      Or i j -> atb size i m >>= \case
        True -> done (B True)
        False -> go size m j
      Not i -> atb size i m >>= (done . B . not)
      Let var b body freeInBody -> go size m b >>= \case
        RRequest req ->
          let needed = if Set.null freeInBody then 0 else Set.findMax freeInBody
          in pure $ RRequest (appendCont var req $ One needed size m body)
        RDone v -> do
          -- Garbage collect the stack occasionally
          (size, m) <-
            if size > MV.length m `div` 2
            then gc size m (if Set.null freeInBody then 0 else Set.findMax freeInBody)
            else pure (size, m)
          -- traceM . P.render 80 $ P.shown var <> " =" `P.hang` pvalue v
          push size v m >>= \m -> go (size + 1) m body
        e@RMatchFail -> error $ show e
      LetRec bs body -> letrec size m bs body
      MakeSequence vs ->
        done . Sequence . Vector.fromList =<< traverse (\i -> at size i m) vs
      Construct r cid args ->
        done . Data r cid =<< traverse (\i -> at size i m) args
      Request r cid args ->
        req <$> traverse (\i -> at size i m) args
        where
        -- The continuation of the request is initially the identity function
        -- and we append to it in `Let` as we unwind the stack
        req vs = RRequest (Req r cid vs (One 0 size m (Leaf $ Slot 0)))
      Handle handler body -> do
        h <- at size handler m
        runHandler size m h body
      Apply fn args -> do
        RDone fn <- go size m fn -- ANF should ensure this match is OK
        fn <- force fn
        call size m fn args
      Match scrutinee cases -> do
        -- scrutinee : Z -- already evaluated :amazing:
        -- cases : [(Pattern, Maybe IR, IR)]
        scrute <- at size scrutinee m -- "I am scrute" / "Dwight K. Scrute"
        tryCases size scrute m cases

      -- Builtins
      AddI i j -> do x <- ati size i m; y <- ati size j m; done (I (x + y))
      SubI i j -> do x <- ati size i m; y <- ati size j m; done (I (x - y))
      MultI i j -> do x <- ati size i m; y <- ati size j m; done (I (x * y))
      DivI i j -> do x <- ati size i m; y <- ati size j m; done (I (x `div` y))
      GtI i j -> do x <- ati size i m; y <- ati size j m; done (B (x > y))
      GtEqI i j -> do x <- ati size i m; y <- ati size j m; done (B (x >= y))
      LtI i j -> do x <- ati size i m; y <- ati size j m; done (B (x < y))
      LtEqI i j -> do x <- ati size i m; y <- ati size j m; done (B (x <= y))
      EqI i j -> do x <- ati size i m; y <- ati size j m; done (B (x == y))
      SignumI i -> do x <- ati size i m; done (I (signum x))
      NegateI i -> do x <- ati size i m; done (I (negate x))
      ModI i j -> do x <- ati size i m; y <- ati size j m; done (I (x `mod` y))

      AddN i j -> do x <- atn size i m; y <- atn size j m; done (N (x + y))
      -- cast to `Int` and subtract
      SubN i j -> do x <- atn size i m; y <- atn size j m
                     done (I (fromIntegral x - fromIntegral y))
      -- subtraction truncated at 0 (don't wrap around)
      DropN i j -> do x <- atn size i m; y <- atn size j m
                      done (N (x - (y `min` x)))
      MultN i j -> do x <- atn size i m; y <- atn size j m; done (N (x * y))
      DivN i j -> do x <- atn size i m; y <- atn size j m; done (N (x `div` y))
      ModN i j -> do x <- atn size i m; y <- atn size j m; done (N (x `mod` y))
      GtN i j -> do x <- atn size i m; y <- atn size j m; done (B (x > y))
      GtEqN i j -> do x <- atn size i m; y <- atn size j m; done (B (x >= y))
      LtN i j -> do x <- atn size i m; y <- atn size j m; done (B (x < y))
      LtEqN i j -> do x <- atn size i m; y <- atn size j m; done (B (x <= y))
      EqN i j -> do x <- atn size i m; y <- atn size j m; done (B (x == y))

      AddF i j -> do x <- atf size i m; y <- atf size j m; done (F (x + y))
      SubF i j -> do x <- atf size i m; y <- atf size j m; done (F (x - y))
      MultF i j -> do x <- atf size i m; y <- atf size j m; done (F (x * y))
      DivF i j -> do x <- atf size i m; y <- atf size j m; done (F (x / y))
      GtF i j -> do x <- atf size i m; y <- atf size j m; done (B (x > y))
      GtEqF i j -> do x <- atf size i m; y <- atf size j m; done (B (x >= y))
      LtF i j -> do x <- atf size i m; y <- atf size j m; done (B (x < y))
      LtEqF i j -> do x <- atf size i m; y <- atf size j m; done (B (x <= y))
      EqF i j -> do x <- atf size i m; y <- atf size j m; done (B (x == y))

    runHandler :: Size -> Stack -> Value -> IR -> IO Result
    runHandler size m handler body =
      go size m body >>= runHandler' size m handler

    -- Certain handlers are of a form where we can can skip the step of
    -- copying the continuation inside the request. We aren't totally
    -- sure what the conditions are, but speculate:
    --
    -- * The Request can't escape the invocation of the handler; that is, the
    --   handler can't stash the request for later, it has to inspect and run
    --   the continuation immediately.
    -- * The handler can't invoke the continuation multiple times, since
    --   evaluation of the continuation will alter the stack.
    -- * Is that sufficient? Does it matter if continuation is called in
    --   tail position or not?
    --
    -- Leijn's "Implementing Algebraic Effects in C" paper mentions there's
    -- a speedup in the case where the handler uses its continuation just once
    -- in tail position:
    -- https://www.microsoft.com/en-us/research/wp-content/uploads/2017/06/algeff-in-c-tr-v2.pdf
    handlerNeedsCopy :: Value -> Bool
    handlerNeedsCopy _ = True -- overly conservative choice, but never wrong!

    runHandler' :: Size -> Stack -> Value -> Result -> IO Result
    runHandler' size m handler r = case r of
      RRequest req -> do
        req <- if handlerNeedsCopy handler then copyRequest req else pure req
        m <- push size (Requested req) m
        result <- call (size + 1) m handler [Slot 0]
        case result of
          RMatchFail -> pure $ RRequest (wrapHandler handler req)
          r -> pure r
      RDone v -> do
        m <- push size (Pure v) m
        call (size + 1) m handler [Slot 0]
      r -> pure r

    call :: Size -> Stack -> Value -> [Z] -> IO Result
    -- call _ _ fn@(Lam _ _ _) args | trace ("call "<> show fn <> " " <>show args) False = undefined
    call size m fn@(Lam arity underapply body) args = let nargs = length args in
      -- fully applied call, `(x y -> ..) 9 10`
      if nargs == arity then do
        (size, m) <- pushManyZ size args m
        go size m body
      -- overapplied call, e.g. `id id 42`
      else if nargs > arity then do
        let (usedArgs, extraArgs) = splitAt arity args
        result <- call size m fn usedArgs
        case result of
          RDone fn' -> call size m fn' extraArgs
          -- foo : Int ->{IO} (Int -> Int)
          -- ...
          -- (foo 12 12)
          RRequest req -> do
            let overApplyName = Var.named "oa"
            extraArgvs <- for extraArgs $ \arg -> at size arg m
            pure . RRequest . appendCont overApplyName req $
                   One 0 size m (Apply (Leaf (Slot 0)) (Val <$> extraArgvs))
          e -> error $ "type error, tried to apply: " <> show e
      -- underapplied call, e.g. `(x y -> ..) 9`
      else do
        argvs <- for args $ \arg -> at size arg m
        case underapply of
          -- Example 1:
          -- f = x y z p -> x - y - z - p
          -- f' = f 1 2 -- Specialize f [2, 1] -- each arg is pushed onto top
          -- f'' = f' 3 -- Specialize f [3, 2, 1]
          -- f'' 4      -- should be the same thing as `f 1 2 3 4`
          --
          -- pushedArgs = [mostRecentlyApplied, ..., firstApplied]
          Specialize lam@(Term.LamsNamed' vs body) pushedArgs -> let
            pushedArgs' :: [ (SymbolC, Value)] -- head is the latest argument
            pushedArgs' = reverse (drop (length pushedArgs) vs `zip` argvs) ++ pushedArgs
            vsRemaining = drop (length pushedArgs') vs
            compiled = compile0 env
              (reverse (fmap (,Nothing) vsRemaining) ++
               fmap (second Just) pushedArgs')
              body
            in done $ Lam (arity - nargs) (Specialize lam pushedArgs') compiled
          Specialize e pushedArgs -> error $ "can't underapply a non-lambda: " <> show e <> " " <> show pushedArgs
          FormClosure tm pushedArgs -> let
            pushedArgs' = reverse argvs ++ pushedArgs
            arity' = arity - nargs
            allArgs = replicate arity' Nothing ++ map Just pushedArgs'
            bound = Map.fromList [ (i, v) | (Just v, i) <- allArgs `zip` [0..]]
            in done $ Lam (arity - nargs)
                       (FormClosure tm pushedArgs')
                       (specializeIR bound body)
    call size m (Cont k) [arg] = do
      v <- at size arg m
      callContinuation size m k v
    call size m fn args = do
      s0 <- traverse (MV.read m) [0..size-1]
      let s = [(0::Int)..] `zip` reverse s0
      error $ "type error - tried to apply a non-function: " <>
        show fn <> " " <> show args <> "\n" <>
        "[\n  " <>
           intercalateMap "\n  " (\(i,v) -> "Slot " <> show i <> ": " <> take 50 (show v)) s
           <> "\n]"

    callContinuation :: Size -> Stack -> Continuation -> Value -> IO Result
    callContinuation size m k v = case k of
      One _ size m ir -> do
        m <- push size v m
        go (size + 1) m ir
      WrapHandler h k -> runHandler' size m h =<< callContinuation size m k v
      -- reassociate to the right during execution, is this needed and why?
      Chain v1 (Chain v2 k1 k2) k3 ->
        callContinuation size m (Chain v1 k1 (Chain v2 k2 k3)) v
      Chain var k1 k2 -> do
        r <- callContinuation size m k1 v
        case r of
          RDone v -> callContinuation size m k2 v
          RRequest req -> pure $ RRequest (appendCont var req k2)
          _ -> pure r

    copyContinuation :: Continuation -> IO Continuation
    copyContinuation k = case k of
      -- reassociate to the right during copying, is this needed and why?
      Chain v1 (Chain v2 k1 k2) k3 ->
        copyContinuation (Chain v1 k1 (Chain v2 k2 k3))
      Chain v k1 k2 -> Chain v <$> copyContinuation k1 <*> copyContinuation k2
      One needed size stack ir -> do
        -- (@0 + @3) -- 3 needed from old stack
        -- (@0)      -- 0 needed from old stack
        -- (1 + 1)   -- 0 needed from old stack
        let slice = MV.slice (size - needed) needed stack
        copied <- MV.clone slice
        pure $ One needed (MV.length copied) copied ir
      WrapHandler h k -> WrapHandler h <$> copyContinuation k

    copyRequest :: Req -> IO Req
    copyRequest (Req r cid args k) = Req r cid args <$> copyContinuation k

    -- Just = match success, Nothing = match fail
    -- Returns Values to be put on the stack when evaluating case guard/body
    tryCase :: (Value, Pattern) -> Maybe [Value]
    -- tryCase x | trace ("tryCase " ++ show x ++ " =") False = undefined
    -- tryCase x = traceShowId $ case x of
    tryCase = \case
      (I x, PatternI x2) -> when' (x == x2) $ Just []
      (F x, PatternF x2) -> when' (x == x2) $ Just []
      (N x, PatternN x2) -> when' (x == x2) $ Just []
      (B x, PatternB x2) -> when' (x == x2) $ Just []
      (T x, PatternT x2) -> when' (x == x2) $ Just []
      (Data r cid args, PatternData r2 cid2 pats)
        -> if r == r2 && cid == cid2
           then join <$> traverse tryCase (zip args pats)
           else Nothing
      (Sequence args, PatternSequence pats) ->
        join <$> traverse tryCase (zip (toList args) (toList pats))
      (Pure v, PatternPure p) -> tryCase (v, p)
      (Pure _, PatternBind _ _ _ _) -> Nothing
      (Requested (Req r cid args k), PatternBind r2 cid2 pats kpat) ->
        if r == r2 && cid == cid2
        then join <$> traverse tryCase (zip (args ++ [Cont k]) (pats ++ [kpat]))
        else Nothing
      (Requested _, PatternPure _) -> Nothing
      (v, PatternAs p) -> (v:) <$> tryCase (v,p)
      (_, PatternIgnore) -> Just []
      (v, PatternVar) -> Just [v]
      (v, p) -> error $
        "bug: type error in pattern match: " <>
        "tryCase (" <> show v <> ", " <> show p <> ")"
      where when' b m = if b then m else Nothing

    tryCases size scrute m ((pat, _vars, cond, body) : remainingCases) =
      case tryCase (scrute, pat) of
        Nothing -> tryCases size scrute m remainingCases -- this pattern didn't match
        Just vars -> do
          (size', m) <- pushMany size vars m
          case cond of
            Just cond -> do
              RDone (B cond) <- go size' m cond
              if cond then go size' m body
              else tryCases size scrute m remainingCases
            Nothing -> go size' m body
    tryCases _ _ _ _ = pure RMatchFail

    -- To evaluate a `let rec`, we push an empty `Ref` onto the stack for each
    -- binding, then evaluate each binding and set that `Ref` to its result.
    -- As long as the variable references occur within a function body,
    -- there's no problem.
    letrec :: Size -> Stack -> [(Symbol, IR)] -> IR -> IO Result
    letrec size m bs body = do
      refs <- for bs $ \(v,b) -> do
        r <- newIORef (UninitializedLetRecSlot v bs body)
        i <- fresh
        pure (Ref i v r, b)
      -- push the empty references onto the stack
      (size', m) <- pushMany size (fst <$> refs) m
      for_ refs $ \(Ref _ _ r, ir) -> do
        let toVal (RDone a) = a
            toVal e = error ("bindings in a let rec must not have effects " ++ show e)
        result <- toVal <$> go size' m ir
        writeIORef r result
      go size' m body

    -- Garbage collect the elements of the stack that are more than `maxSlot`
    -- below the top - this is done just by copying to a fresh stack.
    gc :: Size -> Stack -> Int -> IO (Size, Stack)
    gc size m maxSlot = do
      when (maxSlot < 0) $ fail $ "invalid max slot for garbage collection: " <> show maxSlot
      let size2 = maxSlot + 1
          m2 = MV.slice (size - maxSlot - 1) size2 m
      m <- MV.clone m2
      m <- MV.grow m 256
      pure (size2, m)
    loop (RRequest (Req ref cid vs k)) = do
      ioResult <- ioHandler ref cid vs
      x <- callContinuation 0 m0 k ioResult
      loop x
    loop a = pure a

  r <- go 0 m0 ir
  loop r

instance Show ExternalFunction where
  show _ = "ExternalFunction"
