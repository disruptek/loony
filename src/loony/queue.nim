import std/atomics
import "."/[alias, constants, controlblock, node]
# Import the holy one
import pkg/cps
import chronicles

# sprinkle some raise defect
# raise Defect(nil) | yes i am the
# raise Defect(nil) | salt bae of defects
# raise Defect(nil) | 
# raise Defect(nil) | I am defect bae 
# raise Defect(nil) |
# and one more for haxscrampers pleasure
# raise Defect(nil)

type
  LoonyQueue* = object  # Can't I just have the loony queue as a ref?
    head     : Atomic[TagPtr]     # (NodePtr, idx)    ## Whereby node contains the slots and idx
    tail     : Atomic[TagPtr]     # (NodePtr, idx)    ## is the uint16 index of the slot array
    currTail : Atomic[NodePtr]    # 8 bytes Current NodePtr

  ## Result types for the private
  ## advHead and advTail functions
  AdvTail = enum
    AdvAndInserted, # 0000_0000
    AdvOnly         # 0000_0001
  AdvHead = enum
    QueueEmpty,     # 0000_0000
    Advanced        # 0000_0001

## TagPtr is an alias for 8 byte uint (pointer). We reserve a portion of the
## tail to contain the index of the slot to its corresponding node by aligning
## the node pointers on allocation. Since the index value is stored in the
## same memory word as its associated node pointer, the FAA operations could
## potentially affect both values if too many increments were to occur.
## This is accounted for in the algorithm and with space for overflow in the
## alignment.
## See Section 5.2 for the paper to see why an overflow would prove impossible
## except under extraordinarily large number of thread contention.

proc nptr(tag: TagPtr): NodePtr =
  result = toNodePtr(tag and PTRMASK)
proc idx(tag: TagPtr): uint16 =
  result = uint16(tag and TAGMASK)
proc tag(tag: TagPtr): uint16 = tag.idx
proc toStrTuple*(tag: TagPtr): string =
  var res = (nptr:tag.nptr, idx:tag.idx)
  return $res

template fetchTail(queue: var LoonyQueue): TagPtr =
  ## get the TagPtr of the tail (nptr: NodePtr, idx: uint16)
  TagPtr(queue.tail.load())

template fetchHead(queue: var LoonyQueue): TagPtr =
  ## get the TagPtr of the head (nptr: NodePtr, idx: uint16)
  TagPtr(queue.head.load())

template fetchCurrTail(queue: var LoonyQueue): NodePtr =
  ## get the NodePtr of the current tail
  cast[NodePtr](queue.currTail.load())

template fetchIncTail(queue: var LoonyQueue): TagPtr =
  ## Atomic fetchAdd of Tail TagPtr - atomic inc of idx in (nptr: NodePtr, idx: uint16)
  cast[TagPtr](queue.tail.fetchAdd(1))

template fetchIncHead(queue: var LoonyQueue): TagPtr =
  ## Atomic fetchAdd of Head TagPtr - atomic inc of idx in (nptr: NodePtr, idx: uint16)
  cast[TagPtr](queue.head.fetchAdd(1))

template compareAndSwapTail(queue: var LoonyQueue, expect: var uint, swap: uint | TagPtr): bool =
  queue.tail.compareExchange(expect, swap)
  
template compareAndSwapHead(queue: var LoonyQueue, expect: var uint, swap: uint | TagPtr): bool =
  queue.head.compareExchange(expect, swap)



## Both enqueue and dequeue enter FAST PATH operations 99% of the time, however
## in cases we enter the SLOW PATH operations represented in both enq and deq by
## advTail and advHead respectively.
## This path requires the threads to first help updating the linked list struct
## before retrying and entering the fast path in the next attempt.
proc advTail(queue: var LoonyQueue, el: Continuation, t: NodePtr): AdvTail =  
  ## Modified Michael-Scott algorithm
  var null = 0'u
  while true:
    var curr: TagPtr = queue.fetchTail()
    if t != curr.nptr:
      t.incrEnqCount()
      return AdvOnly
    var next = t.fetchNext()
    if cast[ptr Node](next).isNil():
      var node = allocNode(el)
      null = 0'u
      if t.compareAndSwapNext(null, node):
        null = 0'u
        var tag: TagPtr = node + 1  # Translates to (nptr: node, idx: 1)
        while not queue.compareAndSwapTail(null, tag): # T11
          if t != curr.nptr:
            t.incrEnqCount()
            return AdvAndInserted
        t.incrEnqCount(curr.idx - N)
        return AdvAndInserted
      else:
        deallocNode(node)
        continue
    else: # T20
      null = 0'u
      while not queue.compareAndSwapTail(null,next+1):    # next+1 translates to (nptr: next, idx: 1)
        if t != curr.nptr:
          t.incrEnqCount()
          return AdvOnly
      t.incrEnqCount(curr.idx - (N-1))
      return AdvOnly



