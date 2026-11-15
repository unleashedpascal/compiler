# `for ... step`

`step N` clause in `for` loops advances the counter by an arbitrary positive amount on each iteration. Works with both `to` and `downto`, and with inline `var` counters.

Modeswitch: `forstep`, enabled by default in `{$mode unleashed}`; opt in elsewhere with `{$modeswitch forstep}`.

## Basic use

```pascal
for i := 1 to 10 step 2 do
  write(i, ' '); // 1 3 5 7 9

for i := 20 downto 1 step 3 do
  write(i, ' '); // 20 17 14 11 8 5 2

for var k := 5 to 50 step 5 do
  write(k, ' '); // 5 10 15 ... 50
```

The step expression must be ordinal and positive. Use `downto` for descending loops - the step itself is always positive, and a non-positive constant is a parse error.

## Single evaluation

The step expression is evaluated **once** before the loop starts, so calls with side effects fire exactly one time - the same way the classic for-loop treats its upper bound:

```pascal
for i := 0 to 12 step computeStep do
  use(i); // computeStep called exactly once
```

## `step` is a context-sensitive keyword

`step` is **not** a reserved token. The parser checks for it in one position only: right after the `to` / `downto` expression and before `do`. Anywhere else `step` stays an ordinary identifier, so existing code keeps compiling:

```pascal
var step: integer = 5; // OK - a variable named step

function step: integer; // OK - a function named step

type TFoo = record step: integer end; // OK - a record field named step

for i := 1 to step do use(i); // OK - the upper bound is the variable

for i := 0 to step step 1 do use(i); // OK - first `step` is the upper bound, second is the keyword
```

The SynEdit highlighter in Unleashed Pascal IDE mirrors this: only the keyword position lights up.

## Constant `step 1` folds back

A literal `step 1` is dropped during `simplify`, so the loop reverts to the regular for-loop code path and keeps every existing optimization (range-check elision, unrolling, ...). Only `step N` for `N >= 2`, or a non-constant step, takes the dedicated path.

## Generated code

A surviving step lowers the for-loop to a while-loop with the increment at the **start** of each pass, guarded by a first-iteration flag:

```
steptemp := step;  totemp := to;  i := from;  first := true;
while true do begin
  if first then first := false
  else if totemp - i < steptemp then begin
    i := i + steptemp;             // - steptemp for downto
    break;
  end else i := i + steptemp;      // - steptemp for downto
  if i > totemp then break;        // < totemp for downto
  body;                            // continue lands on the next pass
end;
```

`totemp - i` (`i - totemp` for `downto`) is the distance left to the bound. It is computed as an unsigned number of the counter's size, so it is exact for every counter type and never wraps. The loop stops as soon as the next step would go past the bound, which also covers a bound at the very end of the counter's type: `for var b: byte := 0 to 255 step 55 do` visits 0, 55, 110, 165, 220 and stops.

This shape lets every control-flow construct behave as in a regular for-loop:

- `continue` jumps to the always-true while-condition; the next pass runs the increment, the range check, then the body. No infinite loop.
- `break` exits cleanly; the counter holds the value at break time.
- `exit` and `raise` propagate normally; no temporaries to clean up.

Cost: one boolean temp plus one branch per iteration.

## Counter value after the loop

Unleashed mode preserves the for-loop counter after the loop (see [tweaks.md](tweaks.md)). With `step`, the guarantee is "last assigned value" - and because the lowering advances the counter *before* the range check, a natural exit leaves the **first value past the bound**, not the last one the body saw:

```pascal
for i := 1 to 10 step 4 do ; // body sees 1, 5, 9
{ i = 13 after the loop (9 + step) }

for i := 20 downto 1 step 3 do ; // body sees 20, 17, ..., 2
{ i = -1 after the loop (2 - step) }

for i := 1 to 10 step 4 do
  if i = 5 then break;
{ i = 5 - break keeps the exact value }
```

When the post-loop value matters, prefer `break` (exact), or derive the last body value as `i - step` (`i + step` for `downto`) after a natural exit.

