# test-tool

A small CLI runner that compiles every `.pp` / `.pas` file under `testfiles/`, optionally executes the produced binary, and reports pass / fail with timings. Written in `{$mode unleashed}` so that building the tool itself exercises the compiler under test.

## Build

```
lazbuild unleashed/tests/testtool/testtool.lpi
```

The built binary lands in `unleashed/tests/testtool.exe`. By default it invokes whatever `fpc` is on `PATH`. Override with `--fpc=PATH` (see below).

## Directory layout

```
unleashed/tests/
  testtool/         tool source (testtool.lpr, testtool.lpi)
  testtool.exe      built binary
  testfiles/        test sources, one .pp per test
    <feature>/      tests grouped by language feature
    sanity_*.pp     self-tests for the runner
  tests.log         one line per test, written every run
  fail.log          failures only, written only when at least one fails
  .tmp/             transient build artifacts, removed at end of run
```

The `testfiles/` root may also be moved with `--path=DIR`.

## Quick start

```
testtool                          run the whole suite, parallel
testtool --filter=autofree        run only tests whose path contains "autofree"
testtool --only-failed            rerun what failed in the previous run
testtool --fail-fast              stop at the first failure
testtool --list                   just print discovered tests, do not run
testtool --parallel=1             force sequential execution
testtool --help                   full option list
```

## How a test is judged

The runner walks `testfiles/` recursively, picks up each `.pp` / `.pas` file, and for each one:

1. extracts the first `{ ... }` comment in the file and parses any `%FLAG` tokens out of it
2. compiles the file with `fpc` (extra args injected per `%OPT=` and per `--fpc` config)
3. depending on the flags, either expects the compile to fail, or runs the produced exe and inspects its exit code

Default verdict rules, in priority order:

| Situation | Verdict |
|---|---|
| `%CPU` set and target cpu not in the list | SKIP, phase `skip` (nothing compiled) |
| Compiler hung past the timeout | FAIL, phase `compile-timeout` |
| `%FAIL` set and compiler exited non-zero | PASS, phase `expected-fail` |
| `%FAIL` set and compiler exited zero | FAIL, phase `compile` |
| Compile failed without `%FAIL` | FAIL, phase `compile`, notes = compiler output |
| `%NORUN` (or `--norun`) and compile succeeded | PASS, phase `compile` |
| Run hung past the timeout | FAIL, phase `run-timeout` |
| Run exited 0 | PASS, phase `run` |
| Run exited non-zero | FAIL, phase `run`, notes = program output |

## Writing a test

A test is a single `.pp` (or `.pas`) file. The body uses `Halt(N)` to signal verdict at runtime, where `N = 0` (or natural fall-through) means pass and any other value means fail. Different `Halt(N)` calls at different points in the body let you identify the failing assertion site from the exit code recorded in `fail.log`.

Minimal example:

```pascal
program inline_vars_inferred_01;
{$mode unleashed}
var s: string;
begin
  var n := 42;
  if n <> 42 then Halt(1);
  s := 'hello';
  if Length(s) <> 5 then Halt(2);
end.
```

When this test fails with `exit=2`, the author knows it was the second check.

### File-level flags

Flags live in the FIRST `{ ... }` comment in the file. The comment must come before any code and must not be a compiler directive (`{$...}`). Unknown flags are silently ignored. Flag names are case-insensitive (`%norun` works the same as `%NORUN`).

```
{ %FLAG1 %FLAG2=value }
program tname;
{$mode unleashed}
...
```

A value containing whitespace must be quoted with `"..."`, otherwise the tokenizer splits on the first space and only the head ends up as the value:

```
{ %OPT="-O3 -OoDEADSTORE" %NORUN }      <- correct: OPT receives both args
{ %OPT=-O3 -OoDEADSTORE %NORUN }        <- WRONG: OPT receives only `-O3`
```

