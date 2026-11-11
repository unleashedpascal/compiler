# `$embedstr` / `$embedbytes` Directives

Embed the contents of a file into the source at compile time - the asset ships inside the binary, with no runtime file I/O and no external resource to lose. Two directives, one per output type:

- **`$embedstr`** - the file becomes a `String`.
- **`$embedbytes`** - the file becomes an `array of byte`.

Both read the file as raw bytes and emit the encoded data at the directive site. They are directives, not modeswitches - always available regardless of `{$mode}`.

The name `embed` (rather than `include`) is deliberate: `{$include}` / `{$i}` splice another file in as *source code to be compiled*, whereas these directives bake a file in as *data*.

## Two forms each

Each directive has a 2-arg and a 1-arg form: a name in front of the path (`NAME 'path'`) emits a named constant, the path alone (`'path'`) emits a bare value expression.

```pascal
{$embedstr   NAME 'path'}   // const NAME: String = '...';
{$embedstr   'path'}        // bare String expression
{$embedbytes NAME 'path'}   // const NAME: array[0..N-1] of byte = (...);
{$embedbytes 'path'}        // bare [$xx,$yy,...] array literal
```

The path is always written in quotes, `'...'` or `"..."`, and may contain spaces. A path without quotes is an error. Path resolution matches `{$I}`:

- an **absolute** path is used verbatim;
- a **relative** path is searched in the current source file's directory, then the local includepath, then the global includepath;
- a name starting with `*` stands for the current source file, so `'*.dat'` inside `unit1.pas` means `unit1.dat` (same rule as `{$R *.res}`).

## `$embedstr`

For a non-empty file, the 2-arg form emits a `const` whose initializer is the file bytes as concatenated Pascal string fragments:

```pascal
const <name>: String =
'<printable run 1>'+#$nn+#$nn+'<printable run 2>'
+'<printable run 3>'+...;
```

The 1-arg form emits just the expression (no `const`, no `;`), usable anywhere a `String` value fits. Bytes are classified at encode time:

- printable ASCII (`$20..$7E` except the apostrophe) goes into single-quoted runs;
- everything else (control bytes, high-bit bytes, the apostrophe) becomes a `#$nn` escape (`#$n` for single-nibble values).

Empty file: the 2-arg form emits `const <name>: String = '';`, the 1-arg form emits `''`.

After compilation the constant is a `String` whose bytes match the file byte for byte: `length(schema)` is the file size, `byte(schema[i])` is byte `i-1` of the original.

## `$embedbytes`

The 2-arg form emits a typed `const` with a parenthesized initializer (standard Pascal array-init syntax, so the emitted const compiles in every mode):

```pascal
const <name>: array[0..N-1] of byte =
($a,$bb,$4,$5,
$6,$7,$8);
```

The 1-arg form emits a bare array literal in square brackets: `[$a,$bb,$4,...]`. The bracket difference mirrors how Pascal parses constructors per context: `(...)` is the typed-const initializer, `[...]` is the inline array constructor used in expressions, which resolves to `array of byte` automatically when the surrounding context expects one.

Empty file: 2-arg emits `const <name>: array of byte = ();`, 1-arg emits `[]`. Bytes are emitted in compact hex (`$X` for `0..$F`, `$XX` otherwise), broken across lines at about 64 characters.

```pascal
procedure sendFrame(const bytes: array of byte);
begin
  stream.Write(bytes[0], length(bytes));
end;

begin
  sendFrame({$embedbytes 'frame.bin'}); // 1-arg, inline
end.
```

### Pitfall: typed-const init takes `(...)`, not `[...]`

```pascal
const data: array of byte = {$embedbytes 'data.bin'}; // does NOT compile
```

Pascal's typed-const initializer parses `(...)`, not the `[...]` the 1-arg form emits. Use the 2-arg form for named byte arrays: `{$embedbytes data 'data.bin'}`.

### Pitfall: `var x := {$embedbytes ...}` infers `array of LongInt`

```pascal
var x := {$embedbytes 'data.bin'}; // x is array of LongInt, NOT array of byte
```

The 1-arg form is a bare `[$xx,...]` literal, and inline-var inference picks the default integer type (`LongInt`) for integer-literal elements regardless of value range. Symptom: `length(x)` is right but each element is 4 bytes, so `move(x[0], dest, length(x))` copies only every fourth byte of what you meant. Pin the type instead:

```pascal
{$embedbytes data 'path'}                            // 2-arg: array[0..N-1] of byte
var x: array of byte := {$embedbytes 'data.bin'};    // explicit annotation
foo({$embedbytes 'data.bin'});                       // a byte-array parameter pins it
```

## Parameters

Words after the path are parameters. With them the constant holds the file packed, encrypted, or both, in place of the file as it is:

```pascal
{$embedstr data 'lang.txt' compress}
{$embedstr data 'lang.txt' compress=zstd}
{$embedstr data 'lang.txt' encrypt}
{$embedstr data 'lang.txt' compress encrypt=aes}
{$embedstr data 'lang.txt' encrypt seed='my secret key' nullnonce}
{$embedbytes data 'lang.txt' compress=gzip}
```

