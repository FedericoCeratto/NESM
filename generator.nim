import macros
from typesinfo import isBasic, estimateBasicSize
from typesinfo import TypeChunk, Context
from tables import Table, contains, `[]`, `[]=`, initTable,
                   pairs
from strutils import `%`
from sequtils import mapIt, foldl, toSeq, filterIt
from streams import readData, writeData, readChar, write
from endians import swapEndian16, swapEndian32, swapEndian64

static:
  let STREAM_NAME* = !"thestream"

proc genCStringDeserialize(name: NimNode
                           ): NimNode {.compileTime.} =
  quote do:
    block:
      var str = "" & `STREAM_NAME`.readChar()
      var index = 0
      while str[index] != '\x00':
        str &= `STREAM_NAME`.readChar()
        index += 1
      `name` = str[0..<index]

proc genCStringSerialize(name: NimNode
                         ): NimNode {.compileTime.} =
  quote do:
    `STREAM_NAME`.writeData(`name`[0].unsafeAddr,
                            `name`.len)
    `STREAM_NAME`.write('\x00')

proc genDeserialize(name: NimNode,
                    size: NimNode): NimNode {.compileTime.} =
  quote do:
    assert(`size` ==
           `STREAM_NAME`.readData(`name`.unsafeAddr, `size`),
           "Stream was not provided enough data")

proc genSwapCall(size: int): NimNode {.compileTime.} =
  case size
  of 2: bindSym("swapEndian16")
  of 4: bindSym("swapEndian32")
  of 8: bindSym("swapEndian64")
  else:
    error("The endian cannot be swapped due to no " &
          "implementation of swap for size = " & $size)
    newEmptyNode()

proc genDeserializeSwap(name: NimNode,
                        size: int): NimNode {.compileTime.} =
  let isize = newIntLitNode(size)
  let swapcall = genSwapCall(size)
  quote do:
    var thedata = newString(`isize`)
    assert(`STREAM_NAME`.readData(thedata.addr, `isize`) ==
           `isize`,
           "Stream has not provided enough data")
    `swapcall`(`name`.unsafeAddr, thedata.addr)

proc genSerialize(name: NimNode,
                  size: NimNode): NimNode {.compileTime.} =
  quote do:
    `STREAM_NAME`.writeData(`name`.unsafeAddr, `size`)

proc genSerializeSwap(name: NimNode,
                      size: int): NimNode {.compileTime.} =
  let isize = newIntLitNode(size)
  let swapcall = genSwapCall(size)
  quote do:
    var thedata = newString(`isize`)
    `swapcall`(thedata.addr, `name`.unsafeAddr)
    `STREAM_NAME`.writeData(thedata.unsafeAddr, `isize`)

proc genPeriodic(context: Context, elem: NimNode,
                 length: proc(source: NimNode): NimNode,
                 ): TypeChunk {.compileTime.}

proc genCase(context: Context, decl: NimNode
             ): TypeChunk {.compileTime.}

proc caseWorkaround(tc: TypeChunk,
                    st: NimNode): TypeChunk {.compileTime.} =
  # st - type of field under case
  var t = tc
  let oldser = t.serialize
  let olddeser = t.deserialize
  let tmpvar = nskVar.genSym("tmp")
  t.serialize = proc(s:NimNode): NimNode =
    let os = oldser(tmpvar)
    quote do:
      var `tmpvar` = `s`
      `os`
  t.deserialize = proc(s:NimNode): NimNode =
    let ods = olddeser(tmpvar)
    quote do:
      var `tmpvar`: `st`
      `ods`
      `s` = `tmpvar`
  t

proc correct_sum(part_size: NimNode): NimNode =
  let result_node = newIdentNode("result")
  if part_size.kind in [nnkStmtList, nnkCaseStmt]:
    part_size
  else:
    result_node.infix("+=", part_size)

