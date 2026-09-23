# `for parallel`

```
for parallel [(N)] var i := lo to|downto hi [step s] [chunk c] do STMT
```

Runs the loop body across a pool of worker threads instead of one iteration after another. The pool is built on `BeginThread()`, every iteration is handed out exactly once, and the loop is a barrier - control does not pass `do` until every iteration has finished, and everything the bodies wrote is visible afterwards.

Modeswitch: `parallelfor`, enabled by default in `{$mode unleashed}`. On Unix the program also needs a threading driver (`cthreads` first in `uses`).

## Basic use

```pascal
var total: integer;
begin
  total := 0;
  for parallel var i := 1 to 1000000 do
    InterlockedExchangeAdd(total, i); // shared state -> atomic, always
end;
```

The body is the same statement you would write in a classic `for`. The difference: several iterations run at once on different threads, so any state shared between iterations must be touched with an atomic (`InterlockedIncrement()`, `InterlockedExchangeAdd()`, ...) or under a [`lock`](lock.md). A per-iteration local needs nothing - each worker owns its own.

## The counter is mandatory and inline

```pascal
for parallel var i := 1 to N do ... // ok - each worker owns its copy of i
```

A pre-existing variable is rejected (`` `for parallel` requires an inline loop variable - write `for parallel var i := ...` ``) - one shared counter cannot be handed to several threads at once.

## Pool size

Default: `min(GetCPUCount, iteration_count)` threads. An explicit size goes in parentheses right after `parallel`:

```pascal
for parallel var i := 1 to N do ...       // one worker per core (capped by N)
for parallel(4) var i := 1 to N do ...    // at most 4 workers
for parallel(1) var i := 1 to N do ...    // sequential: runs on the caller, no spawn
```

The count is evaluated once and clamped to `[1, min(iteration_count, 256)]`. The calling thread is itself one of the workers - `parallel(N)` spawns `N-1` helpers and joins the dispatch, never sitting idle. `parallel(1)` spawns nothing and is a plain sequential loop.

## Dispatch and ordering

Iterations are handed out dynamically through a shared atomic counter: each worker claims the next block of indices and computes `i := lo +/- index*step`. Work rebalances automatically when iterations take uneven time, but the order bodies run in, and which thread runs a given `i`, are **undefined** - never rely on either.

`lo`, `hi`, `step`, and `chunk` are each evaluated once before the pool starts, exactly like a classic `for`. The dispatch counter follows the loop variable's width: a 64-bit variable gets a 64-bit counter (ranges past 2^31 work), smaller types including enums and chars stay on the 32-bit path. Targets without 64-bit interlocked ops reject a 64-bit counter at compile time.

## `downto`, `step`, `chunk`

All compose in the header, in this order:

```pascal
for parallel var i := 100 downto 1 do ...                 // top-down
for parallel var i := 1 to 200 step 2 do ...              // 1, 3, ..., 199
for parallel(4) var i := 1 to N step 2 chunk 100 do ...   // full stack
```

`step` is positive (descend with `downto`; needs `forstep`, on by default). `chunk N` sets how many indices one counter grab claims - the worker then walks that block with no further atomics. This is the cure for cheap bodies paying a contended atomic per iteration. Default: `count div (workers*4)`, floored at 1 (about four grabs per worker - late rebalancing still works, counter contention stays negligible). Pick a large chunk for tiny uniform bodies, a small one for expensive uneven ones. A non-positive constant chunk is a compile error; a runtime value below 1 is clamped to 1. Like `step`, `chunk` is a keyword only in this one spot.

## The body reaches enclosing locals

The body is hoisted into a hidden nested routine, so it reads and writes the enclosing routine's locals across the worker threads (concurrent writes still need atomics or a lock):

```pascal
function countOdd(n: integer): integer;
var c: integer;
begin
  c := 0;
  for parallel var i := 1 to n do
    if odd(i) then InterlockedIncrement(c); // c is countOdd's local
  result := c;
end;
```

## `WorkerIndex` and `WorkerCount`

Two implicit read-only locals inside the body: `WorkerIndex` (0 to `WorkerCount`-1, claimed once per worker at entry, stable for the whole loop) and `WorkerCount` (the pool size after clamping). They exist for lock-free per-worker private state - a scratch buffer or partial sum per worker, indexed without any atomics:

```pascal
var acc: array[0..3] of int64;
...
for parallel(4) var i := 1 to N do
  acc[WorkerIndex] += weight(i); // private slot - no atomics
// after the barrier: total := acc[0] + acc[1] + acc[2] + acc[3]
```

