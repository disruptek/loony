import std/atomics
import "."/[constants, controlblock, alias, memalloc]
# Import the holy one
import pkg/cps

type
  Node* = object
    slots* : array[0..N-1, Atomic[uint]]    # Pointers to object
    next*  : Atomic[NodePtr]              # NodePtr - successor node
    ctrl*  : ControlBlock                 # Control block for mem recl

template toNodePtr*(pt: uint | ptr Node): NodePtr =  # Convert ptr Node into NodePtr uint
  cast[NodePtr](pt)
template toNode*(pt: NodePtr | uint): Node =         # Convert NodePtr to ptr Node and deref
  cast[ptr Node](pt)[]
template toUInt*(node: var Node): uint =             # Get address to node
  cast[uint](node.addr)
template toUInt*(nodeptr: ptr Node): uint =          # Equivalent to toNodePtr
  cast[uint](nodeptr)

proc prepareElement*(el: Continuation): uint =
  GC_ref(el)
  return (cast[uint](el) or WRITER)  # BIT or

template fetchNext*(node: Node): NodePtr = node.next.load()
template fetchNext*(node: NodePtr): NodePtr =
  # get the NodePtr to the next Node, can be converted to a TagPtr of (nptr: NodePtr, idx: 0'u16)
  (node.toNode).next.load()

template fetchAddSlot*(t: Node, idx: uint16, w: uint): uint = t.slots[idx].fetchAdd(w)
template fetchAddSlot*(t: NodePtr, idx: uint16, w: uint): uint =
  (t.toNode).slots[idx].fetchAdd(w)
# Fetches the pointer to the object in the slot while atomically increasing the val
# 
# Remembering that the pointer has 3 tail bits clear; these are reserved
# and increased atomically do indicate RESUME, READER, WRITER statuship.

template compareAndSwapNext*(t: Node, expect: var uint, swap: var uint): bool =
  t.next.compareExchange(expect, swap)
template compareAndSwapNext*(t: NodePtr, expect: var uint, swap: var uint): bool =
  (t.toNode).next.compareExchange(expect, swap) # Dumb, this needs to have expect be variable

template deallocNode*(n: var Node) =
  # echo "deallocd"
  deallocAligned(n.addr, NODEALIGN.int)
  
template deallocNode*(n: NodePtr) =
  # echo "deallocd"
  deallocAligned(cast[pointer](n), NODEALIGN.int)


proc allocNode*(): NodePtr =     # Is this for some reason better if template?
  # echo "allocd"
  var res = cast[ptr Node](allocAligned0(sizeof(Node), NODEALIGN.int))
  res[] = Node()
  result = res.toNodePtr()

proc allocNode*(el: Continuation): NodePtr =
  # echo "allocd"
  var res = cast[ptr Node](allocAligned0(sizeof(Node), NODEALIGN.int))
  res[] = Node()
  res[].slots[0].store(el.prepareElement())
  return res.toNodePtr()



proc tryReclaim*(t: NodePtr, start: uint16) =
  # echo "trying to reclaim"
  for i in start..N-1:
    var s = t.toNode().slots[i]
    # echo "Slot current val ", s.load()
    if (s.load() and CONSUMED) != CONSUMED:
      var prev = s.fetchAdd(RESUME) and CONSUMED
      # echo prev
      if prev != CONSUMED:
        return
  var flags = t.toNode().ctrl.fetchAddReclaim(SLOT)
  # echo "Try reclaim flag ", flags
  if flags == (ENQ or DEQ):
    deallocNode(t)

proc incrEnqCount*(t: NodePtr, final: uint16 = 0) =
  var finalCount: uint16 = final
  var mask: ControlMask
  var currCount: uint16
  if finalCount == 0:
    mask = t.toNode().ctrl.fetchAddTail(1)
    finalCount = mask.getHigh()
    currCount = cast[uint16](1 + (mask and MASK))
  else:
    var v: uint32 = 1 + (cast[uint32](finalCount) shl 16)
    mask = t.toNode().ctrl.fetchAddTail(v)
    currCount = cast[uint16](1 + (mask and MASK))
  if currCount == finalCount:
    var prev = t.toNode().ctrl.fetchAddReclaim(ENQ)
    # echo "IncrEnqCount prev ", prev
    # echo "IncrEnqCount new ", t.toNode().ctrl.reclaim.load()
    if prev == (DEQ or SLOT):
      deallocNode(t)

proc incrDeqCount*(t: NodePtr, final: uint16 = 0) =
  var finalCount: uint16 = final
  var mask: ControlMask
  var currCount: uint16
  # echo "Incrementing deq count"
  if finalCount == 0:
    mask = t.toNode().ctrl.fetchAddTail(1)
    finalCount = mask.getHigh()
    currCount = cast[uint16](1 + (mask and MASK))
    # echo "If finalcount == 0, vals ", finalCount, " ", currCount
  else:
    var v: uint32 = 1 + (cast[uint32](finalCount) shl 16)
    mask = t.toNode().ctrl.fetchAddTail(v)
    currCount = cast[uint16](1 + (mask and MASK))
  #   echo "finalcount != 0, vals ", finalCount, " ", currCount
  # echo "Finalcount & currCount, vals ", finalCount, " ", currCount
  if currCount == finalCount:
    var prev = t.toNode().ctrl.fetchAddReclaim(DEQ)   # The article ommits the deq
    # echo "IncrDEQCount prev ", prev
    # echo "IncrDEQCount new ", t.toNode().ctrl.reclaim.load()
    if prev == (ENQ or SLOT):                         # algorithm but I'm guessing i
      deallocNode(t)                                  # swap these vals to DEQ and ENQ