Parameters work with both directives and with both forms; `length({$embedstr 'lang.txt' compress})` is the size of the packed file.

| Parameter | Values | Without a value | What it does |
|---|---|---|---|
| `compress` | `deflate`, `zlib`, `gzip`, `zstd` | `deflate` | packs the file |
| `encrypt` | `chacha20_ietf`, `chacha20`, `aes` | `chacha20_ietf` | encrypts the file |
| `seed=text` | any text | error, `=` is required | sets the key of `encrypt` |
| `nonce=text` | any text | error, `=` is required | sets the nonce of `encrypt` |
| `nullnonce` | none, a value is an error | | makes the nonce of `encrypt` all zero bytes |

How a parameter is written:

- A parameter is `name`, `name=value` or `name='value with spaces'`. Double quotes work too: `name="value with spaces"`.
- Inside a quoted value a doubled quote stands for one quote: `seed='it''s'` is the text `it's`.
- A value may be empty: `seed=` and `seed=''` are the same.
- Parameter names and the values of `compress` and `encrypt` ignore case: `Compress=ZLIB` is `compress=zlib`. The text of `seed` and `nonce` is taken byte for byte.
- The order of the parameters does not matter.
- Each parameter may be written once.
- A value cannot contain `}`, because that character ends the directive.

With both `compress` and `encrypt` the file is packed first and encrypted second, whichever parameter comes first.

The compiler only packs and encrypts. Unpacking and decrypting happen in the program at run time, with any implementation of the formats described below.

### `compress`

| Value | The constant holds | Bytes around the packed stream | What checks the data |
|---|---|---|---|
| `deflate` | a raw DEFLATE stream (RFC 1951) | none | nothing |
| `zlib` | a zlib stream (RFC 1950) | 2 before, 4 after | Adler-32 of the file |
| `gzip` | a gzip stream (RFC 1952) | 10 before, 8 after | CRC-32 and the size of the file |
| `zstd` | one Zstandard frame (RFC 8878) | a frame of its own | 32 bits of XXH64 of the file |

- `deflate`, `zlib` and `gzip` hold the same packed stream; they differ only in the bytes around it. The packer uses a 32 KiB window and writes whichever of the three DEFLATE block kinds comes out smallest.
- The gzip header carries no file name and no time, so the same file gives the same bytes in every build.
- The Zstandard frame also states the size of the file in its header when the file is smaller than 17 MiB. On a few tens of KiB of text it is about as large as the DEFLATE stream; on larger files it comes out smaller, about a tenth on 300 KiB to 1 MiB of source text. Its unpacker is larger than a DEFLATE one.
- An empty file gives a valid stream that unpacks to nothing.
- Packing does not always shrink: a tiny file, or one that is packed already (PNG, JPEG, an archive), comes out a few bytes larger than it went in.

A `zlib` constant read back with the `zstream` unit of FPC:

```pascal
uses Classes, zstream;

{$embedstr lang 'lang.txt' compress=zlib}

function unpack(const data: string): string;
begin
  result := '';
  var source := autofree TStringStream.Create(data);
  var z := autofree TDecompressionStream.Create(source);
  var buffer: array[4096] of char;
  var count: longint;
  repeat
    count := z.Read(buffer, sizeof(buffer));
    result += copy(buffer, 1, count);
  until count = 0;
end;
```

### `encrypt`

| Value | Cipher | Key | Nonce |
|---|---|---|---|
| `chacha20_ietf` | ChaCha20 with a 32-bit block counter (RFC 8439) | 32 bytes | 12 bytes |
| `chacha20` | ChaCha20 with a 64-bit block counter (the original cipher) | 32 bytes | 8 bytes |
| `aes` | AES-256 in counter mode | 32 bytes | 16 bytes |

Where the key and the nonce come from:

| Written | Key | Nonce |
|---|---|---|
| `encrypt` | random | random |
| `encrypt seed='abc'` | the text `abc` | random |
| `encrypt nonce='xyz'` | random | the text `xyz` |
| `encrypt nullnonce` | random | zero bytes |
| `encrypt seed='abc' nonce='xyz'` | the text `abc` | the text `xyz` |
| `encrypt seed='abc' nullnonce` | the text `abc` | zero bytes |

- A random key or nonce is new at every compilation and for every directive, so two builds of the same source hold different bytes.
- A text shorter than the size in the table is padded with zero bytes at its end. A longer text is cut to that size. `seed=` gives a key of 32 zero bytes, `nonce=` is the same as `nullnonce`.
- With `seed`, and `nonce` or `nullnonce`, nothing is random and every build holds the same bytes.

The constant is laid out like this:

```
key (32 bytes, only without `seed`) | nonce | encrypted file | tag (16 bytes)
```

