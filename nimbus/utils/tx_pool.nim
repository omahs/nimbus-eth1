# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## TODO:
## =====
## * Support `local` accounts the txs of which would be prioritised. This is
##   currently unsupported. For now, all txs are considered from `remote`
##   accounts.
##
## * No uncles are handled by this pool
##
## * Impose a size limit to the bucket database. Which items would be removed?
##
## * There is a conceivable problem with the per-account optimisation. The
##   algorithm chooses an account and does not stop packing until all txs
##   of the account are packed or the block is full. In the lattter case,
##   there might be some txs left unpacked from the account which might be
##   the most lucrative ones. Should this be tackled (see also next item)?
##
## * The classifier throws out all txs with negative gas tips. This implies
##   that all subsequent txs must also be suspended for this account even
##   though these following txs might be extraordinarily profitable so that
##   packing the whole account might be woth wile. Should this be considered,
##   somehow (see also previous item)?
##
##
## Transaction Pool
## ================
##
## The transaction pool collects transactions and holds them in a database.
## This database consists of the three buckets *pending*, *staged*, and
## *packed* and a *waste basket*. These database entities are discussed in
## more detail, below.
##
## At some point, there will be some transactions in the *staged* bucket.
## Upon request, the pool will pack as many of those transactions as possible
## into to *packed* bucket which will subsequently be used to generate a
## new Ethereum block.
##
## When packing transactions from *staged* into *packed* bucked, the staged
## transactions are sorted by *sender account* and *nonce*. The *sender
## account* values are ordered by a *ranking* function (highest ranking first)
## and the *nonce* values by their natural integer order. Then, transactions
## are greedily picked from the ordered set until there are enough
## transactions in the *packed* bucket. Some boundary condition applies which
## roughly says that for a given account, all the transactions packed must
## leave no gaps between nonce values when sorted.
##
## The rank function applied to the *sender account* sorting is chosen as a
## guess for higher profitability which goes with a higher rank account.
##
##
## Rank calculator
## ---------------
## Let *tx()* denote the mapping
## ::
##   tx: (account,nonce) -> tx
##
## from an index pair *(account,nonce)* to a transaction *tx*. Also, for some
## external parameter *baseFee*, let
## ::
##   maxProfit: (tx,baseFee) -> tx.effectiveGasTip(baseFee) * tx.gasLimit
##
## be the maximal tip a single transation can achieve (where unit of the
## *effectiveGasTip()* is a *price* and *gasLimit* is a *commodity value*.).
## Then the rank function
## ::
##   rank(account) = Σ maxProfit(tx(account,ν),baseFee) / Σ tx(account,ν).gasLimit
##                   ν                                    ν
##
## is a *price* estimate of the maximal avarage tip per gas unit over all
## transactions for the given account. The nonces `ν` for the summation
## run over all transactions from the *staged* and *packed* bucket.
##
##
##
##
## Pool database:
## --------------
## ::
##    <Batch queue>     .   <Status buckets>      .    <Terminal state>
##                      .                         .
##                      .                         .    +----------+
##    --> txJobAddTxs -------------------------------> |          |
##                |     .        +-----------+    .    | disposed |
##                +------------> |  pending  | ------> |          |
##                      .        +-----------+    .    |          |
##                      .          |  ^   ^       .    |  waste   |
##                      .          v  |   |       .    |  basket  |
##                      .   +----------+  |       .    |          |
##                      .   |  staged  |  |       .    |          |
##                      .   +----------+  |       .    |          |
##                      .     |    |  ^   |       .    |          |
##                      .     |    v  |   |       .    |          |
##                      .     |  +----------+     .    |          |
##                      .     |  |  packed  | -------> |          |
##                      .     |  +----------+     .    |          |
##                      .     +----------------------> |          |
##                      .                         .    +----------+
##
## The three columns *Batch queue*, *State bucket*, and *Terminal state*
## represent three different accounting (or database) systems. The pool
## database is continuosly updated while new transactions are added.
## Transactions are bundled with meta data which holds the full datanbase
## state in addition to other cached information like the sender account.
##
##
## Batch Queue
## -----------
## The batch queue holds different types of jobs to be run later in a batch.
## When running at a time, all jobs are executed in *FIFO* mode until the queue
## is empty.
##
## When entering the pool, new transactions are bundled with meta data and
## appended to the batch queue. These bundles are called *item*. When the
## batch commits, items are forwarded to one of the following entites:
##
## * the *staged* bucket if the transaction is valid and match some constraints
##   on expected minimum mining fees (or a semblance of that for *non-PoW*
##   networks)
## * the *pending* bucket if the transaction is valid but is not subject to be
##   held in the *staged* bucket
## * the *waste basket* if the transaction is invalid
##
## If a valid transaction item supersedes an existing one, the existing
## item is moved to the waste basket and the new transaction replaces the
## existing one in the current bucket if the gas price of the transaction is
## at least `priceBump` per cent higher (see adjustable parameters, below.)
##
## Status buckets
## --------------
## The term *bucket* is a nickname for a set of *items* (i.e. transactions
## bundled with meta data as mentioned earlier) all labelled with the same
## `status` symbol and not marked  *waste*. In particular, bucket membership
## for an item is encoded as
##
## * the `status` field indicates the particular *bucket* membership
## * the `reject` field is reset/unset and has zero-equivalent value
##
## The following boundary conditions hold for the union of all buckets:
##
## * *Unique index:*
##    Let **T** be the union of all buckets and **Q** be the
##    set of *(sender,nonce)* pairs derived from the items of **T**. Then
##    **T** and **Q** are isomorphic, i.e. for each pair *(sender,nonce)*
##    from **Q** there is exactly one item from **T**, and vice versa.
##
## * *Consecutive nonces:*
##     For each *(sender0,nonce0)* of **Q**, either
##     *(sender0,nonce0-1)* is in  **Q** or *nonce0* is the current nonce as
##     registered with the *sender account* (implied by the block chain),
##
## The *consecutive nonces* requirement involves the *sender account*
## which depends on the current state of the block chain as represented by the
## internally cached head (i.e. insertion point where a new block is to be
## appended.)
##
## The following notation describes sets of *(sender,nonce)* pairs for
## per-bucket items. It will be used for boundary conditions similar to the
## ones above.
##
## * **Pending** denotes the set of *(sender,nonce)* pairs for the
##   *pending* bucket
##
## * **Staged** denotes the set of *(sender,nonce)* pairs for the
##   *staged* bucket
##
## * **Packed** denotes the set of *(sender,nonce)* pairs for the
##   *packed* bucket
##
## The pending bucket
## ^^^^^^^^^^^^^^^^^^
## Items in this bucket hold valid transactions that are not in any of the
## other buckets. All itmes might be promoted form here into other buckets if
## the current state of the block chain as represented by the internally cached
## head changes.
##
## The staged bucket
## ^^^^^^^^^^^^^^^^^
## Items in this bucket are ready to be added to a new block. They typycally
## imply some expected minimum reward when mined on PoW networks. Some
## boundary condition holds:
##
## * *Consecutive nonces:*
##     For any *(sender0,nonce0)* pair from **Staged**, the pair
##     *(sender0,nonce0-1)* is not in **Pending**.
##
## Considering the respective boundary condition on the union of buckets
## **T**, this condition here implies that a *staged* per sender nonce has a
## predecessor in the *staged* or *packed* bucket or is a nonce as registered
## with the *sender account*.
##
## The packed bucket
## ^^^^^^^^^^^^^^^^^
## All items from this bucket have been selected from the *staged* bucket, the
## transactions of which (i.e. unwrapped items) can go right away into a new
## ethernet block. How these items are selected was described at the beginning
## of this chapter. The following boundary conditions holds:
##
## * *Consecutive nonces:*
##     For any *(sender0,nonce0)* pair from **Packed**, the pair
##     *(sender0,nonce0-1)* is neither in **Pending**, nor in **Staged**.
##
## Considering the respective boundary condition on the union of buckets
## **T**, this condition here implies that a *packed* per-sender nonce has a
## predecessor in the very *packed* bucket or is a nonce as registered with the
## *sender account*.
##
##
## Terminal state
## --------------
## After use, items are disposed into a waste basket *FIFO* queue which has a
## maximal length. If the length is exceeded, the oldest items are deleted.
## The waste basket is used as a cache for discarded transactions that need to
## re-enter the system. Recovering from the waste basket saves the effort of
## recovering the sender account from the signature. An item is identified
## *waste* if
##
## * the `reject` field is explicitely set and has a value different
##   from a zero-equivalent.
##
## So a *waste* item is clearly distinguishable from any active one as a
## member of one of the *status buckets*.
##
##
##
## Pool coding
## ===========
## The idea is that there are concurrent *async* instances feeding transactions
## into a batch queue via `jobAddTxs()`. The batch queue is then processed on
## demand not until `jobCommit()` is run. A piece of code using this pool
## architecture could look like as follows:
## ::
##    # see also unit test examples, e.g. "Block packer tests"
##    var db: BaseChainDB                    # to be initialised
##    var txs: seq[Transaction]              # to be initialised
##
##    proc mineThatBlock(blk: EthBlock)      # external function
##
##    ..
##
##    var xq = TxPoolRef.new(db)             # initialise tx-pool
##    ..
##
##    xq.jobAddTxs(txs)                      # add transactions to be held
##    ..                                     # .. on the batch queue
##
##    xq.jobCommit                           # run batch queue worker/processor
##    let newBlock = xq.ethBlock             # fetch current mining block
##
##    ..
##    mineThatBlock(newBlock) ...            # external mining & signing process
##    ..
##
##    let newTopHeader = db.getCanonicalHead # new head after mining
##    xp.jobDeltaTxsHead(newTopHeader)       # add transactions update jobs
##    xp.head = newTopHeader                 # adjust block insertion point
##    xp.jobCommit                           # run batch queue worker/processor
##
##
## Discussion of example
## ---------------------
## In the example, transactions are collected via `jobAddTx()` and added to
## a batch of jobs to be processed at a time when considered right. The
## processing is initiated with the `jobCommit()` directive.
##
## The `ethBlock()` directive retrieves a new block for mining derived
## from the current pool state. It invokes the block packer whic accumulates
## txs from the `pending` buscket into the `packed` bucket which then go
## into the block.
##
## Then mining and signing takes place ...
##
## After mining and signing, the view of the block chain as seen by the pool
## must be updated to be ready for a new mining process. In the best case, the
## canonical head is just moved to the currently mined block which would imply
## just to discard the contents of the *packed* bucket with some additional
## transactions from the *staged* bucket. A more general block chain state
## head update would be more complex, though.
##
## In the most complex case, the newly mined block was added to some block
## chain branch which has become an uncle to the new canonical head retrieved
## by `getCanonicalHead()`. In order to update the pool to the very state
## one would have arrived if worked on the retrieved canonical head branch
## in the first place, the directive `jobDeltaTxsHead()` calculates the
## actions of what is needed to get just there from the locally cached head
## state of the pool. These actions are added by `jobDeltaTxsHead()` to the
## batch queue to be executed when it is time.
##
## Then the locally cached block chain head is updated by setting a new
## `topHeader`. The *setter* behind this assignment also caches implied
## internal parameters as base fee, fork, etc. Only after the new chain head
## is set, the `jobCommit()` should be started to process the update actions
## (otherwise txs might be thrown out which could be used for packing.)
##
##
## Adjustable Parameters
## ---------------------
##
## flags
##   The `flags` parameter holds a set of strategy symbols for how to process
##   items and buckets.
##
##   *stageItems1559MinFee*
##     Stage tx items with `tx.maxFee` at least `minFeePrice`. Other items are
##     left or set pending. This symbol affects post-London tx items, only.
##
##   *stageItems1559MinTip*
##     Stage tx items with `tx.effectiveGasTip(baseFee)` at least
##     `minTipPrice`. Other items are considered underpriced and left or set
##     pending. This symbol affects post-London tx items, only.
##
##   *stageItemsPlMinPrice*
##     Stage tx items with `tx.gasPrice` at least `minPreLondonGasPrice`.
##     Other items are considered underpriced and left or set pending. This
##     symbol affects pre-London tx items, only.
##
##   *packItemsMaxGasLimit*
##     It set, the *packer* will execute and collect additional items from
##     the `staged` bucket while accumulating `gasUsed` as long as
##     `maxGasLimit` is not exceeded. If `packItemsTryHarder` flag is also
##     set, the *packer* will not stop until at least `hwmGasLimit` is
##     reached.
##
##     Otherwise the *packer* will accumulate up until `trgGasLimit` is
##     not exceeded, and not stop until at least `lwmGasLimit` is reached
##     in case `packItemsTryHarder` is also set,
##
##   *packItemsTryHarder*
##     It set, the *packer* will *not* stop accumulaing transactions up until
##     the `lwmGasLimit` or `hwmGasLimit` is reached, depending on whether
##     the `packItemsMaxGasLimit` is set. Otherwise, accumulating stops
##     immediately before the next transaction exceeds `trgGasLimit`, or
##     `maxGasLimit` depending on `packItemsMaxGasLimit`.
##
##   *autoUpdateBucketsDB*
##     Automatically update the state buckets after running batch jobs if the
##     `dirtyBuckets` flag is also set.
##
##   *autoZombifyUnpacked*
##     Automatically dispose *pending* or *staged* tx items that were added to
##     the state buckets database at least `lifeTime` ago.
##
##   *autoZombifyPacked*
##     Automatically dispose *packed* tx itemss that were added to
##     the state buckets database at least `lifeTime` ago.
##
##   *..there might be more strategy symbols..*
##
## head
##   Cached block chain insertion point. Typocally, this should be the the
##   same header as retrieved by the `getCanonicalHead()`.
##
## hwmTrgPercent
##   This parameter implies the size of `hwmGasLimit` which is calculated
##   as `max(trgGasLimit, maxGasLimit * lwmTrgPercent  / 100)`.
##
## lifeTime
##   Txs that stay longer in one of the buckets will be  moved to a waste
##   basket. From there they will be eventually deleted oldest first when
##   the maximum size would be exceeded.
##
## lwmMaxPercent
##   This parameter implies the size of `lwmGasLimit` which is calculated
##   as `max(minGasLimit, trgGasLimit * lwmTrgPercent  / 100)`.
##
## minFeePrice
##   Applies no EIP-1559 txs only. Txs are packed if `maxFee` is at least
##   that value.
##
## minTipPrice
##   For EIP-1559, txs are packed if the expected tip (see `estimatedGasTip()`)
##   is at least that value. In compatibility mode for legacy txs, this
##   degenerates to `gasPrice - baseFee`.
##
## minPreLondonGasPrice
##   For pre-London or legacy txs, this parameter has precedence over
##   `minTipPrice`. Txs are packed if the `gasPrice` is at least that value.
##
## priceBump
##   There can be only one transaction in the database for the same `sender`
##   account and `nonce` value. When adding a transaction with the same
##   (`sender`, `nonce`) pair, the new transaction will replace the current one
##   if it has a gas price which is at least `priceBump` per cent higher.
##
##
## Read-Only Parameters
## --------------------
##
## baseFee
##   This parameter is derived from the internally cached block chain state.
##   The base fee parameter modifies/determines the expected gain when packing
##   a new block (is set to *zero* for *pre-London* blocks.)
##
## dirtyBuckets
##   If `true`, the state buckets database is ready for re-org if the
##   `autoUpdateBucketsDB` flag is also set.
##
## gasLimit
##   Taken or derived from the current block chain head, incoming txs that
##   exceed this gas limit are stored into the *pending* bucket (maybe
##   eligible for staging at the next cycle when the internally cached block
##   chain state is updated.)
##
## hwmGasLimit
##   This parameter is at least `trgGasLimit` and does not exceed
##   `maxGasLimit` and can be adjusted by means of setting `hwmMaxPercent`. It
##   is used by the packer as a minimum block size if both flags
##   `packItemsTryHarder` and `packItemsMaxGasLimit` are set.
##
## lwmGasLimit
##   This parameter is at least `minGasLimit` and does not exceed
##   `trgGasLimit` and can be adjusted by means of setting `lwmTrgPercent`. It
##   is used by the packer as a minimum block size if the flag
##   `packItemsTryHarder` is set and `packItemsMaxGasLimit` is unset.
##
## maxGasLimit
##   This parameter is at least `hwmGasLimit`. It is calculated considering
##   the current state of the block chain as represented by the internally
##   cached head. This parameter is used by the *packer* as a size limit if
##   `packItemsMaxGasLimit` is set.
##
## minGasLimit
##   This parameter is calculated considering the current state of the block
##   chain as represented by the internally cached head. It can be used for
##   verifying that a generated block does not underflow minimum size.
##   Underflow can only be happen if there are not enough transaction available
##   in the pool.
##
## trgGasLimit
##   This parameter is at least `lwmGasLimit` and does not exceed
##   `maxGasLimit`. It is calculated considering the current state of the block
##   chain as represented by the internally cached head. This parameter is
##   used by the *packer* as a size limit if `packItemsMaxGasLimit` is unset.
##

