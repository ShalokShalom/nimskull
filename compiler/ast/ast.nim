#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## abstract syntax tree + symbol table

import
  compiler/ast/[
    lineinfos, # Positional information
    idents,    # Ast identifiers
    ast_types, # Main ast type definitions
    ast_idgen, # Per module Id generation
    ast_query, # querying/reading the ast
  ],
  compiler/front/[
    options
  ],
  compiler/utils/[
    ropes,
    int128 # Values for integer nodes
  ],
  std/[
    strutils,
    tables # For symbol table mapping
  ]

export ast_types, ast_idgen, ast_query, int128

var ggDebug* {.deprecated.}: bool ## convenience switch for trying out things

when defined(useNodeIds):
  const nodeIdToDebug* = -1 # 2322968

proc addAllowNil*(father, son: Indexable) {.inline.} =
  father.sons.add(son)

var gNodeId: int
template setNodeId() =
  inc gNodeId
  result.id = gNodeId
  when defined(useNodeIds):
    if result.id == nodeIdToDebug:
      echo "KIND ", result.kind
      writeStackTrace()

func newNodeI*(kind: TNodeKind, info: TLineInfo): PNode =
  ## new node with line info, no type, and no children
  result = PNode(kind: kind, info: info, reportId: emptyReportId)
  {.cast(noSideEffect).}:
    setNodeId()
  when false:
    # this would add overhead, so we skip it; it results in a small amount of leaked entries
    # for old PNode that gets re-allocated at the same address as a PNode that
    # has `nfHasComment` set (and an entry in that table). Only `nfHasComment`
    # should be used to test whether a PNode has a comment; gconfig.comments
    # can contain extra entries for deleted PNode's with comments.
    gconfig.comments.del(result.id)

proc newNode*(kind: TNodeKind): PNode =
  ## new node with unknown line info, no type, and no children
  result = newNodeI(kind, unknownLineInfo)

proc newNodeI*(kind: TNodeKind, info: TLineInfo, children: int): PNode =
  ## new node with line info, no type, and children
  result = newNodeI(kind, info)
  if children > 0:
    newSeq(result.sons, children)

proc newNodeIT*(kind: TNodeKind, info: TLineInfo, typ: PType): PNode =
  ## new node with line info, type, and no children
  result = newNodeI(kind, info)
  result.typ = typ

proc newNodeIT*(kind: TNodeKind, info: TLineInfo, typ: PType, children: int): PNode =
  ## new node with line info, type, and children
  result = newNodeIT(kind, info, typ)
  if children > 0:
    newSeq(result.sons, children)

proc newTree*(kind: TNodeKind; children: varargs[PNode]): PNode =
  result = newNode(kind)
  if children.len > 0:
    result.info = children[0].info
  result.sons = @children

proc newTreeI*(kind: TNodeKind; info: TLineInfo; children: varargs[PNode]): PNode =
  result = newNodeI(kind, info)
  result.sons = @children

proc newTreeIT*(kind: TNodeKind; info: TLineInfo; typ: PType; children: varargs[PNode]): PNode =
  result = newNodeIT(kind, info, typ)
  result.sons = @children

when false:
  import tables, strutils
  var x: CountTable[string]

  addQuitProc proc () {.noconv.} =
    for k, v in pairs(x):
      echo k
      echo v

proc newSym*(symKind: TSymKind, name: PIdent, id: ItemId, owner: PSym,
             info: TLineInfo, typ: PType; options: TOptions = {}): PSym =
  # generates a symbol and initializes the hash field too
  result = PSym(name: name, kind: symKind, flags: {}, info: info, itemId: id,
                typ: typ, options: options, owner: owner, offset: defaultOffset)
  when false:
    if id.module == 48 and id.item == 39:
      writeStackTrace()
      echo "kind ", symKind, " ", name.s
      if owner != nil: echo owner.name.s

proc newSym*(symKind: TSymKind, name: PIdent, id: ItemId, owner: PSym,
             info: TLineInfo; options: TOptions = {}): PSym {.inline.} =
  # generates a symbol and initializes the hash field too
  result = newSym(symKind, name, id, owner, info, typ = nil, options)

proc linkTo*(t: PType, s: PSym): PType {.discardable.} =
  t.sym = s
  s.typ = t
  result = t

proc linkTo*(s: PSym, t: PType): PSym {.discardable.} =
  t.sym = s
  s.typ = t
  result = s

proc appendToModule*(m: PSym, n: PNode) =
  ## The compiler will use this internally to add nodes that will be
  ## appended to the module after the sem pass
  if m.ast == nil:
    m.ast = newNode(nkStmtList)
    m.ast.sons = @[n]
  else:
    assert m.ast.kind == nkStmtList
    m.ast.sons.add(n)

