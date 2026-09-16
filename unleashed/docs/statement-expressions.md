# Statement Expressions

Use `if`, `case`, and `try` as expressions that yield a value. The value is computed where it is consumed - no single-use temporaries, no `result := ...` branch dance.

Modeswitch: `statementexpressions`, enabled by default in `{$mode unleashed}` and `{$mode delphi}`. Elsewhere:

```pascal
{$mode objfpc}
{$modeswitch statementexpressions}
```

(`match` has an expression form too - it lives with the rest of match in [match.md](match.md).)

## `if` expression

```pascal
var s := if x > 0 then 'positive' else 'non-positive';
```

Both branches are single expressions of compatible types; the `else` branch is required. There is no closing `end`. Only the taken branch is evaluated - side effects in the other branch never fire:

```pascal
var s := if useCache then cached else loadFromDatabase;
// loadFromDatabase is called only when useCache is false
```

Chaining reads like a cascade:

```pascal
var s := if x > 100 then 'large' else if x > 10 then 'medium' else 'small';
```

## `case` expression

A `case` expression always closes with `end`, like the statement form:

```pascal
var s := case day of
  1: 'Monday';
  2: 'Tuesday';
  3: 'Wednesday';
else
  'other'
end;
```

`otherwise` works in place of `else`. The semicolon after the last branch is optional: `else 'other'; end` and `else 'other' end` are the same.

The `else` branch may be left out only when the labels cover every value of the subject type:

```pascal
var s := case flag of
  true:  'yes';
  false: 'no';
end;
```

Anything less than full coverage without `else` reports `Statement expression does not handle all cases, an else branch is required`. A string subject has no enumerable range, so string `case` expressions always need the `else` branch.

Ranges and comma lists work exactly as in a `case` statement:

```pascal
var s := case x of
  0:    'zero';
  1..9: 'single digit';
else
  'large'
end;
```

An empty branch body (`'a': ;`) is rejected - every branch must be an expression.

## `try`-`except` expression

Evaluates the expression; if it raises, the fallback after `except` becomes the value. Closes with `end`:

```pascal
var s := try risky except 'fallback' end;

// with exception type filters and a final catch-all
var s := try risky except on e: EConvertError do 'convert error' else 'other error' end;
```

`on` handlers must be followed by an `else` branch, since a filtered handler alone leaves some exceptions without a value; leaving it out reports `Statement expression does not handle all cases, an else branch is required`.

`try`-`finally` is not available as an expression - `try x finally ... end` reports `try..finally cannot be used as an expression`.

## Type unification

All branches must yield compatible types; the result type unifies them:

```pascal
var s := if b then 'hello' else 'world';        // String
var i := case x of 1: 10; 2: 20; else 30 end;   // integer
var x := if b then 42 else 'hello';             // Error: Incompatible types
```

| Branches | Result |
|---|---|
| two string literals | `String` (AnsiString under `$H+`, ShortString under `$H-`) |
| char and string | the string type |
| short / ansi / wide / unicode mix | the wider carrier (`WideString` or `UnicodeString` wins) |
| two shortstrings of different length | the longer one |
| two integers | a common integer type that holds both ranges, regardless of branch order |
| integer and float | the float |
| two floats | the wider float |
| two classes | their nearest common ancestor |
| `nil` and a class | the class |
| two object types | the common ancestor object |
| two interfaces | the common ancestor interface |
| anything and `Variant` | `Variant` |

```pascal
var big: int64 := 1 shl 40;

var a := if cond then 0 else big;      // int64-wide: holds big untruncated
var b := if cond then 3.5 else big;    // float
var c := if cond then -1 else 100000;  // LongInt (covers both)

var s: TStream := if cond then TStringStream.Create('') else TMemoryStream.Create; // TStream
var t: TStream := if cond then nil else TMemoryStream.Create;
```

## Anonymous functions as branches

A branch may be an anonymous function or procedure. The expression then has no type of its own: it takes the type of the procedural variable or function reference it is assigned or passed to, and every branch must convert to that type.

```pascal
type
  TIntFunc = reference to function(a: integer): integer;

var f: TIntFunc := if double then
                     function(a: integer): integer begin result := a * 2; end
                   else
                     function(a: integer): integer begin result := a + 1; end;
writeln(f(10));
```

The same works in `case` and `try` expressions and as a call argument. Assigning such an expression to anything else (a `pointer`, a string) reports `Anonymous functions in a statement expression require a procedural variable or function reference type`.

## Array and set constructors as branches

A bare `[...]` constructor in a branch yields a dynamic array, so an inferred variable or a function result gets an array:

```pascal
var arr := if positive then [1, 2, 3] else [-1, -2, -3];   // array of integer
var empty := if flag then [shHigh] else [];                // array of TShade, length 0 or 1
```

When the consumer is a set (assignment to a set variable, a set-typed parameter or property, an operand of a set operator), the branches are read as set constructors instead:

```pascal
var shades: TShades := if flag then [shLow, shHigh] else [];
if count(if flag then [shLow] else []) = 1 then ...
shades := shades + (if flag then [shMid] else []);
```

## Where they can appear

Anywhere an expression is expected:

```pascal
writeln(if b then 'yes' else 'no');                  // argument
arr[if i > 0 then i else 0] := value;                // array index
foo(case mode of 1: 'fast'; else 'slow' end);        // argument
var x := 1+(if b then 10 else 20);                   // sub-expression (parenthesize)
writeln($'{if score >= 60 then 'pass' else 'fail'}');// interpolation placeholder
Format('%d (%s)', [n, if odd(n) then 'odd' else 'even']); // array of const
```

## Every branch is a single expression

A branch is one expression - not a statement, not a block. Two consequences:

**No `begin..end` branches.** A branch cannot contain declarations or multiple statements; `if c then begin ... end else ...` in expression position reports `Illegal expression` at the `begin`. Hoist the work into a function (or compute the pieces in inline vars above the expression) when a branch needs more than one step.

**No value-less statements as branches.** `raise`, `exit`, `Halt()`, `break`, `continue`, `goto`, and bare procedure calls do not produce a value, so they are rejected (`Illegal expression`):

```pascal
// rejected: raise is a statement, not an expression
result := case n of
  1: 'one';
  2: 'two';
else
  raise Exception.Create('bad n')
end;
```

For the "this should not happen" pattern keep the statement form:

```pascal
case n of
  1: result := 'one';
  2: result := 'two';
else
  raise Exception.Create('bad n');
end;
```

## Demo

```pascal
program statement_expr_demo;

{$mode unleashed}

uses SysUtils;

type
  TFormatter = reference to function(n: integer): string;

function parsePort(const s: string): integer;
begin
  result := try StrToInt(s) except 8080 end; // bad input collapses to the default
end;

begin
  for var score in [45, 71, 96] do begin
    var grade := case score of
      90..100: 'A';
      75..89:  'B';
      60..74:  'C';
    else
      'F'
    end;
    writeln($'score {score}: grade {grade}, {if score >= 60 then 'pass' else 'fail'}');
  end;

  writeln($'port "8123" -> {parsePort('8123')}');
  writeln($'port "oops" -> {parsePort('oops')}');

  // the branches pick a formatter, the reference gets called later
  var hex := true;
  var fmt: TFormatter := if hex then
                           function(n: integer): string begin result := '$' + IntToHex(n, 2); end
                         else
                           function(n: integer): string begin result := IntToStr(n); end;
  writeln($'255 -> {fmt(255)}');
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
score 45: grade F, fail
score 71: grade C, pass
score 96: grade A, pass
port "8123" -> 8123
port "oops" -> 8080
255 -> $FF
```