import
  std/[sequtils, tables],
  ../db/db_chain,
  ./tx_pool/[tx_chain, tx_desc, tx_info, tx_item, tx_job],
  ./tx_pool/tx_tabs,
  ./tx_pool/tx_tasks/[tx_add, tx_bucket, tx_head, tx_dispose, tx_packer],
  chronicles,
  eth/[common, keys],
  stew/[keyed_queue, results],
  stint

# hide complexity unless really needed
when JobWaitEnabled:
  import chronos

export
  TxItemRef,
  TxItemStatus,
  TxJobDataRef,
  TxJobID,
  TxJobKind,
  TxPoolFlags,
  TxPoolRef,
  TxTabsGasTotals,
  TxTabsItemsCount,
  results,
  tx_desc.startDate,
  tx_info,
  tx_item.GasPrice,
  tx_item.`<=`,
  tx_item.`<`,
  tx_item.effectiveGasTip,
  tx_item.info,
  tx_item.itemID,
  tx_item.sender,
  tx_item.status,
  tx_item.timeStamp,
  tx_item.tx

{.push raises: [Defect].}

logScope:
  topics = "tx-pool"

# ------------------------------------------------------------------------------
# Private functions: tasks processor
# ------------------------------------------------------------------------------

proc maintenanceProcessing(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Tasks to be done after job processing

  # Purge expired items
  if autoZombifyUnpacked in xp.pFlags or
     autoZombifyPacked in xp.pFlags:
    # Move transactions older than `xp.lifeTime` to the waste basket.
    xp.disposeExpiredItems

  # Update buckets
  if autoUpdateBucketsDB in xp.pFlags:
    if xp.pDirtyBuckets:
      # For all items, re-calculate item status values (aka bucket labels).
      # If the `force` flag is set, re-calculation is done even though the
      # change flag has remained unset.
      discard xp.bucketUpdateAll
      xp.pDirtyBuckets = false


proc processJobs(xp: TxPoolRef): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Job queue processor
  var rc = xp.byJob.fetch
  while rc.isOK:
    let task = rc.value
    rc = xp.byJob.fetch
    result.inc

    case task.data.kind
    of txJobNone:
      # No action
      discard

    of txJobAddTxs:
      # Add a batch of txs to the database
      var args = task.data.addTxsArgs
      let (_,topItems) = xp.addTxs(args.txs, args.info)
      xp.pDoubleCheckAdd topItems

    of txJobDelItemIDs:
      # Dispose a batch of items
      var args = task.data.delItemIDsArgs
      for itemID in args.itemIDs:
        let rcItem = xp.txDB.byItemID.eq(itemID)
        if rcItem.isOK:
          discard xp.txDB.dispose(rcItem.value, reason = args.reason)

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc new*(T: type TxPoolRef; db: BaseChainDB; miner: EthAddress): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor, returns a new tx-pool descriptor. The `miner` argument is
  ## the fee beneficiary for informational purposes only.
  new result
  result.init(db,miner)

# ------------------------------------------------------------------------------
# Public functions, task manager, pool actions serialiser
# ------------------------------------------------------------------------------

proc job*(xp: TxPoolRef; job: TxJobDataRef): TxJobID
    {.discardable,gcsafe,raises: [Defect,CatchableError].} =
  ## Queue a new generic job (does not run `jobCommit()`.)
  xp.byJob.add(job)

# core/tx_pool.go(848): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
proc jobAddTxs*(xp: TxPoolRef; txs: openArray[Transaction]; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Queues a batch of transactions jobs to be processed in due course (does
  ## not run `jobCommit()`.)
  ##
  ## The argument Transactions `txs` may come in any order, they will be
  ## sorted by `<account,nonce>` before adding to the database with the
  ## least nonce first. For this reason, it is suggested to pass transactions
  ## in larger groups. Calling single transaction jobs, they must strictly be
  ## passed smaller nonce before larger nonce.
  discard xp.job(TxJobDataRef(
    kind:     txJobAddTxs,
    addTxsArgs: (
      txs:    toSeq(txs),
      info:   info)))

# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
proc jobAddTx*(xp: TxPoolRef; tx: Transaction; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `jobAddTxs()` for a single transaction.
  xp.jobAddTxs(@[tx], info)


proc jobDeltaTxsHead*(xp: TxPoolRef; newHead: BlockHeader): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## This function calculates the txs to add or delete that need to take place
  ## after the cached block chain head is set to the position implied by the
  ## argument `newHead`. If successful, the txs to add or delete are queued
  ## on the job queue (run `jobCommit()` to execute) and `true` is returned.
  ## Otherwise nothing is done and `false` is returned.
  let rcDiff = xp.headDiff(newHead)
  if rcDiff.isOk:
    let changes = rcDiff.value

    # Re-inject transactions, do that via job queue
    if 0 < changes.addTxs.len:
      discard xp.job(TxJobDataRef(
        kind:       txJobAddTxs,
        addTxsArgs: (
          txs:      toSeq(changes.addTxs.nextValues),
          info:     "")))

    # Delete already *mined* transactions
    if 0 < changes.remTxs.len:
      discard xp.job(TxJobDataRef(
        kind:       txJobDelItemIDs,
        delItemIDsArgs: (
          itemIDs:  toSeq(changes.remTxs.keys),
          reason:   txInfoChainHeadUpdate)))

    return true


proc jobCommit*(xp: TxPoolRef; forceMaintenance = false)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## This function processes all jobs currently queued. If the the argument
  ## `forceMaintenance` is set `true`, mainenance processing is always run.
  ## Otherwise it is only run if there were active jobs.
  let nJobs = xp.processJobs
  if 0 < nJobs or forceMaintenance:
    xp.maintenanceProcessing
  debug "processed jobs", nJobs

proc nJobs*(xp: TxPoolRef): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Return the number of jobs currently unprocessed, waiting.
  xp.byJob.len

# hide complexity unless really needed
when JobWaitEnabled:
  proc jobWait*(xp: TxPoolRef) {.async,raises: [Defect,CatchableError].} =
    ## Asynchronously wait until at least one job is queued and available.
    ## This function might be useful for testing (available only if the
    ## `JobWaitEnabled` compile time constant is set.)
    await xp.byJob.waitAvail


proc triggerReorg*(xp: TxPoolRef) =
  ## This function triggers a bucket re-org action with the next job queue
  ## maintenance-processing (see `jobCommit()`) by setting the `dirtyBuckets`
  ## parameter. This re-org action eventually happens when the
  ## `autoUpdateBucketsDB` flag is also set.
  xp.pDirtyBuckets = true

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc baseFee*(xp: TxPoolRef): GasPrice =
  ## Getter, this parameter modifies/determines the expected gain when packing
  xp.chain.baseFee

proc dirtyBuckets*(xp: TxPoolRef): bool =
  ## Getter, bucket database is ready for re-org if the `autoUpdateBucketsDB`
  ## flag is also set.
  xp.pDirtyBuckets

proc ethBlock*(xp: TxPoolRef): EthBlock
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, retrieves a packed block ready for mining and signing depending
  ## on the internally cached block chain head, the txs in the pool and some
  ## tuning parameters. The following block header fields are left
  ## uninitialised:
  ##
  ## * *extraData*: Blob
  ## * *mixDigest*: Hash256
  ## * *nonce*:     BlockNonce
  ##
  ## Note that this getter runs *ad hoc* all the txs through the VM in
  ## order to build the block.
  xp.packerVmExec                            # updates vmState
  result.header = xp.chain.getHeader         # uses updated vmState
  for (_,nonceList) in xp.txDB.decAccount(txItemPacked):
    result.txs.add toSeq(nonceList.incNonce).mapIt(it.tx)

proc gasCumulative*(xp: TxPoolRef): GasInt
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, retrieves the gas that will be burned in the block after
  ## retrieving it via `ethBlock`.
  xp.chain.gasUsed

proc gasTotals*(xp: TxPoolRef): TxTabsGasTotals
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, retrieves the current gas limit totals per bucket.
  xp.txDB.gasTotals

proc lwmTrgPercent*(xp: TxPoolRef): int =
  ## Getter, `trgGasLimit` percentage for `lwmGasLimit` which is
  ## `max(minGasLimit, trgGasLimit * lwmTrgPercent  / 100)`
  xp.chain.lhwm.lwmTrg

proc flags*(xp: TxPoolRef): set[TxPoolFlags] =
  ## Getter, retrieves strategy symbols for how to process items and buckets.
  xp.pFlags

proc head*(xp: TxPoolRef): BlockHeader =
  ## Getter, cached block chain insertion point. Typocally, this should be the
  ## the same header as retrieved by the `getCanonicalHead()` (unless in the
  ## middle of a mining update.)
  xp.chain.head

proc hwmMaxPercent*(xp: TxPoolRef): int =
  ## Getter, `maxGasLimit` percentage for `hwmGasLimit` which is
  ## `max(trgGasLimit, maxGasLimit * hwmMaxPercent  / 100)`
  xp.chain.lhwm.hwmMax

proc maxGasLimit*(xp: TxPoolRef): GasInt =
  ## Getter, hard size limit when packing blocks (see also `trgGasLimit`.)
  xp.chain.limits.maxLimit

# core/tx_pool.go(435): func (pool *TxPool) GasPrice() *big.Int {
proc minFeePrice*(xp: TxPoolRef): GasPrice =
  ## Getter, retrieves minimum for the current gas fee enforced by the
  ## transaction pool for txs to be packed. This is an EIP-1559 only
  ## parameter (see `stage1559MinFee` strategy.)
  xp.pMinFeePrice

proc minPreLondonGasPrice*(xp: TxPoolRef): GasPrice =
  ## Getter. retrieves, the current gas price enforced by the transaction
  ## pool. This is a pre-London parameter (see `packedPlMinPrice` strategy.)
  xp.pMinPlGasPrice

proc minTipPrice*(xp: TxPoolRef): GasPrice =
  ## Getter, retrieves minimum for the current gas tip (or priority fee)
  ## enforced by the transaction pool. This is an EIP-1559 parameter but it
  ## comes with a fall back interpretation (see `stage1559MinTip` strategy.)
  ## for legacy transactions.
  xp.pMinTipPrice

# core/tx_pool.go(474): func (pool SetGasPrice,*TxPool) Stats() (int, int) {
# core/tx_pool.go(1728): func (t *txLookup) Count() int {
# core/tx_pool.go(1737): func (t *txLookup) LocalCount() int {
# core/tx_pool.go(1745): func (t *txLookup) RemoteCount() int {
proc nItems*(xp: TxPoolRef): TxTabsItemsCount
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, retrieves the current number of items per bucket and
  ## some totals.
  xp.txDB.nItems

proc profitability*(xp: TxPoolRef): GasPrice =
  ## Getter, a calculation of the average *price* per gas to be rewarded after
  ## packing the last block (see `ethBlock`). This *price* is only based on
  ## execution transaction in the VM without *PoW* specific rewards. The net
  ## profit (as opposed to the *PoW/PoA* specifc *reward*) can be calculated
  ## as `gasCumulative * profitability`.
  if 0 < xp.chain.gasUsed:
    (xp.chain.profit div xp.chain.gasUsed.u256).truncate(uint64).GasPrice
  else:
    0.GasPrice

proc trgGasLimit*(xp: TxPoolRef): GasInt =
  ## Getter, soft size limit when packing blocks (might be extended to
  ## `maxGasLimit`)
  xp.chain.limits.trgLimit

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `baseFee=`*(xp: TxPoolRef; val: GasPrice)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Setter, sets `baseFee` explicitely witout triggering a packer update.
  ## Stil a database update might take place when updating account ranks.
  ##
  ## Typically, this function would *not* be called but rather the `head=`
  ## update would be employed to do the job figuring out the proper value
  ## for the `baseFee`.
  xp.txDB.baseFee = val
  xp.chain.baseFee = val

proc `lwmTrgPercent=`*(xp: TxPoolRef; val: int) =
  ## Setter, `val` arguments outside `0..100` are ignored
  if 0 <= val and val <= 100:
    xp.chain.lhwm = (lwmTrg: val, hwmMax: xp.chain.lhwm.hwmMax)

proc `flags=`*(xp: TxPoolRef; val: set[TxPoolFlags]) =
  ## Setter, strategy symbols for how to process items and buckets.
  xp.pFlags = val

proc `hwmMaxPercent=`*(xp: TxPoolRef; val: int) =
  ## Setter, `val` arguments outside `0..100` are ignored
  if 0 <= val and val <= 100:
    xp.chain.lhwm = (lwmTrg: xp.chain.lhwm.lwmTrg, hwmMax: val)

proc `maxRejects=`*(xp: TxPoolRef; val: int) =
  ## Setter, the size of the waste basket. This setting becomes effective with
  ## the next move of an item into the waste basket.
  xp.txDB.maxRejects = val

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc `minFeePrice=`*(xp: TxPoolRef; val: GasPrice)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter for `minFeePrice`.  If there was a value change, this function
  ## implies `triggerReorg()`.
  if xp.pMinFeePrice != val:
    xp.pMinFeePrice = val
    xp.pDirtyBuckets = true

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc `minPreLondonGasPrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter for `minPlGasPrice`. If there was a value change, this function
  ## implies `triggerReorg()`.
  if xp.pMinPlGasPrice != val:
    xp.pMinPlGasPrice = val
    xp.pDirtyBuckets = true

# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc `minTipPrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter for `minTipPrice`. If there was a value change, this function
  ## implies `triggerReorg()`.
  if xp.pMinTipPrice != val:
    xp.pMinTipPrice = val
    xp.pDirtyBuckets = true

proc `head=`*(xp: TxPoolRef; val: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, cached block chain insertion point. This will also update the
  ## internally cached `baseFee` (depends on the block chain state.)
  if xp.chain.head != val:
    xp.chain.head = val # calculates the new baseFee
    xp.txDB.baseFee = xp.chain.baseFee
    xp.pDirtyBuckets = true
    xp.bucketFlushPacked

# ------------------------------------------------------------------------------
# Public functions, per-tx-item operations
# ------------------------------------------------------------------------------

# core/tx_pool.go(979): func (pool *TxPool) Get(hash common.Hash) ..
# core/tx_pool.go(985): func (pool *TxPool) Has(hash common.Hash) bool {
proc getItem*(xp: TxPoolRef; hash: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Returns a transaction if it is contained in the pool.
  xp.txDB.byItemID.eq(hash)

proc disposeItems*(xp: TxPoolRef; item: TxItemRef;
                   reason = txInfoExplicitDisposal;
                   otherReason = txInfoImpliedDisposal): int
    {.discardable,gcsafe,raises: [Defect,CatchableError].} =
  ## Move item to wastebasket. All items for the same sender with nonces
  ## greater than the current one are deleted, as well. The function returns
  ## the number of items eventally removed.
  xp.disposeItemAndHigherNonces(item, reason, otherReason)

# ------------------------------------------------------------------------------
# Public functions, more immediate actions deemed not so important yet
# ------------------------------------------------------------------------------

#[

# core/tx_pool.go(561): func (pool *TxPool) Locals() []common.Address {
proc getAccounts*(xp: TxPoolRef; local: bool): seq[EthAddress]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the accounts currently considered `local` or `remote` (i.e.
  ## the have txs of that kind) destaged on request arguments.
  if local:
    result = xp.txDB.locals
  else:
    result = xp.txDB.remotes

# core/tx_pool.go(1797): func (t *txLookup) RemoteToLocals(locals ..
proc remoteToLocals*(xp: TxPoolRef; signer: EthAddress): int
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  xp.txDB.setLocal(signer)
  xp.txDB.bySender.eq(signer).nItems

]#

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------