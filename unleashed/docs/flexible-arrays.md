# Flexible Array Members

Declare a record with a variable-length tail: `data: array[] of T` as the last field (the C99 flexible-array-member layout). The record header has a fixed size, the tail extends as far as the allocation says it does, and `sizeof(rec)` reports only the fixed part.

Modeswitch: `flexiblearrays`, enabled by default in `{$mode unleashed}`. Elsewhere:

```pascal
{$mode objfpc}
{$modeswitch flexiblearrays}
```

## What it does

A flexible array member (FAM) is the last field of a record, declared with empty brackets and no bound:

```pascal
type
  PMessage = ^TMessage;
  TMessage = packed record
    code: integer;
    len:  integer;
    data: array[] of byte; // flexible array member
  end;
```

The record has the same memory layout as one ending after `len`, plus whatever payload you allocate behind it. There is no separate buffer, no pointer chase, no managed lifetime. The compiler does not track the runtime length, so FAM indexing skips both compile-time and runtime range checks even under `{$rangechecks on}`.

## Allocation and use

The record and its tail live in one block: allocate fixed part plus payload with a single `GetMem()`, write the tail through the FAM field by index, free the whole thing with one `FreeMem()`:

```pascal
var msg: PMessage;
begin
  GetMem(msg, sizeof(TMessage)+1024);
  msg^.code := 42;
  msg^.len := 1024;
  for var i := 0 to 1023 do
    msg^.data[i] := byte(i);
  // ... use msg ...
  FreeMem(msg);
end;
```

`sizeof(TMessage)` returns 8 here (just `code` and `len`). The FAM contributes nothing to the static size, so the allocation math is the obvious `sizeof(rec) + payload` - no off-by-one for a phantom one-element tail.

## Memory layout

```
            +----------+----------+----------+ ... +----------+
GetMem ---> | code (4) | len (4)  | data[0]  |     | data[N]  |
            +----------+----------+----------+ ... +----------+
            ^                     ^
            msg                   msg^.data
            |<-- sizeof(rec) -->|<---- payload bytes ---->|
```

The FAM starts at the offset natural alignment gives the element type after the last fixed field. For `array[] of int64` after a 4-byte field on a 64-bit target, the compiler inserts the usual 4 padding bytes before the FAM, exactly as for any other field.

## Why a FAM and not the alternatives

Three patterns are common today; each loses something the FAM keeps:

| Pattern | Problem |
|---|---|
| `data: array[0..0] of byte` (the "struct hack", `ANYSIZE_ARRAY`) | `{$rangechecks on}` rejects every access past index 0; `sizeof()` is one element too large; the padding story is implicit |
| `data: PByte` to a separate buffer | two allocations, two frees, an extra indirection per access, and the single-block layout Win32 structures demand is gone |
| `case integer of 0: (data: array[0..high(integer)-X] of byte)` | `sizeof()` rolls over, `high()` lies, and the compiler has no idea of the actual extent |

The FAM gives the inline layout, honest `sizeof()`, a working `{$R+}` for the rest of the program, and a single allocation - in one feature.

## Restrictions

Enforced at parse time, each with a dedicated diagnostic:

1. **The FAM must be the last field.** `A flexible array member must be the last field of the record`. The rule spans the whole record body: no instance field or variant part may follow the FAM after a visibility keyword, a method or a `class var` group either. A `class var` declared after the FAM is fine, it is static storage outside the layout.
2. **At least one fixed field must precede it.** `A record with a flexible array member must have at least one other field`.
3. **One FAM per record, one identifier per FAM declaration.** `one, two: array[] of byte` is rejected like a second FAM would be.
4. **Plain `record` instance fields only.** Not in a `class`, `object`, variant part, `union` variant, `class var`, or `threadvar`.
5. **A FAM-record cannot be embedded in another structured type** - use a pointer field instead. This covers a plain field, a tuple element and an `embed` of a FAM-record inside a `union`.
6. **A FAM-record cannot be an array element type** - the per-element size would be undefined. Static, dynamic and open array parameters alike.
7. **A FAM-record cannot be a stand-alone variable, value parameter, or function result.** `Variable of type "T" with flexible array member must be allocated dynamically (use a pointer)`. Stand-alone means any storage the compiler would have to size itself: a `var` or `threadvar` section, an inline `var` (declared or inferred, also `with var`), a `static` or `threadstatic` variable, a typed constant, a tuple element. Function result covers routines, procedural types and function references.

Reference parameters (`var`, `const`, `constref`, `out`) of FAM-record type stay legal - they pass an address, no copy involved. Pointer-to-FAM-record (`PFamRec`) is unrestricted: field of any type, array element, any parameter kind, function result.

### Composition

With `composablerecords`, a FAM-record can be the **last** member of another record through `embed` or an inline anonymous `record ... end` block. The surrounding record then ends in the FAM and is a FAM-record itself: it obeys restrictions 5 to 7 and is allocated the same way.

```pascal
type
  TPayload = record
    len: integer;
    data: array[] of byte;
  end;

  PPacket = ^TPacket;
  TPacket = record
    id: integer;
    embed TPayload; // TPacket is now a FAM-record, data is its tail
  end;

var p: PPacket;
begin
  GetMem(p, sizeof(TPacket)+16);
  p^.id := 1;
  p^.len := 16;
  p^.data[15] := 0;
  FreeMem(p);
end;
```