proc genTypeChunk*(context: Context, thetype: NimNode,
                   ): TypeChunk
                   {.compileTime.} =
  result.has_hidden = false
  case thetype.kind
  of nnkIdent:
    # It's a type, declared as identifier. Might be a basic
    # type or
    # some of previously declared type in serializable block
    let plaintype = $thetype
    if plaintype.isBasic():
      let size = estimateBasicSize(plaintype)
      result.size = proc (source: NimNode): NimNode =
        newIntLitNode(size)
      result.serialize = proc(source: NimNode): NimNode =
        if context.swapEndian and (size in [2, 4, 8]):
          genSerializeSwap(source, size)
        else:
          genSerialize(source, newIntLitNode(size))
      result.deserialize = proc(source: NimNode): NimNode =
        if context.swapEndian and (size in [2, 4, 8]):
          genDeserializeSwap(source, size)
        else:
          genDeserialize(source, newIntLitNode(size))
    elif plaintype in context.declared:
      let declared_type = context.declared[plaintype]
      if declared_type.dynamic and context.is_static:
        error("Only static objects can be nested into" &
              " static objects, but '" & plaintype &
              "' is not a static object!")
      if declared_type.has_hidden:
        warning("Seems like the " & plaintype &
          " (at " & thetype.lineinfo() & ")" &
          " have hidden fields inside. This may lead to" &
          " compile error if the " & plaintype & " was " &
          "imported from another module. Consider including" &
          " imported module or sharing " & plaintype & "'s" &
          " fields via '*' postfix")
      return context.declared[plaintype]
    elif thetype.repr == "string" and not context.is_static:
      let len_proc = proc (s: NimNode):NimNode =
        (quote do: len(`s`)).last
      result = context.genPeriodic(newEmptyNode(), len_proc)
    elif thetype.repr == "cstring" and not context.is_static:
      result.serialize = proc (s: NimNode): NimNode =
        genCStringSerialize(s)
      result.deserialize = proc (s: NimNode): NimNode =
        genCStringDeserialize(s)
      result.size = proc (s: NimNode): NimNode =
        (quote do: len(`s`) + 1).last
    elif plaintype in ["float", "int", "uint"]:
      error((("The type $1 is not allowed due to ambiguity" &
              ". Consider using $1") % plaintype) & "32.")
    else:
      error(("Type $1 is not a basic " % plaintype) &
            "type nor a complex type under 'serializable'" &
            " block!")
  of nnkBracketExpr:
    # The template type. typename[someargs].
    expectMinLen(thetype, 2)
    let name = $thetype[0]
    case name
    of "array":
      expectMinLen(thetype, 3)
      let elemType = thetype[2]
      let sizeDecl = thetype[1]
      let arrayLen =
        if sizeDecl.kind == nnkInfix and
           sizeDecl[0].repr == "..":
          newTree(nnkPar,
                  sizeDecl[2].infix("+", newIntLitNode(1)))
        else:
          sizeDecl
      let sizeproc = proc (source: NimNode): NimNode =
        arrayLen
      result = context.genPeriodic(elemType, sizeproc)
    of "seq":
      if context.is_static:
        error("Dynamic types not supported in static" &
              " structures")
      let elem = thetype[1]
      let seqLen = proc (source: NimNode): NimNode =
        (quote do: len(`source`)).last
      result = context.genPeriodic(elem, seqLen)
    else:
      error("Type $1 is not supported!" % name)
  of nnkTupleTy, nnkRecList:
    var elems =
      newSeq[tuple[key:string, val:TypeChunk]](thetype.len())
    var index = 0
    var newContext = context
    let settingsKeyword = newIdentNode("set").postfix("!")
    for declaration in thetype.children():
      let decl =
        case declaration.kind
        of nnkRecCase:
          expectMinLen(declaration, 2)
          declaration[0]
        else:
          declaration
      if decl.kind == nnkNilLit:
        elems.del(index)
        continue
      elif decl[0] == settingsKeyword:
        let command = decl[1]
        case command.kind
        of nnkIdent:
          let strcommand = $command
          if strcommand in ["bigEndian", "littleEndian"]:
            newContext.swapEndian = strcommand != $cpuEndian
          else:
            error("Unknown setting: " & strcommand)
        else:
          error("Unknown setting: " & $command.repr)
        elems.del(index)
        continue
      decl.expectMinLen(2)
      if decl[0].kind != nnkPostfix and
         thetype.kind == nnkRecList:
        result.has_hidden = true
      let name = $decl[0].basename
      let subtype = decl[1]
      let tc = newContext.genTypeChunk(subtype)
      let elem =
        case declaration.kind
        of nnkRecCase:
          # A bad hackery to avoid expression without address
          # problem when accessing to field under case.
          tc.caseWorkaround(subtype)
        else:
          tc
      elems[index] = (name, elem)
      index += 1
      if declaration.kind == nnkRecCase:
        let casechunk = newContext.genCase(declaration)
        elems.add(("", TypeChunk()))
        elems[index] = ("", casechunk)
        index += 1
    result.size = proc (source: NimNode): NimNode =
      result = newIntLitNode(0)
      var result_list = newSeq[NimNode]()
      for i in elems.items():
        let n = !i.key
        let newsource =
          if ($n).len > 0: (quote do: `source`.`n`).last
          else: source
        let e = i.val
        let part_size = e.size(newsource)
        if context.is_static and not
          (part_size.kind in [nnkStmtList, nnkCaseStmt]):
          result = result.infix("+", part_size)
        else:
          result_list.add(correct_sum(part_size))
      if not context.is_static:
        result_list.add(correct_sum(result))
        result = newStmtList(result_list)
      else:
        result = newTree(nnkPar, result)
    result.serialize = proc(source: NimNode): NimNode =
      result = newStmtList(parseExpr("discard"))
      for i in elems.items():
        let n = !i.key
        let newsource =
          if ($n).len > 0: (quote do: `source`.`n`).last
          else: source
        let e = i.val
        result.add(e.serialize(newsource))
    result.deserialize = proc(source: NimNode): NimNode =
      result = newStmtList(parseExpr("discard"))
      for i in elems.items():
        let n = !i.key
        let newsource =
          if ($n).len > 0: (quote do: `source`.`n`).last
          else: source
        let e = i.val
        result &= e.deserialize(newsource)
  of nnkObjectTy:
    expectMinLen(thetype, 3)
    assert(thetype[1].kind == nnkEmpty,
           "Inheritence not supported in serializable")
    return context.genTypeChunk(thetype[2])
  of nnkRefTy:
    expectMinLen(thetype, 1)
    let objectchunk = context.genTypeChunk(thetype[0])
    result.has_hidden = objectchunk.has_hidden
    result.size = objectchunk.size
    result.serialize = objectchunk.serialize
    result.deserialize = proc(source: NimNode): NimNode =
      result = newStmtList(parseExpr("new(result)"))
      result.add(objectchunk.deserialize(source))
  of nnkDistinctTy:
    expectMinLen(thetype, 1)
    let basetype = thetype[0]
    let distincted = context.genTypeChunk(basetype)
    let tmp = nskVar.genSym("tmp")
    result.has_hidden = true
    result.size = distincted.size
    result.serialize = proc(source: NimNode): NimNode =
      let serialization = distincted.serialize(tmp)
      quote do:
        var `tmp` = cast[`basetype`](`source`)
        `serialization`
    result.deserialize = proc(source: NimNode): NimNode =
      let deserialization = distincted.deserialize(tmp)
      let r = !"result"
      quote do:
        var `tmp` = cast[`basetype`](`source`)
        `deserialization`
        cast[type(`r`)](`tmp`)
  else:
    discard
    error("Unexpected AST")
  result.dynamic = not context.is_static

