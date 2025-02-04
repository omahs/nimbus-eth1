# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Stack, Memory, Storage And Flow Operations
## ===============================================================
##

{.push raises: [].}

import
  ../../evm_errors,
  ../../code_stream,
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../gas_costs,
  ../op_codes,
  ../utils/utils_numeric,
  ./oph_defs,
  ./oph_helpers,
  eth/common,
  stint

when not defined(evmc_enabled):
  import
    ../gas_meter,
    ../../state,
    ../../../db/ledger

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when evmc_enabled:
  proc sstoreEvmc(c: Computation, slot, newValue: UInt256, coldAccess = 0.GasInt): EvmResultVoid =
    let
      status   = c.host.setStorage(c.msg.contractAddress, slot, newValue)
      gasParam = GasParams(kind: Op.Sstore, s_status: status)
      res      = ? c.gasCosts[Sstore].c_handler(newValue, gasParam)
      gasCost  = res.gasCost + coldAccess

    c.opcodeGastCost(Sstore, gasCost, "SSTORE")

else:
  proc sstoreImpl(c: Computation, slot, newValue: UInt256): EvmResultVoid =
    let
      currentValue = c.getStorage(slot)
      gasParam = GasParams(
        kind: Op.Sstore,
        s_currentValue: currentValue)

      res = ? c.gasCosts[Sstore].c_handler(newValue, gasParam)

    ? c.opcodeGastCost(Sstore, res.gasCost, "SSTORE")
    if res.gasRefund > 0:
      c.gasMeter.refundGas(res.gasRefund)

    c.vmState.mutateStateDB:
      db.setStorage(c.msg.contractAddress, slot, newValue)
    ok()


  proc sstoreNetGasMeteringImpl(c: Computation; slot, newValue: UInt256, coldAccess = 0.GasInt): EvmResultVoid =
    let
      stateDB = c.vmState.readOnlyStateDB
      currentValue = c.getStorage(slot)

      gasParam = GasParams(
        kind: Op.Sstore,
        s_currentValue: currentValue,
        s_originalValue: stateDB.getCommittedStorage(c.msg.contractAddress, slot))

      res = ? c.gasCosts[Sstore].c_handler(newValue, gasParam)

    ? c.opcodeGastCost(Sstore, res.gasCost + coldAccess, "SSTORE")

    if res.gasRefund != 0:
      c.gasMeter.refundGas(res.gasRefund)

    c.vmState.mutateStateDB:
      db.setStorage(c.msg.contractAddress, slot, newValue)
    ok()

template sstoreEvmcOrSstore(cpt, slot, newValue: untyped): auto =
  when evmc_enabled:
    sstoreEvmc(cpt, slot, newValue, 0.GasInt)
  else:
    sstoreImpl(cpt, slot, newValue)

template sstoreEvmcOrNetGasMetering(cpt, slot, newValue: untyped, coldAccess = 0.GasInt): auto =
  when evmc_enabled:
    sstoreEvmc(cpt, slot, newValue, coldAccess)
  else:
    sstoreNetGasMeteringImpl(cpt, slot, newValue, coldAccess)

