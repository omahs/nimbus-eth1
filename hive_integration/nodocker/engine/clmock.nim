import
  std/[times, tables],
  chronicles,
  nimcrypto/sysrand,
  stew/[byteutils, endians2],
  eth/common, chronos,
  json_rpc/rpcclient,
  ../../../nimbus/rpc/merge/mergeutils,
  ../../../nimbus/rpc/execution_types,
  ../../../nimbus/[constants],
  ../../../nimbus/common as nimbus_common,
  ./engine_client

import web3/engine_api_types except Hash256  # conflict with the one from eth/common

# Consensus Layer Client Mock used to sync the Execution Clients once the TTD has been reached
type
  CLMocker* = ref object
    com: CommonRef

    # Number of required slots before a block which was set as Head moves to `safe` and `finalized` respectively
    slotsToSafe*     : int
    slotsToFinalized*: int

    # Wait time before attempting to get the payload
    payloadProductionClientDelay: int

    # Block production related
    blockTimestampIncrement*: Option[int]

    # Block Production State
    client                  : RpcClient
    nextFeeRecipient*       : EthAddress
    nextPayloadID*          : PayloadID
    currentPayloadNumber*   : uint64

    # Chain History
    headerHistory           : Table[uint64, common.BlockHeader]

    # PoS Chain History Information
    prevRandaoHistory*      : Table[uint64, common.Hash256]
    executedPayloadHistory* : Table[uint64, ExecutionPayload]
    headHashHistory         : seq[BlockHash]

    # Latest broadcasted data using the PoS Engine API
    latestHeadNumber*       : uint64
    latestHeader*           : common.BlockHeader
    latestPayloadBuilt*     : ExecutionPayload
    latestBlockValue*       : Option[UInt256]
    latestBlobsBundle*      : Option[BlobsBundleV1]
    latestPayloadAttributes*: PayloadAttributes
    latestExecutedPayload*  : ExecutionPayload
    latestForkchoice*       : ForkchoiceStateV1

    # Merge related
    firstPoSBlockNumber       : Option[uint64]
    ttdReached*               : bool
    transitionPayloadTimestamp: Option[int]
    safeSlotsToImportOptimistically: int
    chainTotalDifficulty      : UInt256

    # Shanghai related
    nextWithdrawals*          : Option[seq[WithdrawalV1]]

  BlockProcessCallbacks* = object
    onPayloadProducerSelected* : proc(): bool {.gcsafe.}
    onGetPayloadID*            : proc(): bool {.gcsafe.}
    onGetPayload*              : proc(): bool {.gcsafe.}
    onNewPayloadBroadcast*     : proc(): bool {.gcsafe.}
    onForkchoiceBroadcast*     : proc(): bool {.gcsafe.}
    onSafeBlockChange *        : proc(): bool {.gcsafe.}
    onFinalizedBlockChange*    : proc(): bool {.gcsafe.}

  GetPayloadResponse = object
    executionPayload: ExecutionPayload
    blockValue: Option[UInt256]
    blobsBundle: Option[BlobsBundleV1]

func latestPayloadNumber(h: Table[uint64, ExecutionPayload]): uint64 =
  result = 0'u64
  for n, _ in h:
    if n > result:
      result = n

func latestWithdrawalsIndex(h: Table[uint64, ExecutionPayload]): uint64 =
  result = 0'u64
  for n, p in h:
    if p.withdrawals.isNone:
      continue
    let wds = p.withdrawals.get
    for w in wds:
      if w.index.uint64 > result:
        result = w.index.uint64

proc init*(cl: CLMocker, client: RpcClient, com: CommonRef) =
  cl.client = client
  cl.com = com
  cl.slotsToSafe = 1
  cl.slotsToFinalized = 2
  cl.payloadProductionClientDelay = 1
  cl.headerHistory[0] = com.genesisHeader()

proc newClMocker*(client: RpcClient, com: CommonRef): CLMocker =
  new result
  result.init(client, com)