proc genPeriodic(context: Context, elem: NimNode,
                 length: proc (s:NimNode): NimNode,
                 ): TypeChunk =
  let elemString = elem.repr
  let lencheck = length(newEmptyNode())
  let is_array = lencheck.kind != nnkCall
  let lenvarname =
    if is_array: lencheck
    else: nskVar.genSym("length")
  if (elemString.isBasic() or elem.kind == nnkEmpty) and
     not context.swapEndian:
    # For seqs or arrays of trivial objects
    let element =
      if elem.kind == nnkEmpty: "char"
      else: elemString
    let elemSize = estimateBasicSize(element)
    let eSize = newIntLitNode(elemSize)
    result.size = proc (s: NimNode): NimNode =
      let arraylen = length(s)
      arraylen.infix("*", newIntLitNode(elemSize))
    result.serialize = proc (s: NimNode): NimNode =
      let lens = length(s)
      let size = (quote do: `lens` * `eSize`).last
      let newsource = (quote do: `s`[0]).last
      let serialization = genSerialize(newsource, size)
      quote do:
        if `lens` > 0: `serialization`
    result.deserialize = proc (s: NimNode): NimNode =
      let size = (quote do: `lenvarname` * `eSize`).last
      let newsource = (quote do: `s`[0]).last
      let deserialization = genDeserialize(newsource, size)
      quote do:
        if `lenvarname` > 0: `deserialization`
    result.dynamic = not context.is_static
    result.has_hidden = false
  else:
    # Complex subtypes
    let onechunk = context.genTypeChunk(elem)
    let index_letter = nskForVar.genSym("index")
    result.size = proc (s: NimNode): NimNode =
      let periodic_len = length(s)
      let newsource = (quote do: `s`[`index_letter`]).last
      let chunk_size = one_chunk.size(newsource)
      if is_array and chunk_size.kind != nnkStmtList:
        periodic_len.infix("*", chunk_size)
      else:
        let chunk_expr = correct_sum(chunk_size)
        quote do:
          for `index_letter` in 0..<(`periodic_len`):
            `chunk_expr`
    result.serialize = proc(s: NimNode): NimNode =
      let periodic_len = length(s)
      let newsource = (quote do: `s`[`index_letter`]).last
      let chunk_expr = onechunk.serialize(newsource)
      quote do:
        for `index_letter` in 0..<(`periodic_len`):
          `chunk_expr`
    result.deserialize = proc(s: NimNode): NimNode =
      let newsource = (quote do: `s`[`index_letter`]).last
      let chunk_expr = onechunk.deserialize(newsource)
      quote do:
        for `index_letter` in 0..<(`lenvarname`):
          `chunk_expr`
  if not is_array:
    let size_header_chunk = context.genTypeChunk(
      newIdentNode("int32"))
    let preresult = result
    result.size = proc(s:NimNode):NimNode =
      let presize = preresult.size(s)
      let headersize = size_header_chunk.size(s)
      let r = !"result"
      if presize.kind notin [nnkInfix, nnkIntLit, nnkCall]:
        quote do:
          `presize`
          `r` += `headersize`
      else:
        headersize.infix("+", presize)
    result.serialize = proc(s:NimNode): NimNode =
      let lens = length(s)
      let shc_ser = size_header_chunk.serialize(lenvarname)
      let pr_ser = preresult.serialize(s)
      quote do:
        var `lenvarname` = `lens`
        `shc_ser`
        `pr_ser`
    result.deserialize = proc(s:NimNode): NimNode =
      let init_template =
        if elem.kind == nnkEmpty: (quote do: newString).last
        else: (quote do: newSeq[`elem`]).last
      let sd = size_header_chunk.deserialize(lenvarname)
      let deserialization = preresult.deserialize(s)
      quote do:
        var `lenvarname`: int32
        `sd`
        `s` = `init_template`(`lenvarname`)
        `deserialization`