A field after such an `embed` is rejected by restriction 1 like a field after the FAM itself.

### Methods and managed fields

A FAM-record can have methods, properties, operators and management operators; they change nothing in the layout. Managed fields (strings, dynamic arrays, interfaces) and a managed FAM element type are allowed, but the record is created with `GetMem()` and released with `FreeMem()`, so nothing initializes or finalizes it automatically. Call `Initialize()` / `Finalize()` on the record yourself (this also runs the `Initialize` / `Finalize` management operators) and `FillChar()` the tail before writing managed elements into it.

## Use cases

- **Win32 structures.** `BITMAPINFO`, `LOGPALETTE`, `TOKEN_GROUPS`, `TOKEN_PRIVILEGES`, `SOCKET_ADDRESS_LIST`, and friends declare trailing arrays as `array[0..0]` / `ANYSIZE_ARRAY` today, with all the problems above.
- **Network frames.** Packets, WebSocket frames, MQTT messages, IPC payloads - a header carries a length, the body follows in the same block.
- **File formats.** BMP, WAV chunks, custom containers with header plus inline body.
- **Inline buffers in records.** A payload at the node's tail avoids a second allocation and improves cache locality.

## Comparison with `array of T`

A FAM is not a dynamic array; they share no runtime machinery:

| | `array of T` (dynamic) | `array[] of T` (FAM) |
|---|---|---|
| Storage | separate heap block via a managed pointer | inline tail of the record, one block with the header |
| Lifetime | reference-counted, automatic | manual, freed with the containing block |
| `SetLength()` | resizes | not applicable - size fixed by the `GetMem()` |
| `Length(x)` | element count | `0` (the static length); track the real count in a fixed field |
| Range checking | runtime check | none |
| Overhead per record | pointer + refcount block | zero |

Want a managed, resizable array living elsewhere in memory - use `array of T`. Want a fixed-shape tail inline behind the header - use a FAM.

## Debugger view

A FAM has no statically known length, so without help a debugger shows an empty array. The compiler emits a DWARF upper-bound expression that reads the element count at runtime from a sibling ordinal field; fpdebug and gdb evaluate it on every refresh and pretty-print the FAM with the right count.

By default the **last ordinal field declared before the FAM** is picked automatically - the typical "header + count + payload" layout needs no annotation:

```pascal
type
  PTokenPrivileges = ^TTokenPrivileges;
  TTokenPrivileges = packed record
    PrivilegeCount: DWORD;
    Privileges:     array[] of LUID_AND_ATTRIBUTES; // auto-binds PrivilegeCount
  end;
```

If the count is not the last ordinal field before the FAM, bind it explicitly with the `count` clause:

```pascal
type
  TBatch = packed record
    count:    DWORD;
    reserved: DWORD;
    items:    array[] of TItem count count;
  end;
```

The named field must be a field of the same record, declared before the FAM, of an ordinal type sized 1 / 2 / 4 / 8 bytes. Misuse diagnostics:

- `Count field "X" is not a field of this record`
- `Count field "X" must be of an ordinal type`
- `Count field "X" must be declared before the flexible array member`

This is purely a debug-info detail: no runtime cost, no layout change, no effect on `sizeof()` or indexing, and range checks stay off for FAM accesses either way. DWARF only (`-gw2` and `-gw3`); CodeView and Stabs are unaffected.

## PPU streams

The FAM flag (`ado_IsFlexibleArray`) is part of `arrayoptions`, which PPU files already stream. A FAM-record declared in one unit behaves identically when used from another - same `sizeof()`, same disabled range check.

## Limitations

- No auto-promotion to pointer - where a FAM-record by value is illegal, you write `PFamRec` yourself.
- `Length()` on the FAM returns 0, not the payload count - track the count in a fixed field (which also feeds the debugger view).
- The FAM tail is not zero-initialized - use `FillChar()` when needed.
- No `for elem in fam do` enumeration - without a known length the loop has no termination condition.

## Demo

```pascal
program fam_demo;

{$mode unleashed}
{$rangechecks on}

type
  PMessage = ^TMessage;
  TMessage = packed record
    code: integer;
    len: integer;
    data: array[] of byte; // flexible array member
  end;

function newMessage(code: integer; const payload: array of byte): PMessage;
begin
  GetMem(result, sizeof(TMessage)+length(payload));
  result^.code := code;
  result^.len := length(payload);
  for var i := 0 to high(payload) do result^.data[i] := payload[i];
end;

procedure dump(msg: PMessage);
begin
  write($'code={msg^.code} len={msg^.len} bytes:');
  // FAM indexing is range-check-free even under rangechecks on
  for var i := 0 to msg^.len-1 do write(' $', HexStr(msg^.data[i], 2));
  writeln;
end;

begin
  writeln($'sizeof(TMessage) = {sizeof(TMessage)} (fixed part only)');
  var msg := newMessage(7, [$DE, $AD, $BE, $EF]);
  writeln($'length(msg^.data) = {length(msg^.data)} (static length, not payload)');
  dump(msg);
  FreeMem(msg);
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
sizeof(TMessage) = 8 (fixed part only)
length(msg^.data) = 0 (static length, not payload)
code=7 len=4 bytes: $DE $AD $BE $EF
```
