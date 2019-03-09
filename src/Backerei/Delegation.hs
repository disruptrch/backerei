module Backerei.Delegation where

import           Control.Applicative
import           Control.Monad
import           Data.List           (zip)
import qualified Data.Text           as T
import           Foundation
import qualified Prelude             as P

import qualified Backerei.RPC        as RPC
import           Backerei.Types

getContributingBalancesFor :: RPC.Config -> Int -> Int -> Int -> T.Text -> IO ([(T.Text, Tezzies)], Tezzies)
getContributingBalancesFor config cycleLength snapshotInterval cycle delegate = do
  snapshotBlockHash <- snapshotHash config cycle cycleLength snapshotInterval
  delegators <- RPC.delegatedContracts config snapshotBlockHash delegate
  balances <- mapM (RPC.balanceAt config snapshotBlockHash) delegators
  fullBalance <- RPC.delegateBalanceAt config snapshotBlockHash delegate
  frozenByCycle <- RPC.frozenBalanceByCycle config snapshotBlockHash delegate
  let totalFrozenRewards = foldl' (P.+) 0 (fmap frozenRewards frozenByCycle)
      selfBalance = fullBalance P.- totalFrozenRewards
  stakingBalance <- RPC.stakingBalanceAt config snapshotBlockHash delegate
  when (selfBalance P.+ P.sum balances /= stakingBalance) $ error "should not happen"
  return (filter ((<) 0 . snd) ((delegate, selfBalance) : zip delegators balances), stakingBalance)

snapshotHash :: RPC.Config -> Int -> Int -> Int -> IO T.Text
snapshotHash config cycle cycleLength snapshotInterval = do
  hash <- hashToQuery config cycle cycleLength
  (CycleInfo _ snapshot) <- RPC.cycleInfo config hash cycle
  let blockHeight = snapshotHeight cycle snapshot cycleLength snapshotInterval
  blockHashByLevel config blockHeight

snapshotLevel :: RPC.Config -> Int -> Int -> Int -> IO Int
snapshotLevel config cycle cycleLength snapshotInterval = do
  hash <- hashToQuery config cycle cycleLength
  CycleInfo _ snapshot <- RPC.cycleInfo config hash cycle
  return $ snapshotHeight cycle snapshot cycleLength snapshotInterval

hashToQuery :: RPC.Config -> Int -> Int -> IO T.Text
hashToQuery config cycle cycleLength = do
  (BlockHeader hashHead levelHead _) <- RPC.header config RPC.head
  currentLevel <- RPC.currentLevel config hashHead
  let blocksAgo = cycleLength P.* (levelCycle currentLevel - cycle)
      levelToQuery = min (levelHead P.- blocksAgo) levelHead
  blockHashByLevel config levelToQuery

snapshotHeight :: Int -> Int -> Int -> Int -> Int
snapshotHeight cycle snapshot cycleLength snapshotInterval = (cycle - 7) * cycleLength + ((snapshot + 1) * snapshotInterval)

startingBlock :: Int -> Int -> Int
startingBlock cycle cycleLength = (cycle * cycleLength) + 1

endingBlock :: Int -> Int -> Int
endingBlock cycle cycleLength = ((cycle + 1) * cycleLength)

estimatedRewards :: RPC.Config -> Int -> Int -> T.Text -> IO Tezzies
estimatedRewards config cycleLength cycle delegate = do
  hash <- hashToQuery config cycle cycleLength
  bakingRights <- filter ((==) 0 . bakingPriority) `fmap` RPC.bakingRightsFor config hash delegate cycle
  endorsingRights <- RPC.endorsingRightsFor config hash delegate cycle
  let bakingReward :: Tezzies
      bakingReward = 16
      endorsingReward :: Tezzies
      endorsingReward = 2
      totalReward :: Tezzies
      totalReward = (bakingReward P.* fromIntegral (P.length bakingRights)) P.+ (endorsingReward P.* fromIntegral (P.sum $ fmap (P.length . endorsingSlots) endorsingRights))
  return totalReward

blockHashByLevel :: RPC.Config -> Int -> IO T.Text
blockHashByLevel config level = do
  (BlockHeader hashHead levelHead _) <- RPC.header config RPC.head
  (BlockHeader hash' level' _) <- RPC.header config (T.concat [hashHead, "~", T.pack $ P.show $ levelHead - level])
  when (level /= level') $ error "should not happen: tezos rpc fault, wrong level"
  return hash'

stolenBlocks :: RPC.Config -> Int -> Int -> T.Text -> IO [(Int, T.Text, Int, Tezzies, Tezzies)]
stolenBlocks config cycleLength cycle delegate = do
  hash <- hashToQuery config cycle cycleLength
  bakingRights <- filter ((<) 0 . bakingPriority) `fmap` RPC.bakingRightsFor config hash delegate cycle
  mconcat `fmap` forM bakingRights (\(BakingRight _ priority _ level) -> do
    hash <- blockHashByLevel config level
    (BlockMetadata _ baker balanceUpdates) <- RPC.metadata config hash
    if baker /= delegate then return [] else do
      operations <- RPC.operations config hash
      let [update] = filter (\u -> updateKind u == "freezer" && updateCategory u == Just "rewards" && updateDelegate u == Just delegate) balanceUpdates
          reward = updateChange update
          fees = P.sum $ fmap (P.sum . fmap (fromMaybe 0 . opcontentsFee) . operationContents) operations
      return [(level, hash, priority, reward, fees)])

calculateRewardsFor :: RPC.Config -> Int -> Int -> Int -> T.Text -> Tezzies -> Rational -> IO ((Tezzies, Tezzies, Tezzies, Tezzies), [(T.Text, Tezzies, Tezzies)], Tezzies)
calculateRewardsFor config cycleLength snapshotInterval cycle delegate rewards fee = do
  (balances, stakingBalance) <- getContributingBalancesFor config cycleLength snapshotInterval cycle delegate
  let totalBalance :: Tezzies
      totalBalance = P.sum $ fmap snd balances
      feeTz :: Tezzies
      feeTz = P.fromRational fee
      (_, bakerBalance) = P.head balances
      bakerSelfReward = bakerBalance P.* rewards P./ totalBalance
      bakerFeeReward = feeTz P.* rewards P.* (totalBalance P.- bakerBalance) P./ totalBalance
      delegatorRewards = (\(x, y) -> (x, y, y P.* (1 P.- feeTz) P.* rewards P./ totalBalance)) <$> drop 1 balances
      totalDelegatorRewards = P.sum (fmap (\(_, _, r) -> r) delegatorRewards)
      {- Leftover from fixed-precision floor rounding. -}
      bakerLooseReward = rewards P.- totalDelegatorRewards P.- bakerSelfReward P.- bakerFeeReward
      bakerTotalReward = bakerSelfReward P.+ bakerFeeReward P.+ bakerLooseReward
      bakerRewards = (bakerSelfReward, bakerFeeReward, bakerLooseReward, bakerTotalReward)
  when (bakerTotalReward P.+ totalDelegatorRewards /= rewards) $ error "should not happen: rewards mismatch"
  return (bakerRewards, delegatorRewards, stakingBalance)
