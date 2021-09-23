import std/osproc
import std/strutils
import std/logging
import std/atomics
import std/os
import std/macros

import pkg/balls
import pkg/cps
import pkg/arc

import loony

const
  sleepEnabled = true
  continuationCount = when defined(windows): 1_000 else: 1
let
  threadCount = when defined(danger): 2000*countProcessors() else: 1

var q = initLoonyQueue[Continuation]()

type
  C = ref object of Continuation

addHandler newConsoleLogger()
setLogFilter:
  when defined(danger):
    lvlNotice
  elif defined(release):
    lvlInfo
  else:
    lvlDebug

proc dealloc(c: C; E: typedesc[C]): E =
  checkpoint "reached dealloc"

proc runThings(arg: bool) {.thread.} =
  while true:
    var job = pop q
    if job.dismissed:
      break
    else:
      while job.running:
        echo "pre-tramp ", atomicRC(job)
        job = trampoline job
        if not job.dismissed:
          echo "post-tramp ", atomicRC(job)

proc enqueue(c: sink C): C {.cpsMagic.} =
  echo "pre-queue ", atomicRC(c)
  q.push c

var counter {.global.}: Atomic[int]

# try to delay a reasonable amount of time despite platform
when sleepEnabled:
  when defined(windows):
    proc noop(c: C): C {.cpsMagic.} =
      sleep:
        when defined(danger):
          1
        else:
          0 # 🤔
      c
  else:
    import posix
    proc noop(c: C): C {.cpsMagic.} =
      const
        ns = when defined(danger): 1_000 else: 10_000
      var x = Timespec(tv_sec: 0.Time, tv_nsec: ns)
      var y: Timespec
      if 0 != nanosleep(x, y):
        raise
      c
else:
  proc noop(c: C): C {.cpsMagic.} =
    c

proc doContinualThings() {.cps: C.} =
  enqueue()
  noop()
  enqueue()
  discard counter.fetchAdd(1)

template expectCounter(n: int): untyped =
  ## convenience
  try:
    check counter.load == n
  except Exception:
    checkpoint " counter: ", load counter
    checkpoint "expected: ", n
    raise

proc main =
  suite "loony":
    block:
      ## run some continuations through the queue in another thread
      #when defined(danger): skip "boring"
      var thr: Thread[bool]

      counter.store 0
      dumpAllocStats:
        for i in 0 ..< continuationCount:
          var c = whelp doContinualThings()
          discard enqueue c
        createThread(thr, runThings, true)
        joinThread thr
        expectCounter continuationCount

    block:
      ## run some continuations through the queue in many threads
      #when not defined(danger): skip "slow"
      var threads: seq[Thread[bool]]
      newSeq(threads, threadCount)

      counter.store 0
      dumpAllocStats:
        for i in 0 ..< continuationCount:
          var c = whelp doContinualThings()
          discard enqueue c
        checkpoint "queued $# continuations" % [ $continuationCount ]

        for thread in threads.mitems:
          createThread(thread, runThings, true)
        checkpoint "created $# threads" % [ $threadCount ]

        for thread in threads.mitems:
          joinThread thread
        checkpoint "joined $# threads" % [ $threadCount ]

        expectCounter continuationCount

when isMainModule:
  main()
