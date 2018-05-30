{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}

module InputSelection.Policy (
    -- * Infrastructure
    LiftQuickCheck(..)
  , RunPolicy(..)
  , HasTreasuryAddress(..)
  , InputSelectionPolicy
  , PrivacyMode(..)
  , InputSelectionFailure (..)
    -- * Transaction statistics
  , TxStats(..)
    -- * Specific policies
  , exactSingleMatchOnly
  , largestFirst
  , random
  ) where

import           Universum

import           Control.Lens ((%=), (.=))
import           Control.Lens.TH (makeLenses)
import           Control.Monad.Except (MonadError (..))
import qualified Data.Map as Map
import qualified Data.Set as Set
import           Test.QuickCheck

import           Cardano.Wallet.Kernel.CoinSelection.Types (ExpenseRegulation (..),
                                                            getRegulationRatio)

import           Util.Histogram (BinSize (..), Histogram)
import qualified Util.Histogram as Histogram
import           Util.MultiSet (MultiSet)
import qualified Util.MultiSet as MultiSet
import           UTxO.DSL

{-------------------------------------------------------------------------------
  Auxiliary: lift QuickCheck computations
-------------------------------------------------------------------------------}

-- | Monads in which we can run QuickCheck generators
class Monad m => LiftQuickCheck m where
   -- | Run a QuickCheck computation
  liftQuickCheck :: Gen x -> m x

-- | TODO: We probably don't want this instance (or abstract in a different
-- way over "can generate random numbers")
instance LiftQuickCheck IO where
  liftQuickCheck = generate

instance LiftQuickCheck m => LiftQuickCheck (StateT s m) where
  liftQuickCheck = lift . liftQuickCheck

{-------------------------------------------------------------------------------
  Transaction statistics
-------------------------------------------------------------------------------}

-- | Transaction statistics
--
-- Transaction statistics are used for policy evaluation. For "real" input
-- selection policies we don't necessarily need to return this information,
-- although it may be beneficial to do so even there -- it may be useful
-- to monitor these statistics and learn something about the wallet as it
-- operates in reality.
data TxStats = TxStats {
      -- | Number of inputs
      --
      -- This is a histogram because although a single transaction only has
      -- a single value for its number of inputs, recording this as a histogram
      -- allows us to combine the statistics of many transactions.
      txStatsNumInputs :: !Histogram

      -- | Change/payment ratios
    , txStatsRatios    :: !(MultiSet Double)
    }

instance Monoid TxStats where
  mempty = TxStats {
        txStatsNumInputs = Histogram.empty
      , txStatsRatios    = MultiSet.empty
      }
  mappend a b = TxStats {
        txStatsNumInputs = mappendUsing Histogram.add  txStatsNumInputs
      , txStatsRatios    = mappendUsing MultiSet.union txStatsRatios
      }
    where
      mappendUsing :: (a -> a -> a) -> (TxStats -> a) -> a
      mappendUsing op f = f a `op` f b

-- | Partial transaciton statistics
--
-- Partial transactions statistics are useful when constructing a transaciton
-- piece by piece.
data PartialTxStats = PartialTxStats {
      -- | Number of inputs
      --
      -- Unlike for 'TxStats', this is not a histogram. Suppose we have two
      -- 'PartialTxStats' with 'ptxStatsNumInputs' equal to @n@ and @m@.
      -- Then the final histogram should have a single bin at @n + m@ with
      -- count 1. This is rather different from having two transactions with
      -- @n@ inputs and @m@ outputs; this would result in a histogram with
      -- /two/ bins at @n@ and @m@ both with count 1, or, if @n == m@, a
      -- single bin at @n@ with count 2.
      ptxStatsNumInputs :: !Int

      -- | Change/payment ratios
    , ptxStatsRatios    :: !(MultiSet Double)
    }

instance Monoid PartialTxStats where
  mempty = PartialTxStats {
        ptxStatsNumInputs = 0
      , ptxStatsRatios    = MultiSet.empty
      }
  mappend a b = PartialTxStats {
        ptxStatsNumInputs = mappendUsing (+)            ptxStatsNumInputs
      , ptxStatsRatios    = mappendUsing MultiSet.union ptxStatsRatios
      }
    where
      mappendUsing :: (a -> a -> a) -> (PartialTxStats -> a) -> a
      mappendUsing op f = f a `op` f b