const                         # for all kind of hash tables:
  GrowthFactor* = 2           # must be power of 2, > 0
  StartSize* = 8              # must be power of 2, > 0

proc copyStrTable*(dest: var TStrTable, src: TStrTable) =
  dest.counter = src.counter
  setLen(dest.data, src.data.len)
  for i in 0..high(src.data): dest.data[i] = src.data[i]

proc copyIdTable*(dest: var TIdTable, src: TIdTable) =
  dest.counter = src.counter
  newSeq(dest.data, src.data.len)
  for i in 0..high(src.data): dest.data[i] = src.data[i]

proc copyObjectSet*(dest: var TObjectSet, src: TObjectSet) =
  dest.counter = src.counter
  setLen(dest.data, src.data.len)
  for i in 0..high(src.data): dest.data[i] = src.data[i]

proc discardSons*(father: PNode) =
  father.sons = @[]

proc withInfo*(n: PNode, info: TLineInfo): PNode =
  ## set the line information (`info`) on the node `n`
  n.info = info
  return n

proc newIdentNode*(ident: PIdent, info: TLineInfo): PNode =
  result = newNode(nkIdent)
  result.ident = ident
  result.info = info

proc newSymNode2*(sym: PSym): PNode =
  ## creates a new `nkSym` node, unless sym.kind is an skError where an nkError
  ## is extracted from the sym and returned instead.
  # TODO replace newSymNode with this
  if sym.isError:
    result = sym.ast
  else:
    result = newNode(nkSym)
    result.sym = sym
    result.typ = sym.typ
    result.info = sym.info

proc newSymNode2*(sym: PSym, info: TLineInfo): PNode =
  ## creates a new `nkSym` node, unless sym.kind is an skError where an nkError
  ## is extracted from the sym and returned instead. In either case sets the
  ## node info to the one provided
  
  # TODO replace newSymNode with this
  if sym.isError:
    result = sym.ast
    result.info = info
  else:
    result = newNode(nkSym)
    result.sym = sym
    result.typ = sym.typ
    result.info = info

proc newSymNodeIT*(sym: PSym, info: TLineInfo, typ: PType): PNode =
  ## create a new sym node with the supplied `info` and `typ`
  result = newNodeIT(nkSym, info, typ)
  result.sym = sym

proc newSymNode*(sym: PSym, info: TLineInfo): PNode {.inline.} =
  ## create a new sym node from `sym` with its type and supplied `info`
  result = newSymNodeIT(sym, info, sym.typ)

proc newSymNode*(sym: PSym): PNode {.inline.} =
  ## create a new sym node from `sym` with its info and type
  result = newSymNode(sym, sym.info)

proc newIntNode*(kind: TNodeKind, intVal: BiggestInt): PNode =
  result = newNode(kind)
  result.intVal = intVal

proc newIntNode*(kind: TNodeKind, intVal: Int128): PNode =
  result = newNode(kind)
  result.intVal = castToInt64(intVal)

proc newIntTypeNode*(intVal: BiggestInt, typ: PType): PNode =
  let kind = skipTypes(typ, abstractVarRange).kind
  case kind
  of tyInt:     result = newNode(nkIntLit)
  of tyInt8:    result = newNode(nkInt8Lit)
  of tyInt16:   result = newNode(nkInt16Lit)
  of tyInt32:   result = newNode(nkInt32Lit)
  of tyInt64:   result = newNode(nkInt64Lit)
  of tyChar:    result = newNode(nkCharLit)
  of tyUInt:    result = newNode(nkUIntLit)
  of tyUInt8:   result = newNode(nkUInt8Lit)
  of tyUInt16:  result = newNode(nkUInt16Lit)
  of tyUInt32:  result = newNode(nkUInt32Lit)
  of tyUInt64:  result = newNode(nkUInt64Lit)
  of tyBool, tyEnum:
    # XXX: does this really need to be the kind nkIntLit?
    result = newNode(nkIntLit)
  of tyStatic: # that's a pre-existing bug, will fix in another PR
    result = newNode(nkIntLit)
  else: doAssert false, $kind
  result.intVal = intVal
  result.typ = typ

proc newIntTypeNode*(intVal: Int128, typ: PType): PNode =
  # XXX: introduce range check
  newIntTypeNode(castToInt64(intVal), typ)

proc newFloatNode*(kind: TNodeKind, floatVal: BiggestFloat): PNode =
  result = newNode(kind)
  result.floatVal = floatVal

