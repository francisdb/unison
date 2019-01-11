{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveAnyClass,StandaloneDeriving #-}

module Unison.Codebase.Editor where

-- import Debug.Trace
import           Control.Monad                  ( forM_, when, foldM)
import           Control.Monad.Extra            ( ifM )
import Data.Foldable (toList)
import           Data.Bifunctor                 ( second )
import           Data.List                      ( foldl' )
import           Data.List.Extra                ( nubOrd )
import qualified Data.Map                      as Map
import Data.Map (Map)
import           Data.Sequence                  ( Seq )
import           Data.Set                       ( Set )
import qualified Data.Set as Set
import           Data.Text                      ( Text
                                                , unpack
                                                )
import qualified Unison.Builtin                as B
import           Unison.Codebase                ( Codebase )
import qualified Unison.Codebase               as Codebase
import           Unison.Codebase.Branch         ( Branch
                                                , Branch0
                                                )
import qualified Unison.Codebase.Branch        as Branch
import           Unison.FileParsers             ( parseAndSynthesizeFile )
import           Unison.Names                   ( Name
                                                , Names
                                                , NameTarget
                                                )
import           Unison.Parser                  ( Ann )
import qualified Unison.Parser                 as Parser
import qualified Unison.PrettyPrintEnv         as PPE
import           Unison.Reference               ( Reference, pattern DerivedId )
import qualified Unison.Reference              as Reference
import           Unison.Result                  ( Note
                                                , Result
                                                )
import qualified Unison.Result                 as Result
import           Unison.Referent                ( Referent )
import qualified Unison.Referent               as Referent
import qualified Unison.Codebase.Runtime       as Runtime
import qualified Unison.Codebase.TermEdit      as TermEdit
import           Unison.Codebase.Runtime       (Runtime)
import qualified Unison.Term                   as Term
import qualified Unison.Type                   as Type
import qualified Unison.Typechecker            as Typechecker
import qualified Unison.Typechecker.Context    as Context
import           Unison.Typechecker.TypeLookup  ( Decl )
import qualified Unison.UnisonFile             as UF
import           Unison.Util.Free               ( Free )
import qualified Unison.Util.Free              as Free
import           Unison.Var                     ( Var )
import qualified Unison.Var as Var

data Event
  = UnisonFileChanged SourceName Text
  | UnisonBranchChanged (Set Name)

type BranchName = Name
type Source = Text -- "id x = x\nconst a b = a"
type SourceName = Text -- "foo.u" or "buffer 7"
type TypecheckingResult v =
  Result (Seq (Note v Ann))
         (PPE.PrettyPrintEnv, Maybe (UF.TypecheckedUnisonFile' v Ann))
type Term v a = Term.AnnotatedTerm v a
type Type v a = Type.AnnotatedType v a

data SlurpComponent v =
  SlurpComponent { implicatedTypes :: Set v, implicatedTerms :: Set v }
  deriving (Show)

data SlurpResult v = SlurpResult {
  -- The file that we tried to add from
    originalFile :: UF.TypecheckedUnisonFile v Ann
  -- The branch after adding everything
  , updatedBranch :: Branch
  -- Previously existed only in the file; now added to the codebase.
  , successful :: SlurpComponent v
  -- Exists in the branch and the file, with the same name and contents.
  , duplicates :: SlurpComponent v
  -- Not added to codebase due to the name already existing
  -- in the branch with a different definition.
  , collisions :: SlurpComponent v
  -- Not added to codebase due to the name existing
  -- in the branch with a conflict (two or more definitions).
  , conflicted :: SlurpComponent v
  -- Names that already exist in the branch, but whose definitions
  -- in `originalFile` are treated as updates.
  , updates :: SlurpComponent v
  -- Names of terms in `originalFile` that couldn't be updated because
  -- they refer to existing constructors. (User should instead do a find/replace,
  -- a constructor rename, or refactor the type that the name comes from).
  , collidingConstructors :: Map v Referent
  -- Already defined in the branch, but with a different name.
  , duplicateReferents :: Branch.RefCollisions
  } deriving (Show)

data Input
  -- high-level manipulation of names
  = AliasUnconflictedI (Set NameTarget) Name Name
  | RenameUnconflictedI (Set NameTarget) Name Name
  | UnnameAllI NameTarget Name
  -- low-level manipulation of names
  | AddTermNameI Referent Name
  | AddTypeNameI Reference Name
  | RemoveTermNameI Referent Name
  | RemoveTypeNameI Reference Name
  -- resolving naming conflicts
  | ChooseTermForNameI Referent Name
  | ChooseTypeForNameI Reference Name
  -- create and remove update directives
  | ListAllUpdatesI
  -- clear updates for a term or type
  | RemoveAllTermUpdatesI Referent
  | RemoveAllTypeUpdatesI Reference
  -- resolve update conflicts
  | ChooseUpdateForTermI Referent Referent
  | ChooseUpdateForTypeI Reference Reference
  -- other
  | SlurpFileI AllowUpdates
  | ListBranchesI
  | SearchByNameI [String]
  | SwitchBranchI BranchName
  | ForkBranchI BranchName
  | MergeBranchI BranchName
  | ShowDefinitionI [String]
  | QuitI
  deriving (Show)

-- Whether or not updates are allowed during file slurping
type AllowUpdates = Bool

data DisplayThing a = BuiltinThing | MissingThing Reference.Id | RegularThing a
  deriving (Eq, Ord, Show)

data Output v
  = Success Input
  | NoUnisonFile
  | UnknownBranch BranchName
  | RenameOutput Name Name NameChangeResult
  | AliasOutput Name Name NameChangeResult
  -- todo: probably remove these eventually
  | UnknownName BranchName NameTarget Name
  | NameAlreadyExists BranchName NameTarget Name
  -- `name` refers to more than one `nameTarget`
  | ConflictedName BranchName NameTarget Name
  | BranchAlreadyExists BranchName
  | ListOfBranches BranchName [BranchName]
  | ListOfDefinitions Branch
      [(Name, Referent, Maybe (Type v Ann))]
      [(Name, Reference, DisplayThing (Decl v Ann))]
  | SlurpOutput (SlurpResult v)
  -- Original source, followed by the errors:
  | ParseErrors Text [Parser.Err v]
  | TypeErrors Text PPE.PrettyPrintEnv [Context.ErrorNote v Ann]
  | DisplayConflicts Branch0
  | Evaluated Names ([(Text, Term v ())], Term v ())
  | Typechecked SourceName PPE.PrettyPrintEnv (UF.TypecheckedUnisonFile' v Ann)
  | FileChangeEvent SourceName Text
  | DisplayDefinitions PPE.PrettyPrintEnv
                       [(Reference, DisplayThing (Term v Ann))]
                       [(Reference, DisplayThing (Decl v Ann))]
  deriving (Show)

data NameChangeResult = NameChangeResult
  { oldNameConflicted :: Set NameTarget
  , newNameAlreadyExists :: Set NameTarget
  , changedSuccessfully :: Set NameTarget
  } deriving (Eq, Ord, Show)

instance Semigroup NameChangeResult where (<>) = mappend
instance Monoid NameChangeResult where
  mempty = NameChangeResult mempty mempty mempty
  NameChangeResult a1 a2 a3 `mappend` NameChangeResult b1 b2 b3 =
    NameChangeResult (a1 <> b1) (a2 <> b2) (a3 <> b3)

-- Function for handling name collisions during a file slurp into the codebase.
-- Receives (collisions)
-- Returns (collisions, updates)
type CollisionHandler = Branch0 -> (Branch0, Branch0)

-- All collisions get treated as updates and are added to successful.
updateCollisionHandler :: CollisionHandler
updateCollisionHandler collided = (mempty, collided)

-- All collisions get left alone and are not added to successes.
addCollisionHandler :: CollisionHandler
addCollisionHandler collided = (collided, mempty)

data Command i v a where
  Input :: Command i v i

  -- Presents some output to the user
  Notify :: Output v -> Command i v ()

  -- This doesn't actually write the branch to the codebase,
  -- only the definitions from the file.
  -- It reads from the codebase and does some branch munging.
  -- Call `MergeBranch` after to actually save your work.
  SlurpFile
    :: CollisionHandler
    -> Branch
    -> UF.TypecheckedUnisonFile v Ann
    -> Command i v (SlurpResult v)

  Typecheck :: Branch
            -> SourceName
            -> Source
            -> Command i v (TypecheckingResult v)

  -- Evaluate a UnisonFile and return the result and the result of
  -- any watched expressions (which are just labeled with `Text`)
  Evaluate :: Branch
           -> UF.UnisonFile v Ann
           -> Command i v ([(Text, Term v ())], Term v ())

  -- Load definitions from codebase:
  -- option 1:
      -- LoadTerm :: Reference -> Command i v (Maybe (Term v Ann))
      -- LoadTypeOfTerm :: Reference -> Command i v (Maybe (Type v Ann))
      -- LoadDataDeclaration :: Reference -> Command i v (Maybe (DataDeclaration' v Ann))
      -- LoadEffectDeclaration :: Reference -> Command i v (Maybe (EffectDeclaration' v Ann))
  -- option 2:
      -- LoadTerm :: Reference -> Command i v (Maybe (Term v Ann))
      -- LoadTypeOfTerm :: Reference -> Command i v (Maybe (Type v Ann))
      -- LoadTypeDecl :: Reference -> Command i v (Maybe (TypeLookup.Decl v Ann))
  -- option 3:
      -- TypeLookup :: [Reference] -> Command i v (TypeLookup.TypeLookup)

  ListBranches :: Command i v [BranchName]

  -- Loads a branch by name from the codebase, returning `Nothing` if not found.
  LoadBranch :: BranchName -> Command i v (Maybe Branch)

  -- Switches the app state to the given branch.
  SwitchBranch :: Branch -> BranchName -> Command i v ()

  -- Returns `False` if a branch by that name already exists.
  NewBranch :: BranchName -> Command i v Bool

  -- Create a new branch which is a copy of the given branch, and assign the
  -- forked branch the given name. Returns `False` if the forked branch name
  -- already exists.
  ForkBranch :: Branch -> BranchName -> Command i v Bool

  -- Merges the branch with the existing branch with the given name. Returns
  -- `False` if no branch with that name exists, `True` otherwise.
  MergeBranch :: BranchName -> Branch -> Command i v Bool

  -- Return the subset of the branch tip which is in a conflicted state.
  -- A conflict is:
  -- * A name with more than one referent.
  -- *
  GetConflicts :: Branch -> Command i v Branch0

  -- RemainingWork :: Branch -> Command i v [RemainingWork]

  -- Return a list of terms whose names match the given queries.
  SearchTerms :: Branch
              -> [String]
              -> Command i v [(Name, Referent, Maybe (Type v Ann))]

  -- Return a list of types whose names match the given queries.
  SearchTypes :: Branch
              -> [String]
              -> Command i v [(Name, Reference)] -- todo: can add Kind later

  LoadTerm :: Reference.Id -> Command i v (Maybe (Term v Ann))

  LoadType :: Reference.Id -> Command i v (Maybe (Decl v Ann))

-- todo: generalize this wrt to handling of collisions
fileToBranch
  :: (Var v, Monad m)
  => CollisionHandler
  -> Codebase m v Ann
  -> Branch
  -> UF.TypecheckedUnisonFile v Ann
  -> m (SlurpResult v)
fileToBranch handleCollisions codebase branch unisonFile = let
  branch0 = Branch.head branch
  branchUpdate = Branch.fromTypecheckedFile unisonFile
  collisions0  = Branch.unconflictedCollisions branchUpdate branch0
  duplicates   = Branch.duplicates branchUpdate branch0
  conflicts = Branch.conflicts' branch0
  -- old references with new names
  dupeRefs     = Branch.refCollisions branchUpdate branch0
  diffNames    = Branch.differentNames dupeRefs branch0
  successes    = branchUpdate `Branch.subtract` 
                    (collisions0 <> duplicates <> dupeRefs)
  (collisions, updates) = handleCollisions collisions0
  mkOutput x =
    uncurry SlurpComponent $ Branch.intersectWithFile x unisonFile
  allTypeDecls =
    (second Left <$> UF.effectDeclarations' unisonFile)
      `Map.union` (second Right <$> UF.dataDeclarations' unisonFile)
  hashedTerms = UF.hashTerms unisonFile
  in do
  -- 1. update Branch.collisions to make it only include things with 0 conflicts currently, but which would conflict if an additional definition was added
  -- 2. create Branch.conflicts to include things with name conflicts currently
  -- 3. fold over implicatedTypes of updates with Branch.updateType
  -- 4. fold over implicatedTerms of updates with Branch.updateTerm and getTyping
  -- 5. Causal.step the result of 3+4
  -- 6. MergeBranch at some point (done)
    forM_ (Map.toList allTypeDecls) $ \(_, (r@(DerivedId id), dd)) ->
      when (successes `Branch.contains` r || updates `Branch.contains` r)
        $ Codebase.putTypeDeclaration codebase id dd
    forM_ (Map.toList hashedTerms) $ \(_, (r@(DerivedId id), tm, typ)) ->
      -- Discard all line/column info when adding to the codebase
      when (successes `Branch.contains` r || updates `Branch.contains` r) $
        Codebase.putTerm
          codebase
          id
          (Term.amap (const Parser.External) tm)
          typ

    let updatesOut = mkOutput updates
        b1 = foldl' go1 branch0 (Map.toList allTypeDecls)
        go1 b0 (v, (ref, _)) =
          if Set.member v (implicatedTypes updatesOut) then
            case toList (Branch.typesNamed (Var.name v) b0) of
              [oldref] -> Branch.replaceType oldref ref b0
              wat -> error $
                "Panic - updates contains a type with conflicts " ++
                show wat
          else b0
        go2 (cctors, b0) (v, (r, _, typ)) =
          if Set.member v (implicatedTerms updatesOut) then
            case toList (Branch.termsNamed (Var.name v) b0) of
              [Referent.Ref oldref] -> getTyping oldref typ >>= \typing -> pure $
                (cctors, Branch.replaceTerm oldref r typing b0)
              [oldref] -> pure (Map.insert v oldref cctors, b0)
              wat -> error $
                "Panic - updates contains a term with conflicts " ++
                show wat
          else pure (cctors, b0)

        getTyping oldTerm newType = do
          oldTypeo <- Codebase.getTypeOfTerm codebase oldTerm
          pure $ case oldTypeo of
            Just oldType ->
              if Typechecker.isEqual oldType newType then TermEdit.Same
              else if Typechecker.isSubtype newType oldType then TermEdit.Subtype
              else TermEdit.Different
            Nothing -> error $ "Tried to replace " ++ show oldTerm
                    ++ " but its type wasn't found in the codebase. Panic!"

    (collidingCtors, b2) <- foldM go2 (Map.empty, b1) (Map.toList hashedTerms)
    -- TODO: make sure it's a noop when updating a definition w/ name conflict
    pure $ SlurpResult unisonFile
       (Branch.append (successes <> dupeRefs <> b2) branch)
       (mkOutput successes)
       (mkOutput duplicates)
       (mkOutput collisions)
       (mkOutput conflicts)
       updatesOut
       collidingCtors
       diffNames

typecheck
  :: (Monad m, Var v)
  => Codebase m v Ann
  -> Names
  -> SourceName
  -> Text
  -> m (TypecheckingResult v)
typecheck codebase names sourceName src =
  Result.getResult $ parseAndSynthesizeFile
    (((<> B.typeLookup) <$>) . Codebase.typeLookupForDependencies codebase)
    names
    (unpack sourceName)
    src

builtinBranch :: Branch
builtinBranch = Branch.append (Branch.fromNames B.names) mempty

newBranch :: Monad m => Codebase m v a -> BranchName -> m Bool
newBranch codebase branchName = forkBranch codebase builtinBranch branchName

forkBranch :: Monad m => Codebase m v a -> Branch -> BranchName -> m Bool
forkBranch codebase branch branchName = do
  ifM (Codebase.branchExists codebase branchName)
      (pure False)
      ((branch ==) <$> Codebase.mergeBranch codebase branchName branch)

mergeBranch :: Monad m => Codebase m v a -> Branch -> BranchName -> m Bool
mergeBranch codebase branch branchName = ifM
  (Codebase.branchExists codebase branchName)
  (Codebase.mergeBranch codebase branchName branch *> pure True)
  (pure False)

-- Returns terms and types, respectively. For terms that are
-- constructors, turns them into their data types.
collateReferences
  :: [Referent] -- terms requested, including ctors
  -> [Reference] -- types requested
  -> ([Reference], [Reference])
collateReferences terms types =
  let terms' = [ r | Referent.Ref r <- terms ]
      types' = terms >>= \case
        Referent.Con r _ -> [r]
        Referent.Req r _ -> [r]
        _                -> []
  in  (terms', nubOrd $ types' <> types)

commandLine
  :: forall i v a
   . Var v
  => IO i
  -> Runtime v
  -> (Branch -> BranchName -> IO ())
  -> (Output v -> IO ())
  -> Codebase IO v Ann
  -> Free (Command i v) a
  -> IO a
commandLine awaitInput rt branchChange notifyUser codebase command = do
  Free.fold go command
 where
  go :: forall x . Command i v x -> IO x
  go = \case
    -- Wait until we get either user input or a unison file update
    Input         -> awaitInput
    Notify output -> notifyUser output
    SlurpFile handler branch unisonFile ->
      fileToBranch handler codebase branch unisonFile
    Typecheck branch sourceName source ->
      typecheck codebase (Branch.toNames branch) sourceName source
    Evaluate branch unisonFile -> do
      selfContained <- Codebase.makeSelfContained codebase (Branch.head branch) unisonFile
      Runtime.evaluate rt selfContained codebase
    ListBranches                      -> Codebase.branches codebase
    LoadBranch branchName             -> Codebase.getBranch codebase branchName
    NewBranch  branchName             -> newBranch codebase branchName
    ForkBranch  branch     branchName -> forkBranch codebase branch branchName
    MergeBranch branchName branch     -> mergeBranch codebase branch branchName
    GetConflicts branch               ->
      pure $ Branch.conflicts' (Branch.head branch)
    SwitchBranch branch branchName    -> branchChange branch branchName
    SearchTerms branch queries ->
      Codebase.fuzzyFindTermTypes codebase branch queries
    SearchTypes branch queries ->
      pure $ Codebase.fuzzyFindTypes' branch queries
    LoadTerm r -> Codebase.getTerm codebase r
    LoadType r -> Codebase.getTypeDeclaration codebase r