proc waitForTTD*(cl: CLMocker): Future[bool] {.async.} =
  let ttd = cl.com.ttd()
  doAssert(ttd.isSome)
  let (header, waitRes) = await cl.client.waitForTTD(ttd.get)
  if not waitRes:
    error "CLMocker: timeout while waiting for TTD"
    return false

  cl.latestHeader = header
  cl.headerHistory[header.blockNumber.truncate(uint64)] = header
  cl.ttdReached = true

  let headerHash = BlockHash(common.blockHash(cl.latestHeader).data)
  if cl.slotsToSafe == 0:
    cl.latestForkchoice.safeBlockHash = headerHash

  if cl.slotsToFinalized == 0:
    cl.latestForkchoice.finalizedBlockHash = headerHash

  # Reset transition values
  cl.latestHeadNumber = cl.latestHeader.blockNumber.truncate(uint64)
  cl.headHashHistory = @[]
  cl.firstPoSBlockNumber = none(uint64)

  # Prepare initial forkchoice, to be sent to the transition payload producer
  cl.latestForkchoice = ForkchoiceStateV1()
  cl.latestForkchoice.headBlockHash = headerHash

  let res = cl.client.forkchoiceUpdatedV1(cl.latestForkchoice)
  if res.isErr:
    error "waitForTTD: forkchoiceUpdated error", msg=res.error
    return false

  let s = res.get()
  if s.payloadStatus.status != PayloadExecutionStatus.valid:
    error "waitForTTD: forkchoiceUpdated response unexpected",
      expect = PayloadExecutionStatus.valid,
      get = s.payloadStatus.status
    return false

  return true

# Check whether a block number is a PoS block
proc isBlockPoS*(cl: CLMocker, bn: common.BlockNumber): bool =
  if cl.firstPoSBlockNumber.isNone:
    return false

  let number = cl.firstPoSBlockNumber.get()
  let bn = bn.truncate(uint64)
  if number > bn:
    return false

  return true

# Return the per-block timestamp value increment
func getTimestampIncrement(cl: CLMocker): int =
  cl.blockTimestampIncrement.get(1)

# Returns the timestamp value to be included in the next payload attributes
func getNextBlockTimestamp(cl: CLMocker): int64 =
  if cl.firstPoSBlockNumber.isNone and cl.transitionPayloadTimestamp.isSome:
    # We are producing the transition payload and there's a value specified
    # for this specific payload
    return cl.transitionPayloadTimestamp.get
  return cl.latestHeader.timestamp.toUnix + cl.getTimestampIncrement().int64

func setNextWithdrawals(cl: CLMocker, nextWithdrawals: Option[seq[WithdrawalV1]]) =
  cl.nextWithdrawals = nextWithdrawals

func timestampToBeaconRoot(timestamp: Quantity): FixedBytes[32] =
  # Generates a deterministic hash from the timestamp
  let h = keccakHash(timestamp.uint64.toBytesBE)
  FixedBytes[32](h.data)

proc pickNextPayloadProducer(cl: CLMocker): bool =
  let nRes = cl.client.blockNumber()
  if nRes.isErr:
    error "CLMocker: could not get block number", msg=nRes.error
    return false

  let lastBlockNumber = nRes.get
  if cl.latestHeadNumber != lastBlockNumber:
    error "CLMocker: unexpected lastBlockNumber",
      get = lastBlockNumber,
      expect = cl.latestHeadNumber
    return false

  var header: common.BlockHeader
  let hRes = cl.client.headerByNumber(lastBlockNumber, header)
  if hRes.isErr:
    error "CLMocker: Could not get block header", msg=hRes.error
    return false

  let lastBlockHash = header.blockHash
  if cl.latestHeader.blockHash != lastBlockHash:
    error "CLMocker: Failed to obtain a client on the latest block number"
    return false

  return true

func isShanghai(cl: CLMocker, timestamp: Quantity): bool =
  let ts = fromUnix(timestamp.int64)
  cl.com.isShanghaiOrLater(ts)

func isCancun(cl: CLMocker, timestamp: Quantity): bool =
  let ts = fromUnix(timestamp.int64)
  cl.com.isCancunOrLater(ts)

func V1(attr: Option[PayloadAttributes]): Option[PayloadAttributesV1] =
  if attr.isNone:
    return none(PayloadAttributesV1)
  some(attr.get.V1)

