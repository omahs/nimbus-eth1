# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  chronicles,
  eth/common,
  results,
  ../../../kvt as use_kvt,
  ../../base,
  ../../base/base_desc,
  ./common_desc

type
  KvtBaseRef* = ref object
    parent: CoreDbRef            ## Opaque top level descriptor
    kdb: KvtDbRef                ## Shared key-value table
    api*: KvtApiRef              ## Api functions can be re-directed
    cache: KvtCoreDxKvtRef       ## Shared transaction table wrapper

  KvtCoreDxKvtRef = ref object of CoreDxKvtRef
    base: KvtBaseRef             ## Local base descriptor
    kvt: KvtDbRef                ## In most cases different from `base.kdb`

  AristoCoreDbKvtBE* = ref object of CoreDbKvtBackendRef
    kdb*: KvtDbRef

logScope:
  topics = "kvt-hdl"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toError(
    e: KvtError;
    base: KvtBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: false,
    kErr:     e))

func toRc[T](
    rc: Result[T,KvtError];
    base: KvtBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err rc.error.toError(base, info, error)

# ------------------------------------------------------------------------------
# Private `kvt` call back functions
# ------------------------------------------------------------------------------

proc kvtMethods(cKvt: KvtCoreDxKvtRef): CoreDbKvtFns =
  ## Key-value database table handlers

  proc kvtBackend(
      cKvt:KvtCoreDxKvtRef;
        ): CoreDbKvtBackendRef =
    cKvt.base.parent.bless AristoCoreDbKvtBE(kdb: cKvt.kvt)

  proc kvtForget(
      cKvt: KvtCoreDxKvtRef;
      info: static[string];
        ): CoreDbRc[void] =
    let
      base = cKvt.base
      kvt = cKvt.kvt
    if kvt != base.kdb:
      let rc = base.api.forget(kvt)

      # There is not much that can be done in case of a `forget()` error.
      # So unmark it anyway.
      cKvt.kvt = KvtDbRef(nil)

      if rc.isErr:
        return err(rc.error.toError(base, info))
    ok()

  proc kvtGet(
      cKvt: KvtCoreDxKvtRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[Blob] =
    let rc = cKvt.base.api.get(cKvt.kvt, k)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      err(rc.error.toError(cKvt.base, info, KvtNotFound))
    else:
      rc.toRc(cKvt.base, info)

  proc kvtPut(
      cKvt: KvtCoreDxKvtRef;
      k: openArray[byte];
      v: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let rc = cKvt.base.api.put(cKvt.kvt, k, v)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError(cKvt.base, info))

  proc kvtDel(
      cKvt: KvtCoreDxKvtRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let rc = cKvt.base.api.del(cKvt.kvt, k)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError(cKvt.base, info))

  proc kvtHasKey(
      cKvt: KvtCoreDxKvtRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[bool] =
    let rc = cKvt.base.api.hasKey(cKvt.kvt, k)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError(cKvt.base, info))

  CoreDbKvtFns(
    backendFn: proc(): CoreDbKvtBackendRef =
      cKvt.kvtBackend(),

    getFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      cKvt.kvtGet(k, "getFn()"),

    delFn: proc(k: openArray[byte]): CoreDbRc[void] =
      cKvt.kvtDel(k, "delFn()"),

    putFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      cKvt.kvtPut(k, v, "putFn()"),

    hasKeyFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      cKvt.kvtHasKey(k, "hasKeyFn()"),

    forgetFn: proc(): CoreDbRc[void] =
      cKvt.kvtForget("forgetFn()"))

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

func toVoidRc*[T](
    rc: Result[T,KvtError];
    base: KvtBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isErr:
    return err(rc.error.toError(base, info, error))
  ok()

# ---------------------

func to*(dsc: CoreDxKvtRef; T: type KvtDbRef): T =
  KvtCoreDxKvtRef(dsc).kvt

func txTop*(
    base: KvtBaseRef;
    info: static[string];
      ): CoreDbRc[KvtTxRef] =
  base.api.txTop(base.kdb).toRc(base, info)

proc txBegin*(
    base: KvtBaseRef;
    info: static[string];
      ): KvtTxRef =
  let rc = base.api.txBegin(base.kdb)
  if rc.isErr:
    raiseAssert info & ": " & $rc.error
  rc.value

proc persistent*(
    base: KvtBaseRef;
    info: static[string];
      ): CoreDbRc[void] =
  let
    api = base.api
    kvt = base.kdb
    rc = api.persist(kvt)
  if rc.isOk:
    ok()
  elif api.level(kvt) != 0:
    err(rc.error.toError(base, info, TxPending))
  elif rc.error == TxPersistDelayed:
    # This is OK: Piggybacking on `Aristo` backend
    ok()
  else:
    err(rc.error.toError(base, info))

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc newKvtHandler*(
    base: KvtBaseRef;
    info: static[string];
      ): CoreDbRc[CoreDxKvtRef] =
    ok(base.cache)


proc destroy*(base: KvtBaseRef; eradicate: bool) =
  base.api.finish(base.kdb, eradicate)  # Close descriptor


func init*(T: type KvtBaseRef; db: CoreDbRef; kdb: KvtDbRef): T =
  result = T(
    parent: db,
    api:    KvtApiRef.init(),
    kdb:    kdb)

  # Preallocated shared descriptor
  let dsc = KvtCoreDxKvtRef(
    base: result,
    kvt:  kdb)
  dsc.methods = dsc.kvtMethods()
  result.cache = db.bless dsc

  when CoreDbEnableApiProfiling:
    let profApi = KvtApiProfRef.init(result.api, kdb.backend)
    result.api = profApi
    result.kdb.backend = profApi.be

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