-- | Construct transaciton statistics from partial statistics
fromPartialTxStats :: PartialTxStats -> TxStats
fromPartialTxStats PartialTxStats{..} = TxStats{
      txStatsNumInputs = Histogram.singleton (BinSize 1) ptxStatsNumInputs 1
    , txStatsRatios    = ptxStatsRatios
    }

{-------------------------------------------------------------------------------
  Policy
-------------------------------------------------------------------------------}

class Eq a => HasTreasuryAddress a where
  -- | Generate treasury address
    getTreasuryAddr :: a

instance HasTreasuryAddress () where
  getTreasuryAddr = ()

-- | Monads in which we can run input selection policies
class Monad m => RunPolicy m a | m -> a where
  -- | Generate change address
  genChangeAddr :: m a

  -- | Generate fresh hash
  genFreshHash :: m Int

type InputSelectionPolicy h a m =
      (HasTreasuryAddress a, RunPolicy m a, Hash h a)
   => Utxo h a
   -> [(ExpenseRegulation, Output a)]
   -> m (Either (InputSelectionFailure a) (Transaction h a, TxStats))

data InputSelectionFailure a = InputSelectionFailure
                             | InsufficientFundsToCoverFee ExpenseRegulation (Output a)
                             | NeedsExtraInputsToCover (ExpenseRegulation, Output a)


{-------------------------------------------------------------------------------
  Input selection combinator
-------------------------------------------------------------------------------}

data InputPolicyState h a = InputPolicyState {
      -- | Available entries in the UTxO
      _ipsUtxo             :: Utxo h a

      -- | Selected inputs
    , _ipsSelectedInputs   :: Set (Input h a)

      -- | Generated outputs
    , _ipsGeneratedOutputs :: [(ExpenseRegulation, Output a)]
    }

initInputPolicyState :: Utxo h a -> InputPolicyState h a
initInputPolicyState utxo = InputPolicyState {
      _ipsUtxo             = utxo
    , _ipsSelectedInputs   = Set.empty
    , _ipsGeneratedOutputs = []
    }

makeLenses ''InputPolicyState

newtype InputPolicyT h a m x = InputPolicyT {
      unInputPolicyT :: StateT (InputPolicyState h a) (ExceptT (InputSelectionFailure a) m) x
    }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadState (InputPolicyState h a)
           , MonadError (InputSelectionFailure a)
           )

instance MonadTrans (InputPolicyT h a) where
  lift = InputPolicyT . lift . lift

instance LiftQuickCheck m => LiftQuickCheck (InputPolicyT h a m) where
  liftQuickCheck = lift . liftQuickCheck

instance RunPolicy m a => RunPolicy (InputPolicyT h a m) a where
  genChangeAddr   = lift genChangeAddr
  genFreshHash    = lift genFreshHash

runInputPolicyT :: (Hash h a, HasTreasuryAddress a, RunPolicy m a)
                => (Int -> [Value] -> Value)
                -- ^ Function to compute the estimated fees
                -> Utxo h a
                -> InputPolicyT h a m PartialTxStats
                -> m (Either (InputSelectionFailure a) (Transaction h a, TxStats))