func V2(attr: Option[PayloadAttributes]): Option[PayloadAttributesV2] =
  if attr.isNone:
    return none(PayloadAttributesV2)
  some(attr.get.V2)

func V3(attr: Option[PayloadAttributes]): Option[PayloadAttributesV3] =
  if attr.isNone:
    return none(PayloadAttributesV3)
  some(attr.get.V3)

proc fcu(cl: CLMocker, version: Version,
          update: ForkchoiceStateV1,
          attr: Option[PayloadAttributes]):
            Result[ForkchoiceUpdatedResponse, string] =
  case version
  of Version.V1: cl.client.forkchoiceUpdatedV1(update, attr.V1)
  of Version.V2: cl.client.forkchoiceUpdatedV2(update, attr.V2)
  of Version.V3: cl.client.forkchoiceUpdatedV3(update, attr.V3)

proc getNextPayloadID*(cl: CLMocker): bool =
  # Generate a random value for the PrevRandao field
  var nextPrevRandao: common.Hash256
  doAssert randomBytes(nextPrevRandao.data) == 32

  let timestamp = Quantity cl.getNextBlockTimestamp.uint64
  cl.latestPayloadAttributes = PayloadAttributes(
    timestamp:             timestamp,
    prevRandao:            FixedBytes[32] nextPrevRandao.data,
    suggestedFeeRecipient: Address cl.nextFeeRecipient,
  )

  if cl.isShanghai(timestamp):
    cl.latestPayloadAttributes.withdrawals = cl.nextWithdrawals

  if cl.isCancun(timestamp):
    # Write a deterministic hash based on the block number
    let beaconRoot = timestampToBeaconRoot(timestamp)
    cl.latestPayloadAttributes.parentBeaconBlockRoot = some(beaconRoot)

  # Save random value
  let number = cl.latestHeader.blockNumber.truncate(uint64) + 1
  cl.prevRandaoHistory[number] = nextPrevRandao

  let version = cl.latestPayloadAttributes.version
  let res = cl.fcu(version, cl.latestForkchoice, some(cl.latestPayloadAttributes))
  if res.isErr:
    error "CLMocker: Could not send forkchoiceUpdated", version=version, msg=res.error
    return false

  let s = res.get()
  if s.payloadStatus.status != PayloadExecutionStatus.valid:
    error "CLMocker: Unexpected forkchoiceUpdated Response from Payload builder",
      status=s.payloadStatus.status

  if s.payloadStatus.latestValidHash.isNone or s.payloadStatus.latestValidHash.get != cl.latestForkchoice.headBlockHash:
    error "CLMocker: Unexpected forkchoiceUpdated LatestValidHash Response from Payload builder",
      latest=s.payloadStatus.latestValidHash,
      head=cl.latestForkchoice.headBlockHash

  doAssert s.payLoadID.isSome
  cl.nextPayloadID = s.payloadID.get()
  return true

proc getPayload(cl: CLMocker, payloadId: PayloadID): Result[GetPayloadResponse, string] =
  let ts = cl.latestPayloadAttributes.timestamp
  if cl.isCancun(ts):
    let res = cl.client.getPayloadV3(payloadId)
    if res.isErr:
      return err(res.error)
    let x = res.get
    return ok(GetPayloadResponse(
      executionPayload: executionPayload(x.executionPayload),
      blockValue: some(x.blockValue),
      blobsBundle: some(x.blobsBundle)
    ))

  if cl.isShanghai(ts):
    let res = cl.client.getPayloadV2(payloadId)
    if res.isErr:
      return err(res.error)
    let x = res.get
    return ok(GetPayloadResponse(
      executionPayload: executionPayload(x.executionPayload),
      blockValue: some(x.blockValue)
    ))

  let res = cl.client.getPayloadV1(payloadId)
  if res.isErr:
    return err(res.error)
  return ok(GetPayloadResponse(
    executionPayload: executionPayload(res.get),
  ))

