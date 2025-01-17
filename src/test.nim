import cps, macros
import loony {.all.}

# Moment of truth
var queue = createShared(LoonyQueue)
queue[] = initLoonyQueue()

type
  C = ref object of Continuation
    q: ptr LoonyQueue
  ThreadArg = object
    q: ptr LoonyQueue

proc dealloc(c: C, E: typedesc[C]): E =
  echo "reached dealloc"

var targ = ThreadArg(q: queue)

import os
proc runThings(targ: ThreadArg) {.thread.} =
  var q = targ.q
  var i: int
  var prev: C
  var str: string
  while i < 50:
    # echo str
    var job = q[].pop()
    if job == nil:
      # echo "nil"
      inc(i)
      sleep(50)
      continue
    while job.running():
      job = trampoline job
      str.add('C')
      # echo str
      # echo job.running()
      # i = 0
  echo "Finished"

import atomics
var counter {.global.}: Atomic[int]


# expandMacros:
proc pass(cFrom,cTo: C): C =
  cTo.q = cFrom.q
  return cTo

proc register(c: C): C {.cpsMagic.} =
  c.q[].push(c)
  return nil

proc doContinualThings() {.cps:C.} =
  var orig = getThreadId()
  # echo "WOAH ", orig
  register()
  discard counter.fetchAdd(1)
  register()
  # echo "end"
  orig = 5


var thr: Thread[ThreadArg]
var thr2: Thread[ThreadArg]
var thr3: Thread[ThreadArg]
dumpAllocStats:
  for i in 0..5000:
    var c = whelp doContinualThings()
    c.q = queue
    queue[].push(c)
  createThread(thr, runThings, targ)
  joinThread(thr)
  echo counter.load()
  