| Flag | Effect |
|---|---|
| `%NORUN` | Compile only; do not run the produced exe. Pass = compiler exits 0. |
| `%FAIL` | The test must NOT compile. Pass = compiler exits non-zero. |
| `%OPT=ARGS` | Extra arguments passed verbatim to the compiler. Quote the value if it contains spaces: `%OPT="-O2 -Cr"`. |
| `%TIMEOUT=N` | Per-test timeout in seconds, overrides `--timeout`. |
| `%CHECKBIN_HAS=L` | Comma-separated list of substrings; each MUST appear in the produced binary. After successful compile (and run, if any), the runner reads the exe as bytes and asserts every entry is found. |
| `%CHECKBIN_LACKS=L` | Same shape, opposite assertion: every entry MUST NOT appear. Useful for verifying RTTI stripping, dead-code elimination, etc. |
| `%CPU=L` | Comma-separated list of target cpus (as reported by `fpc -iTP`, e.g. `x86_64,aarch64`) the test applies to. When the compiler targets a cpu not in the list, the test is reported as SKIP instead of being compiled. Use for tests that exercise 64-bit-only behavior such as `Int64` `for parallel` loop variables. |
| `%EXPECTMSG=S` | The compiler output must contain `S`, checked for passing and `%FAIL` tests alike; quote the value when it has spaces: `%EXPECTMSG="Cannot resize an open array parameter"`. Use it to pin a `%FAIL` test to one specific error, or to assert a warning on a compiling test. |

When either `%CHECKBIN_*` flag is set, the runner adds `-Xs -XX -CX` to the compile to keep dead code and debug-section noise out of the byte search. The check happens whether or not the test runs (so it composes with `%NORUN`). On violation the verdict is FAIL with phase `checkbin` and a note naming the offending substring.

There is no per-file modeswitch flag: a test that needs a specific modeswitch should put `{$modeswitch NAME}` directly in its source. To compile the SAME suite under different mode / modeswitch combinations from the command line, use `--mode=` and `--modeswitch=` (see CLI flags).

Mixing `%NORUN` and `%FAIL` is not meaningful; `%FAIL` takes precedence.

### Naming convention

`<feature>_<variant>_NN.pp`, zero-padded number, lowercase. Examples:

```
inline_vars_inferred_01.pp
autofree_in_try_except_classical_var_01.pp
match_returning_tuple_03.pp
```

Tests are grouped into per-feature folders under `testfiles/`. The runner descends recursively, so any depth works.

## CLI flags

### Selection

| Flag | Effect |
|---|---|
| `--path=DIR` | Override the `testfiles/` root. Useful for pointing the runner at another suite, e.g. `--path=tests/webtbs` to run the FPC tracker tests with the configured compiler. |
| `--filter=SUBSTR` | Run only tests whose absolute path contains `SUBSTR`. |
| `--exclude=SUBSTR` | Drop tests whose path contains `SUBSTR`. Applied after `--filter`. |
| `--limit=N` | Cap the test count to N after filter / exclude. Takes the first N from the sorted list. |
| `--only-failed` | Rerun only tests listed in the previous `fail.log`. Exits 0 with a message if no `fail.log` exists. |
| `--list` | Print discovered test paths and exit; do not compile or run anything. |

### Execution

| Flag | Effect |
|---|---|
| `--fpc=PATH` | Path to the `fpc` binary. Default: `fpc` resolved through `PATH`. |
| `--norun` | Force `%NORUN` semantics on every test. Compile-only run; useful when the run side is too slow or unavailable. |
| `--timeout=N` | Default per-test timeout in seconds. `0` disables the timeout entirely. Default: `30`. Overridden per-test by `%TIMEOUT=N`. |
| `--parallel=N` | Number of worker threads. Each worker uses its own `.tmp/W<i>/` subdir so artifacts never collide. Default: half the CPU core count. Use `--parallel=1` to force sequential. |
| `--fail-fast` | Stop dispatching new tests at the first failure. In parallel mode, workers already mid-test finish normally; only the unscheduled tail is skipped. |

### Mode / modeswitch overrides

When set, these patch the test source on the fly into a temporary copy under `.tmp/`; the on-disk test file is never modified.

