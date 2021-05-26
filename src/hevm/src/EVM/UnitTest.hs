{-# Language LambdaCase #-}
{-# Language DataKinds #-}
{-# Language ImplicitParams #-}
{-# LANGUAGE FlexibleInstances #-}

module EVM.UnitTest where

import Debug.Trace

import Prelude hiding (Word)

import EVM
import EVM.ABI
import EVM.Concrete hiding (readMemoryWord)
import EVM.Symbolic
import EVM.Dapp
import EVM.Debug (srcMapCodePos)
import EVM.Exec
import EVM.Format
import EVM.Solidity
import EVM.SymExec
import EVM.Types
import EVM.Transaction (initTx)
import EVM.Mutate (mutateAbiValue)
import qualified EVM.Fetch

import qualified EVM.FeeSchedule as FeeSchedule

import EVM.Stepper (Stepper, interpret)
import qualified EVM.Stepper as Stepper
import qualified Control.Monad.Operational as Operational

import Control.Lens hiding (Indexed)
import Control.Monad.State.Strict hiding (state)
import qualified Control.Monad.State.Strict as State

import Control.Monad.Par.Class (spawn_)
import Control.Monad.Par.IO (runParIO)

import qualified Data.ByteString.Lazy as BSLazy
import qualified Data.SBV.Trans.Control as SBV (Query, getValue, resetAssertions)
import qualified Data.SBV.Internals as SBV (State)
import Data.Binary.Get    (runGet)
import Data.ByteString    (ByteString)
import Data.SBV    hiding (verbose)
import Data.SBV.Control   (CheckSatResult(..), checkSat)
import Data.Decimal       (DecimalRaw(..))
import Data.Either        (isRight, lefts)
import Data.Foldable      (toList)
import Data.Map           hiding (mapMaybe, toList, map, filter, null, take)
import Data.Maybe         (fromMaybe, catMaybes, fromJust, isJust, fromMaybe, mapMaybe)
import Data.Text          (isPrefixOf, stripSuffix, intercalate, Text, pack, unpack)
import Data.Text.Encoding (encodeUtf8)
import System.Environment (lookupEnv)
import System.IO          (hFlush, stdout)
import GHC.Generics       (Generic)

import qualified Control.Monad.Par.Class as Par
import qualified Data.ByteString as BS
import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified Data.Text as Text
import qualified Data.Text.IO as Text

import Data.MultiSet (MultiSet)
import qualified Data.MultiSet as MultiSet

import Data.Set (Set)
import qualified Data.Set as Set

import Data.Vector (Vector)
import qualified Data.Vector as Vector

import Test.QuickCheck hiding (verbose)

data UnitTestOptions = UnitTestOptions
  { oracle     :: EVM.Query -> IO (EVM ())
  , verbose    :: Maybe Int
  , maxIter    :: Maybe Integer
  , smtTimeout :: Maybe Integer
  , smtState   :: Maybe SBV.State
  , solver     :: Maybe Text
  , match      :: Text
  , fuzzRuns   :: Int
  , replay     :: Maybe (Text, BSLazy.ByteString)
  , vmModifier :: VM -> VM
  , dapp       :: DappInfo
  , testParams :: TestVMParams
  , mutations  :: Int
  , corpus     :: FilePath
  }

data TestVMParams = TestVMParams
  { testAddress       :: Addr
  , testCaller        :: Addr
  , testOrigin        :: Addr
  , testGasCreate     :: W256
  , testGasCall       :: W256
  , testBalanceCreate :: W256
  , testBalanceCall   :: W256
  , testCoinbase      :: Addr
  , testNumber        :: W256
  , testTimestamp     :: W256
  , testGaslimit      :: W256
  , testGasprice      :: W256
  , testMaxCodeSize   :: W256
  , testDifficulty    :: W256
  , testChainId       :: W256
  }

-- | For each tuple of (contract, method) we store the calldata required to reach each known path in the method
-- | The keys in the corpus are hashed to keep the size of the serialized representation manageable
type Corpus = Map W256 (Map W256 AbiValue)

data FuzzResult = Pass | Fail VM String

defaultGasForCreating :: W256
defaultGasForCreating = 0xffffffffffff

defaultGasForInvoking :: W256
defaultGasForInvoking = 0xffffffffffff

defaultBalanceForCreator :: W256
defaultBalanceForCreator = 0xffffffffffffffffffffffff

defaultBalanceForCreated :: W256
defaultBalanceForCreated = 0xffffffffffffffffffffffff

defaultMaxCodeSize :: W256
defaultMaxCodeSize = 0xffffffff

type ABIMethod = Text

-- | Assuming a constructor is loaded, this stepper will run the constructor
-- to create the test contract, give it an initial balance, and run `setUp()'.
initializeUnitTest :: UnitTestOptions -> SolcContract -> Stepper ()
initializeUnitTest UnitTestOptions { .. } theContract = do

  let addr = testAddress testParams

  Stepper.evm $ do
    -- Maybe modify the initial VM, e.g. to load library code
    modify vmModifier
    -- Make a trace entry for running the constructor
    pushTrace (EntryTrace "constructor")

  -- Constructor is loaded; run until it returns code
  void Stepper.execFully

  Stepper.evm $ do
    -- Give a balance to the test target
    env . contracts . ix addr . balance += w256 (testBalanceCreate testParams)

    -- call setUp(), if it exists, to initialize the test contract
    let theAbi = view abiMap theContract
        setUp  = abiKeccak (encodeUtf8 "setUp()")

    when (isJust (Map.lookup setUp theAbi)) $ do
      abiCall testParams "setUp()" emptyAbi
      popTrace
      pushTrace (EntryTrace "setUp()")

  -- Let `setUp()' run to completion
  res <- Stepper.execFully
  Stepper.evm $ case res of
    Left e -> pushTrace (ErrorTrace e)
    _ -> popTrace


-- | Assuming a test contract is loaded and initialized, this stepper
-- will run the specified test method and return whether it succeeded.
runUnitTest :: UnitTestOptions -> ABIMethod -> AbiValue -> Stepper Bool
runUnitTest a method args = do
  x <- execTest a method args
  checkFailures a method x

execTest :: UnitTestOptions -> ABIMethod -> AbiValue -> Stepper Bool
execTest UnitTestOptions { .. } method args = do
  -- Set up the call to the test method
  Stepper.evm $ do
    abiCall testParams method args
    pushTrace (EntryTrace method)
  -- Try running the test method
  Stepper.execFully >>= \case
     -- If we failed, put the error in the trace.
    Left e -> Stepper.evm (pushTrace (ErrorTrace e)) >> pure True
    _ -> pure False

checkFailures :: UnitTestOptions -> ABIMethod -> Bool -> Stepper Bool
checkFailures UnitTestOptions { .. } method bailed = do
   -- Decide whether the test is supposed to fail or succeed
  let shouldFail = "testFail" `isPrefixOf` method
  if bailed then
    pure shouldFail
  else do
    -- Ask whether any assertions failed
    Stepper.evm $ do
      popTrace
      abiCall testParams "failed()" emptyAbi
    res <- Stepper.execFully
    case res of
      Right (ConcreteBuffer r) ->
        let AbiBool failed = decodeAbiValue AbiBoolType (BSLazy.fromStrict r)
        in pure (shouldFail == failed)
      _ -> error "internal error: unexpected failure code"

-- | Either generates the calldata by mutating an example from the corpus, or synthesizes a random example
genWithCorpus :: UnitTestOptions -> Corpus -> SolcContract -> Text -> [AbiType] -> Gen AbiValue
genWithCorpus opts corpus contract' sig tps = do
  -- TODO: also check that the contract matches here
  case Map.lookup (hashCall (contract', sig)) corpus of
    Nothing -> genAbiValue (AbiTupleType $ Vector.fromList tps)
    Just examples -> frequency
      [ (mutations opts,         Test.QuickCheck.elements (Map.elems examples) >>= mutateAbiValue)
      , (100 - (mutations opts), genAbiValue (AbiTupleType $ Vector.fromList tps))
      ]

-- | Randomly generates the calldata arguments and runs the test, updates the corpus with a new example if we explored a new path
fuzzTest :: UnitTestOptions -> Text -> [AbiType] -> VM -> StateT Corpus IO FuzzResult
fuzzTest opts sig types vm = do
  let code' = _contractcode . fromJust $ currentContract vm
      contract' = fromJust $ lookupCode code' (dapp opts)
  corpus <- get
  args <- liftIO . generate $ genWithCorpus opts corpus contract' sig types
  (res, (vm', coverage)) <- liftIO $ runStateT (interpretWithCoverage opts (runUnitTest opts sig args)) (vm, mempty)
  modify $ updateCorpus (hashCall (contract', sig)) (hashTrace coverage) args
  if res
     then pure Pass
     else pure $ Fail vm' (show . ByteStringS . encodeAbiValue $ args)
  where
    updateCorpus k1 k2 v c = case Map.lookup k1 c of
      Nothing -> Map.insert k1 (Map.insert k2 v mempty) c
      Just m' -> Map.insert k1 (Map.insert k2 v m') c

hashCall :: (SolcContract, Text) -> W256
hashCall (contract', sig) = keccak . encodeUtf8 $
  (Text.pack . show . _runtimeCodehash $ contract') <> (Text.pack . show . _creationCodehash $ contract') <> sig

hashTrace :: MultiSet OpLocation -> W256
hashTrace = keccak . encodeUtf8 . Text.pack . show . (fmap hashLoc) . MultiSet.toList

hashLoc :: OpLocation -> W256
hashLoc (OpLocation code ix) = keccak . encodeUtf8 . Text.pack $ (show code) <> (show ix)

tick :: Text -> IO ()
tick x = Text.putStr x >> hFlush stdout

-- | This is like an unresolved source mapping.
data OpLocation = OpLocation
  { srcCode :: ContractCode
  , srcOpIx :: Int
  } deriving (Show, Eq, Ord, Generic)

srcMapForOpLocation :: DappInfo -> OpLocation -> Maybe SrcMap
srcMapForOpLocation dapp (OpLocation hash opIx) = srcMap dapp hash opIx

type CoverageState = (VM, MultiSet OpLocation)

currentOpLocation :: VM -> OpLocation
currentOpLocation vm =
  case currentContract vm of
    Nothing ->
      error "internal error: why no contract?"
    Just c ->
      OpLocation
        (view contractcode c)
        (fromMaybe (error "internal error: op ix") (vmOpIx vm))

execWithCoverage :: StateT CoverageState IO VMResult
execWithCoverage = do _ <- runWithCoverage
                      fromJust <$> use (_1 . result)

runWithCoverage :: StateT CoverageState IO VM
runWithCoverage = do
  -- This is just like `exec` except for every instruction evaluated,
  -- we also increment a counter indexed by the current code location.
  vm0 <- use _1
  case view result vm0 of
    Nothing -> do
      vm1 <- zoom _1 (State.state (runState exec1) >> get)
      zoom _2 (modify (MultiSet.insert (currentOpLocation vm1)))
      runWithCoverage
    Just _ -> pure vm0


interpretWithCoverage
  :: UnitTestOptions
  -> Stepper a
  -> StateT CoverageState IO a
interpretWithCoverage opts =
  eval . Operational.view

  where
    eval
      :: Operational.ProgramView Stepper.Action a
      -> StateT CoverageState IO a

    eval (Operational.Return x) =
      pure x

    eval (action Operational.:>>= k) =
      case action of
        Stepper.Exec ->
          execWithCoverage >>= interpretWithCoverage opts . k
        Stepper.Run ->
          runWithCoverage >>= interpretWithCoverage opts . k
        Stepper.Wait q ->
          do m <- liftIO (oracle opts q)
             zoom _1 (State.state (runState m)) >> interpretWithCoverage opts (k ())
        Stepper.Ask _ ->
          error "cannot make choice in this interpreter"
        Stepper.EVM m ->
          zoom _1 (State.state (runState m)) >>= interpretWithCoverage opts . k

coverageReport
  :: DappInfo
  -> MultiSet SrcMap
  -> Map Text (Vector (Int, ByteString))
coverageReport dapp cov =
  let
    sources :: SourceCache
    sources = view dappSources dapp

    allPositions :: Set (Text, Int)
    allPositions =
      ( Set.fromList
      . mapMaybe (srcMapCodePos sources)
      . toList
      $ mconcat
        ( view dappSolcByName dapp
        & Map.elems
        & map (\x -> view runtimeSrcmap x <> view creationSrcmap x)
        )
      )

    srcMapCov :: MultiSet (Text, Int)
    srcMapCov = MultiSet.mapMaybe (srcMapCodePos sources) cov

    linesByName :: Map Text (Vector ByteString)
    linesByName =
      Map.fromList $ zipWith
          (\(name, _) lines' -> (name, lines'))
          (view sourceFiles sources)
          (view sourceLines sources)

    f :: Text -> Vector ByteString -> Vector (Int, ByteString)
    f name =
      Vector.imap
        (\i bs ->
           let
             n =
               if Set.member (name, i + 1) allPositions
               then MultiSet.occur (name, i + 1) srcMapCov
               else -1
           in (n, bs))
  in
    Map.mapWithKey f linesByName

coverageForUnitTestContract
  :: UnitTestOptions
  -> Map Text SolcContract
  -> SourceCache
  -> (Text, [(Test, [AbiType])])
  -> IO (MultiSet SrcMap)
coverageForUnitTestContract
  opts@(UnitTestOptions {..}) contractMap _ (name, testNames) = do

  -- Look for the wanted contract by name from the Solidity info
  case preview (ix name) contractMap of
    Nothing ->
      -- Fail if there's no such contract
      error $ "Contract " ++ unpack name ++ " not found"

    Just theContract -> do
      -- Construct the initial VM and begin the contract's constructor
      let vm0 = initialUnitTestVm opts theContract
      (vm1, cov1) <-
        execStateT
          (interpretWithCoverage opts
            (Stepper.enter name >> initializeUnitTest opts theContract))
          (vm0, mempty)

      -- Define the thread spawner for test cases
      let
        runOne' (test, _) = spawn_ . liftIO $ do
          (_, (_, cov)) <-
            runStateT
              (interpretWithCoverage opts (runUnitTest opts (extractSig test) emptyAbi))
              (vm1, mempty)
          pure cov
      -- Run all the test cases in parallel and gather their coverages
      covs <-
        runParIO (mapM runOne' testNames >>= mapM Par.get)

      -- Sum up all the coverage counts
      let cov2 = MultiSet.unions (cov1 : covs)

      pure (MultiSet.mapMaybe (srcMapForOpLocation dapp) cov2)

runUnitTestContract
  :: UnitTestOptions
  -> Corpus
  -> Map Text SolcContract
  -> (Text, [(Test, [AbiType])])
  -> SBV.Query (Corpus, [(Bool, VM)])
runUnitTestContract
  opts@(UnitTestOptions {..}) corpus' contractMap (name, testSigs) = do

  -- Print a header
  liftIO $ putStrLn $ "Running " ++ show (length testSigs) ++ " tests for "
    ++ unpack name

  -- Look for the wanted contract by name from the Solidity info
  case preview (ix name) contractMap of
    Nothing ->
      -- Fail if there's no such contract
      error $ "Contract " ++ unpack name ++ " not found"

    Just theContract -> do
      -- Construct the initial VM and begin the contract's constructor
      let vm0 = initialUnitTestVm opts theContract
      vm1 <-
        liftIO $ execStateT
          (EVM.Stepper.interpret oracle
            (Stepper.enter name >> initializeUnitTest opts theContract))
          vm0

      case view result vm1 of
        Nothing -> error "internal error: setUp() did not end with a result"
        Just (VMFailure _) -> liftIO $ do
          Text.putStrLn "\x1b[31m[BAIL]\x1b[0m setUp() "
          tick "\n"
          tick $ failOutput vm1 opts "setUp()"
          pure (corpus', [(False, vm1)])
        Just (VMSuccess _) -> do
          let
            runCache :: ([(Either Text Text, VM)], VM, Corpus) -> (Test, [AbiType])
                        -> SBV.Query ([(Either Text Text, VM)], VM, Corpus)
            runCache (results, vm, corp) (test, types) = do
              (t, r, vm', corp') <- runTest opts vm corp (test, types)
              liftIO $ Text.putStrLn t
              let vmCached = vm & set (cache . fetched) (view (cache . fetched) vm')
              pure (((r, vm'): results), vmCached, corp')

          -- Run all the test cases and print their status updates,
          -- accumulating the vm cache throughout
          (details, _, finalCorpus) <- foldM runCache ([], vm1, corpus') testSigs

          let running = [x | (Right x, _) <- details]
          let bailing = [x | (Left  x, _) <- details]

          liftIO $ do
            tick "\n"
            tick (Text.unlines (filter (not . Text.null) running))
            tick (Text.unlines (filter (not . Text.null) bailing))

          pure (finalCorpus, [(isRight r, vm) | (r, vm) <- details])


runTest :: UnitTestOptions -> VM -> Corpus -> (Test, [AbiType]) -> SBV.Query (Text, Either Text Text, VM, Corpus)
runTest opts@UnitTestOptions{..} vm corpus' (ConcreteTest testName, []) = do
  (msg, verboseMsg, postvm) <- liftIO (runOne opts vm testName emptyAbi)
  pure (msg, verboseMsg, postvm, corpus')
runTest opts@UnitTestOptions{..} vm corpus' (ConcreteTest testName, types) = liftIO $ case replay of
  Nothing -> fuzzRun opts vm corpus' testName types
  Just (sig, callData) ->
    if sig == testName
    then do
      (msg, verboseMsg, postvm) <- runOne opts vm testName $ decodeAbiValue (AbiTupleType (Vector.fromList types)) callData
      pure (msg, verboseMsg, postvm, corpus')
    else fuzzRun opts vm corpus' testName types
runTest opts vm corpus' (SymbolicTest testName, types) = do
  (msg, verboseMsg, postvm) <- symRun opts vm testName types
  pure (msg, verboseMsg, postvm, corpus')

-- | Define the thread spawner for normal test cases
runOne :: UnitTestOptions -> VM -> ABIMethod -> AbiValue -> IO (Text, Either Text Text, VM)
runOne opts@UnitTestOptions{..} vm testName args = do
  let argInfo = pack (if args == emptyAbi then "" else " with arguments: " <> show args)
  (bailed, vm') <-
    runStateT
      (EVM.Stepper.interpret oracle (execTest opts testName args))
      vm
  (success, vm'') <-
    runStateT
      (EVM.Stepper.interpret oracle (checkFailures opts testName bailed)) vm'
  if success
  then
     let gasSpent = num (testGasCall testParams) - view (state . gas) vm'
         gasText = pack $ show (fromIntegral gasSpent :: Integer)
     in
        pure
          ("\x1b[32m[PASS]\x1b[0m "
           <> testName <> argInfo <> " (gas: " <> gasText <> ")"
          , Right (passOutput vm'' opts testName)
          , vm''
          )
  else if bailed then
        pure
          ("\x1b[31m[BAIL]\x1b[0m "
           <> testName <> argInfo
          , Left (failOutput vm'' opts testName)
          , vm''
          )
      else
        pure
          ("\x1b[31m[FAIL]\x1b[0m "
           <> testName <> argInfo
          , Left (failOutput vm'' opts testName)
          , vm''
          )

-- | Define the thread spawner for property based tests
fuzzRun :: UnitTestOptions -> VM -> Corpus -> Text -> [AbiType] -> IO (Text, Either Text Text, VM, Corpus)
fuzzRun opts@UnitTestOptions{..} vm corpus' testName types = do

  (res, finalCorpus) <- foldM (\(res, corp) _ -> case res of
      Pass -> runStateT (fuzzTest opts testName types vm) corp
      Fail {} -> pure (res, corp)
    ) (Pass, corpus') [0..fuzzRuns]

  case res of
    (Pass) ->
      pure ("\x1b[32m[PASS]\x1b[0m "
              <> testName <> " (runs: " <> (pack . show $ fuzzRuns) <> ")"
             -- this isn't the post vm we actually want, as we
             -- can't retrieve the correct vm from quickcheck
           , Right (passOutput vm opts testName)
           , vm
           , finalCorpus
           )
    (Fail vm' cex) ->
      pure ("\x1b[31m[FAIL]\x1b[0m "
             <> testName <> ". Counterexample: " <> ppOutput
             <> "\nRun:\n dapp test --replay '(\"" <> testName <> "\",\""
             <> (pack cex) <> "\")'\nto test this case again, or \n dapp debug --replay '(\""
             <> testName <> "\",\"" <> (pack cex) <> "\")'\nto debug it."
           , Left (failOutput vm' opts testName)
           , vm'
           , finalCorpus
           )
       where
         abiValue = decodeAbiValue (AbiTupleType (Vector.fromList types)) $ BSLazy.fromStrict $ hexText (pack cex)
         ppOutput = pack $ show abiValue

-- | Define the thread spawner for symbolic tests
-- TODO: return a list of VM's
symRun :: UnitTestOptions -> VM -> Text -> [AbiType] -> SBV.Query (Text, Either Text Text, VM)
symRun opts@UnitTestOptions{..} concreteVm testName types = do
    SBV.resetAssertions
    let vm = symbolify concreteVm
    (cd, cdlen) <- symCalldata testName types []
    let cd' = (SymbolicBuffer cd, w256lit cdlen)
        shouldFail = "proveFail" `isPrefixOf` testName

    -- get all posible postVMs for the test method
    allPaths <- fst <$> runStateT
        (EVM.SymExec.interpret oracle maxIter (execSymTest opts testName cd')) vm
    let consistentPaths = flip filter allPaths $
          \(_, vm') -> case view result vm' of
            Just (VMFailure DeadPath) -> False
            _ -> True
    results <- forM consistentPaths $
      -- If the vm execution succeeded, check if the vm is reachable,
      -- and if any ds-test assertions were triggered
      -- Report a failure depending on the prefix of the test name

      -- If the vm execution failed, check if the vm is reachable, and if so,
      -- report a failure unless the test is supposed to fail.

      \(bailed, vm') -> do
        let ?context = DappContext { _contextInfo = dapp, _contextEnv = vm ^?! EVM.env }
        SBV.resetAssertions
        constrain $ sAnd (fst <$> view EVM.constraints vm')
        unless bailed $
          case view result vm' of
            Just (VMSuccess (SymbolicBuffer buf)) ->
              constrain $ litBytes (encodeAbiValue $ AbiBool $ not shouldFail) .== buf
            r -> error $ "unexpected return value: " ++ show r
        checkSat >>= \case
          Sat -> do
            prettyCd <- prettyCalldata cd' testName types
            let explorationFailed = case view result vm' of
                  Just (VMFailure e) -> case e of
                                          NotUnique _ -> True
                                          UnexpectedSymbolicArg -> True
                                          _ -> False
                  _ -> False
            return $
              if shouldFail && bailed && not explorationFailed
              then Right ()
              else Left (vm', prettyCd)
          Unsat -> return $ Right ()
          Unk -> return $ Left (vm', "unknown; query timeout")
          DSat _ -> error "Unexpected DSat"

    if null $ lefts results
    then
      return ("\x1b[32m[PASS]\x1b[0m " <> testName, Right "", vm)
    else
      return ("\x1b[31m[FAIL]\x1b[0m " <> testName, Left $ symFailure opts testName (lefts results), vm)

symFailure :: UnitTestOptions -> Text -> [(VM, Text)] -> Text
symFailure UnitTestOptions {..} testName failures' = mconcat
  [ "Failure: "
  , testName
  , "\n\n"
  , intercalate "\n" $ indentLines 2 . mkMsg <$> failures'
  ]
  where
    showRes vm = let Just res = view result vm in
                 case res of
                   VMFailure _ ->
                     let ?context = DappContext { _contextInfo = dapp, _contextEnv = vm ^?! EVM.env }
                     in prettyvmresult res
                   VMSuccess _ -> if "proveFail" `isPrefixOf` testName
                                  then "Successful execution"
                                  else "Failed: DSTest Assertion Violation"
    mkMsg (vm, cd) = pack $ unlines
      ["Counterexample:"
      ,""
      ,"  result:   " <> showRes vm
      ,"  calldata: " <> unpack cd
      , case verbose of
          Just _ -> unlines
            [ ""
            , unpack $ indentLines 2 (showTraceTree dapp vm)
            ]
          _ -> ""
      ]

prettyCalldata :: (?context :: DappContext) => (Buffer, SymWord) -> Text -> [AbiType]-> SBV.Query Text
prettyCalldata (buffer, S _ cdlen) sig types = do
  cdlen' <- num <$> SBV.getValue cdlen
  cd <- case buffer of
    SymbolicBuffer cd -> mapM (SBV.getValue . fromSized) (take cdlen' cd) <&> BS.pack
    ConcreteBuffer cd -> return $ BS.take cdlen' cd
  pure $ (head (Text.splitOn "(" sig)) <> showCall types (ConcreteBuffer cd)

execSymTest :: UnitTestOptions -> ABIMethod -> (Buffer, SymWord) -> Stepper (Bool, VM)
execSymTest opts@UnitTestOptions{ .. } method cd = do
  -- Set up the call to the test method
  Stepper.evm $ do
    makeTxCall testParams cd
    pushTrace (EntryTrace method)
  -- Try running the test method
  Stepper.runFully >>= \vm' -> case view result vm' of
    Just (VMFailure err) ->
      -- If we failed, put the error in the trace.
      Stepper.evm (pushTrace (ErrorTrace err)) >> (pure (True, vm'))
    Just (VMSuccess _) -> do
      postVm <- checkSymFailures opts
      pure (False, postVm)
    Nothing -> error "Internal Error: execSymTest: vm has not completed execution!"

checkSymFailures :: UnitTestOptions -> Stepper VM
checkSymFailures UnitTestOptions { .. } = do
  -- Ask whether any assertions failed
  Stepper.evm $ do
    popTrace
    abiCall testParams "failed()" emptyAbi
  Stepper.runFully

indentLines :: Int -> Text -> Text
indentLines n s =
  let p = Text.replicate n " "
  in Text.unlines (map (p <>) (Text.lines s))

passOutput :: VM -> UnitTestOptions -> Text -> Text
passOutput vm UnitTestOptions { .. } testName =
  let ?context = DappContext { _contextInfo = dapp, _contextEnv = vm ^?! EVM.env }
  in let v = fromMaybe 0 verbose
  in if (v > 1) then
    mconcat
      [ "Success: "
      , fromMaybe "" (stripSuffix "()" testName)
      , "\n"
      , if (v > 2) then indentLines 2 (showTraceTree dapp vm) else ""
      , indentLines 2 (formatTestLogs (view dappEventMap dapp) (view logs vm))
      , "\n"
      ]
    else ""

failOutput :: VM -> UnitTestOptions -> Text -> Text
failOutput vm UnitTestOptions { .. } testName =
  let ?context = DappContext { _contextInfo = dapp, _contextEnv = vm ^?! EVM.env }
  in mconcat
  [ "Failure: "
  , fromMaybe "" (stripSuffix "()" testName)
  , "\n"
  , case verbose of
      Just _ -> indentLines 2 (showTraceTree dapp vm)
      _ -> ""
  , indentLines 2 (formatTestLogs (view dappEventMap dapp) (view logs vm))
  , "\n"
  ]

formatTestLogs :: (?context :: DappContext) => Map W256 Event -> Seq.Seq Log -> Text
formatTestLogs events xs =
  case catMaybes (toList (fmap (formatTestLog events) xs)) of
    [] -> "\n"
    ys -> "\n" <> intercalate "\n" ys <> "\n\n"

-- Here we catch and render some special logs emitted by ds-test,
-- with the intent to then present them in a separate view to the
-- regular trace output.
formatTestLog :: (?context :: DappContext) => Map W256 Event -> Log -> Maybe Text
formatTestLog _ (Log _ _ []) = Nothing
formatTestLog events (Log _ args (topic:_)) =
  case maybeLitWord topic >>= \t1 -> (Map.lookup (wordValue t1) events) of
    Nothing -> Nothing
    Just (Event name _ types) ->
      case (name <> parenthesise (abiTypeSolidity <$> (unindexed types))) of
        "log(string)" -> Just $ unquote $ showValue AbiStringType args

        -- log_named_x(string, x)
        "log_named_bytes32(string, bytes32)" -> log_named
        "log_named_address(string, address)" -> log_named
        "log_named_int(string, int256)"      -> log_named
        "log_named_uint(string, uint256)"    -> log_named
        "log_named_bytes(string, bytes)"     -> log_named
        "log_named_string(string, string)"   -> log_named

        -- log_named_decimal_x(string, uint, x)
        "log_named_decimal_int(string, int256, uint256)"   -> log_named_decimal
        "log_named_decimal_uint(string, uint256, uint256)" -> log_named_decimal

        -- log_x(x)
        "log_bytes32(bytes32)" -> log_unnamed
        "log_address(address)" -> log_unnamed
        "log_int(int256)"      -> log_unnamed
        "log_uint(uint256)"    -> log_unnamed
        "log_bytes(bytes)"     -> log_unnamed
        "log_string(string)"   -> log_unnamed

        -- log_named_x(bytes32, x), as used in older versions of ds-test.
        -- bytes32 are opportunistically represented as strings in Format.hs
        "log_named_bytes32(bytes32, bytes32)" -> log_named
        "log_named_address(bytes32, address)" -> log_named
        "log_named_int(bytes32, int256)"      -> log_named
        "log_named_uint(bytes32, uint256)"    -> log_named

        _ -> Nothing

        where
          ts = unindexed types
          unquote = Text.dropAround (\c -> c == '"' || c == '«' || c == '»')
          log_unnamed =
            Just $ showValue (head ts) args
          log_named =
            let [key, val] = take 2 (textValues ts args)
            in Just $ unquote key <> ": " <> val
          showDecimal dec val =
            pack $ show $ Decimal (num dec) val
          log_named_decimal =
            case args of
              (ConcreteBuffer b) ->
                case toList $ runGet (getAbiSeq (length ts) ts) (BSLazy.fromStrict b) of
                  [key, (AbiUInt 256 val), (AbiUInt 256 dec)] ->
                    Just $ (unquote (showAbiValue key)) <> ": " <> showDecimal dec val
                  [key, (AbiInt 256 val), (AbiUInt 256 dec)] ->
                    Just $ (unquote (showAbiValue key)) <> ": " <> showDecimal dec val
                  _ -> Nothing
              (SymbolicBuffer _) -> Just "<symbolic decimal>"


word32Bytes :: Word32 -> ByteString
word32Bytes x = BS.pack [byteAt x (3 - i) | i <- [0..3]]

abiCall :: TestVMParams -> Text -> AbiValue -> EVM ()
abiCall params sig args =
  let cd = abiMethod sig args
      l = num . BS.length $ cd
  in makeTxCall params (ConcreteBuffer cd, litWord l)

makeTxCall :: TestVMParams -> (Buffer, SymWord) -> EVM ()
makeTxCall TestVMParams{..} cd = do
  resetState
  assign (tx . isCreate) False
  loadContract testAddress
  assign (state . calldata) cd
  assign (state . caller) (litAddr testCaller)
  assign (state . gas) (w256 testGasCall)
  origin' <- fromMaybe (initialContract (RuntimeCode mempty)) <$> use (env . contracts . at testOrigin)
  let originBal = view balance origin'
  when (originBal < (w256 testGasprice) * (w256 testGasCall)) $ error "insufficient balance for gas cost"
  vm <- get
  put $ initTx vm

initialUnitTestVm :: UnitTestOptions -> SolcContract -> VM
initialUnitTestVm (UnitTestOptions {..}) theContract =
  let
    TestVMParams {..} = testParams
    vm = makeVm $ VMOpts
           { vmoptContract = initialContract (InitCode (ConcreteBuffer (view creationCode theContract)))
           , vmoptCalldata = (mempty, 0)
           , vmoptValue = 0
           , vmoptAddress = testAddress
           , vmoptCaller = litAddr testCaller
           , vmoptOrigin = testOrigin
           , vmoptGas = testGasCreate
           , vmoptGaslimit = testGasCreate
           , vmoptCoinbase = testCoinbase
           , vmoptNumber = testNumber
           , vmoptTimestamp = litWord $ w256 testTimestamp
           , vmoptBlockGaslimit = testGaslimit
           , vmoptGasprice = testGasprice
           , vmoptMaxCodeSize = testMaxCodeSize
           , vmoptDifficulty = testDifficulty
           , vmoptSchedule = FeeSchedule.berlin
           , vmoptChainId = testChainId
           , vmoptCreate = True
           , vmoptStorageModel = ConcreteS -- TODO: support RPC
           , vmoptTxAccessList = mempty -- TODO: support unit test access lists???
           }
    creator =
      initialContract (RuntimeCode mempty)
        & set nonce 1
        & set balance (w256 testBalanceCreate)
  in vm
    & set (env . contracts . at ethrunAddress) (Just creator)


-- | takes a concrete VM and makes all storage symbolic
symbolify :: VM -> VM
symbolify vm =
  vm & over (env . contracts . each . storage) mkSymStorage
     & set (env . storageModel) InitialS
  where
    mkSymStorage :: Storage -> Storage
    mkSymStorage (Symbolic _ _) = error "should not happen"
    mkSymStorage (Concrete s) =
      let
        list = [(literal $ toSizzle k, v) | (C _ k, S _ v) <- Map.toList s]
        symlist = [(litWord k, v) | (k, v) <- Map.toList s]
      in Symbolic symlist $ sListArray 0 list

getParametersFromEnvironmentVariables :: Maybe Text -> IO TestVMParams
getParametersFromEnvironmentVariables rpc = do
  block' <- maybe EVM.Fetch.Latest (EVM.Fetch.BlockNumber . read) <$> (lookupEnv "DAPP_TEST_NUMBER")

  (miner,ts,blockNum,diff) <-
    case rpc of
      Nothing  -> return (0,0,0,0)
      Just url -> EVM.Fetch.fetchBlockFrom block' url >>= \case
        Nothing -> error "Could not fetch block"
        Just EVM.Block{..} -> return (  _coinbase
                                      , wordValue $ forceLit _timestamp
                                      , wordValue _number
                                      , wordValue _difficulty
                                      )
  let
    getWord s def = maybe def read <$> lookupEnv s
    getAddr s def = maybe def read <$> lookupEnv s

  TestVMParams
    <$> getAddr "DAPP_TEST_ADDRESS" (createAddress ethrunAddress 1)
    <*> getAddr "DAPP_TEST_CALLER" ethrunAddress
    <*> getAddr "DAPP_TEST_ORIGIN" ethrunAddress
    <*> getWord "DAPP_TEST_GAS_CREATE" defaultGasForCreating
    <*> getWord "DAPP_TEST_GAS_CALL" defaultGasForInvoking
    <*> getWord "DAPP_TEST_BALANCE_CREATE" defaultBalanceForCreator
    <*> getWord "DAPP_TEST_BALANCE_CALL" defaultBalanceForCreated
    <*> getAddr "DAPP_TEST_COINBASE" miner
    <*> getWord "DAPP_TEST_NUMBER" blockNum
    <*> getWord "DAPP_TEST_TIMESTAMP" ts
    <*> getWord "DAPP_TEST_GAS_LIMIT" 0
    <*> getWord "DAPP_TEST_GAS_PRICE" 0
    <*> getWord "DAPP_TEST_MAXCODESIZE" defaultMaxCodeSize
    <*> getWord "DAPP_TEST_DIFFICULTY" diff
    <*> getWord "DAPP_TEST_CHAINID" 99