Size such arrays with an explicit `parallel(N)` - a default pool's `WorkerCount` is not known up front. `WorkerIndex` identifies the *worker*, not the iteration: one worker executes many `i`. Assigning to either (or passing it to a `var` parameter) is rejected with `Can't assign values to const variable`.

## `continue` / `break`; `exit` / `goto` do not

`continue` skips to the next iteration, as usual. `break` cancels cooperatively: it raises a shared flag, no new iteration starts, but iterations already running on other threads finish (across threads there is no way to stop a body mid-flight). After the join, execution continues past `do`. With `parallel(1)` break is exact, like a sequential loop; a `break` in a nested classic loop still binds to that inner loop.

`exit` is rejected (`` `exit` is not allowed inside a `for parallel` body ``) - it promises to leave the routine immediately, which a pool that must join its threads cannot deliver; write `break` and test a flag after the loop. `goto` out of the body is rejected too, as is `for parallel var x in collection` - only numeric ranges.

## Exceptions

A body that raises does not kill the process: the worker catches it, the **first** exception across all workers is re-raised on the calling thread after the barrier, later ones are dropped. A fault surfaces as an ordinary exception at the loop:

```pascal
try
  for parallel var i := 1 to N do
    if bad(i) then raise EMyError.Create('...');
except
  on e: EMyError do handleIt(e); // re-raised here, after the join
end;
```

## Nested parallel loops

An inner `for parallel` running on a parallel worker defaults its pool to 1 - the outer loop is parallel, the inner sequential per worker. A default inner pool would oversubscribe cores (`outer x inner` threads) and run slower. An explicit `parallel(N)` on the inner loop opts into true nesting - use it only when the inner work is heavy enough to be worth the threads:

```pascal
for parallel var i := 1 to 4 do
  for parallel(4) var j := 1 to 250 do // 4 inner workers per outer worker
    heavy(i, j);
```

## `parallel` is a context-sensitive keyword

Recognized only between `for` and the header, and only when the next token is `var` or `(`. Everywhere else it stays an ordinary identifier, so existing code named `parallel` keeps compiling:

```pascal
var parallel: integer;
for parallel := 1 to 5 do ... // ordinary sequential loop over `parallel`
```

## Threading driver

The pool uses `BeginThread()` / `WaitForThreadTerminate()` from the `system` unit. Windows works as-is. On Unix put `cthreads` first in the program's `uses` - otherwise thread creation fails at run time, like any threaded FPC program. The compiler checks this once per program and warns when `cthreads` is not the first unit named. A unit is initialized after its dependencies, so the check follows the first unit of the first unit: a program whose first unit itself names `cthreads` first passes, and so does one that loads the driver ahead of `uses` with `-Facthreads`. A unit cannot see the program's `uses`, so `for parallel` inside a unit gets a hint instead. A worker that fails to spawn at run time is simply skipped: its share of iterations drains through the workers that did start, worst case the caller alone.

## Errors and edge cases

| Trigger | Message |
|---|---|
| counter not declared inline with `var` | `` `for parallel` requires an inline loop variable - write `for parallel var i := ...` `` |
| `for parallel var x in collection` | `` `for parallel` cannot be combined with a for-in loop `` |
| `exit` inside the body | `` `exit` is not allowed inside a `for parallel` body `` |
| `goto` leaving the body | goto-not-allowed error |
| 64-bit counter on a target without 64-bit interlocked | no-int64-dispatch error |
| non-ordinal / non-positive constant `chunk` | chunk error |

| Case | Behavior |
|---|---|
| empty range (`1 to 0`) | body never runs, no threads spawned |
| `parallel(0)` / negative count | clamped up to 1 (sequential) |
| count > iteration count | clamped down - never more workers than iterations |
| count > 256 | clamped to 256; the counter still covers every index |
| full 64-bit range (`low..high(int64)`) | iteration count itself overflows - not supported |
| plain write to a shared variable | data race - your bug, not the loop's; use an atomic |

## Demo

```pascal
program parallel_for_demo;

{$mode unleashed}

var
  partial: array[4] of double;
  total: integer;

begin
  // per-worker partial sums in private slots - no atomics, combined after the barrier
  for parallel(4) var k := 1 to 2000000 do
    partial[WorkerIndex] += 1.0/(double(k)*k);
  var basel := 0.0;
  for var w in partial do basel += w;
  writeln($'pi ~ {sqrt(6*basel):8:6}');

  // shared state needs an atomic (or a lock)
  total := 0;
  for parallel var i := 1 to 100000 do
    if i mod 7 = 0 then InterlockedIncrement(total);
  writeln($'multiples of 7 up to 100000: {total}');

  // a nested parallel loop runs sequentially on its outer worker by default
  total := 0;
  for parallel var i := 1 to 4 do
    for parallel var j := 1 to 250 do
      InterlockedIncrement(total);
  writeln($'nested total: {total}');
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
pi ~ 3.141592
multiples of 7 up to 100000: 14285
nested total: 1000
```