| Flag | Effect |
|---|---|
| `--mode=NAME` | Override the `{$mode}` directive. If the source contains `{$mode X}`, that line is rewritten to `{$mode NAME}` in the temp copy. If the source has no `{$mode}` directive at all, `-MNAME` is appended to the compiler args instead (which has the same effect). |
| `--modeswitch=LIST` | Inject one or more `{$modeswitch}` directives. `LIST` is comma-separated; each entry is a name with an optional `+` (enable, the default) or `-` (disable) suffix. Examples: `--modeswitch=advancedrecords` enables one switch; `--modeswitch=helpers+,multihelpers-` enables `helpers` and explicitly disables `multihelpers`. |

Injection point for `--modeswitch` directives, first match wins:

1. immediately after the LAST existing `{$modeswitch ...}` directive in the source
2. immediately after the `{$mode ...}` directive
3. immediately after the first non-directive `{...}` comment
4. at the very top of the file

This ordering guarantees the injected directives are not silently overridden by a `{$mode}` directive that appears below them (which would reset all modeswitches to the new mode's defaults).

### Output

| Flag | Effect |
|---|---|
| `--list` | (also a selection flag, see above) |
| `--no-color` | Disable ANSI colors. Auto-applied when stdout is not a console (e.g. piped to a file). |
| `--keep-temp` | Keep `.tmp/W<i>/` artifacts of failing tests (`.exe`, `.o`, `.ppu`, etc.) so they can be inspected after the run. Passing tests are still cleaned. Without this flag the entire `.tmp/` tree is wiped at end of run. |
| `--help`, `-h` | Print the option list and exit. |

## Output files

Both files are written next to `testtool.exe` (`unleashed/tests/`).

### `tests.log`

One line per test, header form:

```
[2026-05-13 22:08:55] [PASS] autofree/autofree_basic_01.pp phase=run exit=0
[2026-05-13 22:08:55] [FAIL] match/match_subject_01.pp phase=run exit=2 (%TIMEOUT=5)
```

Suffix tags in parens echo the flags that were active for that test.

### `fail.log`

Only written when at least one test failed. Each failure entry repeats the header from `tests.log`, followed by indented compiler / runner output. Banner lines (`Free Pascal Compiler ...`, `Copyright ...`, `Target OS: ...`) and noisy absolute paths are stripped so the log stays readable. The leading `Compiling X:\full\path\testfiles\...` is shortened to `Compiling ...\testfiles\...`.

If a subsequent run has zero failures, the previous `fail.log` is deleted.

## Parallel execution

The runner spawns `N` worker threads, each pulling tests off a shared queue protected by a critical section. Each worker has its own `.tmp/W<i>/` subdirectory and sets its own `GTempDir` thread variable, so per-test `.exe` / `.o` / `.ppu` paths never collide even when two tests share the same source basename in different folders.

Test output is serialized through another critical section, so the per-test progress line `[N/M] path ... PASS` is printed atomically. Since workers finish out of order, the `N` is a completion counter (1, 2, 3, ...), not the dispatch index.

`--fail-fast` is honored cooperatively: when any worker observes a failure, it flips a flag that prevents further tests from being dispatched. Workers already mid-test let that test complete (so its result is recorded), then exit.

Default parallelism is `TThread.ProcessorCount div 2`, with a floor of 1.

## Comparing compilers

There is no built-in diff mode; the same effect is achieved with two runs:

```
testtool --fpc=our-ppc                                 # against the local build
testtool --fpc=trunk-ppc                               # against upstream trunk
diff fail.log fail.log.trunk
```

`--path=DIR` complements this for cross-suite comparisons:

```
testtool --fpc=our-ppc --path=../tests/webtbs          # FPC tracker suite, our compiler
testtool --fpc=trunk-ppc --path=../tests/webtbs        # same suite, upstream compiler
```

## Exit code

The runner exits `0` when every test passed, `1` when at least one failed, `2` for a usage / config error (e.g. testfiles directory does not exist).
