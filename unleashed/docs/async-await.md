# `async` / `await` - Thread Futures

`async` runs a routine call or a block on a fresh worker thread and hands back a future; `await` blocks until that thread finishes and reads its result. This is the `std::async` execution model: no function coloring, no event loop, no scheduler. One `async` is one thread, one `await` is one join.

Modeswitch: `asyncawait`, enabled by default in `{$mode unleashed}`. `async`, `await`, `sync`, and `future` are soft keywords - existing identifiers with those names keep working when the switch is off.

## The `future of T` type

`async` yields a `future of T` when the work produces a value of type `T`, or a bare `future` when it produces nothing:

```pascal
var z: future of string := async fetchName;   // explicit type
var z := async fetchName;                     // inferred: future of string
var w: future := async doWork;                // bare future, no value
```

A future is an opaque handle to a pending result. It is reference-counted, so it can be stored, returned from a function, or passed as a parameter, and it stays alive as long as anything (including the running worker) holds it:

```pascal
function startFetch: future of string;
begin
  result := async fetchName; // the future outlives this function
end;
```

Two futures with the same element type are the same type, so futures cross unit boundaries freely (each module interns its own synthesized interface, compared structurally).

## `async` - spawn the work

**Call form** `async <routine call>` evaluates the call's arguments **now**, on the spawning thread, snapshots them by value, and runs the routine on the worker from those snapshots:

```pascal
var a := 2;
var sum := async add(a, 3);      // a is read here, as 2
a := 100;                        // does not affect sum
writeln(await sum);              // 5
```

For a method call the `self` reference is snapshotted the same way (object identity fixed), but the object's fields remain shared state - mutate them from another thread at your own risk.

**Block form** `async begin ... end` runs the block on the worker and yields a bare `future`. The block captures referenced locals **by reference** through the function-reference machinery (heap-allocated, reference-counted), so the future may safely outlive the routine that spawned it and the worker sees later mutations:

```pascal
counter := 0;
var w := async begin
  counter := counter+41;
end;
await w;
writeln(counter+1); // 42
```

Inside a method the block has the method's full class context, like an anonymous function: `Self` and strict private members (including auto-property backing fields) resolve as usual.

A statement keyword after `async` (`if`, `case`, `match`, `try`, `while`, `for`, `repeat`, `with`, `goto`, `raise`) starts the one-statement block form - `async while not done do step;` behaves exactly like the block-wrapped equivalent, with the same by-reference capture and `Cancelled` in scope. An identifier after `async` is always the call form.

## `await` - join and read

`await f` blocks the current thread until `f`'s worker finishes. For a `future of T` it is an expression of type `T`; for a bare `future` it is a statement:

```pascal
writeln(await z);                // string
await w;                         // statement, just joins
```

`await` binds like a unary operator (tighter than binary operators), so `await x + 1` is `(await x) + 1`, and a direct generic call needs parentheses: `await (getAsync<T>(x))`.

Joining is repeatable: the result is cached in the future and the event re-armed, so multiple `await`s on one future all succeed and only the first actually waits:

```pascal
var n := await sum + 1; // second await: reads the cached value, no wait
```

## Controlling the worker

Beyond `await`, the future carries a small control surface. Everything except `Cancel()` is read-only; assigning to any probe is a compile error:

```pascal
var h := async crunch(data);

h.Cancel;             // raise the cooperative cancel flag
writeln(h.Cancelled); // boolean: was Cancel called
writeln(h.Done);      // boolean: has the worker finished (never blocks)
writeln(h.ThreadID);  // TThreadID: the worker's BeginThread id
```

`Done` is published right before the worker releases any awaiter, so a poll loop can track progress without blocking, and once `Done` is true an `await` returns immediately.

### Cooperative cancellation

`Cancel()` kills nothing - it raises a flag the work is expected to poll. Inside `async begin ... end` the flag is visible as a read-only boolean `Cancelled` (the way `WorkerIndex` is visible in a `for parallel` body):

```pascal
var h := async begin
  while not Cancelled do
    doChunk;
end;
// from the spawning side:
h.Cancel;             // ask the worker to stop
await h;              // returns once the loop notices the flag
```

Each nested `async begin` sees its own `Cancelled`. The call form runs an ordinary routine, which cannot see the flag - a cancellable routine takes its own flag as an argument (`Cancel()` / `Cancelled` on the handle still work as caller-side bookkeeping).

### `ThreadID` and the RTL thread API

`ThreadID` returns the value `BeginThread()` handed back - exactly the currency of the RTL thread API: `ThreadSetPriority()`, `WaitForThreadTerminate(h.ThreadID, 100)`, and, if you accept the consequences, `KillThread()`.