runInputPolicyT estimateFee utxo policy = do
     mx <- runExceptT (runStateT (unInputPolicyT policy) initSt)
     case mx of
       Left err ->
         return $ Left err
       Right (ptxStats, finalSt) -> do
         let selectedInputs = finalSt ^. ipsSelectedInputs
             treasuryAddr   = getTreasuryAddr
             -- Filter any treasury address, as they should concur in the input
             -- selection, but not in the calculation of the fee and should not
             -- be visible in the final outputs of the transaction.
             -- NOTE(adn) Is the last sentenced true? As far as the DSL is
             -- concerned, should be perfectly fine to have outputs which
             -- target the treasury address, I guess much less so for the
             -- actual translation to Cardano.
             generatedOutputs = filter ((/=) treasuryAddr . outAddr . snd) (finalSt ^. ipsGeneratedOutputs)
             inputsLen        = length selectedInputs
             outputsWithFees  = distributeFee estimateFee generatedOutputs inputsLen

         case outputsWithFees of
              Left e -> return (Left e)
              Right outputs -> do
                 let upperBoundFee = estimateFee inputsLen (map outVal outputs)
                     -- 'amountNeeded' already includes the fees.
                     amountNeeded  = foldl' (\acc out -> acc + outVal out) 0 outputs
                     amountCovered = utxoBalance (utxoRestrictToInputs selectedInputs utxo)

                 -- Check if the selected inputs covers the fees
                 case amountCovered >= amountNeeded of
                      False -> do
                          -- Calculate how much we need more
                          let slack = amountNeeded - amountCovered
                              -- The extra goal @must@ have by construction a
                              -- 'senderPays' expense regulation, otherwise 'distributeFee'
                              -- would have failed, as the receivers would have failed
                              -- to cover the fees themselves. Therefore, if we got any
                              -- slack we failed to cover, it must come from the sender's side.
                              -- NOTE(adn) I don't think this is true, due to the
                              -- fact we might have things like 'sharedCost', which makes
                              -- the process of attribution of the fee not trivial.
                              newGoal = (SenderPaysFees, Output treasuryAddr slack)
                          -- \"Rerun\" with the amended goals.
                          return $ Left (NeedsExtraInputsToCover newGoal)
                      True -> do
                          h <- genFreshHash
                          return $ Right (
                              Transaction {
                                  trFresh = 0
                                , trIns   = finalSt ^. ipsSelectedInputs
                                , trOuts  = outputs
                                , trFee   = upperBoundFee
                                , trHash  = h
                                , trExtra = []
                                }
                            , fromPartialTxStats ptxStats
                            )
  where
    initSt = initInputPolicyState utxo


-- | Transforms a list of outputs and their 'ExpenseRegulation's into a
-- list of 'Output' already amended by the fee, according to the expense
-- regulation bias. The fee is intended as an upper bound.
distributeFee :: (Int -> [Value] -> Value)
              -> [(ExpenseRegulation, Output a)]
              -> Int
              -- ^ The number of inputs (from the future).
              -> Either (InputSelectionFailure a) [Output a]
distributeFee estimateFee goals expectedInputsLen =
    let upperBoundFee = estimateFee expectedInputsLen (map (outVal . snd) goals)
        epsilon       = case goals of
                            [] -> upperBoundFee
                            _  -> upperBoundFee `div` (fromIntegral $ length goals)
    in case partitionEithers (map (distribute epsilon) goals) of
            ([], validOutputs) ->
                -- Filter outputs which has a final 'outVal' of @exactly@ 0.
                -- It's something quite rare but it can happen, and we probably
                -- don't want them to contribute to the final Tx size and fee
                -- calculation.
                Right (filter ((== 0) . outVal) . map snd $ validOutputs)
            (err : _, _)       -> Left err
    where
        distribute :: Value
                   -- ^ The \"slice\" @ε@ of the total fee each 'Output'
                   -- needs to be amended for.
                   -> (ExpenseRegulation, Output a)
                   -> Either (InputSelectionFailure a) (ExpenseRegulation, Output a)
        distribute epsilon (expenseRegulation, output) =
            let coefficient = getRegulationRatio expenseRegulation
                val = outVal output
                regulated = regulateBy coefficient epsilon val
            in case regulated of
                    Nothing     -> Left (InsufficientFundsToCoverFee expenseRegulation output)
                    Just newVal -> Right (expenseRegulation, output { outVal = newVal })

        -- Regulate the fee according to the 'ExpenseRegulation' coefficient.
        -- This function will currently blow up for a coefficient
        -- greater than 1.0, but it's not totally obvious if this ought to be
        -- an error. For example, having something like 2.0 would indicate that
        -- the recipient is changed twice for the fees, which might be useful
        -- in some future use cases.
        regulateBy :: Double -> Epsilon -> Value -> Maybe Value
        regulateBy ratio epsilon originalAmount
          | ratio == 0.0                = Just (originalAmount + epsilon)
          | ratio > 0.0 && ratio <= 1.0 =
              -- Pessimistic rounding, always try to take the ceiling, to make
              -- sure rounding errors (if any) do not bring the originalAmount below 0.
              -- In other terms, if we don't get 0 here, we are moderately sure rounding
              -- errors shouldn't affect later computations.
              let newAmount = originalAmount - (ceiling $ (fromIntegral epsilon) * ratio)
              in case newAmount < 0 of
                      True  -> Nothing
                      False -> Just newAmount
          | otherwise = error ("epsilon got an invalid expense regulation coefficient: " <> show ratio)