proc genCase(context: Context, decl: NimNode): TypeChunk =
  let checkable = decl[0][0].basename
  let eachbranch = proc(b: NimNode): auto =
    let conditions = toSeq(b.children)
      .filterIt(it.kind != nnkRecList)
    let branch = context.genTypeChunk(b.last)
    let size = proc(source: NimNode):NimNode =
      let casebody = branch.size(source)
      newTree(b.kind, conditions & @[casebody])
    let serialize = proc(source: NimNode): NimNode =
      let casebody = newStmtList(branch.serialize(source))
      newTree(b.kind, conditions & @[casebody])
    let deserialize = proc(source: NimNode): NimNode =
      let casebody = newStmtList(branch.deserialize(source))
      newTree(b.kind, conditions & @[casebody])
    (size, serialize, deserialize)
  let branches = toSeq(decl.children())
    .filterIt(it.kind in [nnkElse, nnkOfBranch])
    .mapIt(eachbranch(it))
  let sizes = branches.mapIt(it[0])
  let serializes = branches.mapIt(it[1])
  let deserializes = branches.mapIt(it[2])
  result.dynamic = true
  let condition = proc (source: NimNode): NimNode =
    (quote do: `source`.`checkable`).last
  result.size = proc(source: NimNode):NimNode =
    let sizenodes:seq[NimNode] = sizes.mapIt(it(source))
    newTree(nnkCaseStmt, condition(source) & sizenodes)
  result.serialize = proc(source: NimNode): NimNode =
    let sernodes:seq[NimNode] = serializes.mapIt(it(source))
    newTree(nnkCaseStmt, condition(source) & sernodes)
  result.deserialize = proc(source: NimNode): NimNode =
    let desernodes:seq[NimNode] =
      deserializes.mapIt(it(source))
    newTree(nnkCaseStmt, condition(source) & desernodes)
