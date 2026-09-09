# `match` Statement

Pattern matching with first-match semantics - a superset of `case` for value dispatch. It handles everything `case` does (ordinal labels, ranges) and adds string subjects, a catch-all branch, comma patterns, subject-less condition branches, tuple patterns with wildcards, a fallthrough mode, and an expression form.

Modeswitch: `match`, enabled by default in `{$mode unleashed}`.

## Subject-based matching

```pascal
match x of
  1: writeln('one');
  2: writeln('two');
  3: writeln('three');
end;
```

The subject expression is evaluated once, then compared against each branch pattern with `=`. The first matching branch executes; the rest are skipped.

## Catch-all: `_`, `else`, `otherwise`

```pascal
match x of
  1: writeln('one');
  _: writeln('other');
end;

match x of
  1: writeln('one');
else
  writeln('other');
end;
```

`_` is an unconditional catch-all branch; `else` works identically (with the same statements-till-`end` semantics as in `case`), and `otherwise` is a synonym for `else`. Only one catch-all is allowed in first-match mode - a `_:` branch followed by `else` reports `` `_:` already covers unmatched values, drop trailing `else`/`otherwise` ``. In `match all` the two are distinct constructs - see the fallthrough section below.

### Indenting the catch-all

The catch-all is a branch like any other, so keep it at label level - one indent inside `match`, not level with the `match` keyword. That way a `begin..end` catch-all closes one indent inside the match's own `end` instead of the two `end`s colliding at the same column:

```pascal
match fn of
  'sin': result := Sin(x);
  'cos': result := Cos(x);
  else begin
    log(fn);
    result := 0;
  end;
end;
```

## String matching

```pascal
match s of
  'hello': writeln('greeting');
  'bye':   writeln('farewell');
  _:       writeln('unknown');
end;
```

Strings work as both subject and patterns - the dispatch `case` classically could not do.

## Comma-separated patterns

```pascal
match x of
  1, 2, 3: writeln('small');
  4, 5, 6: writeln('medium');
  _:       writeln('big');
end;
```

Comma-separated patterns are OR'd. `_` may appear as the **last** element of a comma list; the branch then collapses to catch-all, and the explicit values before the `_` stay purely as documentation:

```pascal
match s of
  'x':         writeln('hit x');
  'w', 'a', _: writeln('w, a, or anything else');
end;
```

`_` anywhere else in the list is rejected (`` `_` must be the last pattern in a `match` branch ``) - values after a `_` would be unreachable.

## Range patterns

```pascal
match x of
  1..10:   writeln('low');
  11..100: writeln('mid');
  _:       writeln('other');
end;
```

`lo..hi` matches when the subject is `>= lo` and `<= hi`; a bound sitting at the subject type's natural minimum or maximum drops the always-true half of the check. Ranges combine freely with comma patterns:

```pascal
match x of
  1..3, 7, 9..10: writeln('picked');
  _:              writeln('skipped');
end;
```

## Condition-based matching (no `of`)

```pascal
match
  x > 100: writeln('big');
  x > 10:  writeln('medium');
  x > 0:   writeln('small');
  _:       writeln('non-positive');
end;
```

Without `of` there is no subject - each branch is a boolean expression, and the first true one executes. This is the structured replacement for an `if / else if` ladder.

## Fallthrough: `match all`

```pascal
match all x of
  5: writeln('five');
  5: writeln('also five');
  3: writeln('three');
  _: writeln('always');
end;
```

`match all` executes **every** matching branch, not just the first. Lowered to independent if-statements inside a `repeat..until true` shell.

`_` is a wildcard branch: it matches any value, so it always executes, in its listed position after the branches above it.

### `else` / `otherwise` as a no-match fallback

```pascal
match all cmd of
  'start': StartJob;
  'stop':  StopJob;
  else writeln('unknown command');
end;
```

In `match all`, `else` (or its synonym `otherwise`) executes only when **no** branch matched. If at least one branch matched, the fallback is skipped - even when several branches matched and all of them ran.

`_` counts as a match. A `match all` containing both a `_:` branch and a trailing `else`/`otherwise` still compiles, but the fallback can never run - the compiler warns `` `_:` always matches, `else`/`otherwise` branch never executes ``.

### `leave`

```pascal
match all x of
  5: begin writeln('five'); leave; end;
  5: writeln('not reached');
  else writeln('not reached');
end;
```

`leave` exits the `match all` block early: the remaining branches and the `else`/`otherwise` fallback are skipped. Since `leave` can only run inside a branch that already matched, the fallback would not have run anyway.

## Tuple patterns with `_` wildcards

```pascal
match p of
  (0, 0): writeln('origin');
  (0, _): writeln('on Y axis');
  (_, 0): writeln('on X axis');
  _:      writeln('other');
end;
```

Available in subject-based mode when the subject is a tuple. `_` inside a tuple pattern skips that field; every non-wildcard field is compared with `=` and the results are AND'd. `(_, _)` matches any tuple of that shape.

Tuple patterns combine with commas like any other pattern: the branch matches when any listed tuple matches. A bare `_` may close the list and turns the branch into a catch-all:

```pascal
function closes(open, close: char): boolean;
begin
  result := match (open, close) of
    ('(', ')'), ('[', ']'), ('{', '}'): true;
    _: false;
  end;
end;
```

## Match as expression

```pascal
var s := match x of
  1: 'one';
  2: 'two';
  _: 'other';
end;

var lbl := match
  x > 100: 'big';
  x > 10:  'medium';
  _:       'small';
end;
```

Each branch yields a value; the result type unifies across branches with the same promotion rules as [if-expressions](statement-expressions.md). Both the subject-based and the condition-based form work, and both close with `end`.

A match expression must be exhaustive: without a `_` / `else` / `otherwise` branch it reports `` `match` expression needs `_:`, `else` or `otherwise` to cover unmatched values ``.

## Not supported

- `where` guards on patterns - use the condition-based mode (no `of`) or nest an `if`.
- Binding / capturing matched values into named variables.

## Demo

```pascal
program match_demo;

{$mode unleashed}

function describe(p: (integer, integer)): string;
begin
  result := match p of
    (0, 0): 'origin';
    (0, _): 'on Y axis';
    (_, 0): 'on X axis';
    _: 'in the field';
  end;
end;

begin
  // condition-based match as an expression
  for var i := 1 to 15 do begin
    var line := match
      (i mod 15) = 0: 'FizzBuzz';
      (i mod 3) = 0: 'Fizz';
      (i mod 5) = 0: 'Buzz';
      _: $'{i}';
    end;
    write(line, ' ');
  end;
  writeln;

  // string dispatch with comma patterns
  for var cmd in ['start', 'help', 'quit'] do
    match cmd of
      'start', 'run': writeln('starting');
      'stop', 'quit': writeln('stopping');
      _: writeln($'unknown command "{cmd}"');
    end;

  // tuple patterns with wildcards
  writeln(describe((0, 5)), ' / ', describe((3, 4)));
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
1 2 Fizz 4 Buzz Fizz 7 8 Fizz Buzz 11 Fizz 13 14 FizzBuzz
starting
unknown command "help"
stopping
on Y axis / in the field
```