type Epsilon = Value

{-------------------------------------------------------------------------------
  Exact matches only
-------------------------------------------------------------------------------}

-- | Look for exact single matches only
--
-- Each goal output must be matched by exactly one available output.
exactSingleMatchOnly :: forall h a m. (Int -> [Value] -> Value) -> InputSelectionPolicy h a m
exactSingleMatchOnly estimateFee utxo = \goals -> runInputPolicyT estimateFee utxo $
    mconcat <$> mapM go goals
  where
    go :: (ExpenseRegulation, Output a) -> InputPolicyT h a m PartialTxStats
    go goal@(_, Output _a val) = do
      i <- useExactMatch val
      ipsSelectedInputs   %= Set.insert i
      ipsGeneratedOutputs %= (goal :)
      return PartialTxStats {
          ptxStatsNumInputs = 1
        , ptxStatsRatios    = MultiSet.singleton 0
        }

-- | Look for an input in the UTxO that matches the specified value exactly
useExactMatch :: (Monad m, Hash h a)
              => Value -> InputPolicyT h a m (Input h a)
useExactMatch goalVal = do
    utxo <- utxoToList <$> use ipsUtxo
    case filter (\(_inp, Output _a val) -> val == goalVal) utxo of
      (i, _o) : _ -> ipsUtxo %= utxoDelete i >> return i
      _otherwise  -> throwError InputSelectionFailure

{-------------------------------------------------------------------------------
  Always find the largest UTxO possible
-------------------------------------------------------------------------------}

-- | Always use largest UTxO possible
--
-- NOTE: This is a very efficient implementation. Doesn't really matter, this
-- is just for testing; we're not actually considering using such a policy.
largestFirst :: forall h a m. Monad m
             => (Int -> [Value] -> Value)
             -> InputSelectionPolicy h a m