proc newStrNode*(kind: TNodeKind, strVal: string): PNode =
  result = newNode(kind)
  result.strVal = strVal

proc newStrNode*(strVal: string; info: TLineInfo): PNode =
  result = newNodeI(nkStrLit, info)
  result.strVal = strVal

proc newProcNode*(kind: TNodeKind, info: TLineInfo, body: PNode,
                 params,
                 name, pattern, genericParams,
                 pragmas, exceptions: PNode): PNode =
  result = newNodeI(kind, info)
  result.sons = @[name, pattern, genericParams, params,
                  pragmas, exceptions, body]

proc newTypeError*(prev: PType,
                   id: ItemId, 
                   owner: PSym = if prev.isNil: nil else: prev.owner,
                   err: PNode): PType =
  ## create a new error type, with an optional `prev`ious type (can be nil) and
  ## `err`or node for the error msg
  result = PType(kind: tyError, owner: owner, size: defaultSize,
                 align: defaultAlignment, itemId: id,
                 lockLevel: UnspecifiedLockLevel, uniqueId: id, n: err)
  result.typeInst = prev

proc newType*(kind: TTypeKind, id: ItemId; owner: PSym): PType =
  result = PType(kind: kind, owner: owner, size: defaultSize,
                 align: defaultAlignment, itemId: id,
                 lockLevel: UnspecifiedLockLevel,
                 uniqueId: id)
  when false:
    if result.itemId.module == 55 and result.itemId.item == 2:
      echo "KNID ", kind
      writeStackTrace()


proc mergeLoc(a: var TLoc, b: TLoc) =
  if a.k == low(typeof(a.k)): a.k = b.k
  if a.storage == low(typeof(a.storage)): a.storage = b.storage
  a.flags.incl b.flags
  if a.lode == nil: a.lode = b.lode
  if a.r == nil: a.r = b.r

proc newSons*(father: Indexable, length: int) =
  setLen(father.sons, length)

proc assignType*(dest, src: PType) =
  dest.kind = src.kind
  dest.flags = src.flags
  dest.callConv = src.callConv
  dest.n = src.n
  dest.size = src.size
  dest.align = src.align
  dest.lockLevel = src.lockLevel
  # this fixes 'type TLock = TSysLock':
  if src.sym != nil:
    if dest.sym != nil:
      dest.sym.flags.incl src.sym.flags-{sfExported}
      if dest.sym.annex == nil: dest.sym.annex = src.sym.annex
      mergeLoc(dest.sym.loc, src.sym.loc)
    else:
      dest.sym = src.sym
  newSons(dest, src.len)
  for i in 0..<src.len: dest[i] = src[i]

proc copyType*(t: PType, id: ItemId, owner: PSym): PType =
  result = newType(t.kind, id, owner)
  assignType(result, t)
  result.sym = t.sym          # backend-info should not be copied

proc exactReplica*(t: PType): PType =
  result = copyType(t, t.itemId, t.owner)

proc copySym*(s: PSym; id: ItemId): PSym =
  result = newSym(s.kind, s.name, id, s.owner, s.info, s.options)
  #result.ast = nil            # BUGFIX; was: s.ast which made problems
  result.typ = s.typ
  result.flags = s.flags
  result.magic = s.magic
  result.options = s.options
  result.position = s.position
  result.loc = s.loc
  result.annex = s.annex      # BUGFIX
  result.constraint = s.constraint
  if result.kind in {skVar, skLet, skField}:
    result.guard = s.guard
    result.bitsize = s.bitsize
    result.alignment = s.alignment

proc createModuleAlias*(s: PSym, id: ItemId, newIdent: PIdent, info: TLineInfo;
                        options: TOptions): PSym =
  result = newSym(s.kind, newIdent, id, s.owner, info, options)
  # keep ID!
  result.ast = s.ast
  #result.id = s.id # XXX figure out what to do with the ID.
  result.flags = s.flags
  result.options = s.options
  result.position = s.position
  result.loc = s.loc
  result.annex = s.annex

proc initStrTable*(x: var TStrTable) =
  x.counter = 0
  newSeq(x.data, StartSize)

proc newStrTable*: TStrTable =
  initStrTable(result)

proc initIdTable*(x: var TIdTable) =
  x.counter = 0
  newSeq(x.data, StartSize)

proc newIdTable*: TIdTable =
  initIdTable(result)

proc resetIdTable*(x: var TIdTable) =
  x.counter = 0
  # clear and set to old initial size:
  setLen(x.data, 0)
  setLen(x.data, StartSize)

proc initObjectSet*(x: var TObjectSet) =
  x.counter = 0
  newSeq(x.data, StartSize)