proc getNextPayload*(cl: CLMocker): bool =
  let res = cl.getPayload(cl.nextPayloadID)
  if res.isErr:
    error "CLMocker: Could not getPayload",
      payloadID=toHex(cl.nextPayloadID)
    return false

  let x = res.get()
  cl.latestPayloadBuilt = x.executionPayload
  cl.latestBlockValue = x.blockValue
  cl.latestBlobsBundle = x.blobsBundle

  let header = toBlockHeader(cl.latestPayloadBuilt)
  let blockHash = BlockHash header.blockHash.data
  if blockHash != cl.latestPayloadBuilt.blockHash:
    error "CLMocker: getNextPayload blockHash mismatch",
      expected=cl.latestPayloadBuilt.blockHash.toHex,
      get=blockHash.toHex
    return false

  if cl.latestPayloadBuilt.timestamp != cl.latestPayloadAttributes.timestamp:
    error "CLMocker: Incorrect Timestamp on payload built",
      expect=cl.latestPayloadBuilt.timestamp.uint64,
      get=cl.latestPayloadAttributes.timestamp.uint64
    return false

  if cl.latestPayloadBuilt.feeRecipient != cl.latestPayloadAttributes.suggestedFeeRecipient:
    error "CLMocker: Incorrect SuggestedFeeRecipient on payload built",
      expect=cl.latestPayloadBuilt.feeRecipient.toHex,
      get=cl.latestPayloadAttributes.suggestedFeeRecipient.toHex
    return false

  if cl.latestPayloadBuilt.prevRandao != cl.latestPayloadAttributes.prevRandao:
    error "CLMocker: Incorrect PrevRandao on payload built",
      expect=cl.latestPayloadBuilt.prevRandao.toHex,
      get=cl.latestPayloadAttributes.prevRandao.toHex
    return false

  if cl.latestPayloadBuilt.parentHash != BlockHash cl.latestHeader.blockHash.data:
    error "CLMocker: Incorrect ParentHash on payload built",
      expect=cl.latestPayloadBuilt.parentHash.toHex,
      get=cl.latestHeader.blockHash
    return false

  if cl.latestPayloadBuilt.blockNumber.uint64.toBlockNumber != cl.latestHeader.blockNumber + 1.toBlockNumber:
    error "CLMocker: Incorrect Number on payload built",
      expect=cl.latestPayloadBuilt.blockNumber.uint64,
      get=cl.latestHeader.blockNumber+1.toBlockNumber
    return false

  return true

func versionedHashes(bb: BlobsBundleV1): seq[BlockHash] =
  doAssert(bb.commitments.len > 0)
  result = newSeqOfCap[BlockHash](bb.commitments.len)

  for com in bb.commitments:
    var h = keccakHash(com.bytes)
    h.data[0] = BLOB_COMMITMENT_VERSION_KZG
    result.add BlockHash(h.data)

proc broadcastNewPayload(cl: CLMocker, payload: ExecutionPayload): Result[PayloadStatusV1, string] =
  var versionedHashes: seq[BlockHash]
  if cl.latestBlobsBundle.isSome:
    # Broadcast the blob bundle to all clients
    versionedHashes = versionedHashes(cl.latestBlobsBundle.get)

  case payload.version
  of Version.V1: return cl.client.newPayloadV1(payload.V1)
  of Version.V2: return cl.client.newPayloadV2(payload.V2)
  of Version.V3: return cl.client.newPayloadV3(payload.V3,
    versionedHashes,
    cl.latestPayloadAttributes.parentBeaconBlockRoot.get)

