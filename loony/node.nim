import std/atomics

import loony/spec
import loony/memalloc
import loony/arc

type
  Node* = object
    slots* : array[0..N, Atomic[uint]]  # Pointers to object
    next*  : Atomic[NodePtr]              # NodePtr - successor node
    ctrl*  : ControlBlock                 # Control block for mem recl

template toNodePtr*(pt: uint | ptr Node): NodePtr =
  # Convert ptr Node into NodePtr uint
  cast[NodePtr](pt)
template toNode*(pt: NodePtr | uint): Node =
  # NodePtr -> ptr Node and deref
  cast[ptr Node](pt)[]
template toUInt*(node: var Node): uint =
  # Get address to node
  cast[uint](node.addr)
template toUInt*(nodeptr: ptr Node): uint =
  # Equivalent to toNodePtr
  cast[uint](nodeptr)

when false:
  proc prepareElement*[T](el: sink T): uint =
    ## Prepare an item to be taken into the queue; we bump the RC first to
    ## ensure that no other operations free it, then add the WRITER bit.
    result = cast[uint](el) or WRITER
    when T is ref:
      let rc = atomicIncRef(el)
      if rc != 0:
        discard atomicDecRef(el)
        raise ValueError.newException:
          "unable to queue an unisolated ref: rc == " & $rc

template fetchNext*(node: Node, moorder: MemoryOrder = moAcquireRelease): NodePtr =
  node.next.load(order = moorder)

template fetchNext*(node: NodePtr, moorder: MemoryOrder = moAcquireRelease): NodePtr =
  # get the NodePtr to the next Node, can be converted to a TagPtr of (nptr: NodePtr, idx: 0'u16)
  (toNode node).next.load(order = moorder)

template fetchAddSlot*(t: Node, idx: uint16, w: uint, moorder: MemoryOrder = moAcquireRelease): uint =
  ## Fetches the pointer to the object in the slot while atomically
  ## increasing the value by `w`.
  ##
  ## Remembering that the pointer has 3 tail bits clear; these are
  ## reserved and increased atomically to indicate RESUME, READER, WRITER
  ## statuship.
  t.slots[idx].fetchAdd(w, order = moorder)

template compareAndSwapNext*(t: Node, expect: var uint, swap: var uint): bool =
  t.next.compareExchange(expect, swap, moRelaxed) # Have changed to relaxed as per cpp impl

template compareAndSwapNext*(t: NodePtr, expect: var uint, swap: var uint): bool =
  # Dumb, this needs to have expect be variable
  (toNode t).next.compareExchange(expect, swap, moRelaxed) # Have changed to relaxed as per cpp impl

proc `=destroy`*(n: var Node) =
  # echo "deallocd"
  deallocAligned(n.addr, NODEALIGN.int)

proc allocNode*(): ptr Node =
  # echo "allocd"
  cast[ptr Node](allocAligned0(sizeof(Node), NODEALIGN.int))

proc allocNode*(w: uint): ptr Node =
  # echo "allocd"
  result = allocNode()
  result.slots[0].store(w)

proc tryReclaim*(node: var Node; start: uint16) =
  # echo "trying to reclaim"
  block done:
    for i in start .. N:
      template s: Atomic[uint] = node.slots[i]
      # echo "Slot current val ", s.load()
      if (s.load(order = moAcquire) and CONSUMED) != CONSUMED:
        var prev = s.fetchAdd(RESUME, order = moRelaxed) and CONSUMED
        # echo prev
        if prev != CONSUMED:
          break done
    var flags = node.ctrl.fetchAddReclaim(SLOT)
    # echo "Try reclaim flag ", flags
    if flags == (ENQ or DEQ):
      `=destroy` node

proc incrEnqCount*(node: var Node; final: uint16 = 0) =
  var mask =
    node.ctrl.fetchAddTail:
      (final.uint32 shl 16) + 1
  template finalCount: uint16 =
    if final == 0:
      getHigh mask
    else:
      final
  if finalCount == (mask.uint16 and MASK) + 1:
    if node.ctrl.fetchAddReclaim(ENQ) == (DEQ or SLOT):
      `=destroy` node

proc incrDeqCount*(node: var Node; final: uint16 = 0) =
  var mask =
    node.ctrl.fetchAddTail:
      (final.uint32 shl 16) + 1
  template finalCount: uint16 =
    if final == 0:
      getHigh mask
    else:
      final
  if finalCount == (mask.uint16 and MASK) + 1:
    if node.ctrl.fetchAddReclaim(DEQ) == (ENQ or SLOT):
      `=destroy` node