proc initIdNodeTable*(x: var TIdNodeTable) =
  x.counter = 0
  newSeq(x.data, StartSize)

proc newIdNodeTable*: TIdNodeTable =
  initIdNodeTable(result)

proc initNodeTable*(x: var TNodeTable) =
  x.counter = 0
  newSeq(x.data, StartSize)

proc isGCedMem*(t: PType): bool {.inline.} =
  result = t.kind in {tyString, tyRef, tySequence} or
           t.kind == tyProc and t.callConv == ccClosure

proc propagateToOwner*(owner, elem: PType; propagateHasAsgn = true) =
  owner.flags.incl elem.flags * {tfHasMeta, tfTriggersCompileTime}
  if tfNotNil in elem.flags:
    if owner.kind in {tyGenericInst, tyGenericBody, tyGenericInvocation}:
      owner.flags.incl tfNotNil

  if elem.isMetaType:
    owner.flags.incl tfHasMeta

  let mask = elem.flags * {tfHasAsgn, tfHasOwned}
  if mask != {} and propagateHasAsgn:
    let o2 = owner.skipTypes({tyGenericInst, tyAlias, tySink})
    if o2.kind in {tyTuple, tyObject, tyArray,
                   tySequence, tySet, tyDistinct}:
      o2.flags.incl mask
      owner.flags.incl mask

  if owner.kind notin {tyProc, tyGenericInst, tyGenericBody,
                       tyGenericInvocation, tyPtr}:
    let elemB = elem.skipTypes({tyGenericInst, tyAlias, tySink})
    if elemB.isGCedMem or tfHasGCedMem in elemB.flags:
      # for simplicity, we propagate this flag even to generics. We then
      # ensure this doesn't bite us in sempass2.
      owner.flags.incl tfHasGCedMem

proc rawAddSon*(father, son: PType; propagateHasAsgn = true) =
  father.sons.add(son)
  if not son.isNil: propagateToOwner(father, son, propagateHasAsgn)

proc rawAddSonNoPropagationOfTypeFlags*(father, son: PType) =
  father.sons.add(son)

proc addSonNilAllowed*(father, son: PNode) =
  father.sons.add(son)

proc delSon*(father: PNode, idx: int) =
  if father.len == 0: return
  for i in idx..<father.len - 1: father[i] = father[i + 1]
  father.sons.setLen(father.len - 1)

template copyNodeImpl(dst, src, processSonsStmt) =
  if src == nil: return
  dst = newNode(src.kind)
  dst.info = src.info
  dst.typ = src.typ
  dst.flags = src.flags * PersistentNodeFlags
  dst.comment = src.comment
  dst.reportId = src.reportId
  when defined(useNodeIds):
    if dst.id == nodeIdToDebug:
      echo "COMES FROM ", src.id
  case src.kind
  of nkCharLit..nkUInt64Lit: dst.intVal = src.intVal
  of nkFloatLiterals: dst.floatVal = src.floatVal
  of nkSym: dst.sym = src.sym
  of nkIdent: dst.ident = src.ident
  of nkStrLit..nkTripleStrLit: dst.strVal = src.strVal
  else: processSonsStmt

proc copyNode*(src: PNode): PNode =
  # does not copy its sons!
  copyNodeImpl(result, src):
    discard

template transitionNodeKindCommon(k: TNodeKind) =
  let obj {.inject.} = n[]
  n[] = TNode(id: obj.id, kind: k, typ: obj.typ, info: obj.info,
              flags: obj.flags)
  # n.comment = obj.comment # shouldn't be needed, the address doesnt' change

proc transitionSonsKind*(n: PNode, kind: range[nkDotCall..nkTupleConstr]) =
  transitionNodeKindCommon(kind)
  n.sons = obj.sons

proc transitionIntKind*(n: PNode, kind: range[nkCharLit..nkUInt64Lit]) =
  transitionNodeKindCommon(kind)
  n.intVal = obj.intVal

proc transitionNoneToSym*(n: PNode) =
  transitionNodeKindCommon(nkSym)

template transitionSymKindCommon*(k: TSymKind) =
  let obj {.inject.} = s[]
  s[] = TSym(kind: k, itemId: obj.itemId, magic: obj.magic, typ: obj.typ, name: obj.name,
             info: obj.info, owner: obj.owner, flags: obj.flags, ast: obj.ast,
             options: obj.options, position: obj.position, offset: obj.offset,
             loc: obj.loc, annex: obj.annex, constraint: obj.constraint)
  when defined(nimsuggest):
    s.allUsages = obj.allUsages

proc transitionGenericParamToType*(s: PSym) =
  transitionSymKindCommon(skType)