proc broadcastNextNewPayload(cl: CLMocker): bool =
  let res = cl.broadcastNewPayload(cl.latestPayloadBuilt)
  if res.isErr:
    error "CLMocker: broadcastNewPayload Error", msg=res.error
    return false

  let s = res.get()
  if s.status == PayloadExecutionStatus.valid:
    # The client is synced and the payload was immediately validated
    # https:#github.com/ethereum/execution-apis/blob/main/src/engine/specification.md:
    # - If validation succeeds, the response MUST contain {status: VALID, latestValidHash: payload.blockHash}
    let blockHash = cl.latestPayloadBuilt.blockHash
    if s.latestValidHash.isNone:
      error "CLMocker: NewPayload returned VALID status with nil LatestValidHash",
        expected=blockHash.toHex
      return false

    let latestValidHash = s.latestValidHash.get()
    if latestValidHash != BlockHash(blockHash):
      error "CLMocker: NewPayload returned VALID status with incorrect LatestValidHash",
        get=latestValidHash.toHex, expected=blockHash.toHex
      return false

  elif s.status == PayloadExecutionStatus.accepted:
    # The client is not synced but the payload was accepted
    # https:#github.com/ethereum/execution-apis/blob/main/src/engine/specification.md:
    # - {status: ACCEPTED, latestValidHash: null, validationError: null} if the following conditions are met:
    # the blockHash of the payload is valid
    # the payload doesn't extend the canonical chain
    # the payload hasn't been fully validated.
    let nullHash = BlockHash common.Hash256().data
    let latestValidHash = s.latestValidHash.get(nullHash)
    if s.latestValidHash.isSome and latestValidHash != nullHash:
      error "CLMocker: NewPayload returned ACCEPTED status with incorrect LatestValidHash",
        hash=latestValidHash.toHex
      return false

  else:
    error "CLMocker: broadcastNewPayload Response",
      status=s.status
    return false

  cl.latestExecutedPayload = cl.latestPayloadBuilt
  let number = uint64 cl.latestPayloadBuilt.blockNumber
  cl.executedPayloadHistory[number] = cl.latestPayloadBuilt
  return true

proc broadcastForkchoiceUpdated*(cl: CLMocker,
      update: ForkchoiceStateV1): Result[ForkchoiceUpdatedResponse, string] =
  let version = cl.latestExecutedPayload.version
  cl.fcu(version, update, none(PayloadAttributes))

proc broadcastLatestForkchoice(cl: CLMocker): bool =
  let res = cl.broadcastForkchoiceUpdated(cl.latestForkchoice)
  if res.isErr:
    error "CLMocker: broadcastForkchoiceUpdated Error", msg=res.error
    return false

  let s = res.get()
  if s.payloadStatus.status != PayloadExecutionStatus.valid:
    error "CLMocker: broadcastForkchoiceUpdated Response",
      status=s.payloadStatus.status
    return false

  if s.payloadStatus.latestValidHash.get != cl.latestForkchoice.headBlockHash:
    error "CLMocker: Incorrect LatestValidHash from ForkchoiceUpdated",
      get=s.payloadStatus.latestValidHash.get.toHex,
      expect=cl.latestForkchoice.headBlockHash.toHex

  if s.payloadStatus.validationError.isSome:
    error "CLMocker: Expected empty validationError",
      msg=s.payloadStatus.validationError.get

  if s.payloadID.isSome:
    error "CLMocker: Expected empty PayloadID",
      msg=s.payloadID.get.toHex

  return true


