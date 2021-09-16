# O. Giersch and J. Nolte, "Fast and Portable Concurrent FIFO Queues With Deterministic Memory Reclamation," in IEEE Transactions on Parallel and Distributed Systems, vol. 33, no. 3, pp. 604-616, 1 March 2022, doi: 10.1109/TPDS.2021.3097901.

## NOTE - Have moved all this into the folder and divided it up now that I've
##        got the general workings and algorithms

import pkg/cps
import std/atomics

const
  ## Slot flag constants
  UNINIT   =   uint8(   0   ) # 0000_0000
  RESUME   =   uint8(1      ) # 0000_0001
  WRITER   =   uint8(1 shl 1) # 0000_0010
  READER   =   uint8(1 shl 2) # 0000_0100
  CONSUMED =  READER or WRITER# 0000_0110
  
  SLOT     =   uint8(1      ) # 0000_0001
  DEQ      =   uint8(1 shl 1) # 0000_0010
  ENQ      =   uint8(1 shl 2) # 0000_0100
  #
  N        =         1024     # Number of slots per node in the queue
  #
  TAGBITS   : uint = 11               # Each node must be aligned to this value
  NODEALIGN : uint = 1 shl TAGBITS    # in order to store the required number of
  TAGMASK   : uint = NODEALIGN - 1    # tag bits in every node pointer
  PTRMASK   : uint = high(uint) xor TAGMASK


type
  NodePtr = uint
  TagPtr = uint   # Aligned pointer with 12 bit prefix containing the tag. Access using procs nptr and idx
  ControlMask = uint32

  Node = object
    ## REVIEW - pretty sure ordering of fields matters.
    slots : array[0..N, Atomic[uint]]    # Pointers to object
    next  : Atomic[NodePtr]                 # NodePtr - successor node
    ctrl  : ControlBlock                 # Control block for mem recl

  LoonyQueue = object
    head     : Atomic[TagPtr]     # (NodePtr, idx)    ## Whereby node contains the slots and idx
    tail     : Atomic[TagPtr]     # (NodePtr, idx)    ## is the uint16 index of the slot array
    currTail : Atomic[NodePtr]    # 8 bytes Current NodePtr
  
  ## Control block for memory reclamation
  ControlBlock = object
    ## high uint16 final observed count of slow-path enqueue ops
    ## low uint16: current count
    headMask : Atomic[ControlMask]     # (uint16, uint16)  4 bytes
    ## high uint16, final observed count of slow-path dequeue ops,
    ## low uint16: current count
    tailMask : Atomic[ControlMask]     # (uint16, uint16)  4 bytes
    ## Bitmask for storing current reclamation status
    ## All 3 bits set = node can be reclaimed
    reclaim  : Atomic[ uint8]     #                   1 byte

const
  # Ref-count constants
  SHIFT = 16      # Shift to access 'high' 16 bits of uint32
  MASK  = 0xFFFF  # Mask to access 'low' 16 bits of uint32

type
  ## Result types for the private
  ## advHead and advTail functions
  AdvTail = enum
    AdvAndInserted, # 0000_0000
    AdvOnly         # 0000_0001
  AdvHead = enum
    QueueEmpty,     # 0000_0000
    Advanced        # 0000_0001

template toNodePtr(pt: uint | ptr Node): NodePtr =  # Convert ptr Node into NodePtr uint
  cast[NodePtr](pt)
template toNode(pt: NodePtr | uint): Node =         # Convert NodePtr to ptr Node and deref
  cast[ptr Node](pt)[]
template toUInt(node: var Node): uint =             # Get address to node
  cast[uint](node.addr)
template toUInt(nodeptr: ptr Node): uint =          # Equivalent to toNodePtr
  cast[uint](nodeptr)


template prepareElement(el: Continuation): uint =
  (cast[uint](el) or WRITER)  # BIT or

template fetchTail(queue: var LoonyQueue): TagPtr =
  ## get the TagPtr of the tail (nptr: NodePtr, idx: uint16)
  TagPtr(queue.tail.load())

template fetchHead(queue: var LoonyQueue): TagPtr =
  ## get the TagPtr of the head (nptr: NodePtr, idx: uint16)
  TagPtr(queue.head.load())

template fetchCurrTail(queue: var LoonyQueue): NodePtr =
  ## get the NodePtr of the current tail REVIEW why isn't this a TagPtr?
  cast[NodePtr](queue.currTail.load())