proc transitionRoutineSymKind*(s: PSym, kind: range[skProc..skTemplate]) =
  transitionSymKindCommon(kind)
  s.gcUnsafetyReason = obj.gcUnsafetyReason
  s.transformedBody = obj.transformedBody

proc transitionToLet*(s: PSym) =
  transitionSymKindCommon(skLet)
  s.guard = obj.guard
  s.bitsize = obj.bitsize
  s.alignment = obj.alignment

proc shallowCopy*(src: PNode): PNode =
  # does not copy its sons, but provides space for them:
  copyNodeImpl(result, src):
    newSeq(result.sons, src.len)

proc copyTree*(src: PNode): PNode =
  # copy a whole syntax tree; performs deep copying
  copyNodeImpl(result, src):
    newSeq(result.sons, src.len)
    for i in 0..<src.len:
      result[i] = copyTree(src[i])

proc copyTreeWithoutNode*(src, skippedNode: PNode): PNode =
  copyNodeImpl(result, src):
    result.sons = newSeqOfCap[PNode](src.len)
    for n in src.sons:
      if n != skippedNode:
        result.sons.add copyTreeWithoutNode(n, skippedNode)

proc copyTreeWithoutNodes*(src: PNode; skippedNodes: varargs[PNode]): PNode =
  copyNodeImpl(result, src):
    result.sons = newSeqOfCap[PNode](src.len)
    for n in src.sons:
      if n notin skippedNodes:
        result.sons.add copyTreeWithoutNodes(n, skippedNodes)

proc makeStmtList*(n: PNode): PNode =
  if n.kind == nkStmtList:
    result = n
  else:
    result = newNodeI(nkStmtList, n.info)
    result.add n

proc toVar*(typ: PType; kind: TTypeKind; idgen: IdGenerator): PType =
  ## If ``typ`` is not a tyVar then it is converted into a `var <typ>` and
  ## returned. Otherwise ``typ`` is simply returned as-is.
  result = typ
  if typ.kind != kind:
    result = newType(kind, nextTypeId(idgen), typ.owner)
    rawAddSon(result, typ)

proc toRef*(typ: PType; idgen: IdGenerator): PType =
  ## If ``typ`` is a tyObject then it is converted into a `ref <typ>` and
  ## returned. Otherwise ``typ`` is simply returned as-is.
  result = typ
  if typ.skipTypes({tyAlias, tyGenericInst}).kind == tyObject:
    result = newType(tyRef, nextTypeId(idgen), typ.owner)
    rawAddSon(result, typ)

proc toObject*(typ: PType): PType =
  ## If ``typ`` is a tyRef then its immediate son is returned (which in many
  ## cases should be a ``tyObject``).
  ## Otherwise ``typ`` is simply returned as-is.
  let t = typ.skipTypes({tyAlias, tyGenericInst})
  if t.kind == tyRef: t.lastSon
  else: typ

proc toObjectFromRefPtrGeneric*(typ: PType): PType =
  #[
  See also `toObject`.
  Finds the underlying `object`, even in cases like these:
  type
    B[T] = object f0: int
    A1[T] = ref B[T]
    A2[T] = ref object f1: int
    A3 = ref object f2: int
    A4 = object f3: int
  ]#
  result = typ
  while true:
    case result.kind
    of tyGenericBody: result = result.lastSon
    of tyRef, tyPtr, tyGenericInst, tyGenericInvocation, tyAlias: result = result[0]
      # automatic dereferencing is deep, refs #18298.
    else: break
  assert result.sym != nil

proc newProcType*(info: TLineInfo; id: ItemId; owner: PSym): PType =
  result = newType(tyProc, id, owner)
  result.n = newNodeI(nkFormalParams, info)
  rawAddSon(result, nil) # return type
  # result.n[0] used to be `nkType`, but now it's `nkEffectList` because
  # the effects are now stored in there too ... this is a bit hacky, but as
  # usual we desperately try to save memory:
  result.n.add newNodeI(nkEffectList, info)

proc addParam*(procType: PType; param: PSym) =
  param.position = procType.len-1
  procType.n.add newSymNode(param)
  rawAddSon(procType, param.typ)

proc toHumanStrImpl[T](kind: T, num: static int): string =
  result = $kind
  result = result[num..^1]
  result[0] = result[0].toLowerAscii

proc toHumanStr*(kind: TSymKind): string =
  ## strips leading `sk`
  result = toHumanStrImpl(kind, 2)

proc toHumanStr*(kind: TTypeKind): string =
  ## strips leading `tk`
  result = toHumanStrImpl(kind, 2)