The first value past the bound may not fit in the counter's type. The counter then wraps around, while the loop itself still stops at the right place:

```pascal
var b: byte;

for b := 0 to 250 step 50 do ; // body sees 0, 50, ..., 250
{ b = 44 after the loop (250 + 50 = 300 wraps to 44) }
```

`i - step` still gives the last body value here, as long as it is computed in the counter's type (`byte(b - 50) = 250`).

## Type rules

The step expression must be ordinal; the compiler picks the wider of the step type and the counter's range type for the increment arithmetic.

| Counter type | Step | Status |
|---|---|---|
| integer of any width (`byte` ... `int64`) | any positive integer expression | works |
| enum | positive integer (ordinal distance) | works: `for var d := dMon to dFri step 2 do` visits every other value |
| `char` | - | not supported: rejected with `Illegal type conversion: "ShortString" to "AnsiChar"` |

Note the inline-var inference gotcha: `for var ch := 'a' to 'z' do` infers a **string** counter (char literals promote to string under inference) - a char counter needs the explicit type, `for var ch: char := 'a' to 'z' do`, and takes no `step`.

## Errors

| Message | Trigger |
|---|---|
| `Step value must be a positive integer` | constant `step 0` or `step -N` |
| `Step expression must be of ordinal type` | step is a real / string / pointer expression |
| `Step is not allowed in for-in loops` | `step` after a `for ... in` collection |

With the modeswitch off (`{$modeswitch forstep-}`), `step` in a for-header is not recognized at all and the parser reports `Syntax error, "DO" expected but "identifier STEP" found`.

## Edge cases

| Case | Behavior |
|---|---|
| `for i := 1 to 5 step 100 do` | body runs once (`i = 1`), then `1 + 100 > 5` exits |
| `for i := 10 to 1 step 2 do` | empty range, body never runs |
| `for i := 5 to 5 step 3 do` | single iteration (`i = 5`) |
| `for var b: byte := 0 to 250 step 50 do` | last step lands exactly on the bound: body sees 0, 50, ..., 250, then exits; `250 + 50` does not fit in a `byte`, the loop still stops |
| `for var b: byte := 0 to 255 step 55 do` | bound is `High(byte)`: body sees 0, 55, 110, 165, 220, then exits |
| `for var b: byte := 255 downto 0 step 50 do` | bound is `Low(byte)`: body sees 255, 205, ..., 5, then exits |
| `for var i: int64 := Low(int64) to High(int64) step High(int64) do` | distance to the bound is wider than `High(int64)`: body sees `Low(int64)`, -1, `High(int64) - 1`, then exits |
| step from a runtime variable holding `0` | the counter never advances - infinite loop; no compile-time check is possible, prefer constants |
| nested for-step loops | each level keeps its own step and counter |

`step` also composes with `for parallel` loops - see [parallelfor.md](parallelfor.md).

## Demo

```pascal
program for_step_demo;

{$mode unleashed}

type
  TDay = (dMon, dTue, dWed, dThu, dFri);

var
  calls: integer = 0;

function stride: integer;
begin
  inc(calls);
  result := 4;
end;

begin
  // every third number: 3 + 6 + ... + 99
  var sum := 0;
  for var i := 3 to 99 step 3 do sum += i;
  writeln($'sum of multiples of 3 up to 99: {sum}');

  // countdown by 25
  write('launch in:');
  for var t := 100 downto 0 step 25 do write(' ', t);
  writeln;

  // enum counters advance by ordinal distance
  write('every other day: ');
  for var d: TDay := dMon to dFri step 2 do write(d, ' ');
  writeln;

  // the step expression is evaluated once, before the loop starts
  var hits := 0;
  for var i := 0 to 20 step stride do inc(hits);
  writeln($'0..20 step stride(): {hits} iterations, stride evaluated {calls} time(s)');
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
sum of multiples of 3 up to 99: 1683
launch in: 100 75 50 25 0
every other day: dMon dWed dFri
0..20 step stride(): 6 iterations, stride evaluated 1 time(s)
```