`KillThread()` is a last resort. The thread dies without unwinding: no `finally` runs, allocations leak, a held lock (the heap manager's, say) can deadlock the process later. The future's machinery is not compensated either - a killed worker never signals completion, so `Done` stays false, a later `await` blocks forever, and the future object is never freed. Prefer `Cancel()` plus a polling worker.

## Fire and forget

Spawn without keeping the future and the work still runs - the worker holds the only reference and the future frees itself when the thread is done:

```pascal
async logToFile('done'); // runs on a worker, nobody waits
async begin
  flushCaches;
end;
```

A statement intrinsic such as `async writeln(...)` runs verbatim on the worker - its operands are evaluated there, so reading a local of the spawning routine is a compile error pointing to the block form: `` `async` on a statement that reads local variables; wrap it in `async begin ... end` to capture them ``.

## `sync` - run a block on the main thread

Inside a worker, GUI controls (and anything else the main thread owns) are off limits. A `sync` block hands its body to the main thread and blocks until it has run - the marshaling counterpart of `async`:

```pascal
async begin
  var data := fetchReport;         // slow work, on the worker
  sync begin
    memo1.Append(data.summary);    // on the main thread
  end;
  archive(data);                   // worker resumes after the block ran
end;
```

A single statement needs no block: `sync memo1.Append(s);` or `sync progress += 1;`.

It lowers to `TThread.Synchronize(nil, <body>)`, so `Classes` must be in the uses clause (a dedicated error says so otherwise). The body captures referenced locals by reference like `async begin..end`; since the caller waits, the captures stay valid and the body's writes are visible to the caller afterwards. Inside a method the body sees `Self`. Run on the main thread itself, the body executes in place, so a routine containing `sync` works from either side. An exception raised in the body re-raises in the calling thread, where the usual worker exception flow picks it up.

`sync` is a soft keyword decided by shape: followed by a token that can start a statement (`begin`, an identifier, `if`, `for`, ...) it is the keyword; followed by `:=`, `;`, `(`, `.`, `[`, or an operator it resolves to a user symbol named sync. Both coexist in one scope.

Two rules to keep straight:

- **Somebody must pump the queue.** The LCL message loop does it on its own; a console program calls `CheckSynchronize()` on the main thread.
- **Never `await` on the main thread while a worker sits in `sync`.** Each would wait for the other, forever. Let the message loop pump, or poll: `while not h.Done do CheckSynchronize(10);`. Awaiting the same future from another worker is fine - the main thread stays free to run the body.

## Exceptions

A worker exception is captured and **re-raised on the caller at the first `await`**:

```pascal
var bad := async begin
  raise Exception.Create('boom');
end;
try
  await bad;
except
  on e: Exception do writeln(e.Message); // boom
end;
```

Delivery is exactly once: after the first `await` re-raises, a later `await` on the same future yields the zeroed result instead. A fire-and-forget future is never awaited, so its exception is swallowed and freed at finalization - when a worker may fail and the failure matters, keep the future and `await` it.

## Targets of the call form

Accepted: ordinary routines, methods of any visibility including strict private, overloaded routines, generic specializations (`async twoOf<integer>(21)`), and procvar calls (`async pv()` - the procvar value is snapshotted; later reassignment does not affect the spawned work). An open array parameter (`array of T`) takes a dynamic array, a static array or an array literal; the array itself is snapshotted and the worker's call converts it again.

Rejected, with dedicated errors:

- **`var` / `out` arguments** - `` `async` cannot pass a `var` or `out` argument - the snapshot would drop the worker's writes ``. Use the block form or return the value through the future.
- **An open array parameter passed on** - `` `async` cannot pass an open array parameter on; pass a dynamic or static array ``. Inside a routine with `xs: array of T`, `async f(xs)` has no array of its own to snapshot; declare the parameter as a dynamic array or copy it first.
- **Nested routines** - `` `async` cannot run a nested routine - it needs the enclosing frame, which may be gone before the worker runs ``. Move the work to a top-level routine.

## Compile-time checks

```pascal
writeln('z = ', z);   // Error: future value used without `await` - call `await` to read its result
await n;              // Error: `await` requires a future expression
async (a+b);          // Error: `async` requires a routine call or a `begin..end` block
```

Outside the modeswitch none of the keywords is recognized and existing code is untouched.

## Notes

- **Threads must be available.** On Unix add `cthreads` as the first unit of the program; Windows works out of the box.
- **Everything the routine reaches runs on the worker** - including callbacks it invokes. A handler that must touch the GUI wraps that part in `sync`, or marshals manually with `TThread.Synchronize(nil, ...)` / `TThread.Queue(nil, ...)` (the `nil` because the worker is a plain `BeginThread()` thread with no `TThread` instance).
- **Shared mutable state is your responsibility.** The call form snapshots arguments, but the block form captures by reference and a snapshotted `self` shares the object - synchronize concurrent access yourself ([`lock`](lock.md) pairs well).
- **Fire-and-forget work may not finish.** At program exit outstanding fire-and-forget workers are not awaited. Keep and `await` the future when completion matters.
- **Cleanup is automatic.** When the last reference to a future drops, a synthesized destructor releases the RTL event, the thread handle, and a still-unread exception. Built on `system`-unit primitives only (`BeginThread()`, `RTLEvent*`) - no RTL changes.

## Demo

```pascal
program async_demo;

{$mode unleashed}

uses SysUtils;

function slowSquare(n: integer): integer;
begin
  for var i := 1 to 20000000 do ; // simulate work
  result := n*n;
end;

begin
  // two workers run while the main thread keeps going
  var a := async slowSquare(7);
  var b := async slowSquare(9);
  writeln('workers spawned, main thread free');
  writeln($'a + b = {await a + await b}');

  // block form captures locals by reference
  var hits := 0;
  var w := async begin
    for var i := 1 to 1000 do inc(hits);
  end;
  await w;
  writeln($'hits = {hits}');

  // cancellation is cooperative
  var loop := async begin
    while not Cancelled do ThreadSwitch;
  end;
  loop.Cancel;
  await loop;
  writeln($'loop done = {loop.Done}, cancelled = {loop.Cancelled}');

  // a worker exception re-raises at the first await
  var bad := async begin
    raise Exception.Create('boom');
  end;
  try
    await bad;
  except
    on e: Exception do writeln($'caught: {e.Message}');
  end;
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
workers spawned, main thread free
a + b = 130
hits = 1000
loop done = TRUE, cancelled = TRUE
caught: boom
```
