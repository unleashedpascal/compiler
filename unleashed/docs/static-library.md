# Static Libraries

`-XA` (long form `--staticlib`) builds a `library` or `program` into a standalone static library: one `.a` archive that carries the code of the module, every unit it uses and the runtime itself. A program written in any language whose toolchain links `.a` archives (C, C++, Rust, Zig, another Pascal program) links it like any other static library and calls the routines listed in the `exports` clause. Nothing else has to be installed or shipped next to it.

The runtime inside the archive is private to it. Two static libraries built with `-XA` can be linked into the same program without a single symbol clash, each with its own heap, its own thread bookkeeping and its own unit initialization.

CLI-only; there is no directive form.

| Item | Value |
|---|---|
| Option | `-XA`, or `--staticlib` |
| Input | a `library` (its body runs at `rtlInit`) or a `program` |
| Output | `<module>.a`, or the `-o` name verbatim with `.a` appended when it has no extension; no `lib` prefix is added |
| Visible symbols | exactly the names in the `exports` clause |
| Targets | Windows and Linux targets that link with GNU `ld`; verified on `i386-win32`, `x86_64-win64` and `x86_64-linux` |
| Tools | GNU binutils for the target: `ld` and `objcopy` newer than the ones bundled with FPC, see below |

## The archive

The compiler links every object of the program relocatably with the exports as the only roots, so anything no export reaches, runtime included, is dropped; on Windows it then writes the import stubs for the DLL functions the surviving code still calls, folds the per-routine sections into the standard ones (a Windows executable can hold at most 96 sections) and finally hides every symbol but the exports. The result is one object inside one archive:

```shell
fpc -XA egg.pas
```

builds `egg.a` from a `library egg;` source. The archive depends on nothing but the operating system: on Windows the import table lists the system DLLs the code uses (`kernel32.dll`, for example), on Linux without `cthreads` there is no dependency at all, the runtime talks to the kernel directly.

`-o` names the archive the way it names an executable: `-o ../egg` gives `../egg.a`, `-o libegg.a` gives exactly that. Nothing is prefixed, so a program that wants to link it with `{$linklib egg}` or `-legg` has to ask for the `lib` prefix by name.

### Binutils

The bundled binutils of an FPC installation are too old for this: the `ld` 2.28 that ships with FPC silently ignores `--gc-sections` in a relocatable link and produces an archive that carries the whole runtime. Point the compiler at a current GNU binutils with `-FD`:

```shell
fpc -XA -FDC:\mingw64\bin egg.pas
```

Version 2.28 is too old; 2.41 and 2.42 are verified to work. `ld --version` prints the version a toolchain has. Cross-compiling needs binutils for the target (`x86_64-linux-ld`, `x86_64-linux-objcopy`); the compiler looks them up with the usual `-XP` prefix rules.

### What is not in the archive

| Item | Why |
|---|---|
| debug information | the relocatable link strips it; a static library is a release artifact |
| the startup code | the host program owns `main`, `_start` and `DllMain`; the library gets going when the host calls its init export |
| shared libraries the code links against | `{$linklib}` of a `.so` or `.dll` cannot go into an archive; the compiler warns and the host program has to link them itself (`cthreads` on Linux is the usual case, its `pthread` symbols live in `libc` on any current glibc) |

## Exports

The `exports` clause decides what the host program can see. Every name listed there becomes a global symbol of the archive; everything else is local, mangled Pascal names included.

```pascal
library egg;

{$mode unleashed}

uses SysUtils;

function eggCrack(n: longint): longint; cdecl;
begin
  result := n*2;
end;

var
  eggLevel: longint = 7;

exports
  rtlInit name 'egg_init',
  rtlDone name 'egg_done',
  eggCrack name 'egg_crack',
  eggLevel name 'egg_level';

begin
end.
```

| Export | Symbol in the archive |
|---|---|
| `eggCrack name 'egg_crack'` | `egg_crack` |
| `eggCrack` (no `name`) | `eggCrack`, spelled as written in the clause |
| `eggCrack` listed while the routine already carries `public name 'x'` | `x`, the routine's own symbol, no wrapper; `public name` alone exports nothing, the routine still has to be listed |
| `eggLevel name 'egg_level'` (a variable) | `egg_level`; the variable is renamed, initialized data stays readable before `rtlInit` |
| any export on `i386-win32` | the name plus the C-decorated alias: `_egg_crack` for `cdecl`, `_egg_crack@4` for `stdcall` |