largestFirst estimateFee utxo = \goals -> runInputPolicyT estimateFee utxo $
    mconcat <$> mapM go goals
  where
    go :: (ExpenseRegulation, Output a) -> InputPolicyT h a m PartialTxStats
    go goal@(expenseRegulation, Output _a val) = do
        sorted   <- sortBy sortKey . utxoToList <$> use ipsUtxo
        selected <- case select sorted utxoEmpty 0 of
                      Nothing -> throwError InputSelectionFailure
                      Just u  -> return u

        ipsUtxo             %= utxoRemoveInputs (utxoDomain selected)
        ipsSelectedInputs   %= Set.union (utxoDomain selected)
        ipsGeneratedOutputs %= (goal :)

        let selectedSum = utxoBalance selected
            change      = selectedSum - val

        unless (change == 0) $ do
          changeAddr <- genChangeAddr
          ipsGeneratedOutputs %= ((expenseRegulation, Output changeAddr change) :)

        return PartialTxStats {
            ptxStatsNumInputs = utxoSize selected
          , ptxStatsRatios    = MultiSet.singleton (fromIntegral change / fromIntegral val)
          }
      where
        select :: [(Input h a, Output a)] -- ^ Sorted available UTxO
               -> Utxo h a                -- ^ Selected UTxO
               -> Value                   -- ^ Accumulated value
               -> Maybe (Utxo h a)
        select _                   acc accSum | accSum >= val = Just acc
        select []                  _   _      = Nothing
        select ((i, o):available') acc accSum =
            select available' (utxoInsert (i, o) acc) (accSum + outVal o)

    -- Sort by output value, descending
    sortKey :: (Input h a, Output a) -> (Input h a, Output a) -> Ordering
    sortKey = flip (comparing (outVal . snd))

{-------------------------------------------------------------------------------
  Random
-------------------------------------------------------------------------------}

data PrivacyMode = PrivacyModeOn | PrivacyModeOff

-- | Random input selection
--
-- Random input selection has the advantage that is it self correcting, in the
-- following sense: suppose that 90% of our UTxO consists of small outputs;
-- then random selection has a 90% change of choosing those small outputs.
--
-- For each output we add a change output that is between 0.5 and 2 times the
-- size of the output, making it hard to identify. This has the additional
-- benefit of introducing another self-correction: if there are frequent
-- requests for payments around certain size, the UTxO will contain lots of
-- available change outputs of around that size.
random :: forall h a m. LiftQuickCheck m
       => PrivacyMode
       -> (Int -> [Value] -> Value)
       -> InputSelectionPolicy h a m
random privacyMode estimateFee utxo = \goals -> runInputPolicyT estimateFee utxo $
    mconcat <$> mapM go goals
  where
    go :: (ExpenseRegulation, Output a) -> InputPolicyT h a m PartialTxStats
    go goal@(expenseRegulation, Output _a val) = do
        -- First attempt to find a change output in the ideal range.
        -- Failing that, try to at least cover the value.
        --
        -- TODO: We should take deposit/payment ratio into account and
        -- change number of change outputs accordingly
        selected <- case privacyMode of
          PrivacyModeOff -> randomInRange fallback
          PrivacyModeOn  -> randomInRange ideal `catchError` \_err ->
                            randomInRange fallback
        ipsSelectedInputs   %= Set.union (utxoDomain selected)
        ipsGeneratedOutputs %= (goal :)
        let selectedSum = utxoBalance selected
            change      = selectedSum - val
        unless (change == 0) $ do
          changeAddr <- genChangeAddr
          ipsGeneratedOutputs %= ((expenseRegulation, Output changeAddr change) :)
        return PartialTxStats {
            ptxStatsNumInputs = utxoSize selected
          , ptxStatsRatios    = MultiSet.singleton (fromIntegral change / fromIntegral val)
          }
      where
        changeMin = val `div` 2
        changeMax = val *     2
        ideal     = (val + changeMin, val + changeMax)
        fallback  = (val, maxBound)

-- | Random input selection: core algorithm
--
-- Select random inputs until we reach a value in the given bounds.
-- Returns the selected outputs.
randomInRange :: forall h a m. (Hash h a, LiftQuickCheck m)
              => (Value, Value) -> InputPolicyT h a m (Utxo h a)
randomInRange (lo, hi) =
    go 0 utxoEmpty utxoEmpty
  where
    -- Returns the UTxO that we used to cover the range if successful
    go :: Value    -- ^ Accumulated value
       -> Utxo h a -- ^ Discarded UTxO (not used, but not useable either)
       -> Utxo h a -- ^ Used UTxO
       -> InputPolicyT h a m (Utxo h a)
    go acc discarded used =
      if lo <= acc && acc <= hi
        then do
          ipsUtxo %= utxoUnion discarded -- make discarded available again
          return used
        else do
          io@(_, out) <- useRandomOutput
          let acc' = acc + outVal out
          if acc' <= hi -- should we pick this value?
            then go acc' discarded (utxoInsert io used)
            else go acc  (utxoInsert io discarded) used

useRandomOutput :: LiftQuickCheck m
                => InputPolicyT h a m (Input h a, Output a)
useRandomOutput = do
    utxo <- utxoToMap <$> use ipsUtxo
    mIO  <- liftQuickCheck $ randomElement utxo
    case mIO of
      Nothing          -> throwError InputSelectionFailure
      Just (io, utxo') -> ipsUtxo .= utxoFromMap utxo' >> return io

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

-- | Pick a random element from a map
--
-- Returns 'Nothing' if the map is empty
randomElement :: forall k a. Map k a -> Gen (Maybe ((k, a), Map k a))
randomElement m
  | Map.null m = return Nothing
  | otherwise  = (Just . withIx) <$> choose (0, Map.size m - 1)
  where
    withIx :: Int -> ((k, a), Map k a)
    withIx ix = (Map.elemAt ix m, Map.deleteAt ix m)