template fetchIncTail(queue: var LoonyQueue): TagPtr =
  ## Atomic fetchAdd of Tail TagPtr - atomic inc of idx in (nptr: NodePtr, idx: uint16)
  TagPtr(queue.tail.fetchAdd(1))

template fetchIncHead(queue: var LoonyQueue): TagPtr =
  ## Atomic fetchAdd of Head TagPtr - atomic inc of idx in (nptr: NodePtr, idx: uint16)
  TagPtr(queue.head.fetchAdd(1))

template fetchNext(node: Node): NodePtr = node.next.load()
template fetchNext(node: NodePtr): NodePtr =
  # get the NodePtr to the next Node, can be converted to a TagPtr of (nptr: NodePtr, idx: 0'u16)
  (node.toNode).next.load()

template fetchAddSlot(t: Node, idx: uint16, w: uint): uint = t.slots[idx].fetchAdd(w)
template fetchAddSlot(t: NodePtr, idx: uint16, w: uint): uint =
  (t.toNode).slots[idx].fetchAdd(w)
# Fetches the pointer to the object in the slot while atomically increasing the val
# 
# Remembering that the pointer has 3 tail bits clear; these are reserved
# and increased atomically do indicate RESUME, READER, WRITER statuship.



template compareAndSwapNext(t: Node, expect: var uint, swap: var uint): bool =
  t.next.compareExchange(expect, swap)
template compareAndSwapNext(t: NodePtr, expect: var uint, swap: var uint): bool =
  (t.toNode).next.compareExchange(expect, swap) # Dumb, this needs to have expect be variable

template compareAndSwapTail(queue: var LoonyQueue, expect: var uint, swap: uint | TagPtr): bool =
  queue.tail.compareExchange(expect, swap)
  
template compareAndSwapHead(queue: var LoonyQueue, expect: var uint, swap: uint | TagPtr): bool =
  queue.head.compareExchange(expect, swap)


