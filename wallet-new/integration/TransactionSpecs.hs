{-# LANGUAGE RankNTypes    #-}
{-# LANGUAGE TupleSections #-}

module TransactionSpecs (transactionSpecs) where

import           Universum

import           Cardano.Wallet.API.V1.Errors hiding (describe)
import           Cardano.Wallet.Client.Http
import           Control.Lens
import qualified Pos.Core as Core
import           Test.Hspec

import           Control.Concurrent (threadDelay)
import           Text.Show.Pretty (ppShow)
import           Util

{-# ANN module ("HLint: ignore Reduce duplication" :: Text) #-}

log :: MonadIO m => Text -> m ()
log = putStrLn . mappend "[TEST-LOG] "

ppShowT :: Show a => a -> Text
ppShowT = fromString . ppShow

transactionSpecs :: WalletRef -> WalletClient IO -> Spec
transactionSpecs wRef wc = do
    describe "Transactions" $ do
        it "posted transactions appear in the index" $ do
            genesis <- genesisWallet wc
            (fromAcct, _) <- firstAccountAndId wc genesis

            wallet <- sampleWallet wRef wc
            (toAcct, toAddr) <- firstAccountAndId wc wallet

            let payment = Payment
                    { pmtSource =  PaymentSource
                        { psWalletId = walId genesis
                        , psAccountIndex = accIndex fromAcct
                        }
                    , pmtDestinations = pure PaymentDistribution
                        { pdAddress = addrId toAddr
                        , pdAmount = tenthOf (accAmount fromAcct)
                        }
                    , pmtGroupingPolicy = Nothing
                    , pmtSpendingPassword = Nothing
                    }
                tenthOf (V1 c) = V1 (Core.mkCoin (Core.getCoin c `div` 10))

            etxn <- postTransaction wc payment

            txn <- fmap wrData etxn `shouldPrism` _Right

            eresp <- getTransactionIndex wc (Just (walId wallet)) (Just (accIndex toAcct)) Nothing
            resp <- fmap wrData eresp `shouldPrism` _Right

            map txId resp `shouldContain` [txId txn]

        it "asset-locked wallets can receive funds and transaction are confirmed in index" $ do
            genesis <- genesisWallet wc
            (fromAcct, _) <- firstAccountAndId wc genesis

            wallet <- genesisAssetLockedWallet wc
            (toAcct, toAddr) <- firstAccountAndId wc wallet

            let payment = Payment
                    { pmtSource =  PaymentSource
                        { psWalletId = walId genesis
                        , psAccountIndex = accIndex fromAcct
                        }
                    , pmtDestinations = pure PaymentDistribution
                        { pdAddress = addrId toAddr
                        , pdAmount = tenthOf (accAmount fromAcct)
                        }
                    , pmtGroupingPolicy = Nothing
                    , pmtSpendingPassword = Nothing
                    }
                tenthOf (V1 c) = V1 (Core.mkCoin (Core.getCoin c `div` 10))

            etxn <- postTransaction wc payment

            txn <- fmap wrData etxn `shouldPrism` _Right

            threadDelay 120000000
            eresp <- getTransactionIndex wc (Just (walId wallet)) (Just (accIndex toAcct)) Nothing
            resp <- fmap wrData eresp `shouldPrism` _Right

            map txId resp `shouldContain` [txId txn]
            let txnEntry: _ = filter ( \x -> (txId x) == (txId txn)) resp
            log $ "Resp   : " <> ppShowT txnEntry
            txConfirmations txnEntry `shouldNotBe` 0

        it "sending from asset-locked address in wallet with no ther addresses gets 0 confirmations from core nodes" $ do
            genesis <- genesisAssetLockedWallet wc
            (fromAcct, _) <- firstAccountAndId wc genesis

            wallet <- sampleWallet wRef wc
            (toAcct, toAddr) <- firstAccountAndId wc wallet

            let payment = Payment
                    { pmtSource =  PaymentSource
                        { psWalletId = walId genesis
                        , psAccountIndex = accIndex fromAcct
                        }
                    , pmtDestinations = pure PaymentDistribution
                        { pdAddress = addrId toAddr
                        , pdAmount = tenthOf (accAmount fromAcct)
                        }
                    , pmtGroupingPolicy = Nothing
                    , pmtSpendingPassword = Nothing
                    }
                tenthOf (V1 c) = V1 (Core.mkCoin (Core.getCoin c `div` 10))

            etxn <- postTransaction wc payment

            txn <- fmap wrData etxn `shouldPrism` _Right

            threadDelay 120000000
            eresp <- getTransactionIndex wc (Just (walId wallet)) (Just (accIndex toAcct)) Nothing
            resp <- fmap wrData eresp `shouldPrism` _Right :: IO [ Transaction]
            let txnEntry : _ = filter ( \x -> (txId x) == (txId txn)) resp
            log $ "Resp   : " <> ppShowT txnEntry
            txConfirmations txnEntry `shouldBe` 0

        it "estimate fees of a well-formed transaction" $ do
            ws <- (,)
                <$> (randomCreateWallet >>= createWalletCheck wc)
                <*> (randomCreateWallet >>= createWalletCheck wc)

            ((fromAcct, _), (_toAcct, toAddr)) <- (,)
                <$> firstAccountAndId wc (fst ws)
                <*> firstAccountAndId wc (snd ws)

            let amount = V1 (Core.mkCoin 42)

            let payment = Payment
                    { pmtSource = PaymentSource
                        { psWalletId = walId (fst ws)
                        , psAccountIndex = accIndex fromAcct
                        }
                    , pmtDestinations = pure PaymentDistribution
                        { pdAddress = addrId toAddr
                        , pdAmount = amount
                        }
                    , pmtGroupingPolicy = Nothing
                    , pmtSpendingPassword = Nothing
                    }

            efee <- getTransactionFee wc payment
            case efee of
                Right fee ->
                    feeEstimatedAmount (wrData fee)
                        `shouldSatisfy`
                            (> amount)
                Left (ClientWalletError (NotEnoughMoney _)) ->
                    pure ()
                Left err ->
                    expectationFailure $
                        "Expected either a successful fee or a NotEnoughMoney "
                        <> " error, got: "
                        <> show err

        it "fails if you spend too much money" $ do
            wallet <- sampleWallet wRef wc
            (toAcct, toAddr) <- firstAccountAndId wc wallet

            let payment = Payment
                    { pmtSource =  PaymentSource
                        { psWalletId = walId wallet
                        , psAccountIndex = accIndex toAcct
                        }
                    , pmtDestinations = pure PaymentDistribution
                        { pdAddress = addrId toAddr
                        , pdAmount = tooMuchCash (accAmount toAcct)
                        }
                    , pmtGroupingPolicy = Nothing
                    , pmtSpendingPassword = Nothing
                    }
                tooMuchCash (V1 c) = V1 (Core.mkCoin (Core.getCoin c * 2))
            etxn <- postTransaction wc payment

            void $ etxn `shouldPrism` _Left
