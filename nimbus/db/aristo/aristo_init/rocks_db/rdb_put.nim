# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB store data record
## ==========================

{.push raises: [].}

import
  eth/common,
  rocksdb,
  results,
  stew/keyed_queue,
  ../../[aristo_blobify, aristo_desc],
  ../init_common,
  ./rdb_desc

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "aristo-rocksdb"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc disposeSession(rdb: var RdbInst) =
  rdb.session.close()
  rdb.session = WriteBatchRef(nil)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc begin*(rdb: var RdbInst) =
  if rdb.session.isNil:
    rdb.session = rdb.baseDb.openWriteBatch()

proc rollback*(rdb: var RdbInst) =
  if not rdb.session.isClosed():
    rdb.rdKeyLru.clear() # Flush caches
    rdb.rdVtxLru.clear() # Flush caches
    rdb.disposeSession()

proc commit*(rdb: var RdbInst): Result[void,(AristoError,string)] =
  if not rdb.session.isClosed():
    defer: rdb.disposeSession()
    rdb.baseDb.write(rdb.session).isOkOr:
      const errSym = RdbBeDriverWriteError
      when extraTraceMessages:
        trace logTxt "commit", error=errSym, info=error
      return err((errSym,error))
  ok()


proc putAdm*(
    rdb: var RdbInst;
    xid: AdminTabID;
    data: Blob;
      ): Result[void,(AdminTabID,AristoError,string)] =
  let dsc = rdb.session
  if data.len == 0:
    dsc.delete(xid.toOpenArray, $AdmCF).isOkOr:
      const errSym = RdbBeDriverDelAdmError
      when extraTraceMessages:
        trace logTxt "putAdm()", xid, error=errSym, info=error
      return err((xid,errSym,error))
  else:
    dsc.put(xid.toOpenArray, data, $AdmCF).isOkOr:
      const errSym = RdbBeDriverPutAdmError
      when extraTraceMessages:
        trace logTxt "putAdm()", xid, error=errSym, info=error
      return err((xid,errSym,error))
  ok()


proc putKey*(
    rdb: var RdbInst;
    data: openArray[(VertexID,HashKey)];
      ): Result[void,(VertexID,AristoError,string)] =
  let dsc = rdb.session
  for (vid,key) in data:

    if key.isValid:
      dsc.put(vid.toOpenArray, key.data, $KeyCF).isOkOr:
        # Caller must `rollback()` which will flush the `rdKeyLru` cache
        const errSym = RdbBeDriverPutKeyError
        when extraTraceMessages:
          trace logTxt "putKey()", vid, error=errSym, info=error
        return err((vid,errSym,error))
    
      # Update cache
      if not rdb.rdKeyLru.lruUpdate(vid, key):
        discard rdb.rdKeyLru.lruAppend(vid, key, RdKeyLruMaxSize)

    else:
      dsc.delete(vid.toOpenArray, $KeyCF).isOkOr:
        # Caller must `rollback()` which will flush the `rdKeyLru` cache
        const errSym = RdbBeDriverDelKeyError
        when extraTraceMessages:
          trace logTxt "putKey()", vid, error=errSym, info=error
        return err((vid,errSym,error))

      # Update cache, vertex will most probably never be visited anymore
      rdb.rdKeyLru.del vid

  ok()


proc putVtx*(
    rdb: var RdbInst;
    data: openArray[(VertexID,VertexRef)];
      ): Result[void,(VertexID,AristoError,string)] =
  let dsc = rdb.session
  for (vid,vtx) in data:

    if vtx.isValid:
      let rc = vtx.blobify()
      if rc.isErr:
        # Caller must `rollback()` which will flush the `rdVtxLru` cache
        return err((vid,rc.error,""))

      dsc.put(vid.toOpenArray, rc.value, $VtxCF).isOkOr:
        # Caller must `rollback()` which will flush the `rdVtxLru` cache
        const errSym = RdbBeDriverPutVtxError
        when extraTraceMessages:
          trace logTxt "putVtx()", vid, error=errSym, info=error
        return err((vid,errSym,error))

      # Update cache
      if not rdb.rdVtxLru.lruUpdate(vid, vtx):
        discard rdb.rdVtxLru.lruAppend(vid, vtx, RdVtxLruMaxSize)

    else:
      dsc.delete(vid.toOpenArray, $VtxCF).isOkOr:
        # Caller must `rollback()` which will flush the `rdVtxLru` cache
        const errSym = RdbBeDriverDelVtxError
        when extraTraceMessages:
          trace logTxt "putVtx()", vid, error=errSym, info=error
        return err((vid,errSym,error))

      # Update cache, vertex will most probably never be visited anymore
      rdb.rdVtxLru.del vid

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