func jumpImpl(c: Computation; jumpTarget: UInt256): EvmResultVoid =
  if jumpTarget >= c.code.len.u256:
    return err(opErr(InvalidJumpDest))

  let jt = jumpTarget.truncate(int)
  c.code.pc = jt

  let nextOpcode = c.code.peek
  if nextOpcode != JumpDest:
    return err(opErr(InvalidJumpDest))

  # TODO: next check seems redundant
  if not c.code.isValidOpcode(jt):
    return err(opErr(InvalidJumpDest))

  ok()

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  popOp: VmOpFn = func (k: var VmCtx): EvmResultVoid =
    ## 0x50, Remove item from stack.
    k.cpt.stack.popInt.isOkOr:
      return err(error)
    ok()

  mloadOp: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x51, Load word from memory
    let memStartPos = ? k.cpt.stack.popInt()

    let memPos = memStartPos.cleanMemRef
    ? k.cpt.opcodeGastCost(Mload,
      k.cpt.gasCosts[Mload].m_handler(k.cpt.memory.len, memPos, 32),
      reason = "MLOAD: GasVeryLow + memory expansion")

    k.cpt.memory.extend(memPos, 32)
    k.cpt.stack.push k.cpt.memory.read32Bytes(memPos)


  mstoreOp: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x52, Save word to memory
    let (memStartPos, value) = ? k.cpt.stack.popInt(2)

    let memPos = memStartPos.cleanMemRef
    ? k.cpt.opcodeGastCost(Mstore,
      k.cpt.gasCosts[Mstore].m_handler(k.cpt.memory.len, memPos, 32),
      reason = "MSTORE: GasVeryLow + memory expansion")

    k.cpt.memory.extend(memPos, 32)
    k.cpt.memory.write(memPos, value.toBytesBE)


  mstore8Op: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x53, Save byte to memory
    let (memStartPos, value) = ? k.cpt.stack.popInt(2)

    let memPos = memStartPos.cleanMemRef
    ? k.cpt.opcodeGastCost(Mstore8,
      k.cpt.gasCosts[Mstore8].m_handler(k.cpt.memory.len, memPos, 1),
      reason = "MSTORE8: GasVeryLow + memory expansion")

    k.cpt.memory.extend(memPos, 1)
    k.cpt.memory.write(memPos, value.toByteArrayBE[31])


  # -------

  sloadOp: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x54, Load word from storage.
    let
      cpt = k.cpt
      slot = ? cpt.stack.popInt()
    cpt.stack.push cpt.getStorage(slot)

  sloadEIP2929Op: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x54, EIP2929: Load word from storage for Berlin and later
    let
      cpt = k.cpt
      slot = ? cpt.stack.popInt()
      gasCost = cpt.gasEip2929AccountCheck(cpt.msg.contractAddress, slot)
    ? cpt.opcodeGastCost(Sload, gasCost, reason = "sloadEIP2929")
    cpt.stack.push cpt.getStorage(slot)

  # -------

  sstoreOp: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x55, Save word to storage.
    let
      cpt = k.cpt
      (slot, newValue) = ? cpt.stack.popInt(2)

    ? checkInStaticContext(cpt)
    sstoreEvmcOrSstore(cpt, slot, newValue)


  sstoreEIP1283Op: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x55, EIP1283: sstore for Constantinople and later
    let
      cpt = k.cpt
      (slot, newValue) = ? cpt.stack.popInt(2)

    ? checkInStaticContext(cpt)
    sstoreEvmcOrNetGasMetering(cpt, slot, newValue)


  sstoreEIP2200Op: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x55, EIP2200: sstore for Istanbul and later
    let
      cpt = k.cpt
      (slot, newValue) = ? cpt.stack.popInt(2)

    ? checkInStaticContext(cpt)
    const SentryGasEIP2200 = 2300

    if cpt.gasMeter.gasRemaining <= SentryGasEIP2200:
      return err(opErr(OutOfGas))

    sstoreEvmcOrNetGasMetering(cpt, slot, newValue)


  sstoreEIP2929Op: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x55, EIP2929: sstore for Berlin and later
    let
      cpt = k.cpt
      (slot, newValue) = ? cpt.stack.popInt(2)

    ? checkInStaticContext(cpt)

    # Minimum gas required to be present for an SSTORE call, not consumed
    const SentryGasEIP2200 = 2300

    if cpt.gasMeter.gasRemaining <= SentryGasEIP2200:
      return err(opErr(OutOfGas))

    var coldAccessGas = 0.GasInt
    when evmc_enabled:
      if cpt.host.accessStorage(cpt.msg.contractAddress, slot) == EVMC_ACCESS_COLD:
        coldAccessGas = ColdSloadCost
    else:
      cpt.vmState.mutateStateDB:
        if not db.inAccessList(cpt.msg.contractAddress, slot):
          db.accessList(cpt.msg.contractAddress, slot)
          coldAccessGas = ColdSloadCost

    sstoreEvmcOrNetGasMetering(cpt, slot, newValue, coldAccessGas)

  # -------

  jumpOp: VmOpFn = func (k: var VmCtx): EvmResultVoid =
    ## 0x56, Alter the program counter
    let jumpTarget = ? k.cpt.stack.popInt()
    jumpImpl(k.cpt, jumpTarget)


  jumpIOp: VmOpFn = func (k: var VmCtx): EvmResultVoid =
    ## 0x57, Conditionally alter the program counter.
    let (jumpTarget, testedValue) = ? k.cpt.stack.popInt(2)
    if testedValue.isZero:
      return ok()
    jumpImpl(k.cpt, jumpTarget)

  pcOp: VmOpFn = func (k: var VmCtx): EvmResultVoid =
    ## 0x58, Get the value of the program counter prior to the increment
    ##       corresponding to this instruction.
    k.cpt.stack.push max(k.cpt.code.pc - 1, 0)

  msizeOp: VmOpFn = func (k: var VmCtx): EvmResultVoid =
    ## 0x59, Get the size of active memory in bytes.
    k.cpt.stack.push k.cpt.memory.len

  gasOp: VmOpFn = func (k: var VmCtx): EvmResultVoid =
    ## 0x5a, Get the amount of available gas, including the corresponding
    ##       reduction for the cost of this instruction.
    k.cpt.stack.push k.cpt.gasMeter.gasRemaining

  jumpDestOp: VmOpFn = func (k: var VmCtx): EvmResultVoid =
    ## 0x5b, Mark a valid destination for jumps. This operation has no effect
    ##       on machine state during execution.
    ok()

  tloadOp: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x5c, Load word from transient storage.
    let
      slot = ? k.cpt.stack.popInt()
      val  = k.cpt.getTransientStorage(slot)
    k.cpt.stack.push val

  tstoreOp: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x5d, Save word to transient storage.
    ? checkInStaticContext(k.cpt)

    let
      slot = ? k.cpt.stack.popInt()
      val  = ? k.cpt.stack.popInt()
    k.cpt.setTransientStorage(slot, val)
    ok()

  mCopyOp: VmOpFn = proc (k: var VmCtx): EvmResultVoid =
    ## 0x5e, Copy memory
    let (dst, src, size) = ? k.cpt.stack.popInt(3)

    let (dstPos, srcPos, len) =
      (dst.cleanMemRef, src.cleanMemRef, size.cleanMemRef)

    ? k.cpt.opcodeGastCost(Mcopy,
      k.cpt.gasCosts[Mcopy].m_handler(k.cpt.memory.len, max(dstPos, srcPos), len),
      reason = "Mcopy fee")

    k.cpt.memory.copy(dstPos, srcPos, len)
    ok()

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  VmOpExecMemory*: seq[VmOpExec] = @[

    (opCode: Pop,       ## x50, Remove item from stack
     forks: VmOpAllForks,
     name: "pop",
     info: "Remove item from stack",
     exec: (prep: VmOpIgnore,
            run:  popOp,
            post: VmOpIgnore)),

    (opCode: Mload,     ## 0x51, Load word from memory
     forks: VmOpAllForks,
     name: "mload",
     info: "Load word from memory",
     exec: (prep: VmOpIgnore,
            run:  mloadOp,
            post: VmOpIgnore)),

    (opCode: Mstore,    ## 0x52, Save word to memory
     forks: VmOpAllForks,
     name: "mstore",
     info: "Save word to memory",
     exec: (prep: VmOpIgnore,
            run:  mstoreOp,
            post: VmOpIgnore)),

    (opCode: Mstore8,   ## 0x53, Save byte to memory
     forks: VmOpAllForks,
     name: "mstore8",
     info: "Save byte to memory",
     exec: (prep: VmOpIgnore,
            run:  mstore8Op,
            post: VmOpIgnore)),

    (opCode: Sload,     ## 0x54, Load word from storage
     forks: VmOpAllForks - VmOpBerlinAndLater,
     name: "sload",
     info: "Load word from storage",
     exec: (prep: VmOpIgnore,
            run:  sloadOp,
            post: VmOpIgnore)),

    (opCode: Sload,     ## 0x54, sload for Berlin and later
     forks: VmOpBerlinAndLater,
     name: "sloadEIP2929",
     info: "EIP2929: sload for Berlin and later",
     exec: (prep: VmOpIgnore,
            run:  sloadEIP2929Op,
            post: VmOpIgnore)),

    (opCode: Sstore,    ## 0x55, Save word
     forks: VmOpAllForks - VmOpConstantinopleAndLater,
     name: "sstore",
     info: "Save word to storage",
     exec: (prep: VmOpIgnore,
            run:  sstoreOp,
            post: VmOpIgnore)),

    (opCode: Sstore,    ## 0x55, sstore for Constantinople and later
     forks: VmOpConstantinopleAndLater - VmOpPetersburgAndLater,
     name: "sstoreEIP1283",
     info: "EIP1283: sstore for Constantinople and later",
     exec: (prep: VmOpIgnore,
            run:  sstoreEIP1283Op,
            post: VmOpIgnore)),

    (opCode: Sstore,    ## 0x55, sstore for Petersburg and later
     forks: VmOpPetersburgAndLater - VmOpIstanbulAndLater,
     name: "sstore",
     info: "sstore for Constantinople and later",
     exec: (prep: VmOpIgnore,
            run:  sstoreOp,
            post: VmOpIgnore)),

    (opCode: Sstore,    ##  0x55, sstore for Istanbul and later
     forks: VmOpIstanbulAndLater - VmOpBerlinAndLater,
     name: "sstoreEIP2200",
     info: "EIP2200: sstore for Istanbul and later",
     exec: (prep: VmOpIgnore,
            run:  sstoreEIP2200Op,
            post: VmOpIgnore)),

    (opCode: Sstore,    ##  0x55, sstore for Berlin and later
     forks: VmOpBerlinAndLater,
     name: "sstoreEIP2929",
     info: "EIP2929: sstore for Istanbul and later",
     exec: (prep: VmOpIgnore,
            run:  sstoreEIP2929Op,
            post: VmOpIgnore)),

    (opCode: Jump,      ## 0x56, Jump
     forks: VmOpAllForks,
     name: "jump",
     info: "Alter the program counter",
     exec: (prep: VmOpIgnore,
            run:  jumpOp,
            post: VmOpIgnore)),

    (opCode: JumpI,     ## 0x57, Conditional jump
     forks: VmOpAllForks,
     name: "jumpI",
     info: "Conditionally alter the program counter",
     exec: (prep: VmOpIgnore,
            run:  jumpIOp,
            post: VmOpIgnore)),

    (opCode: Pc,        ## 0x58, Program counter prior to instruction
     forks: VmOpAllForks,
     name: "pc",
     info: "Get the value of the program counter prior to the increment "&
           "corresponding to this instruction",
     exec: (prep: VmOpIgnore,
            run:  pcOp,
            post: VmOpIgnore)),

    (opCode: Msize,     ## 0x59, Memory size
     forks: VmOpAllForks,
     name: "msize",
     info: "Get the size of active memory in bytes",
     exec: (prep: VmOpIgnore,
            run:  msizeOp,
            post: VmOpIgnore)),

    (opCode: Gas,       ##  0x5a, Get available gas
     forks: VmOpAllForks,
     name: "gas",
     info: "Get the amount of available gas, including the corresponding "&
           "reduction for the cost of this instruction",
     exec: (prep: VmOpIgnore,
            run:  gasOp,
            post: VmOpIgnore)),

    (opCode: JumpDest,  ## 0x5b, Mark jump target. This operation has no effect
                        ##       on machine state during execution
     forks: VmOpAllForks,
     name: "jumpDest",
     info: "Mark a valid destination for jumps",
     exec: (prep: VmOpIgnore,
            run:  jumpDestOp,
            post: VmOpIgnore)),

    (opCode: Tload,     ## 0x5c, Load word from transient storage.
     forks: VmOpCancunAndLater,
     name: "tLoad",
     info: "Load word from transient storage",
     exec: (prep: VmOpIgnore,
            run:  tloadOp,
            post: VmOpIgnore)),

    (opCode: Tstore,     ## 0x5d, Save word to transient storage.
     forks: VmOpCancunAndLater,
     name: "tStore",
     info: "Save word to transient storage",
     exec: (prep: VmOpIgnore,
            run:  tstoreOp,
            post: VmOpIgnore)),

    (opCode: Mcopy,     ## 0x5e, Copy memory
     forks: VmOpCancunAndLater,
     name: "MCopy",
     info: "Copy memory",
     exec: (prep: VmOpIgnore,
            run:  mCopyOp,
            post: VmOpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
