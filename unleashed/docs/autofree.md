# Scoped Cleanup - `defer`, `autofree`, scoped `with`

Scope-based resource management without the `try..finally` boilerplate: write the cleanup next to the acquisition, once, and stop indenting entire routine bodies into `finally` pyramids. Built on top of Pascal's existing `try..finally` and integrated with the `with` statement.

Modeswitch: `autofree`, enabled by default in `{$mode unleashed}`. Elsewhere:

```pascal
{$mode objfpc}
{$modeswitch autofree}
```

Two keywords are reserved when the modeswitch is active - `defer` and `autofree` - plus a small extension to `with`.

## `defer STATEMENT;`

Register a statement to fire at the end of the enclosing `begin..end` block, in **LIFO** order. Argument expressions are evaluated **at exit**, not at registration - the deferred call sees the variable's last value.

```pascal
begin
  lock.Enter;
  defer lock.Leave; // fires no matter how we exit

  AssignFile(f, 'x.txt');
  Reset(f);
  defer CloseFile(f);

  defer writeln('done'); // any statement, not just cleanup

  // a multi-statement defer needs begin..end
  defer begin
    stateManager.Pop;
    log('exit');
  end;
end;
```

### When defers fire

The scope is the enclosing `begin..end` block (or a scoped-`with` body). Defers run on:

- normal end of the block;
- `exit` / `exit(value)` - `result` is computed first, then defers, then the return;
- `break` / `continue` (the loop body's defers run before the jump);
- `goto` out of the block;
- an exception propagating out of the block.

They do **not** fire on `Halt()`, `RunError()`, or termination by signal - those bypass the `try..finally` machinery.

### LIFO order

```pascal
defer writeln('A');   // fires 3rd
defer writeln('B');   // fires 2nd
defer writeln('C');   // fires 1st
writeln('body');
// output: body, C, B, A
```

### Conditional registration

Only defers whose registration site is actually reached fire. If a `raise` happens between two defers, only the first is registered:

```pascal
defer writeln('first');
raise EBoom.Create('!');
defer writeln('second'); // never registered, never fires
// output: first
```

### Evaluation timing - at exit, not at registration

```pascal
var v := 1;
defer writeln('v = ', v);
v := 2;
v := 3;
// output: v = 3
```

For a snapshot, capture into a local before registering:

```pascal
var snapshot := v;
defer writeln('snapshot = ', snapshot);
```

### Per-iteration cleanup in loops

The scope is `begin..end`, not the routine - so per-iteration cleanup needs an explicit block in the loop body:

```pascal
for var i := 1 to 3 do begin
  defer writeln('iter ', i, ' cleanup'); // fires every iteration
  writeln('iter ', i);
  if i = 2 then break;
end;
// output: iter 1 / iter 1 cleanup / iter 2 / iter 2 cleanup
```

A bare `for ... do defer foo;` (no `begin..end`) registers the defer in the enclosing block, firing once at the end of *that* block.

### Forbidden contexts

- `defer defer X;` - a `defer` cannot be another `defer`'s statement (`` `defer` cannot be the deferred statement of another `defer` ``).
- Inside an `asm..end` block.
- In a routine compiled with `{$IMPLICITEXCEPTIONS OFF}` - defer needs a `try..finally`.

## `autofree EXPR`

Sugar that turns a fresh class instance into a scoped resource. The generated cleanup is `if x<>nil then begin x.Free; x := nil end`, so a manual `x.Free; x := nil;` earlier in the scope makes the auto-cleanup a no-op rather than a double-free.

```pascal
// inline-var (with type inference)
begin
  var list := autofree TStringList.Create;
  list.Add('hello');
end;
// list.Free called here

// existing local
var list: TStringList;
begin
  list := autofree TStringList.Create;
  list.Add('hello');
end;
// list.Free called here

// multiple, freed in LIFO order
begin
  var a := autofree TFoo.Create;
  var b := autofree TBar.Create;
end;
// b.Free, then a.Free
```

A constructor that raises does not double-free: FPC's normal auto-destroy on failed construction still runs, and the auto-Free does not fire on the never-assigned variable.

### Restrictions

- The expression must yield a class derived from `TObject` (`` `autofree` requires a class type derived from TObject ``).
- The LHS must be a plain local or inline variable - fields, globals, array elements, and dereferences are rejected, because the cleanup is scoped to the routine and freeing something whose lifetime exceeds it would be wrong.
- Not allowed as a function-call argument (`foo(autofree T.Create)`) - assign to a local first.

## Scoped `with`

The `with` statement accepts new clause forms under `autofree`. They bind a class instance (or a plain local) that the with-body sees in scope, with optional cleanup.

```pascal
// Form C: inline-var with type inference (with optional autofree)
with var http := autofree TFPHTTPClient.Create(nil) do
  s := http.Get('http://example.com/');

// Form C without autofree: manual lifetime
with var http := TFPHTTPClient.Create(nil) do begin
  defer http.Free;
  s := http.Get('http://example.com/');
end;

// Form D: inline-var with explicit type, optional initializer
// no init - stack-allocate a record local the body fills in:
with var t: TPoint do begin
  t.a := 10;
  t.b := 20;
  process(t);
end;

// aggregate-literal init (record / array):
with var p: TPoint := (a: 1; b: 2) do
  writeln(a, ' ', b); // 1 2

// explicit-type autofree:
with var a: TStringList := autofree TStringList.Create do
  a.Add('hello');
// a.Free called here

// Form B: bind to an existing local
var http: TFPHTTPClient;
with http := autofree TFPHTTPClient.Create(nil) do
  s := http.Get('http://example.com/');

// Form A: hidden holder (methods reachable through the with-symtable)
with autofree TFPHTTPClient.Create(nil) do
  s := Get('http://example.com/');

// Multi-with, mixed forms
with var a := autofree TA.Create, var b := autofree TB.Create, existing_c do
  use(a, b, existing_c);
// LIFO: b.Free, then a.Free
```

Forms C and D differ only in how the type is supplied (inferred from the init vs explicit annotation), mirroring regular inline-var declarations. Form D's initializer is optional; Form C requires one. `autofree` is accepted on every form that has an initializer; aggregate literals on records / arrays reject it (the target is not a class).

A `defer` written inside a scoped-with body is scoped to that `with` (fires before the autofree cleanup), even with a single-statement body:

```pascal
with var t := autofree T.Create do
  defer doCleanup; // doCleanup fires, then t.Free
```

The classic `with X do BODY` (no inline-var, no autofree) is unchanged.

## Unit initialization and finalization

A `defer` written directly in a unit's `initialization` section does not run when that section ends. It runs at the very end of the unit's finalization, so a resource set up during initialization stays usable for as long as the unit is loaded. The same holds for `autofree`, and for the `begin..end` form a unit may use instead of the `initialization` keyword.

```pascal
unit ucache;

{$mode unleashed}

interface

uses Classes;

var
  cache: TStringList;

implementation

initialization
  cache := autofree TStringList.Create;
  cache.Add('warm');

finalization
  cache.SaveToFile('cache.txt'); // cache is still alive here

end.
// cache.Free runs after the finalization body
```

| Where the `defer` sits | When it runs |
|---|---|
| top level of `initialization` | after the whole finalization body, in reverse registration order |
| a nested `begin..end` inside `initialization` | at the end of that nested block |
| top level of `finalization` | at the end of the finalization body |
| a routine or the program body | at the end of its block, as everywhere else |

- The unit's own `finalization` statements run first, the hoisted ones after all of them. Code in `finalization` still sees the objects alive.
- A unit that has initialization defers but no `finalization` section gets one generated, so the deferred statements still run at unload.
- A defer the initialization never reached does not run. The flag that records it is unit level storage and starts out false.
- If the initialization section raises, the RTL does not finalize the unit and the hoisted statements never run. Inside a routine the `try..finally` covers the exception path too, so this is the one place where `defer` is weaker.
- A deferred statement that reads a variable living in a routine frame keeps the block scope it had, because it cannot outlive the frame it reads.

## Lowering

`defer X;` registers an entry in a per-block list; at the end of the block the parser injects a `try..finally` that runs the entries in reverse, each gated on a per-defer boolean flag so only reached registrations fire. `autofree EXPR` desugars to the assignment plus a registered nil-guarded `Free()` defer. A defer at the top level of a unit's initialization section is not lowered into that block at all: the parser hands it to the module, which emits it at the end of the unit's finalization routine, guarded by a unit level flag the initialization sets when it reaches the defer. A scoped `with` with both user defers and `autofree` nests two `try..finally` frames - the autofree cleanup is the outer one, so it runs after any body defers.

## Limitations

- `autofree` not yet allowed as a call argument (`foo(autofree T.Create)`).
- `var x := autofree existing.Create` where `existing` is an instance (not a type) is accepted but wrong - it would `Free()` an instance the scope does not own. Do not do that.
- A manual `defer x.Free` next to `autofree x` does not warn; the nil-guard makes the second Free a no-op (a redundant `x := nil` at scope exit, not a crash).

## Demo

```pascal
program autofree_demo;

{$mode unleashed}

uses Classes, SysUtils;

type
  TResource = class
    name: string;
    constructor Create(const aName: string);
    destructor Destroy; override;
  end;

constructor TResource.Create(const aName: string);
begin
  name := aName;
  writeln($'  open {name}');
end;

destructor TResource.Destroy;
begin
  writeln($'  close {name}');
  inherited;
end;

procedure work;
begin
  var a := autofree TResource.Create('A');
  var b := autofree TResource.Create('B');
  writeln('  using A and B');
  // b closes first (LIFO), then a - even on an exception
end;

procedure withDefer;
begin
  writeln('  step 1');
  defer writeln('  cleanup 1');
  writeln('  step 2');
  defer writeln('  cleanup 2');
  writeln('  step 3');
end;

begin
  writeln('autofree (LIFO close):');
  work;
  writeln('defer (LIFO):');
  withDefer;
  writeln('scoped with:');
  with var list := autofree TStringList.Create do begin
    list.Add('one');
    list.Add('two');
    writeln('  list has ', list.Count, ' items');
  end;
  writeln('done');
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output (verified leak-free under `-gh`):

```
autofree (LIFO close):
  open A
  open B
  using A and B
  close B
  close A
defer (LIFO):
  step 1
  step 2
  step 3
  cleanup 2
  cleanup 1
scoped with:
  list has 2 items
done
```