proc produceSingleBlock*(cl: CLMocker, cb: BlockProcessCallbacks): bool {.gcsafe.} =
  doAssert(cl.ttdReached)

  cl.currentPayloadNumber = cl.latestHeader.blockNumber.truncate(uint64) + 1'u64
  if not cl.pickNextPayloadProducer():
    return false

  # Check if next withdrawals necessary, test can override this value on
  # `OnPayloadProducerSelected` callback
  if cl.nextWithdrawals.isNone:
    var nw: seq[WithdrawalV1]
    cl.setNextWithdrawals(some(nw))

  if cb.onPayloadProducerSelected != nil:
    if not cb.onPayloadProducerSelected():
      return false

  if not cl.getNextPayloadID():
    return false

  cl.setNextWithdrawals(none(seq[WithdrawalV1]))

  if cb.onGetPayloadID != nil:
    if not cb.onGetPayloadID():
      return false

  # Give the client a delay between getting the payload ID and actually retrieving the payload
  #time.Sleep(PayloadProductionClientDelay)

  if not cl.getNextPayload():
    return false

  if cb.onGetPayload != nil:
    if not cb.onGetPayload():
      return false

  if not cl.broadcastNextNewPayload():
    return false

  if cb.onNewPayloadBroadcast != nil:
    if not cb.onNewPayloadBroadcast():
      return false

  # Broadcast forkchoice updated with new HeadBlock to all clients
  let previousForkchoice = cl.latestForkchoice
  cl.headHashHistory.add cl.latestPayloadBuilt.blockHash

  cl.latestForkchoice = ForkchoiceStateV1()
  cl.latestForkchoice.headBlockHash = cl.latestPayloadBuilt.blockHash

  let hhLen = cl.headHashHistory.len
  if hhLen > cl.slotsToSafe:
    cl.latestForkchoice.safeBlockHash = cl.headHashHistory[hhLen - cl.slotsToSafe - 1]

  if hhLen > cl.slotsToFinalized:
    cl.latestForkchoice.finalizedBlockHash = cl.headHashHistory[hhLen - cl.slotsToFinalized - 1]

  if not cl.broadcastLatestForkchoice():
    return false

  if cb.onForkchoiceBroadcast != nil:
    if not cb.onForkchoiceBroadcast():
      return false

  # Broadcast forkchoice updated with new SafeBlock to all clients
  if cb.onSafeBlockChange != nil and cl.latestForkchoice.safeBlockHash != previousForkchoice.safeBlockHash:
    if not cb.onSafeBlockChange():
      return false

  # Broadcast forkchoice updated with new FinalizedBlock to all clients
  if cb.onFinalizedBlockChange != nil and cl.latestForkchoice.finalizedBlockHash != previousForkchoice.finalizedBlockHash:
    if not cb.onFinalizedBlockChange():
      return false

  # Broadcast forkchoice updated with new FinalizedBlock to all clients
  # Save the number of the first PoS block
  if cl.firstPoSBlockNumber.isNone:
    let number = cl.latestHeader.blockNumber.truncate(uint64) + 1
    cl.firstPoSBlockNumber = some(number)

  # Save the header of the latest block in the PoS chain
  cl.latestHeadNumber = cl.latestHeadNumber + 1

  # Check if any of the clients accepted the new payload
  var newHeader: common.BlockHeader
  let res = cl.client.headerByNumber(cl.latestHeadNumber, newHeader)
  if res.isErr:
    error "CLMock ProduceSingleBlock", msg=res.error
    return false

  let newHash = BlockHash newHeader.blockHash.data
  if newHash != cl.latestPayloadBuilt.blockHash:
    error "CLMocker: None of the clients accepted the newly constructed payload",
      hash=newHash.toHex
    return false

  # Check that the new finalized header has the correct properties
  # ommersHash == 0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347
  if newHeader.ommersHash != EMPTY_UNCLE_HASH:
    error "CLMocker: Client produced a new header with incorrect ommersHash", ommersHash = newHeader.ommersHash
    return false

  # difficulty == 0
  if newHeader.difficulty != 0.u256:
    error "CLMocker: Client produced a new header with incorrect difficulty", difficulty = newHeader.difficulty
    return false

  # mixHash == prevRandao
  if newHeader.mixDigest != cl.prevRandaoHistory[cl.latestHeadNumber]:
    error "CLMocker: Client produced a new header with incorrect mixHash",
      get = newHeader.mixDigest.data.toHex,
      expect = cl.prevRandaoHistory[cl.latestHeadNumber].data.toHex
    return false

  # nonce == 0x0000000000000000
  if newHeader.nonce != default(BlockNonce):
    error "CLMocker: Client produced a new header with incorrect nonce",
      nonce = newHeader.nonce.toHex
    return false

  if newHeader.extraData.len > 32:
    error "CLMocker: Client produced a new header with incorrect extraData (len > 32)",
      len = newHeader.extraData.len
    return false

  cl.latestHeader = newHeader
  cl.headerHistory[cl.latestHeadNumber] = cl.latestHeader

  return true

# Loop produce PoS blocks by using the Engine API
proc produceBlocks*(cl: CLMocker, blockCount: int, cb: BlockProcessCallbacks): bool {.gcsafe.} =
  # Produce requested amount of blocks
  for i in 0..<blockCount:
    if not cl.produceSingleBlock(cb):
      return false
  return true

proc posBlockNumber*(cl: CLMocker): uint64 =
  cl.firstPoSBlockNumber.get(0'u64)