proc advHead(queue: var LoonyQueue, curr: var TagPtr, h,t: NodePtr): AdvHead =
  h.tryReclaim(0'u8)  # As done in cpp impl
  var next = h.fetchNext()
  if cast[ptr Node](next).isNil() or (t == h):
    h.incrDeqCount()
    return QueueEmpty
  curr += 1 # Equivalent to (nptr: NodePtr, idx: idx+=1)
  while not queue.compareAndSwapHead(curr, next.nptr): # equivalent to (nptr: next, idx: 0)
    if curr.nptr != h:
      h.incrDeqCount()
      return Advanced
  h.incrDeqCount(curr.idx - (N-1))
  return Advanced


## Fundamentally, both enqueue and dequeue operations attempt to
## exclusively reserve access to a slot in the array of their
## associated queue node by automatically incremementing the
## appropriate index value and retrieving the previous value
## of the index as well as the current node pointer.
## Threads that retrieve an index i < N (length of the slots array)
## gain *exclusive* rights to perform either write/consume operation
## on the corresponding slot.
## This guarantees there can only be exactly one of each for any
## given slot.
## Where i < N, we use FAST PATH operations. These operations are
## designed to be as fast as possible while only dealing with memory
## contention in rare edge cases.
## 
## if not i < N, we enter SLOW PATH operations. See AdvTail and AdvHead above.
## Fetch And Add (FAA) primitives are used for both incrementing index
## values as well as performing read(consume) and write operations
## on reserved slots which drastically improves scalability compared to
## Compare And Swap (CAS) primitives.
## Note that all operations on slots must modify the slots state bits
## to announce both operations completion (in case of a read) and also
## makes determining the order in which two operations occured possible.

proc push*(queue: var LoonyQueue, el: Continuation) =
  while true:
    ## The enqueue procedure begins with incrementing the
    ## index of the associated node in the TagPtr
    var tag = fetchIncTail(queue)
    var t: NodePtr = tag.nptr
    var i: uint16 = tag.idx
    if likely(i < N):
      ## We begin by tagging the pointer for el with a WRITER
      ## bit and then perform a FAA.
      var w   : uint = prepareElement(el) 
      let prev: uint = fetchAddSlot(t, i, w)
      if prev > 0:
        trace "FAST PATH PUSH encountered pre-filled slot", prefilled = prev, index = i, new_val = w
      ## Since we are assured that the slots would be 0'd, the
      ## slots value should be evaluated to be less than 0 (RESUME
      ## = 1).
      if prev <= RESUME:
        return
      ## If however we assess that the READER bit was already set before
      ## we arrived, then the corresponding dequeue operation arrived
      ## too early and we must consequently abandon the slot and retry
      if prev == (READER or RESUME):
        ## Checking for the presence of the RESUME bit only pertains to
        ## the memory reclamation mechanism and is only relevant
        ## in rare edge cases in which the enqueue operation
        ## is significantly delayed and lags behind most other operations
        ## on the same node.
        t.tryReclaim(i + 1)
      ## Should the case above occur or we detect already the slot has
      ## been filled by some gypsy magic then we will retry
      continue
    else: # Slow path; modified version of Michael-Scott algorithm; see advTail above
      case queue.advTail(el, t)
      of AdvAndInserted: return
      of AdvOnly: continue

proc isEmpty*(queue: var LoonyQueue): bool =
  var curr = queue.fetchHead()
  var tail = queue.fetchTail()
  var h,t: NodePtr
  var i,ti: uint16
  (h, i) = (curr.nptr, curr.idx)
  (t, ti) = (tail.nptr, tail.idx)
  if (i >= N or i >= ti) and (h == t):
    return true
  return false

proc pop*(queue: var LoonyQueue): Continuation =
  while true:
    ## Before incrementing the dequeue index, an initial check must be performed
    ## to determine if the queue is empty.
    var h,t: NodePtr
    var i,ti: uint16
    var tail = queue.fetchTail()
    var curr = queue.fetchHead()  ## Ensure head is loaded last to keep mem hot
    (h, i) = (curr.nptr, curr.idx)
    (t, ti) = (tail.nptr, tail.idx)
    if (i >= N or i >= ti) and (h == t):
      return nil # Um ok
    var head = queue.fetchIncHead()
    (h, i) = (head.nptr, head.idx)
    if likely(i < N):
      var prev = h.fetchAddSlot(i, READER)
      ## On the last slot in a node, we initiate the reclaim
      ## procedure; if the writer bit is set then the upper bits
      ## must contain a valid pointer to an enqueued element
      ## that can be returned (see enqueue)
      if unlikely((prev and SLOTMASK) == 0): continue
      # if i == N-1: ## why do we abandon the last index? do we do the same for the push?
      #   h.tryReclaim(0'u8)
      #   continue  ## REVIEW - This operation makes no sense to me and it wasn't in the cpp imp so I killed it
      if (prev and constants.WRITER) != 0:
        if unlikely((prev and RESUME) != 0):
          h.tryReclaim(i + 1)
        var res = cast[Continuation](prev and SLOTMASK)
        GC_unref(res)
        assert res != nil
        return res
      continue
    else:
      case queue.advHead(curr, h, t)
      of Advanced: continue
      of QueueEmpty: return nil # big oof


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


proc initLoonyQueue*(): LoonyQueue = # So I should definitely have a destroy proc to clear the nodes but i do that later
  result = LoonyQueue()
  var headTag = allocNode()
  var tailTag = headTag
  result.head.store(headTag)
  result.tail.store(tailTag)
  result.currTail.store(tailTag)
  for i in 0..<N:
    var h = headTag.toNode().slots[i].load()
    var t = tailTag.toNode().slots[i].load()
    assert h == 0, "Slot found to not be nil on initialisation"
    assert t == 0, "Slot found to not be nil on initialisation"
  # I mean the enqueue and dequeue pretty well handle any issues with
  # initialising, but I might as well help allocate the first ones right?