template incrEnqCount(t: NodePtr, v: uint = 0'u) =
  discard # TODO
template incrDeqCount(t: NodePtr, v: uint = 0'u) =
  discard # TODO


proc tryReclaim(idx: uint): Node =
  discard # TODO


template deallocNode(n: var Node) =
  freeShared(n.addr)
template deallocNode(n: NodePtr) =
  freeShared(cast[ptr Node](n))

proc allocNode(): NodePtr =     # Is this for some reason better if template?
  var res {.align(NODEALIGN).} = createShared(Node)
  return res.toNodePtr
proc allocNode(el: Continuation): NodePtr =
  ## Allocate a fresh node with the first slot assigned
  ## to element el with the writer slot set
  var res {.align(NODEALIGN).} = createShared(Node)
  res[].slots[0].store(el.prepareElement())
  return res.toNodePtr

proc initNode(): Node =
  var res {.align(NODEALIGN).} = Node(); return res # Should I still use mem alloc createShared?
proc init[T: Node](t: T): T =
  var res {.align(NODEALIGN).} = Node(); return res


proc nptr(tag: TagPtr): NodePtr =
  result = toNodePtr(tag and PTRMASK)
proc idx(tag: TagPtr): uint16 =
  result = uint16(tag and TAGMASK)
proc tag(tag: TagPtr): uint16 = tag.idx
proc `$`(tag: TagPtr): string =
  var res = (nptr:tag.nptr, idx:tag.idx)
  return $res

proc getHigh(mask: ControlMask): uint16 =
  return cast[uint16](mask shr SHIFT)
proc getLow(mask: ControlMask): uint16 =
  return cast[uint16](mask)

proc fetchAddHigh(mask: var Atomic[ControlMask]): uint16 =
  return cast[uint16]((mask.fetchAdd(1 shl SHIFT)) shr SHIFT)
proc fetchAddLow(mask: var Atomic[ControlMask]): uint16 =
  return cast[uint16](mask.fetchAdd(1))
proc fetchAddMask(mask: var Atomic[ControlMask], pos: int, val: uint32): ControlMask =
  if pos > 0:
    return mask.fetchAdd(val shl SHIFT)
  return mask.fetchAdd(val)

proc isConsumed(slot: uint): bool =
  discard
  # TODO


proc advTail(queue: var LoonyQueue, el: Continuation, t: NodePtr): AdvTail =  
  var null = 0'u
  while true:
    var curr: TagPtr = queue.fetchTail()
    if t != curr.nptr:
      t.incrEnqCount()
      return AdvOnly
    var next = t.fetchNext()
    if cast[ptr Node](next).isNil():
      var node = cast[NodePtr](el) # allocNode(el) TODO; allocate mem
      null = 0'u
      if t.compareAndSwapNext(null, node):
        null = 0'u
        var tag: TagPtr = node + 1  # Translates to (nptr: node, idx: 1)
        while not queue.compareAndSwapTail(null, tag): # T11
          if t != curr.nptr:
            t.incrEnqCount()
            return AdvAndInserted
        t.incrEnqCount(curr.idx-N)
        return AdvAndInserted
      else:
        # deallocNode(node) TODO; dealloc mem
        continue
    else: # T20
      null = 0'u
      while not queue.compareAndSwapTail(null,next+1):    # next+1 translates to (nptr: next, idx: 1)
        if t != curr.nptr:
          t.incrEnqCount()
          return AdvOnly
      t.incrEnqCount(curr.idx-N)
      return AdvOnly

proc advHead(queue: var LoonyQueue, curr: var TagPtr, h,t: NodePtr): AdvHead =
  ## Reviewd, seems to follow the algorithm correctly and makes logical sense
  ## TODO DOC
  var next = h.fetchNext()
  if cast[ptr Node](next).isNil() or (t == h):
    h.incrDeqCount()
    return QueueEmpty
  curr += 1 # Equivalent to (nptr: NodePtr, idx: idx+=1)
  while not queue.compareAndSwapHead(curr, next.nptr): # equivalent to (nptr: next, idx: 0)
    if curr.nptr != h:
      h.incrDeqCount()
      return Advanced
  h.incrDeqCount(curr.idx-N)
  return Advanced



proc enqueue(queue: var LoonyQueue, el: Continuation) =
  while true:
    var tag = fetchIncTail(queue)
    var t: NodePtr = tag.nptr
    var i: uint16 = tag.idx
    if i < N:
      var w   : uint = prepareElement(el)
      let prev: uint = fetchAddSlot(t, i, w)
      if prev <= RESUME:
        return
      if prev == (READER or RESUME):
        (t.toNode) = tryReclaim(i + 1)
      continue
    else:     # Slow path; modified version of Michael-Scott algorithm
      case queue.advTail(el, t)
      of AdvAndInserted: return
      of AdvOnly: continue

proc deque(queue: var LoonyQueue): Continuation =
  while true:
    var curr = queue.fetchHead()
    var tail = queue.fetchTail()
    var h,t: NodePtr
    var i,ti: uint16
    (h, i) = (curr.nptr, curr.idx)
    (t, ti) = (tail.nptr, tail.idx)
    if (i >= N or i >= ti) and (h == t):
      return nil # Um ok
    var ntail = queue.fetchIncTail()
    (h, i) = (ntail.nptr, ntail.idx)
    if i < N:
      var prev = h.fetchAddSlot(i, READER)
      if i == N-1:
        (h.toNode) = tryReclaim(0)
      if (prev and WRITER) != 0:
        if (prev and RESUME) != 0:
          (h.toNode) = tryReclaim(i + 1)
        return cast[Continuation](prev and PTR_MASK) # TODO: define PTR_MASK
      continue
    else:
      case queue.advHead(curr, h, t)
      of Advanced: continue
      of QueueEmpty: return nil # big oof

proc isEmpty(queue: var LoonyQueue): bool =
  discard # TODO

## Consumed slots have been written to and then read
## If a concurrent deque operation outpaces the
## corresponding enqueue operation then both operations
## have to abandon and try again. Once all slots in the
## node have been consumed or abandoned, the node is
## considered drained and unlinked from the list.
## Node can be reclaimed and de-allocated.

## Queue manages an enqueue index and a dequeue index.
## Each are modified by fetchAndAdd; gives thread reserves
## previous index for itself which may be used to address
## a slot in the respective nodes array.
## ANCHOR both node pointers are tagged with their assoc
## index value -> they store both address to respective
## node as well as the current index value in the same
## memory word.
## Requires a sufficient number of available bits that
## are not used to present the nodes addresses themselves.