- The key is stored only when it is random. A key given with `seed` is not in the constant; the program supplies it when it decrypts.
- The nonce is always stored, whether random, given or zero.
- The encrypted file is as long as the file (or the packed file).
- The tag is a Poly1305 checksum that needs the key. If any byte of the constant is changed in the binary, the tag no longer matches.

How the bytes are made, for all three ciphers:

1. The cipher produces its key stream from the key and the nonce, with the block counter at zero. For `aes` the 16-byte nonce is the first counter block and counts up as one 128-bit number, high byte first.
2. The first 32 bytes of the key stream are the Poly1305 key.
3. The file is XOR-ed with the key stream that follows. ChaCha20 skips the rest of its first 64-byte block, so the file starts at block 1. `aes` goes on with the next block, the third.
4. The tag is Poly1305 over: the encrypted file, zero bytes up to a multiple of 16, eight zero bytes, and the length of the encrypted file as a 64-bit number, low byte first.

For `chacha20_ietf` this is exactly the ChaCha20-Poly1305 AEAD of RFC 8439 with no associated data, so a standard implementation opens the constant: the nonce is the first 12 bytes (after the key, when there is one), the rest is the AEAD output.

What encryption is good for here, and what it is not:

- It keeps the text out of `strings` and out of a hex or resource editor, and the tag makes an edited constant fail to decrypt.
- With a random key the key sits in the constant, in front of the data. Someone who reads the machine code of the program can decrypt and re-encrypt the data. The same holds for a `seed` that is a literal in the source.
- The same `seed` with the same nonce for two different files gives away both files to anyone who has one of them. Give each file its own `nonce`, or leave the nonce random.

## Use cases

- Baking small fixed assets (icons, fonts, schemas, templates) into a single-binary executable.
- Compiled-in default configuration that always exists as a fallback.
- Lookup tables produced by an external tool, picked up at the next build without a generated `.pas` file.
- Byte-exact test fixtures - compile-time embedding rules out "file missing at run time".
- Larger text assets shipped packed (`compress`), and texts that should be neither readable nor editable in the binary (`encrypt`).

Use `$embedstr` when the consumer wants text or a buffer to `move()` out of; `$embedbytes` when an API demands `array of byte` typing (binary protocols, hash inputs, decoder feed).

## Constraints and notes

- **2-arg forms** expand to a `const` declaration, so they must sit where a const declaration is valid: at unit / program scope (after `uses`), or anywhere a local `const` is accepted in unleashed mode.
- **1-arg forms** expand to a bare expression and must sit where a value of the matching type fits (argument, comparison operand, right-hand side). No named binding - to reference the same data twice, use the 2-arg form.
- The data is baked in at the directive site; repointing the file requires recompilation.
- Large files inflate compile time (the constant still travels through the parser); keep embedded assets reasonably small.

## Errors

| Trigger | Diagnostic |
|---|---|
| `{$embedstr}` / `{$embedbytes}` with no arguments | `Error: embedstr: missing arguments` / `Error: embedbytes: missing arguments` |
| Path without quotes, as in `{$embedstr foo.txt}` or `{$embedstr data foo.txt}` | `Error: embedstr: the path must be in quotes` / `Error: embedbytes: the path must be in quotes` |
| File not found or not openable | `Fatal: Cannot open include file "<path>"` |
| A word after the path that is not a parameter | `Error: embedstr: unknown parameter "<word>"` |
| The same parameter twice | `Error: embedstr: parameter "<name>" given twice` |
| `compress=` or `encrypt=` with a value that is not in the tables | `Error: embedstr: unknown value "<value>" for "compress"` |
| `seed` or `nonce` without `=` | `Error: embedstr: "seed" needs a value, as in seed=...` |
| `nullnonce=` with a value | `Error: embedstr: "nullnonce" takes no value` |
| `nonce` together with `nullnonce` | `Error: embedstr: "nonce" and "nullnonce" exclude each other` |
| `seed`, `nonce` or `nullnonce` without `encrypt` | `Error: embedstr: "seed" needs "encrypt"` |
| A quoted value with no closing quote | `Error: embedstr: missing closing quote` |

Every one of these errors starts with the name of the directive that raised it, `embedstr:` or `embedbytes:`.

## Demo

With two asset files next to the source - `banner.txt` containing the text `hello from inside the binary` (28 bytes, no trailing newline) and `palette.bin` containing the four raw bytes `$01 $02 $03 $FF`:

```pascal
program embed_demo;

{$mode unleashed}

{$embedstr banner 'banner.txt'}
{$embedbytes palette 'palette.bin'}

begin
  writeln(banner);
  writeln($'banner is {length(banner)} bytes');

  var sum := 0;
  for var b in palette do sum += b;
  writeln($'palette: {length(palette)} bytes, sum {sum}');

  // 1-arg form: inline value, no named constant
  writeln({$embedstr 'banner.txt'});
  {$ifdef WINDOWS}readln;{$endif}
end.
```

Output:

```
hello from inside the binary
banner is 28 bytes
palette: 4 bytes, sum 261
hello from inside the binary
```
