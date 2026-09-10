# Composable Records

A unified mechanism for composing records out of other records and laying out memory the way C11 does. Three things in one feature, gated by a single modeswitch:

1. **Record composition** - embed an existing record into another, anonymously or named, with optional flatten of the embedded fields into the outer scope.
2. **`union`** - C-style untagged memory overlap, replacing the noisy `case TYPE of 0: (...) 1: (...) end;` syntax for the common case where there is no real discriminator.
3. **Anonymous enums as record-scoped types** - inline `kind: (kA, kB, kC);` declarations that put their constants into the record's scope instead of polluting the unit.

Together they make porting C structs (especially WinAPI / POSIX headers heavy with anonymous unions and structs) straightforward, instead of forcing the legacy "duplicate fields across variant branches" workaround.

Feature gated by modeswitch `composablerecords`, enabled by default in `{$mode unleashed}`.

```pascal
{$mode objfpc}
{$modeswitch composablerecords}
```

All existing record syntax keeps working unchanged. The new syntax is strictly additive.

## Why this exists

Stock Pascal records have three structural limitations that hurt every time you port a real-world C struct:

- **The variant section must be the last item.** A C union sitting in the middle of a struct cannot be expressed without duplicating the fields that follow into every variant branch, or without giving up access to one variant entirely. The FPC RTL itself exhibits both workarounds (see [SYSTEM_INFO](#system_info-winapi) and [OVERLAPPED](#overlapped-winapi) below).
- **No way to embed another record's fields.** A C11 anonymous struct (`struct foo { struct bar; ...; }`) flattens `bar`'s fields into `foo`. Pascal forces you to declare `b: TBar;` and dereference through `b` every time, breaking the layout-compatible 1:1 port.
- **`case TYPE of` is verbose and Wirth-era.** For a plain memory overlap it brings a dummy discriminator type, numbered branches `0:`, `1:`, and grouping parentheses - none of which carry semantic weight when there is no real tag.

Composable Records fixes all three without breaking any existing code. New constructs are only recognized when `composablerecords` is active; legacy syntax is still accepted for backward compatibility.

## Composition - three forms

A record can pull fields from another record using one of three forms. The first uses the `embed` keyword, the second a plain `record ... end;`, the third the classic `name: T;`.

### Anonymous embed of an existing type

```pascal
type
  TPoint = record
    x, y: integer;
  end;

  TPixel = record
    embed TPoint;      // anonymous embed - flattens x, y into TPixel scope
    color: longword;
  end;

var
  p: TPixel;
begin
  p.x := 10;           // direct access via flatten
  p.y := 20;
  p.color := $ff0000;
end;
```

The `embed` keyword in a record body introduces an anonymous embed. The next token must be a `record` type name followed by `;`. The fields of that type become accessible directly through the outer record. Methods, properties, and operators of the embedded type are also reachable from the outer record (see [Methods, properties, and operators](#methods-properties-and-operators)).

`embed` is a contextual keyword: if the next token after `embed` is `:` or `,`, it is treated as a regular field name. Stock FPC accepts records with a field named `embed` (`embed: integer;` / `embed, other: byte;`), so those keep parsing unchanged. Outside record bodies `embed` stays a plain identifier.

### Inline anonymous record

```pascal
type
  TVertex = record
    pos: record
      x, y, z: single;
    end;                 // named subfield - regular Pascal, works without composablerecords
    record
      r, g, b, a: byte;  // inline ANONYMOUS record - flattens r, g, b, a into TVertex
    end;
    weight: single;
  end;
```

A `record ... end;` block on its own (no leading field name and `:`) inside another record is an anonymous nested record. Its fields are flattened into the enclosing scope, exactly like an anonymous C11 struct.

The classic named form (`fieldname: record ... end;`) is unchanged - that already works in stock Pascal and the embedded record stays accessible only through the named subfield.

The inline anonymous form also accepts the `packed` and `bitpacked` prefixes, useful for byte-granular and bit-granular layouts inside a union (the PEB / WinAPI struct idiom):

```pascal
type
  THeader = record
    sig: longword;

    packed record                    // packed inline anon - no field padding
      cmd: byte;
      payload_size: word;
      flags: byte;
    end;

    union size 1
      BitField: byte;
      bitpacked record               // bitpacked inline anon - 1 bit per boolean
        IsDirty:   boolean;
        IsLocked:  boolean;
        IsActive:  boolean;
      end;
    end;
  end;
```

All three forms (`record`, `packed record`, `bitpacked record`) work both as a free-standing variant in a record body and inside a `union ... end;` block.

The `bitpacked record` form additionally accepts an `of TYPE` modifier that establishes a default field type for the C-style `name: N;` and `pad N;` shorthand syntax inside - see [Default type and C-style bitfields](#default-type-and-c-style-bitfields).

### Named subfield - standard Pascal, no flatten

The classic `name: T;` form is unchanged. The embedded record stays reachable only through the named field; its members are not flattened into the outer scope. Use this when you want methods, operators, or properties of the embedded type and don't need flat field access.

```pascal
type
  TVec = record
    x, y: single;
    function Length: single;
    class operator + (const a, b: TVec): TVec;
  end;

  TPoint = record
    v: TVec; // named field - access through `p.v.x`, no flatten
    z: single;
  end;

var
  p1, p2: TPoint;
begin
  p1.v.x := 1.0;
  p1.v := p2.v + p1.v;
  writeln(p1.v.Length);
end;
```

If you want flat access, use the anonymous form (`embed TVec;` or `record ... end;`).

### Visibility rules for composition

The intended rule: composition never upgrades visibility. The effective visibility of a flattened field is `min(composition_section_visibility, original_field_visibility_as_seen_from_outer)`.

```pascal
type
  TInternal = record
  private
    secret: integer;    // only same-unit code can see it
  public
    visible: integer;
  end;

  TWrapper = record
  public
    embed TInternal;    // anonymous embed
  end;
```

From the same unit: `wrapper.secret` and `wrapper.visible` both work. From a different unit: only `wrapper.visible` should be accessible - `secret` was private in `TInternal`, so it stays effectively private through the embed.

You cannot bypass `strict private` of the embedded type ever, regardless of where the embed appears.

The composition lookup now runs `is_visible_for_object` on every candidate before returning it. Cases:

- `private` field accessed from the same unit -> reachable through the flat path.
- `private` field accessed from a different unit -> not visible, the flat lookup skips it and the standard "no member" diagnostic fires.
- `strict private` field accessed from anywhere outside the type that owns it -> never visible, same diagnostic.
- `protected` follows the inherited / friend rules - identical to direct access.

Direct named access (`wrapper.TInternal.secret`, or `outer.v.secret` for `v: TInternal`) goes through `searchsym_in_record` and has always respected visibility.

## Memory overlap - `union`

Replaces `case TYPE of 0: (...) 1: (...) end;` for the common case of pure memory overlap.

### Basic syntax

```pascal
type
  TFoo = record
    a: integer;
    union
      record b, c: byte; end;        // variant 1 - anonymous record (flattened: foo.b, foo.c)
      z: word;                       // variant 2 - single field
      ctrl: record k: byte; end;     // variant 3 - named subfield (foo.ctrl.k)
      embed TBar;                    // variant 4 - anonymous embed of TBar
    end;
    d: integer;                      // fields after the union - now legal mid-record
  end;
```

Each line inside `union ... end;` is one variant. Variants overlap in memory; the union's size is the size of the largest variant, aligned per the active `{$packrecords}` setting.

A variant can be:

- An anonymous record (`record fields end;`) - its fields flatten into the outer record scope.
- A single named field (`name: type;`) - the field is accessed by name, no flatten.
- A named subrecord (`name: record fields end;`) - the subrecord is accessed by name, its fields by `outer.name.field`.
- An anonymous embed (`embed TypeName;`) - the embedded type's fields flatten into the outer scope.

### Multi-union per record

A record can have any number of `union` blocks, interleaved with regular fields and other unions:

```pascal
type
  THeader = record
    sig: longword;
    union
      raw: array[0..7] of byte;
      record lo, hi: longword; end;
    end;
    flags: word;
    union
      ctrl: record cmd, status: word; end;
      data: longword;
    end;
    crc: longword;
  end;
```

Each `union` carries its own `end;`, so the boundary is unambiguous and the parser knows to continue reading regular fields after one union closes.

### `union size N` - assert + pad to a fixed size

Append `size <constexpr>` to a `union` keyword to declare an explicit size:

```pascal
type
  TPEBHead = record
    InheritedAddressSpace:    bytebool;
    ReadImageFileExecOptions: bytebool;
    BeingDebugged:            bytebool;
    union size 1
      BitField: byte;
      bitpacked record
        ImageUsesLargePages:          boolean;
        IsProtectedProcess:           boolean;
        IsImageDynamicallyRelocated:  boolean;
        SkipPatchingUser32Forwarders: boolean;
        IsPackagedProcess:            boolean;
        IsAppContainer:               boolean;
        IsProtectedProcessLight:      boolean;
        IsLongPathAwareProcess:       boolean;
      end;
    end;
  end;
```

Semantics:

- If `max(variant_sizes) > N`: **compile error** `Union variants need M bytes but the union was declared "size N"`. Catches accidental growth: if someone adds a 9th `boolean` to the inner bitpacked record, the union now needs 2 bytes and the build breaks immediately at the union declaration site.
- If `max(variant_sizes) <= N`: union is padded to exactly N bytes. Analogous to field-level `size N` which widens a field's slot.

`N` is any const expression evaluated at compile time, including `sizeof()`:

```pascal
union size 64                  // explicit byte count
union size sizeof(TVec)        // size of another type
union size CACHE_LINE * 2      // computed const
```

Without `size`, `union` follows the C rule `sizeof(union) = max(variant_sizes)` - tail growth is silent.

### `union bitsize N` - bit-level assertion

Append `bitsize <constexpr>` to declare a **bit-level** upper bound on the union's variants. Storage is byte-aligned (union is always byte-level), but the assertion catches drift that overflows the requested bit budget.

```pascal
union bitsize 20
  raw: array[0..2] of byte;        { 24 bits = 3 bytes (OK, fits in 3-byte storage) }
  bitpacked record
    a, b, c, d, e, f, g, h: boolean;
    i, j, k, l, m, n, o, p: boolean;
    q, r, s, t: boolean;            { 20 bits OK }
  end;
end;
{ sizeof = ceil(20/8) = 3 bytes }

union bitsize 8
  BitField: Byte;
  bitpacked record
    a, b, c, d, e, f, g, h, i: boolean;   { 9 bits > 8 -> COMPILE ERROR }
  end;
end;
```

Semantics:

- Asserts that no variant exceeds N bits. The check looks **precisely at actual bit usage** in inline bitpacked record variants (peeks the carrier's `databitsize`), not the byte-rounded `sizeof()` - a 20-bit bitpacked record passes `bitsize 20` even though it occupies 3 bytes of storage.
- Union storage size is forced to `ceil(N/8)` bytes (same as the equivalent `union size ceil(N/8)`).
- Stricter sibling of `size N`: where `union size 3` asserts max 24 bits (one byte of every kind), `union bitsize 20` asserts max 20 bits but uses identical 3-byte storage.

Like `size` / `align` / `of`, `bitsize` can appear together with the other modifiers and after `of T`:

```pascal
union of Byte bitsize 8              { default = Byte, max 8 bits }
  BitField: Byte;
  bitpacked record
    a, b, c: 1;
    pad 5;
  end;
end;
```

### `union align N` - force cache-line alignment

Append `align <constexpr>` to bump the union's record-level alignment, bypassing the platform's `recordalignmax` clamp (typically 16 on x86_64):

```pascal
type
  TFalseShareGuard = record
    counterA: int64;
    union align 64 size 64 // 64-byte aligned + 64-byte padded
      v: int64;
    end;
    counterB: int64;
    union align 64 size 64
      v: int64;
    end;
  end;
```

### `union bitalign N` - bit-expressed alignment

Same as `align ceil(N/8)`, kept for symmetry with `record bitalign N`. The union is byte-overlay so bit-level alignment collapses to byte alignment, but accepting the keyword keeps the modifier set uniform between `union` and `record`. Mutually exclusive with `align N`.

```pascal
union of Byte bitalign 32     { = align 4 }
  a: LongWord;
  b: array[0..3] of Byte;
end;
```

### Modifier rules

Strict ordering and uniqueness rules for pre-body modifiers (apply to both `union` and `record` / `bitpacked record`):

1. **`of TYPE` must come first** (right after `union` / `bitpacked record`). Placing it after any other modifier is a compile error.
2. **`size N` and `bitsize N` are mutually exclusive.** Specifying both is a compile error - pick the unit that matches intent.
3. **`align N` and `bitalign N` are mutually exclusive.** Specifying both is a compile error. On `union` (byte-overlay container) `bitalign N` collapses to byte alignment `ceil(N/8)` - accepted for symmetry with `record`, but the bit-level value within a byte boundary has no practical effect there.
4. **Each modifier can appear at most once.** Duplicates are a compile error.
5. **`of TYPE` sets implicit defaults** that explicit modifiers override.

Mod sets:

- **`union`**: `of T`, `size N` XOR `bitsize N`, `align N` XOR `bitalign N`.
- **`record` / `bitpacked record`**: `of T` (only on bitpacked), `size N` XOR `bitsize N`, `align N` XOR `bitalign N`.

Legal combinations:

```
union of T
union of T size N align N
union of T bitsize N align N
union of T size N bitalign N
union of T bitsize N bitalign N
union size N
union bitsize N align N
union bitalign N

bitpacked record of T
bitpacked record of T size N align N
bitpacked record of T bitsize N bitalign N
bitpacked record of T size N bitalign N
record size N align N
record bitsize N bitalign N
```

Illegal:
- `union size N bitsize N` -> `"size" and "bitsize" are mutually exclusive - choose one`
- `record align N bitalign N` -> `"align" and "bitalign" are mutually exclusive - choose one`
- `union align N bitalign N` -> `"align" and "bitalign" are mutually exclusive - choose one`
- `union size N size N` -> `Modifier "size" already specified`
- `union size N of T` -> `"of <type>" must be the first modifier`

### `union of TYPE` - anchor size + align + default type

Shorthand that derives both `size` and `align` from a reference type, plus establishes that type as the **default field type** for the C-style bitfield syntax inside the body (see [Default type and C-style bitfields](#default-type-and-c-style-bitfields) below).

```pascal
union of Byte         { size := sizeof(Byte) = 1, align := AlignOf(Byte) = 1, default = Byte }
union of TVec         { size := sizeof(TVec),     align := AlignOf(TVec),    default = TVec }
union of int64        { size := 8, align := 8, default = int64 }
```

Equivalent to writing `size sizeof(TYPE) align AlignOf(TYPE)` for the size and alignment parts, plus the default-type effect.

Explicit `size` / `align` on the same `union` line **override** the value derived from `of TYPE`:

```pascal
union of Byte size 4              { size = 4 (override), align = 1 (from byte), default = Byte }
union of int64 align 64           { size = 8 (from int64), align = 64 (override), default = int64 }
```

### Why not just keep using `case TYPE of`?

Compare a real WinAPI struct as written in stock FPC vs in `composablerecords`:

```pascal
// stock FPC - case TYPE of, no field allowed after the union
type
  TOverlapped = record
    Internal: ULONG_PTR;
    InternalHigh: ULONG_PTR;
    Offset: DWORD;
    OffsetHigh: DWORD;
    hEvent: HANDLE;
  end;
  // The C union { struct { Offset, OffsetHigh }; PVOID Pointer; } is silently dropped.
  // Pointer-variant access in WinAPI ReadFileEx requires manual cast.

// composablerecords - faithful 1:1 port
type
  TOverlapped = record
    Internal: ULONG_PTR;
    InternalHigh: ULONG_PTR;
    union
      record Offset, OffsetHigh: DWORD; end;
      pPointer: PVOID;
    end;
    hEvent: HANDLE;
  end;
```

No dummy `byte` discriminator type, no `0:` numbering, no extra parentheses, both variants accessible, layout matches C exactly.

### Backward compat - `case TYPE of` still works

The legacy `case TYPE of 0: (...) 1: (...) end;` form keeps compiling. It is accepted but no longer recommended for new code. `union` is the modern path; `case` is kept so that existing units do not need to change.

The tagged variant form (`case kind: TKind of TKind.A: (...); TKind.B: (...);`) is also kept for backward compatibility but discouraged in new code. The recommended pattern for tagged unions is two separate things working together: a discriminator field and a `union` (see [Discriminator + union pattern](#discriminator--union-pattern)).

### Lowering

`union ... end;` is desugared by the parser to the same AST node a `case byte of 0: (variant1); 1: (variant2); ... end;` would produce. No new infrastructure in the type system, the symbol table, the code generator, or RTTI - only a parser-level rewrite. This means existing layout, calling-convention, and PPU-serialization paths continue to work without modification.

## Anonymous enums in records

Stock Pascal already lets you write an anonymous enum as a field type:

```pascal
type
  TFoo = record
    kind: (kA, kB, kC); // anonymous enum - works in any mode
  end;
```

In stock FPC the constants `kA`, `kB`, `kC` leak into the enclosing unit scope - they end up as top-level identifiers and clash with any other `kA` you might want to use elsewhere.

Under `composablerecords`, the constants of an anonymous enum field stay scoped to the record:

- From outside: qualified access only - `TFoo.kA`, `TFoo.kB`, `TFoo.kC`.
- From inside (a method of `TFoo`, or a `with foo do` block): bare names - `kA`, `kB`, `kC`.
- The unit's symbol table stays clean - no leak.

```pascal
type
  TFirst  = record kind: (kA, kB, kC); end;
  TSecond = record kind: (kA, kB, kC); end; // same names, no clash

var
  a: TFirst;
  b: TSecond;
begin
  a.kind := TFirst.kA;
  b.kind := TSecond.kC;
  // a.kind := kA;                              // compile error - kA unqualified
end;
```

Two records with the same enumerator names do not clash because each set lives in its own record's scope.

In stock FPC the same code leaks the enumerators into the surrounding unit scope; that path is suppressed in `composablerecords` mode by skipping the redirect in `tabstractrecordsymtable.insertdef` for `enumdef` and adding the dot-access path for `enumsym` in `factor_read_id`. Named enum types declared at the record level follow the same rule.

### Storage size for anonymous enums

By default an anonymous enum follows the unit's `{$packenum N}` setting (4 bytes if unset). For tightly-packed structs (WinAPI, network protocols, hardware register maps) you usually want 1 or 2 bytes. Two ways:

```pascal
type
  TPacket = record
    kind: (kAudio, kVideo, kCtrl) of Byte;        // 1-byte storage
    code: (cOk, cWarn, cFail) of Word;            // 2-byte storage
  end;
```

`(kA, kB, kC) of T` shrinks the anonymous enum's storage type to `T`. `T` must be ordinal (`Byte`, `Word`, `LongWord`, `Int64`, `ShortInt`, etc.). The compiler validates that every declared enumerator fits in `T`'s ordinal range:

```pascal
type
  TBad = record
    kind: (k0 = 0, k_huge = 300) of Byte; // Error: Enum value 300 does not fit in storage type "Byte" (range up to 255)
  end;
```

Same syntax pattern as `union of T` and `bitpacked record of T` - `of T` everywhere means "anchor the layout / storage on T".

Per-field `size N` / `bitsize N` modifiers are **rejected** on enum fields - the codegen still emits a full-width load/store, so neither shrinking (truncation hazard, would corrupt adjacent fields) nor widening (just dead padding around an unchanged enum) carry any meaningful semantics. Use `(...) of T` to control the enum's storage width. Per-field `align N` / `bitalign N` keep working on enum fields - alignment only ever bumps up, no truncation hazard.

```pascal
type
  TKind = (kA, kB, kC);
  TBad = record
    kind: TKind size 4;     // Error: "size N" is not allowed on enum field of type "TKind" - use `(...) of T` to set the storage type
  end;
  TOk = record
    kind: TKind align 64;   // OK - alignment is independent of storage width
  end;
```

### Discriminator + union pattern

This is the modern replacement for the Pascal-tagged `case TAG: TYPE of`:

```pascal
type
  TPacket = record
    kind: (kAudio, kVideo, kCtrl);                          // discriminator - record-scoped enum
    union
      record codec, channels: byte; sample_rate: word; end; // ~ kAudio
      record codec_video: byte; width, height: word; end;   // ~ kVideo
      ctrl: record cmd, status: word; end;                  // ~ kCtrl
    end;
    crc: longword;
  end;

procedure Process(const p: TPacket);
begin
  match p.kind of
    TPacket.kAudio: writeln('audio codec=', p.codec);
    TPacket.kVideo: writeln('video ', p.width, 'x', p.height);
    TPacket.kCtrl:  writeln('ctrl cmd=', p.ctrl.cmd);
  end;
end;
```

Discriminator and overlap are two orthogonal things; doing them as two orthogonal constructs is cleaner than the legacy "case-of-type" form which conflates them.

## Methods, properties, and operators

The lookup-time fallback resolves **fields, methods, properties, and operators** through the composition list. All four flatten through the same carrier-chain mechanism.

```pascal
type
  TVec = record
    x, y: single;
    function Length: single;
    property Magnitude: single read Length;
    class operator + (const a, b: TVec): TVec;
  end;

  TPoint = record
    embed TVec;
    z: single;
  end;

var
  p1, p2: TPoint;
  v: TVec;
begin
  p1.x := 3; p1.y := 4;
  writeln(p1.Length);          // method, flattened through the embed
  writeln(p1.Magnitude);       // property, flattened through the embed
  writeln(p1.TVec.Length);     // typename-qualified path still works
  v := p1 + p2;                // operator, flattened through the embed; result is TVec
  p1.TVec := p1 + p2;          // assign the operator result back through the embed slice
end;
```

The compiler walks the composition chain the same way it does for fields. The resolved method, property, or operator is reached through the implicit `$compose$N` carrier subscript, with `Self` bound to the embedded slice. The flat form (`p.Length`) and the typename-qualified form (`p.TVec.Length`) compile to the same access.

**Operator result type.** When `+` is found via composition, the operator binds to the embed slice and returns the embed's type (here `TVec`), not the outer record. `v := p1 + p2` works because `v: TVec` matches; `p1 := p1 + p2` is a normal type mismatch (TVec assigned to TPoint) - use `p1.TVec := p1 + p2` to write the result back through the embed slice. The retry handles asymmetric ops (`vec * integer`, only the left record operand is rewritten), symmetric same-type ops (`vec + vec`, both sides rewritten), and cascades into nested embeds (`A embeds B embeds C`, operator defined on `C` is reachable from `A`).

## Generics

A composed record can be generic and use a type parameter as a named subfield:

```pascal
type
  generic TBox<T> = record
    item: T; // named field - access via `b.item.field`
    weight: single;
  end;

  TVec = record
    x, y: single;
  end;

var
  b: specialize TBox<TVec>;
begin
  b.item.x := 1.0;
  b.item.y := 2.0;
  b.weight := 0.5;
end;
```

`union ... end;` inside a generic record body works as well - variants can reference the type parameter via named subfield.

**Restriction in this cut:** `embed T;` where `T` is a generic type parameter is **rejected at the generic declaration site**, before the type argument is known. The parser sees a non-record typesym and emits `Record type expected after "embed"`. To use a generic record member, take the `item: T` named-subfield route. Lifting this restriction (deferring the record-type check to specialization time) is a future enhancement; it requires the embed resolution to participate in generic instantiation rather than parse-time lookup.

- `TBox<T>` itself cannot be used as a type; only its specializations.

## What you cannot embed

To keep semantics clean, only `record` types are accepted:

| Kind            | Anonymous embed                                          |
|-----------------|----------------------------------------------------------|
| `record`        | yes                                                      |
| `class`         | no - it would embed a pointer, not the fields            |
| `object` (legacy) | no - hidden VMT field would mess up layout             |
| `interface`     | no - pointer-based, no field layout to flatten           |
| `helper type`   | no - helpers are not first-class types                   |
| primitive types | no - no fields to flatten                                |
| arrays / pointers | no                                                     |

Using `embed` with a type that is not a record produces a compile error: `Record type expected after "embed"`. Class, legacy object, and interface types are rejected at the embed site - they would embed a pointer (for classes/interfaces) or a hidden VMT field (for objects with methods), neither of which delivers field-flatten semantics. Forgetting `embed` entirely (writing `TName;` solo) falls through to the regular field-declaration path and produces the standard `Syntax error, ":" expected` from the parser.

## Shadowing and name collisions

Composable Records uses **strict declaration-time duplicate detection**, not silent shadowing. When a flattened field name from an `embed` or inline anonymous record collides with another field already in the outer record (direct field, earlier composition, or earlier flattened name), the compiler raises:

```
Duplicate identifier "name" from composition - already present in the surrounding record
```

The new composition is **not registered**. Use a named subfield instead (`name: T;`) which keeps its members in a separate namespace.

```pascal
type
  TRecA = record x: byte; end;
  TRecB = record x: word; end;

  { collision - compile error }
  TBad = record
    embed TRecA;
    embed TRecB;       { error: x already brought in by TRecA }
  end;

  { OK - named subfields, each its own namespace }
  TGood = record
    a: TRecA;          { outer.a.x }
    b: TRecB;          { outer.b.x }
  end;

  { OK - one embed, others named }
  TMixed = record
    embed TRecA;       { outer.x = TRecA.x }
    other: TRecB;      { outer.other.x = TRecB.x }
  end;
```

**Cascade detection.** The check walks the composition chain - if `embed TBase` brings in field `x`, and `TBase` itself embeds `TInner` which also has `x`, the duplicate is caught even though it travels through two levels of indirection.

**Carriers `$compose$N`** (internal slot for anonymous embed / inline anonymous record) are skipped during collision walking - only user-facing field names participate.

## Visibility sections

Composition obeys the same `private` / `protected` / `public` / `published` / `strict private` / `strict protected` sections that work in advanced records. Carriers (the hidden field that owns the storage for an anonymous embed or inline anonymous record) inherit the visibility of the section they appear in.

## `OffsetOf()` and `BitOffsetOf()` intrinsics

Two compile-time intrinsics return the position of a field within a record. Both are enabled together with `composablerecords` because composition makes layout questions far more frequent.

- `OffsetOf(T, field)` returns the **byte** offset.
- `BitOffsetOf(T, field)` returns the **bit** offset.

```pascal
type
  TPacket = record
    a: byte;
    union
      b: word;
      record c, d: byte; end;
    end;
    e: longword;
  end;

const
  OFF_A = OffsetOf(TPacket, a);        // 0
  OFF_B = OffsetOf(TPacket, b);        // 1 (or aligned per packrecords)
  OFF_C = OffsetOf(TPacket, c);        // same as b - inside the union
  OFF_E = OffsetOf(TPacket, e);        // 1 + sizeof(union)
  BIT_E = BitOffsetOf(TPacket, e);     // OFF_E * 8
```

Both accept either Pascal-style `Type.field` or C-style `Type, field` separators (and mixing them within the same call is allowed). Both are constant expressions and can be used in `const` sections, typed constants, inline `var` initializers, and anywhere else a constant is expected. The argument must be a record type and a field reachable from that record (including flattened fields from embeds and union variants).

### Bitpacked records

`bitpacked` records lay out fields at single-bit granularity. The two intrinsics differ in what they do there:

```pascal
type
  TBits = bitpacked record
    a: 0..3;     // 2 bits, bit offset 0
    b: byte;     // 8 bits, bit offset 2 (not on a byte boundary)
    c: 0..7;     // 3 bits, bit offset 10
    d: word;     // 16 bits, bit offset 13
  end;
```

- `BitOffsetOf(TBits, a)` = 0, `(TBits, b)` = 2, `(TBits, c)` = 10, `(TBits, d)` = 13. Always well-defined.
- `OffsetOf(TBits, a)` = 0 (bit offset 0 lands on a byte boundary). `OffsetOf(TBits, b)` is a **compile error** - bit offset 2 has no byte-granular representation. The compiler emits `OffsetOf("b") is not on a byte boundary - use BitOffsetOf instead`.

In non-bitpacked records `BitOffsetOf(T, f)` is always `OffsetOf(T, f) * 8` - the two stay in lock-step. Use `BitOffsetOf()` when you need bit positions for bit-twiddling code, otherwise `OffsetOf()` is the right default and the byte-boundary check catches accidental sub-byte addressing.

## `AlignOf()` and `BitAlignOf()` intrinsics

Two compile-time intrinsics return a type or field alignment, pattern-detected in `factor_read_id` (no RTL stub required, consistent with `OffsetOf()` / `BitOffsetOf()`).

- `AlignOf(T)` returns the alignment requirement of type `T` in **bytes** - the boundary on which a value of that type must be placed for safe access (1 for `byte`, 4 for `integer`, 8 for `int64`, etc.). For records / objects / classes, the type's record-level alignment (max of field alignments).
- `BitAlignOf(T)` returns the same in **bits** - `AlignOf(T) * 8`.

```pascal
const
  ALIGN_INT = AlignOf(integer);          // 4
  ALIGN_I64 = AlignOf(int64);            // 8
  ALIGN_BIT = BitAlignOf(int64);         // 64
```

Both accept either a type or a field reference. For a field reference, the value reflects per-field overrides:

```pascal
type
  TCache = record
    counter: int64 align 64;             // explicit 64-byte alignment
    flag:    boolean;
  end;
const
  CNTR_AL  = AlignOf(TCache.counter);    // 64 - honors `align N`
  FLAG_AL  = AlignOf(TCache.flag);       // 1 - type's natural alignment
  CNTR_BAL = BitAlignOf(TCache.counter); // 512 - CNTR_AL * 8
```

`BitAlignOf()` honors `bitalign N` override on a field (a bit-level alignment for bit-packed contexts):

```pascal
type
  TPack = packed record
    a: byte;
    b: integer bitalign 5;
  end;
const
  B_BAL = BitAlignOf(TPack.b);           // 5 - honors `bitalign N`
  B_AL  = AlignOf(TPack.b);              // 1 - no byte-level override, packed = 1
```

If a field has no per-field override, both intrinsics fall back to the field type's natural alignment.

Use cases:

```pascal
{ static_assert that a record is cache-line aligned }
{$if AlignOf(TCounter) <> 64} {$error not cache-aligned} {$endif}

{ verify field placement matches a C header }
{$if AlignOf(TWinStruct.handle) <> sizeof(pointer)} {$error layout mismatch} {$endif}

{ cross-platform cache line constant }
{$if defined(CPUAARCH64) and defined(DARWIN)}
const CACHE_LINE = 128;     { Apple Silicon }
{$else}
const CACHE_LINE = 64;
{$endif}

type
  TCounter = record v: int64 align CACHE_LINE; end;

{$if AlignOf(TCounter) <> CACHE_LINE} {$error} {$endif}
```

Consistent with C++17 `alignof(T)`, C11 `_Alignof(T)`, Rust `std::mem::align_of::<T>()` - familiar naming and semantics.

### `BitSizeOf()` with `bitsize N` override

The stock FPC `BitSizeOf()` intrinsic reports the actual storage bits a field occupies in a bitpacked context - 3 for `0..7`, 1 for `boolean`, 2 for a 4-variant enum, etc. Under `composablerecords` it also honors the per-field `bitsize N` modifier, so a wide type narrowed by `bitsize N` reports `N`:

```pascal
type
  TBitfield = packed record
    flags: integer bitsize 3; // wide type narrowed to 3 bits
    next:  byte;
  end;
```

`BitSizeOf(TBitfield.flags)` returns **3** (the override), not 32 (the declared `integer`'s natural width). `SizeOf(record.field)` honors per-field overrides the same way: a `size N` modifier makes `SizeOf(record.field)` return `N`, matching the actual slot the field occupies (and the delta you would compute from `OffsetOf()` of the next field). Pure type queries (`SizeOf(TypeName)`, `SizeOf(EnumConstant)`) are unchanged - they report the type's natural size.

```pascal
type
  TR = record
    a: integer size 32; // slot padded to 32 bytes
    b: byte;
  end;

// SizeOf(TR.a)        = 32   (slot, per-field override applied)
// BitSizeOf(TR.a)     = 256  (32 * 8)
// SizeOf(integer)     = 4    (pure type, unchanged)
// OffsetOf(TR.b)      = 32   (matches the slot above)
```

## Per-field sizing and alignment

Four post-suffix modifiers attach to a single field declaration, between the type and any hint directives. They can appear in any order, each modifier at most once, and only have effect inside `composablerecords` (outside the modeswitch they would be parsed as the start of the next field declaration and rejected). Same mutual-exclusion rules as the pre-body modifier set (see [Modifier rules](#modifier-rules)): `size` and `bitsize` are mutually exclusive, `align` and `bitalign` are mutually exclusive.

| Modifier      | Unit  | Effect                                                                 |
|---------------|-------|------------------------------------------------------------------------|
| `align N`     | bytes | force this field's offset to be aligned to N bytes; overrides `{$packrecords}` if set |
| `bitalign N`  | bits  | pad to the next N-bit boundary before placing the field (bit-packed)   |
| `size N`      | bytes | reserve exactly N bytes for this field, regardless of the type's natural size |
| `bitsize N`   | bits  | declare a bit-packed field of exactly N bits (C-style bitfield)        |

`align N` requires N to be a positive power of two. `bitsize N` and `bitalign N` force the containing record into bit-packed alignment, so they only make sense inside an inline record (typically inside a `union` variant) where the bit packing won't interfere with adjacent byte fields.

`size N` and `bitsize N` are **not allowed on enum fields** - the codegen always emits a full-width load/store for the enum's natural type, so a sized slot would either truncate (corrupt adjacent fields) or pad (around an unchanged enum). Use `(...) of T` to control an enum's storage width instead (see [Storage size for anonymous enums](#storage-size-for-anonymous-enums)). `align N` / `bitalign N` keep working on enum fields.

```pascal
type
  // standard alignment override (overrides $packrecords)
  TAligned = record
    a: byte;
    b: longword align 8;       // 7 bytes of padding to land b on 8
  end;

  // explicit padding via size
  TPadded = record
    flag: byte size 4;         // 4-byte slot for a 1-byte value
    next: longword;            // starts at offset 4
  end;

  // C-style bitfield in a union, the PEB example from the design discussion
  TPEBHead = record
    InheritedAddressSpace:    bytebool;
    ReadImageFileExecOptions: bytebool;
    BeingDebugged:            bytebool;
    union
      BitField: byte;
      record
        ImageUsesLargePages:          boolean bitsize 1;
        IsProtectedProcess:           boolean bitsize 1;
        IsImageDynamicallyRelocated:  boolean bitsize 1;
        SkipPatchingUser32Forwarders: boolean bitsize 1;
        IsPackagedProcess:            boolean bitsize 1;
        IsAppContainer:               boolean bitsize 1;
        IsProtectedProcessLight:      boolean bitsize 1;
        IsLongPathAwareProcess:       boolean bitsize 1;
      end;
    end;
  end;
```

The inner anonymous record turns bit-packed on first `bitsize`, and the eight 1-bit booleans share one byte. The surrounding `union` carries the same byte through `BitField` for fast I/O. The whole `TPEBHead` matches the C `_PEB` head 1:1 in layout.

Modifiers survive PPU round-trip, gated by `oo_has_field_sizing` on the parent record def (so older PPUs without the section still load).

## Record pre-body modifiers

Symmetric with `union`: a `record` (any flavor - plain, `packed`, `bitpacked`) can carry the same pre-body modifiers right after the `record` keyword:

```pascal
record [of T] [size N | bitsize N] [align N | bitalign N]
  ... fields ...
end
```

| Modifier      | Effect                                                                |
|---------------|-----------------------------------------------------------------------|
| `of TYPE`     | establishes DEFAULT_TYPE for C-style bitfield syntax (only on `bitpacked record`; rejected on plain `record`) |
| `size N`      | asserts `sizeof(record) <= N` bytes; pads up to exactly N bytes        |
| `bitsize N`   | asserts `databitsize(record) <= N` bits; forces sizeof = `ceil(N/8)` bytes |
| `align N`     | bumps record alignment to N (power of two)                             |
| `bitalign N`  | bit-level alignment - bumps record alignment to `ceil(N/8)` bytes      |

Same rules as on `union` (see [Modifier rules](#modifier-rules)): modifiers appear in any order, each modifier at most once, `size` and `bitsize` are mutually exclusive, `align` and `bitalign` are mutually exclusive, `of T` must come first when present. Coexists with the legacy post-body `end align N` syntax - the larger value wins (the pre-body modifier never lowers an alignment set after `end`).

```pascal
type
  { 1-byte assertion on inline bitpacked record }
  TFlags = bitpacked record of Byte bitsize 8
    a, b, c, d, e, f, g, h: 1;       { adding a 9th -> compile error }
  end;

  { byte-precise size assertion on plain record }
  TFixed = record size 16
    a, b: int64;
  end;

  { the user-asked-for nested scenario - per-variant bit budget }
  TPEB = packed record
    union bitsize 20                  { union total max 20 bits }
      a: bitpacked record of Byte bitsize 9      { variant `a` max 9 bits }
        a, b, c: 1;
      end;
      b: bitpacked record of Byte bitsize 11     { variant `b` max 11 bits }
        a, b, c, d: 1;
      end;
    end;
  end;
```

Errors:
- `Record needs M bytes but was declared "size N"` when contents exceed declared size.
- `Record needs M bits but was declared "bitsize N"` when contents exceed declared bitsize.

The same mechanism the union uses internally - bit-precise peek into the carrier's `databitsize` for inline bitpacked records, byte-rounded for everything else.

## Default type and C-style bitfields

A second-level mechanism on top of `bitpacked record` and `union`: a **default field type** can be attached to either construct via the `of TYPE` modifier. Inside that scope, two shorthand syntaxes become available:

- `name: N;` - "C-style bitfield" - a field of the default type, exactly N bits wide.
- `pad N;` - anonymous padding (N bits, no field name).
- `pad 0;` - alignment marker (pad up to the next default-type storage-unit boundary).

The mechanism mirrors C's `unsigned int flag : 3;` family of declarations, where the type sits on the `struct` member declaration and bit widths sit on each field. Pascal's `of TYPE` lifts the type one level up, the bit widths stay on each field declaration.

### Establishing the default type

```pascal
union of Byte                    { default type = Byte for everything inside }
  BitField: Byte;
  bitpacked record               { inherits Byte from outer }
    a: 1;                        { = Byte bitsize 1 }
    b: 1;
    c: 6;
  end;
end;

bitpacked record of Word         { default type = Word, standalone }
  flags: 4;                      { = Word bitsize 4 }
  count: 12;                     { = Word bitsize 12 }
end;
```

Two anchors are allowed:

| Anchor                          | Effect                                                       |
|---------------------------------|--------------------------------------------------------------|
| `union of T`                    | union size = sizeof(T), union align = AlignOf(T), default = T |
| `bitpacked record of T`         | default = T (size and align come from the bit layout itself) |
| `record of T`                   | **not allowed** - record must be `bitpacked` to host bit-level fields |

### Innermost wins (propagation)

The default-type stack pushes on entering an `of T` scope and pops on exit. An inner block without its own `of T` **inherits** from the nearest enclosing block. An inner `of T2` **overrides** the outer for its own body, then the outer comes back when the inner closes.

```pascal
union of Byte size 1
  BitField: Byte;
  bitpacked record               { inherits Byte }
    a: 1;                        { Byte bitsize 1 }
    bitpacked record of Word     { override: scope = Word }
      x: 4;                      { Word bitsize 4 }
    end;                         { Word scope ends here }
    b: 1;                        { back to Byte bitsize 1 }
  end;
end;
```

### `name: N` syntax

When the surrounding scope is a `bitpacked record` (either directly `of T` or inheriting) and N is an integer literal, `name: N;` declares a field named `name`, of the current default type, occupying exactly N bits. Multi-name allowed:

```pascal
bitpacked record of Byte
  a, b, c: 1;             { three 1-bit fields, all of type Byte }
  d: 5;                   { one 5-bit field of type Byte }
end;
```

`BitSizeOf(record.fieldname)` returns N for these fields. The natural type for reading / writing is the declared default type (a 1-bit `Byte` reads as `Byte` 0 or 1).

Rules:

- `N` must be a positive integer literal (> 0). `name: 0` is rejected.
- `name: N` only fires when (a) the record is bit-aligned (`bitpacked`), (b) a default type is active in this scope. Outside those conditions it falls through to the regular `read_anon_type` path and an integer literal in a type position becomes a parse error.
- Mixed field forms in the same bitpacked record are allowed:

```pascal
bitpacked record of Byte
  full:  Byte;            { regular byte field, 8 bits }
  flag:  1;               { C-style bitfield, 1 bit }
  count: 3;               { C-style bitfield, 3 bits }
  big:   word;            { regular word field, 16 bits }
end;
```

### `pad N` keyword

Anonymous padding bits inside a bitpacked record. Reserves N bits with no accessible field name (the carrier is internally named `$pad$N` with `strict private` visibility). Works with or without an active `of T` default type - the default type only matters for `pad 0` (which uses it as the storage-unit width); plain `pad N` just reserves N bits.

```pascal
bitpacked record of Byte
  a: 3;                   { 3 bits, named `a` }
  pad 5;                  { 5 padding bits, no name }
  b: 8;                   { 8 bits, named `b`, lands at bit 8 }
end;
{ total: 16 bits = 2 bytes }
```

`pad` is a contextual keyword - recognized only in the bitpacked record body when the next token is not `:` or `,`. Records that name a field `pad` keep working:

```pascal
bitpacked record of Byte
  pad: Byte;              { regular field named `pad` - still legal }
end;

bitpacked record of Byte
  pad, x: 2;              { regular bitfields named `pad` and `x`, 2 bits each }
end;
```

### `pad 0` alignment marker

A zero-width pad aligns the next field to the next storage-unit boundary. With an active `of T` default type the granularity is `BitSizeOf(DEFAULT_TYPE)`; without one it falls back to one byte (8 bits). C's `: 0;` analog.

```pascal
bitpacked record of Word          { storage unit = Word = 16 bits }
  a: 5;                           { 5 bits }
  pad 0;                          { align to next 16-bit boundary -> 11 padding bits }
  b: 5;                           { 5 bits starting at bit 16 }
end;
{ total: 16 + 5 = 21 bits = ceil(21/8) = 3 bytes }
```

If the current bit offset is already on a storage-unit boundary, `pad 0` is a no-op.

### Full PEB head example

The motivating use case - faithful port of the Windows `_PEB` header, byte-aligned head fields plus a 1-byte bitfield union sharing the same storage:

```pascal
type
  TPEBHead = record
    InheritedAddressSpace:    bytebool;
    ReadImageFileExecOptions: bytebool;
    BeingDebugged:            bytebool;
    union of Byte size 1                   { default = Byte, assert + pad to 1 byte }
      BitField: Byte;
      bitpacked record                     { inherits Byte }
        ImageUsesLargePages:          1;
        IsProtectedProcess:           1;
        IsImageDynamicallyRelocated:  1;
        SkipPatchingUser32Forwarders: 1;
        IsPackagedProcess:            1;
        IsAppContainer:               1;
        IsProtectedProcessLight:      1;
        IsLongPathAwareProcess:       1;
      end;
    end;
  end;
{ sizeof(TPEBHead) = 4: three 1-byte bytebools + 1-byte union (8x 1-bit = 1 byte). }
```

Adding a 9th `: 1` to the inner record would push it past 1 byte; the `union size 1` constraint raises a compile error, catching the layout drift immediately.

## Aligned heap allocation

`align N` on a field tells the compiler "place this field on an N-byte boundary inside its record". The compiler honors that for **global**, **stack-local**, and **array-of-T** placement: each carrier is laid out by the linker / stack allocator at an N-byte-aligned address. **Heap-allocated** instances are different - `GetMem()` and `New()` return pointers aligned only to `MaxAllocAlignment` (16 on x86_64), regardless of any per-field `align` declaration. That is a limit of the default heap manager, identical to `malloc()` in C, and unaffected by the type's declared alignment.

For cache-line padding patterns (`align 64` per field, then `GetMem()` the record) the gap matters. Four helpers in the `system` unit fix it - available globally, no `uses` clause needed, sit next to `GetMem()` / `AllocMem()` / `ReAllocMem()` / `FreeMem()`:

```pascal
function GetMemAligned(size, alignment: PtrUInt): pointer;
function AllocMemAligned(size, alignment: PtrUInt): pointer;
function ReAllocMemAligned(var p: pointer; new_size, alignment: PtrUInt): pointer;
procedure FreeMemAligned(p: pointer);
```

- `GetMemAligned(size, alignment)` over-allocates `size + alignment + sizeof(pointer)` bytes, computes an aligned address inside the block, stashes the raw allocation pointer in the word immediately preceding the aligned address, and returns the aligned pointer. `alignment` must be a power of two and at least `sizeof(pointer)`; invalid values return NIL.
- `AllocMemAligned(size, alignment)` calls `GetMemAligned()` and zero-fills the user portion (analogous to `AllocMem()` vs `GetMem()`).
- `ReAllocMemAligned(var p, new_size, alignment)` resizes an aligned allocation. Follows the stock `ReAllocMem()` contract: `p=nil` acts as `GetMemAligned()`, `new_size=0` acts as `FreeMemAligned()`, allocation failure frees the old buffer and sets `p := nil`. User data is preserved up to `min(old_user_size, new_size)` bytes. `alignment` may differ from the original allocation's alignment - the new buffer is freshly aligned to the new value.
- `FreeMemAligned(p)` recovers the raw allocation pointer from the header word and forwards to `FreeMem()`. NIL-safe.

**Warning:** Do **NOT** pass an aligned pointer to plain `ReAllocMem()` or `FreeMem()`. The default heap manager has no knowledge of the aligned-allocation header and will either crash on the alignment-shifted pointer or leak the raw allocation. Always use the matching `*Aligned` helper for the entire lifetime of the allocation.

### Verification

```pascal
program test_aligned;

{$mode unleashed}

type
  TCacheLine = record
    v: int64 align 64;
  end;

begin
  var ps: array[10] of ^TCacheLine;
  var bad := 0;
  for var i := 0 to 9 do begin
    ps[i] := GetMemAligned(sizeof(TCacheLine), 64);
    writeln('alloc #', i, ' = ', HexStr(PtrUInt(@ps[i]^.v), 16), '  mod 64 = ', PtrUInt(@ps[i]^.v) mod 64);
    if PtrUInt(@ps[i]^.v) mod 64 <> 0 then inc(bad);
  end;
  writeln('misaligned: ', bad, '/10');
  for var i := 0 to 9 do FreeMemAligned(ps[i]);
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Expected output: every allocation lands on a 64-byte boundary, `misaligned: 0/10`. Default `GetMem()` on the same record would mis-align 7 out of 10 (alignments cycle through 16-byte slots inside the heap allocator).

### When to use which

- **Global / static / stack-local var of a cache-padded record**: plain declaration is enough. The compiler emits sufficient alignment in the data section / stack frame.
- **`array[0..N] of T` on stack or in data section**: same - alignment of the array equals alignment of `T`, every element is N-byte aligned.
- **`GetMem()` / `New()` of a cache-padded record**: needs `GetMemAligned()` / `AllocMemAligned()`. Default heap manager does not honor custom field alignment.
- **`SetLength()` on a dynamic array**: the dynamic array heap chunk is also only 16-byte aligned. For cache-line-aligned dynamic arrays, allocate manually with `GetMemAligned()` and treat the returned pointer as a typed pointer.

### Implementation

The four helpers live in `rtl/inc/alignmem.inc`, included from `rtl/inc/system.inc` after the heap implementation. Forward declarations sit in `rtl/inc/heaph.inc` next to `GetMem()` / `AllocMem()` so the entire family appears together in the `system` interface.

## Backward compatibility

This feature is strictly additive:

- Every existing record definition compiles unchanged.
- The legacy single-trailing-`case` syntax still works:
  ```pas
  TLegacy = record
    a: integer;
    case byte of
      0: (b: integer);
      1: (c: pchar);
  end; // last `end;` closes the record; no explicit case-end
  ```
- `case TAG: TYPE of` (tagged variant) still works.
- `union` is a CONTEXTUAL keyword: only recognized inside a record body, and only when the next token is not `:` or `,`. So a record field literally named `union` (`union: integer;` / `union: record ... end;`) keeps parsing as a regular field declaration even with `composablerecords` active. Outside record bodies it stays a plain identifier - variables, procedure names, parameters, methods called `union` are fine.
- PPU is forward-compatible: composition lists are gated on the `oo_has_compositions` flag in `tobjectoptions`, so older PPUs that don't carry the section continue to load unchanged.
- Files that need any of the new constructs must opt in via `{$mode unleashed}` or `{$modeswitch composablerecords}`. Two contextual keywords are introduced inside record bodies: `union` for memory overlap and `embed` for anonymous record embedding. Both stay plain identifiers outside record bodies, and both fall back to a field name when followed by `:` or `,` - so existing records with `union: record` (e.g. `jwawinuser.pas`) or `embed: T` keep parsing unchanged.

## Implementation status

Shipped working parts (regression tests live under `unleashed/tests/testfiles/composable_records/`, run by the test runner in `unleashed/tests/`):

- modeswitch `composablerecords`, on by default in `{$mode unleashed}`, off by default elsewhere
- `union ... end;` keyword, multi-union per record, regular fields and other unions interleaved, legacy `case TYPE of` still accepted
- `union size <constexpr>` modifier - asserts max(variant size) <= N and pads the union to exactly N bytes; raises `parser_e_union_exceeds_size` if any variant grows past N. `union bitsize <constexpr>` - bit-level upper bound on variants (peeks inner bitpacked record's databitsize for precision); raises `parser_e_union_exceeds_bitsize` if exceeded; union storage forced to `ceil(N/8)` bytes. `union align <constexpr>` modifier - bumps the union's record alignment to N, bypassing the platform `recordalignmax` clamp (cache-line padding pattern). `union of TYPE` shorthand - sets size and alignment from TYPE plus establishes TYPE as the default for C-style bitfields inside.
- `bitpacked record of TYPE` modifier - establishes a default field type for the C-style bitfield syntax inside. parser-wide stack with innermost-wins propagation - inner blocks inherit if they don't declare their own `of`, an inner `of T2` overrides the outer for its body.
- C-style bitfield syntax inside bitpacked records with active default type: `name: N;` translates to `name: T bitsize N`, multi-name supported (`a, b, c: 1`). `pad N;` is anonymous padding (no field name, N bits reserved). `pad 0;` is the C `: 0;` alignment-marker analog (pads to the next default-type storage-unit boundary).
- Duplicate detection on composition: declaration-time collision check walks the new target_def's flattened name set (recursively through its own embeds) against the outer record's already-visible names; any clash raises `parser_e_composition_duplicate_id`. Named subfields keep their separate namespace and never collide.
- inline anonymous record (`record fields end;` solo) inside record bodies and inside union variants, including the `packed record fields end;` / `bitpacked record fields end;` variants (PEB-style boolean bitfield idiom)
- anonymous embed of an existing record type spelled `embed TBar;` (the `embed` keyword is mandatory; shortform `TBar;` solo is rejected)
- lookup-time flatten through composition links: `outer.flat_member` resolves through the carrier; cascade compositions (A embeds B, B embeds C, lookup C.field on A) are resolved by recursive descent and emit a chain of subscripts on the AST. Fields, methods, properties, **and operators** all flatten. operator flatten covers binary, unary, asymmetric (`vec * integer`), symmetric same-type (`vec + vec`), and cascades; the operator returns the embed's type, not the outer record.
- extended record RTTI exposes flattened members alongside carriers: `GetField('flat_name')` resolves through the composition list with the accumulated carrier offset. requires `{$RTTI EXPLICIT FIELDS([vcPublic])}` or `{$M+}` as for any record extended-RTTI usage in stock FPC.
- record-to-record typecast follows stock FPC: `TInner(outer)` compiles when `sizeof(TInner) = sizeof(outer)` and is rejected otherwise. no special path for compositions - composable records inherit the same rule.
- `OffsetOf()` (byte) and `BitOffsetOf()` (bit) compile-time intrinsics with composition-aware path traversal, accumulating every carrier offset along the chain; accepts both Pascal-style `OffsetOf(T.field)` and C-style `OffsetOf(T, field)`, mixing within one call too. `OffsetOf()` on a sub-byte field in a bitpacked record raises a dedicated error pointing the user to `BitOffsetOf()`.
- `AlignOf()` (byte) and `BitAlignOf()` (bit) compile-time intrinsics for type / field alignment introspection, honoring per-field `align N` / `bitalign N` overrides. pattern-detected in `factor_read_id` (no RTL touch). `BitSizeOf()` extended to honor per-field `bitsize N` override (returns the actual storage width, not the declared type's natural bit width).
- per-field post-suffix modifiers `align N` / `bitalign N` / `size N` / `bitsize N`: explicit byte alignment overriding `{$packrecords}`, explicit byte size override, C-style bit-packed fields, bit-level alignment. modifiers can be combined in any order on a single field declaration.
- cross-unit PPU: composition lists and per-field sizing/alignment overrides both serialize per record def, gated on `oo_has_compositions` / `oo_has_field_sizing` so older PPUs without the sections continue to load unchanged
- `GetMemAligned()` / `AllocMemAligned()` / `ReAllocMemAligned()` / `FreeMemAligned()` in the `system` unit - aligned heap allocation for `align N` records that need explicit alignment on heap (default `GetMem()` ignores per-field alignment and returns 16-byte aligned pointers only). available globally, no `uses` clause
- backward-compat: both `union` and `embed` as field names keep working - the keyword form is recognized only when the next token is not `:` or `,`. example: `jwawinuser.pas` has `union: record`, which still parses as a regular field declaration
- IDE: SynEdit contextual highlight (`union` as a keyword only inside record / record-case fold blocks); CodeTools `cmsComposableRecords` modeswitch and parser handlers that expose individual union variants and inline anonymous record fields so autocomplete picks up flat names

## Limitations

These are deliberately out of scope for the first release of `composablerecords`:

- **Flexible Array Members (FAM).** A separate feature with its own modeswitch and [reference page](flexible-arrays.md) (`array[] of T` as the last field of a record). Not part of `composablerecords`; a FAM-record can be embedded only as the last member of a record, which then becomes a FAM-record itself.
- **Class / object / interface embedding.** Discussed and explicitly rejected; the semantics would be confusing or unsafe (see [What you cannot embed](#what-you-cannot-embed)).

## Reference: real-world WinAPI ports

Two structures from `winnt.h` / `minwinbase.h` that the FPC RTL currently ports with workarounds.

### SYSTEM_INFO (WinAPI)

C original:

```c
typedef struct _SYSTEM_INFO {
  union {
    DWORD dwOemId;
    struct {
      WORD wProcessorArchitecture;
      WORD wReserved;
    } DUMMYSTRUCTNAME;
  } DUMMYUNIONNAME;
  DWORD     dwPageSize;
  LPVOID    lpMinimumApplicationAddress;
  LPVOID    lpMaximumApplicationAddress;
  DWORD_PTR dwActiveProcessorMask;
  DWORD     dwNumberOfProcessors;
  DWORD     dwProcessorType;
  DWORD     dwAllocationGranularity;
  WORD      wProcessorLevel;
  WORD      wProcessorRevision;
} SYSTEM_INFO;
```

Stock FPC port (`rtl/win/sysos.inc:208`):

```pascal
TSystemInfo = record
  case LongInt of
    0: ( dwOemId: DWord;
         dwPageSize: DWord;
         lpMinimumApplicationAddress: Pointer;
         lpMaximumApplicationAddress: Pointer;
         dwActiveProcessorMask: PDWord;
         dwNumberOfProcessors: DWord;
         dwProcessorType: DWord;
         dwAllocationGranularity: DWord;
         wProcessorLevel: Word;
         wProcessorRevision: Word; );
    1: ( wProcessorArchitecture: Word;
         wReserved: Word; );
  end;
```

The fields after the union (`dwPageSize` ... `wProcessorRevision`) are duplicated into branch 0. Branch 1 contains only the union part. If you select branch 1 to read `wProcessorArchitecture`, you cannot reach `dwPageSize` through the same value - the layout works but the type system lies.

`composablerecords` port:

```pascal
TSystemInfo = record
  union
    dwOemId: DWORD;
    record
      wProcessorArchitecture: WORD;
      wReserved: WORD;
    end;
  end;
  dwPageSize: DWORD;
  lpMinimumApplicationAddress: LPVOID;
  lpMaximumApplicationAddress: LPVOID;
  dwActiveProcessorMask: DWORD_PTR;
  dwNumberOfProcessors: DWORD;
  dwProcessorType: DWord;
  dwAllocationGranularity: DWord;
  wProcessorLevel: Word;
  wProcessorRevision: Word;
end;
```

Faithful to the C layout, no duplication, both variants accessible.

### OVERLAPPED (WinAPI)

C original:

```c
typedef struct _OVERLAPPED {
  ULONG_PTR Internal;
  ULONG_PTR InternalHigh;
  union {
    struct {
      DWORD Offset;
      DWORD OffsetHigh;
    } DUMMYSTRUCTNAME;
    PVOID Pointer;
  } DUMMYUNIONNAME;
  HANDLE hEvent;
} OVERLAPPED;
```

Stock FPC port (`rtl/win/wininc/struct.inc:5865`):

```pascal
OVERLAPPED = record
  Internal: ULONG_PTR;
  InternalHigh: ULONG_PTR;
  Offset: DWORD;
  OffsetHigh: DWORD;
  hEvent: HANDLE;
end;
```

The pointer variant is dropped entirely. WinAPI calls that use the pointer variant (some `ReadFileEx` / `WriteFileEx` scenarios) require manual `Pointer(@ov.Offset)^` casts at the call site.

`composablerecords` port:

```pascal
TOverlapped = record
  Internal: ULONG_PTR;
  InternalHigh: ULONG_PTR;
  union
    record
      Offset, OffsetHigh: DWORD;
    end;
    pPointer: PVOID;
  end;
  hEvent: THANDLE;
end;
```

Both variants accessible; layout identical to C.

## Demo

A tagged packet type using every core piece at once - `embed` for a shared header, a record-scoped enum with `of byte` storage, a `union` overlaying three payload views, C-style bitfields, and compile-time `OffsetOf()`:

```pascal
program composable_demo;

{$mode unleashed}

type
  // shared header, embedded (flattened) into each packet
  THeader = record
    magic: word;
    len: byte;
  end;

  TPacket = record
    embed THeader;                           // magic, len reachable directly
    kind: (kAudio, kVideo, kCtrl) of byte;   // record-scoped enum, 1-byte storage
    union                                    // memory overlap, no discriminator field
      record channels, sampleKHz: byte; end; // kAudio view
      record width, height: word; end;       // kVideo view
      raw: longword;                         // kCtrl view
    end;
    crc: byte;
  end;

  // C-style bitfields via bitpacked record of Byte
  TFlags = bitpacked record of byte
    ready:   1;
    dirty:   1;
    pad 4;
    level:   2;
  end;

const
  OFF_KIND = OffsetOf(TPacket.kind);
  OFF_CRC  = OffsetOf(TPacket, crc);

procedure describe(const p: TPacket);
begin
  write($'magic=${HexStr(p.magic, 4)} len={p.len} kind={p.kind}: ');
  match p.kind of
    TPacket.kAudio: writeln($'{p.channels}ch @ {p.sampleKHz}kHz');
    TPacket.kVideo: writeln($'{p.width}x{p.height}');
    TPacket.kCtrl:  writeln($'raw=${HexStr(p.raw, 8)}');
  end;
end;

begin
  writeln($'sizeof(TPacket)={sizeof(TPacket)}  OffsetOf(kind)={OFF_KIND}  OffsetOf(crc)={OFF_CRC}');

  var a: TPacket;
  a.magic := $CAFE; a.len := 4; a.kind := TPacket.kAudio;
  a.channels := 2; a.sampleKHz := 48;
  describe(a);

  var v := a; // record copy
  v.kind := TPacket.kVideo;
  v.width := 1920; v.height := 1080;
  describe(v);

  v.kind := TPacket.kCtrl;
  v.raw := $0708_0000;
  describe(v);

  var f: TFlags;
  f.ready := 1; f.dirty := 0; f.level := 3;
  writeln($'sizeof(TFlags)={sizeof(TFlags)} ready={f.ready} level={f.level}');
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
sizeof(TPacket)=16  OffsetOf(kind)=4  OffsetOf(crc)=12
magic=$CAFE len=4 kind=kAudio: 2ch @ 48kHz
magic=$CAFE len=4 kind=kVideo: 1920x1080
magic=$CAFE len=4 kind=kCtrl: raw=$07080000
sizeof(TFlags)=1 ready=1 level=3
```

## Implementation notes

For implementers and reviewers. The user-facing semantics are above; this section sketches how the compiler realizes them.

### Parser hooks - `pdecvar.pas`

`read_record_fields` (basic record body) and `parse_record_members` (advanced records) each grow a small set of contextual checks. Outside record bodies the new tokens never become keywords - existing code using `union` as an identifier keeps compiling.

| Leading token | Construct                         | Disambiguation                                  |
|---------------|-----------------------------------|-------------------------------------------------|
| identifier    | regular field                     | followed by `,` or `:`                          |
| `embed`       | anonymous type embed              | `embed Type;` (next token is a record type name; classes/objects/interfaces rejected) |
| `union`       | union block (`size`/`bitsize`/`align`/`of T` opt.) | recognized inside record body when modeswitch on |
| `pad`         | anonymous padding bits            | `pad N;` / `pad 0;` (only in bitpacked record with active default type; falls back to field name when followed by `:` or `,`) |
| `record`      | inline anonymous record           | unambiguous - no field name precedes            |
| `packed`      | `packed record fields end;`       | inline anon record with packed alignment        |
| `bitpacked`   | `bitpacked record fields end;` (`of T` opt.) | inline anon record with bit alignment    |
| integer literal after `:` | C-style bitfield width | only in bitpacked record with active default type; `name: N;` = `name: DEFAULT_TYPE bitsize N` |
| `of` after `union` / `bitpacked record` keyword | default-type anchor | parses a typename, pushes onto composable_default_type_stack |
| `case`        | legacy variant section            | unchanged                                       |

`union ... end;` reuses FPC's existing variant-records machinery (`unionsymtable`, `insertunionst`). Each modern variant is parsed as a single field declaration with `vd_one_variant` set so the inner `read_record_fields` returns after one iteration; the outer loop then resets `unionsymtable.datasize` so the next variant overlays the same offset. No new AST node, no new RTTI path, layout matches what an equivalent `case byte of` would produce.

### Composition links

Each record def carries a lazy list of composition entries:

```pascal
tcomposition_kind = (
  ck_anon_embed,            // `TBase;`
  ck_inline_record          // `record fields end;` solo
);
tcomposition_entry = record
  carrier      : tobject;   // points to the carrier tfieldvarsym
  carrier_deref: tderef;    // for PPU
  kind         : tcomposition_kind;
end;
```

`add_composition` is called from the parser after the carrier field has been inserted into the record. Both kinds use an auto-generated carrier name (`$compose$N`) so the carrier never clashes with user identifiers.

Crucially, composition entries created inside a `union` variant migrate to the surrounding record after `insertunionst`, since the carrier itself is flattened into the parent. Without this migration, lookups on the outer record would not see members of an anonymous embed or inline record sitting inside a union.

### Lookup fallback

Member access on a record (`p1.x`) is resolved by `searchsym_in_record` first; on miss, `lookup_in_composition` walks the record's composition list:

- `ck_anon_embed`: matches the carrier's typename (so `d.TBase` works) and matches members of the carrier's record def (so `d.common` works).
- `ck_inline_record`: matches members of the carrier's record def only.

When the lookup hits via a member, the caller in `pexpr.pas` inserts an extra subscript through the carrier so the read lands on `record.carrier.target` rather than `record.target`.

### `OffsetOf()` and `BitOffsetOf()` intrinsics

Both pattern-detected in `factor_read_id` so they do not depend on sysconst symbols (which would force an RTL rebuild). Share one walker (`parse_offsetof_like_intrinsic(in_bits: boolean)`); the argument is parsed as `Type[.field|,field]+`. Composition-aware: each carrier-mediated hop adds the carrier's own field offset before descending into its record's symtable.

Internally the walker always accumulates in bits, checking each field's owning symtable for `is_packed` (i.e. `usefieldalignment = bit_alignment`) to decide whether `fieldoffset` is already in bits or needs `* 8`. `BitOffsetOf()` returns the bit total directly. `OffsetOf()` divides by 8 if the total is a multiple of 8, otherwise emits `parser_e_offsetof_subbyte_field` with the field name.

### PPU

Composition lists serialize per record def. `oo_has_compositions` is set on the parent's `objectoptions` whenever `add_composition` runs; ppu read/write of the section is gated on the flag, so older PPUs without it continue to load unchanged. Each entry stores the kind byte and a `tderef` pointing at its carrier.