A routine export gets a small wrapper that carries the export name and calls the routine. The wrapper is where a thread the host program created gets its runtime state on its first call into the library, see below; a routine that already carries the export name through `public name` is exported as it is and gets no wrapper.

Exported routines are meant to be called from C-style code, so they should use `cdecl` (or `stdcall` on Windows). The compiler warns about an export with any other calling convention:

```
Warning: Exported routine "pascalConv" is not callable from C, use cdecl or stdcall
```

`exports` is accepted in a `program` as well when `-XA` is given; without the option a program still cannot export anything.

## Runtime start and shutdown: `rtlInit` and `rtlDone`

Nothing runs before the host program calls into the archive, so the runtime of the library has to be started by the host. Two routines of the `system` unit do that and are meant to be exported under whatever name fits the library:

| Routine | Does |
|---|---|
| `rtlInit` | sets the runtime up: heap, threading, exception handling, standard files, then runs the `initialization` section of every unit in dependency order and finally the body of the `library` |
| `rtlDone` | runs the exit procedures, the `finalization` sections in reverse order and releases the heap and the thread bookkeeping |

Both are `cdecl` and take no arguments. They are reference counted: the first `rtlInit` does the work and every further one only counts, the matching `rtlDone` only counts down and the last one shuts the runtime down. Init/done cycles are allowed, the runtime comes up again on the next `rtlInit`.

The contract for the host program:

- call the init export before the first use of any other export,
- call the done export before the process ends, if init was called,
- do not call into the library after done.

Both are cheap enough to be called from inside a library's own exports: an export that does `rtlInit`, its work and `rtlDone` (a `defer rtlDone` right after the init does exactly that) is self-contained and the host program never has to know about runtime setup. Cost of a cycle: the unit initializations plus the heap setup and teardown, in the order of microseconds to a millisecond.

`rtlInit` sets `IsMultiThread`: the library expects to be called from several threads and keeps its heap and reference counts thread-safe from the start. On Linux it also sets `IsLibrary`, which makes the runtime hand the signal handlers back to the host after its own setup; on Windows `IsLibrary` stays false, the runtime there is the one the TLS callback prepared as if for an executable.

### What needs the runtime

Without `rtlInit` the archive is still valid code, and an export that touches none of the following works fine. Anything below needs the runtime up:

| Needs `rtlInit` | Why |
|---|---|
| `GetMem`, `New`, `Create`, `ansistring`, dynamic arrays, classes | the heap is set up by the runtime |
| `threadvar` on Windows | the TLS slot is allocated by the runtime |
| `raise`, `try` on Linux | the exception stack lives in a threadvar |
| `writeln`, `readln`, `ParamStr` | standard files and arguments |
| resource strings, `WideString` conversions | the managers are installed by the unit initializations |
| the `initialization` section of any unit, the library body | they are what `rtlInit` runs |
| floating point errors as runtime errors | the runtime unmasks the FPU exceptions; without it the host's masks apply and a division by zero yields an infinity |

Plain code, integer arithmetic, stack and static variables, `shortstring`, static arrays, records and calls into the operating system through `external` declarations work without it.

### Threads

A thread the host program created and that calls into the library has no runtime state of its own. The export wrapper takes care of that: on the first call of such a thread it sets the thread up (heap state, exception stack, FPU control word) before the exported routine runs. Threads created by the library itself through `BeginThread` or `TThread` are set up the usual way.

On Windows the archive also carries the TLS callback of the runtime. A host built with a C toolchain registers it through its TLS directory, so the library sees thread attach and detach and releases what a thread allocated when the thread ends. On Linux the same cleanup happens through `cthreads`: a library that uses threads, or that the host calls from several threads, has to put `cthreads` first in its `uses` clause, as any threaded Linux program does. Without `cthreads` the heap of the library is not thread-safe.

## From C

```c
#include <stdio.h>

void egg_init(void);
void egg_done(void);
int egg_crack(int n);

int main(void) {
  egg_init();
  printf("%d\n", egg_crack(21));
  egg_done();
  return 0;
}
```

```shell
gcc host.c egg.a -o host
```

On Windows the archive links with MinGW-w64 as above; the system DLLs it imports are ones every toolchain links by default, and the host does not need to know which ones: their import entries are inside the archive.

On Linux the code in the archive is not position independent unless the runtime and the library were built with `-Cg`. A host linked as a position independent executable, which is what a current `gcc` produces by default, gets text relocations and a linker warning; link the host with `-no-pie`, or build the runtime and the library with `-Cg`.

## From FPC

An FPC program links the archive the way it links any static library: `{$linklib egg}` looks for `libegg.a` on the library path, so build the archive with that name:

```shell
fpc -XA -olibegg.a egg.pas
```

```pascal
program host;

{$mode unleashed}
{$linklib egg}

procedure eggInit; cdecl; external name 'egg_init';
procedure eggDone; cdecl; external name 'egg_done';
function eggCrack(n: longint): longint; cdecl; external name 'egg_crack';

begin
  eggInit;
  writeln(eggCrack(21));
  eggDone;
end.
```

The internal linker of FPC links the archive as it is; its garbage collection drops the TLS callback of the library (nothing in the archive refers to it), so in such a host a thread the host created keeps the runtime state the export wrapper gave it until the process ends. The host program has its own runtime and the library has another; they do not know about each other. Memory allocated by the library has to be freed by the library, and only plain data (integers, `pchar`, records, callbacks) should cross the boundary, the same rules as with a DLL.

## Programs with their own entry point

`rtlInit` is also what a program with `{$entrypoint}` needs. The directive points the program at its own first routine and nothing runs before it, so the routine starts the runtime itself and ends the process with `halt`, which performs the shutdown:

```pascal
program bare;

{$mode unleashed}
{$entrypoint main}

uses SysUtils;

procedure main;
begin
  rtlInit;
  writeln(FormatDateTime('yyyy', 0));
  halt(0);
end;

begin
end.
```

The main block of such a program never runs. `rtlDone` before the `halt` is allowed (a `defer rtlDone` in a routine `main` calls, for example) and harmless: `halt` finds nothing left to finalize.

## Edge cases

| Case | Behavior |
|---|---|
| no `exports` clause with `-XA` | compile error: nothing would survive the gc |
| `Halt` or a runtime error inside the library | ends the host process, the same as inside a DLL outside its attach code |
| an exception leaving an exported routine | undefined, as with any language boundary; catch inside the export |
| `ParamStr`, `ParamCount` on Linux | empty, the library never sees the command line of the host; on Windows they read it from the system |
| `rtlDone` without a matching `rtlInit` | ignored |
| `rtlInit` from two threads at the same time | counted atomically, one of them does the work |
| `-Cn` together with `-XA` | no archive: the pipeline patches object files, nothing to put into a script |
| a `library` with an `initialization` / `finalization` pair instead of a body | both run from `rtlInit` / `rtlDone` like the sections of a unit |

## Demo

A library that prints from an export and from a thread it starts itself, and a C program that links it. The host knows nothing about Pascal: `hello.a` brings its own heap, threads and standard output.

```pascal
library hello;

{$mode unleashed}

uses {$ifdef UNIX}cthreads,{$endif} SysUtils;

function sum(a, b: int32): int32; cdecl;
begin
  write('sum of ', a, ' and ', b, '...');
  result := a+b;
  writeln(' is ', result);
end;

// a library thread prints n ticks, the call returns once it is done
procedure count(n: int32); cdecl;
begin
  var id := BeginThread(function(p: pointer): ptrint
  begin
    for var i := 1 to ptrint(p) do begin
      writeln('tick ', i);
      Sleep(500);
    end;
    result := 0;
  end, pointer(n));
  WaitForThreadTerminate(id, 0);
  CloseThread(id);
end;

exports
  rtlInit name 'hello_init',
  rtlDone name 'hello_done',
  sum     name 'hello_sum',
  count   name 'hello_count';

begin
end.
```

```c
#include <stdio.h>

void hello_init(void);
void hello_done(void);
int hello_sum(int a, int b);
void hello_count(int n);

int main(void) {
  hello_init();
  int r = hello_sum(2, 3);
  printf("C got %d\n", r);
  fflush(stdout);
  hello_count(5);
  hello_done();
  return 0;
}
```

The library writes straight to the standard output while C buffers it, so the host flushes after its own `printf` to keep the lines in order.

Build the library first, then the host:

```shell
fpc -O3 -XA -FD<binutils dir> hello.pas
gcc -s -o host host.c hello.a
```

On Windows with MinGW-w64, for example:

```shell
fpc -O3 -XA -FDC:\mingw64\bin hello.pas
gcc -s -o host.exe host.c hello.a
```

On Linux `fpc` uses the binutils of the system, so `-FD` is not needed as long as `ld --version` reports something newer than 2.28 (2.42, the version of a current Linux Mint, works); the host is linked with `-no-pie`, see [From C](#from-c):

```shell
fpc -O3 -XA hello.pas
gcc -s -no-pie -o host host.c hello.a
```

Output:

```
sum of 2 and 3... is 5
C got 5
tick 1
tick 2
tick 3
tick 4
tick 5
```
