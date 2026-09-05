program testtool;

{$mode unleashed}

uses
  {$IFDEF UNIX}cthreads, termio,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, Process, StrUtils, SyncObjs;

const
  CompilerDefault = 'fpc';
  TestfilesSub    = 'testfiles';
  TempSub        = '.tmp';
  TestsLogName   = 'tests.log';
  FailLogName    = 'fail.log';
  ReadChunkSize  = 8192;

var
  AnsiReset:  String = #27'[0m';
  AnsiGreen:  String = #27'[32m';
  AnsiRed:    String = #27'[31m';
  AnsiYellow: String = #27'[33m';
  AnsiGray:   String = #27'[90m';
  AnsiBold:   String = #27'[1m';

type
  TFlags = record
    NoRun: Boolean;
    Fail: Boolean;
    Opt: String;
    Timeout: Integer;
    CheckBinHas: TStringArray;
    CheckBinLacks: TStringArray;
    Cpu: TStringArray;
    Precompile: String;
    ExpectMsg: String;
  end;

  TVerdict = (vPass, vFail, vSkip);

  TResult = record
    SrcPath: String;     // absolute path to test file
    RelPath: String;     // path relative to testfiles/
    Timestamp: String;   // 'yyyy-mm-dd hh:nn:ss' captured when the test started
    Flags: TFlags;
    Verdict: TVerdict;
    Phase: String;       // 'compile' / 'run' / 'expected-fail'
    ExitCode: Integer;
    Notes: String;
  end;

var
  GBaseDir: String;
  GTestfilesDir: String;
  GBaseTempDir: String;
  GCompilerPath: String;
  GTargetOS: String;
  GTargetCPU: String;
  GForceNoRun: Boolean;
  GFilter: String;
  GExclude: String;
  GLimit: Integer;
  GPathOverride: String;
  GListOnly: Boolean;
  GNoColor: Boolean;
  GKeepTemp: Boolean;
  GFailFast: Boolean;
  GOnlyFailed: Boolean;
  GTimeoutSec: Integer = 30;
  GParallel: Integer;
  GModeOverride: String;
  GModeswitches: TStringArray;
  GResults: array of TResult;

// each worker thread has its own temp subdir to avoid .exe/.o/.ppu collisions
threadvar
  GTempDir: String;

function IsConsoleOutput: Boolean;
{$IFDEF WINDOWS}
var
  h: THandle;
  mode: DWORD;
begin
  h := GetStdHandle(STD_OUTPUT_HANDLE);
  Result := (h <> 0) and (h <> INVALID_HANDLE_VALUE) and GetConsoleMode(h, mode);
end;
{$ELSE}
begin
  Result := IsATTY(StdOutputHandle) <> 0;
end;
{$ENDIF}

procedure DisableColor;
begin
  AnsiReset := ''; AnsiGreen := ''; AnsiRed := '';
  AnsiYellow := ''; AnsiGray := ''; AnsiBold := '';
end;

procedure EnableVT;
{$IFDEF WINDOWS}
const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = $0004;
var
  h: THandle;
  mode: DWORD;
begin
  h := GetStdHandle(STD_OUTPUT_HANDLE);
  if (h <> 0) and (h <> INVALID_HANDLE_VALUE) and GetConsoleMode(h, mode) then
    SetConsoleMode(h, mode or ENABLE_VIRTUAL_TERMINAL_PROCESSING);
end;
{$ELSE}
begin
end;
{$ENDIF}

function ReadFileHead(const Path: String; MaxBytes: Integer): String;
begin
  Result := '';
  var fs := autofree TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  SetLength(Result, MaxBytes);
  var bytes := fs.Read(Result[1], MaxBytes);
  SetLength(Result, bytes);
end;

function ExtractFirstFlagComment(const Source: String): String;
begin
  Result := '';
  var i := 1;
  while (i <= Length(Source)) and (Source[i] in [' ', #9, #10, #13]) do
    Inc(i);
  if (i > Length(Source)) or (Source[i] <> '{') then Exit;
  // skip compiler directive `{$...}`, not a flag comment
  if (i + 1 <= Length(Source)) and (Source[i + 1] = '$') then Exit;
  Inc(i);
  var j := i;
  while (j <= Length(Source)) and (Source[j] <> '}') do
    Inc(j);
  if j > Length(Source) then Exit;
  Result := Copy(Source, i, j - i);
end;

// whitespace-split tokenizer that honors `"..."` so multi-arg values stay
// in one token: %OPT="-O3 -OoDEADSTORE" -> single token `%OPT=-O3 -OoDEADSTORE`
function TokenizeFlagComment(const Source: String): TStringArray;
var
  current: String = '';
  inQuote: Boolean = false;
  c: Char;
begin
  Result := nil;
  for var i := 1 to Length(Source) do
  begin
    c := Source[i];
    if inQuote then
    begin
      if c = '"' then inQuote := false
      else current := current + c;
    end
    else if c = '"' then
      inQuote := true
    else if c in [' ', #9, #10, #13] then
    begin
      if current <> '' then
      begin
        Result := Result + [current];
        current := '';
      end;
    end
    else
      current := current + c;
  end;
  if current <> '' then
    Result := Result + [current];
end;

procedure ParseFlags(const CommentText: String; out Flags: TFlags);
begin
  Flags := Default(TFlags);
  if Trim(CommentText) = '' then Exit;
  var parts := TokenizeFlagComment(CommentText);
  for var p in parts do
  begin
    if not p.StartsWith('%') then continue;
    var eq := Pos('=', p);
    var key := UpperCase(if eq > 0 then Copy(p, 2, eq - 2) else Copy(p, 2, Length(p)));
    var value := if eq > 0 then Copy(p, eq + 1, Length(p)) else '';
    match key of
      'NORUN':      Flags.NoRun := true;
      'FAIL':       Flags.Fail := true;
      'OPT':        Flags.Opt := value;
      'TIMEOUT':    Flags.Timeout := StrToIntDef(value, 0);
      'CHECKBIN_HAS':   Flags.CheckBinHas := value.Split([','], TStringSplitOptions.ExcludeEmpty);
      'CHECKBIN_LACKS': Flags.CheckBinLacks := value.Split([','], TStringSplitOptions.ExcludeEmpty);
      'CPU':        Flags.Cpu := value.Split([','], TStringSplitOptions.ExcludeEmpty);
      'PRECOMPILE': Flags.Precompile := value;
      'EXPECTMSG':  Flags.ExpectMsg := value;
      _:            ; // unknown flag, ignore
    end;
  end;
end;

procedure RunCmd(const Exe: String; const Args: array of String;
                 const WorkDir: String; TimeoutSec: Integer;
                 out ExitCode: Integer; out Output: String; out TimedOut: Boolean);
var
  buf: array[0..ReadChunkSize - 1] of Byte;
begin
  Output := '';
  ExitCode := -1;
  TimedOut := false;
  var proc := autofree TProcess.Create(nil);
  var ms := autofree TMemoryStream.Create;
  proc.Executable := Exe;
  for var a in Args do
    proc.Parameters.Add(a);
  if WorkDir <> '' then
    proc.CurrentDirectory := WorkDir;
  proc.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
  proc.ShowWindow := swoHIDE;
  try
    proc.Execute;
  except
    on e: Exception do
    begin
      Output := 'execute failed: ' + e.Message;
      ExitCode := -1;
      Exit;
    end;
  end;
  var startMs := GetTickCount64;
  while proc.Running or (proc.Output.NumBytesAvailable > 0) do
  begin
    if (TimeoutSec > 0) and (GetTickCount64 - startMs > QWord(TimeoutSec) * 1000) then
    begin
      TimedOut := true;
      try proc.Terminate(124); except end;
      break;
    end;
    var n := proc.Output.NumBytesAvailable;
    if n > 0 then
    begin
      if n > sizeof(buf) then n := sizeof(buf);
      var bytesRead := proc.Output.Read(buf[0], n);
      if bytesRead > 0 then
        ms.WriteBuffer(buf[0], bytesRead);
    end
    else
      Sleep(5);
  end;
  if not TimedOut then
    ExitCode := proc.ExitStatus
  else
    ExitCode := 124;
  SetLength(Output, ms.Size);
  if ms.Size > 0 then
    Move(ms.Memory^, Output[1], ms.Size);
end;

// ask the compiler for one -i info item (e.g. -iTO / -iTP)
function QueryCompilerInfo(const InfoArg: String; out Value: String): Boolean;
var
  code: Integer;
  timedOut: Boolean;
begin
  RunCmd(GCompilerPath, [InfoArg], GBaseDir, 10, code, Value, timedOut);
  Value := Trim(Value);
  Result := (code = 0) and not timedOut and (Value <> '');
end;

// case-insensitive prefix check on a line, after stripping leading whitespace
function LineStartsWithDirective(const Line, Prefix: String): Boolean;
begin
  Result := StartsText(Prefix, TrimLeft(Line));
end;

// scan source lines for the {$mode ...} directive; -1 if not present
function FindModeLine(Lines: TStringList): Integer;
begin
  for var i := 0 to Lines.Count - 1 do
    if LineStartsWithDirective(Lines[i], '{$mode ') and (Pos('}', Lines[i]) > 0) then
      Exit(i);
  Result := -1;
end;

// pick the line index AFTER which CLI modeswitch directives should be inserted;
// -1 means "insert at the very top". priorities (first match wins):
//   1) after the LAST existing {$modeswitch ...}
//   2) after the {$mode ...} directive
//   3) after the first {...} comment that is not a directive
//   4) at top of file
function FindModeswitchInsertPoint(Lines: TStringList): Integer;
begin
  for var i := Lines.Count - 1 downto 0 do
    if LineStartsWithDirective(Lines[i], '{$modeswitch ') and (Pos('}', Lines[i]) > 0) then
      Exit(i);
  for var i := 0 to Lines.Count - 1 do
    if LineStartsWithDirective(Lines[i], '{$mode ') and (Pos('}', Lines[i]) > 0) then
      Exit(i);
  for var i := 0 to Lines.Count - 1 do
  begin
    var trimmed := TrimLeft(Lines[i]);
    if (trimmed = '') or (trimmed[1] <> '{') then continue;
    if (Length(trimmed) >= 2) and (trimmed[2] = '$') then continue;
    if Pos('}', trimmed) > 0 then Exit(i);
    for var j := i + 1 to Lines.Count - 1 do
      if Pos('}', Lines[j]) > 0 then Exit(j);
    break;
  end;
  Result := -1;
end;

// build a `{$modeswitch NAME+}` / `{$modeswitch NAME-}` directive from a CLI
// token; trailing `+` or `-` selects state, default is `+`
function BuildModeswitchLine(const Token: String): String;
var
  name, sign: String;
begin
  name := Token;
  sign := '+';
  if (Length(name) > 0) and (name[Length(name)] in ['+', '-']) then
  begin
    sign := name[Length(name)];
    name := Copy(name, 1, Length(name) - 1);
  end;
  Result := '{$modeswitch ' + name + sign + '}';
end;

// rewrite the test source into a temp file applying --mode and --modeswitch
// CLI overrides; out param tells caller to add `-M<mode>` to compiler args
// when --mode was set but the source had no own {$mode} to replace
function PreparePatchedSource(const SrcPath: String; out NeedsCmdLineMode: Boolean): String;
begin
  Result := '';
  NeedsCmdLineMode := false;
  if (GModeOverride = '') and (Length(GModeswitches) = 0) then Exit;

  var lines := autofree TStringList.Create;
  lines.LoadFromFile(SrcPath);
  var changed := false;

  if GModeOverride <> '' then
  begin
    var idx := FindModeLine(lines);
    if idx >= 0 then
    begin
      lines[idx] := '{$mode ' + GModeOverride + '}';
      changed := true;
    end
    else
      NeedsCmdLineMode := true;
  end;

  if Length(GModeswitches) > 0 then
  begin
    var anchor := FindModeswitchInsertPoint(lines);
    for var i := High(GModeswitches) downto 0 do
      lines.Insert(anchor + 1, BuildModeswitchLine(GModeswitches[i]));
    changed := true;
  end;

  if not changed then Exit;

  Result := IncludeTrailingPathDelimiter(GTempDir) +
            ChangeFileExt(ExtractFileName(SrcPath), '__mod.pp');
  lines.SaveToFile(Result);
end;

function BuildCompileArgs(const SrcPath: String; const Flags: TFlags;
                         const PatchedSrc: String; NeedsCmdLineMode: Boolean): TStringArray;
begin
  Result := nil;
  var optParts: TStringArray := nil;
  if Flags.Opt <> '' then
    optParts := Flags.Opt.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  // %OPT may retarget the test to another cpu (e.g. -Pi386 for stabs
  // coverage); the default -T/-P would feed the redirected compiler a
  // target it does not know, so drop them and let the driver pick the
  // native OS for that cpu
  var retarget := false;
  for var op in optParts do
    if op.StartsWith('-P') and (Length(op) > 2) then retarget := true;
  // intermediate + exe output go to .tmp/
  Result := Result + ['-FE' + GTempDir];
  Result := Result + ['-FU' + GTempDir];
  if not retarget then
  begin
    Result := Result + ['-T' + GTargetOS];
    Result := Result + ['-P' + GTargetCPU];
  end;
  // -g- cancels any -g from fpc.cfg so test binaries never carry debug info;
  // -CX/-XX/-Xs do smart link + strip so the produced exe is minimal release
  // shape (smaller, faster I/O, less noise for %CHECKBIN_* searches)
  Result := Result + ['-g-'];
  Result := Result + ['-CX'];
  Result := Result + ['-XX'];
  Result := Result + ['-Xs'];
  // patched copy lives in .tmp/, so the original test dir must be on the include
  // search path for {$I ...} and unit-uses to keep resolving
  if PatchedSrc <> '' then
  begin
    var srcDir := ExcludeTrailingPathDelimiter(ExtractFilePath(SrcPath));
    Result := Result + ['-Fi' + srcDir];
    Result := Result + ['-Fu' + srcDir];
  end;
  // --mode set but source had no own {$mode} to replace; pass it via -M
  if NeedsCmdLineMode then
    Result := Result + ['-M' + GModeOverride];
  for var op in optParts do
    Result := Result + [op];
  Result := Result + [if PatchedSrc <> '' then PatchedSrc else SrcPath];
end;

function ProducedExePath(const SrcPath, PatchedSrc: String): String;
begin
  var base := if PatchedSrc <> '' then PatchedSrc else SrcPath;
  Result := IncludeTrailingPathDelimiter(GTempDir) +
            ChangeFileExt(ExtractFileName(base), '.exe');
end;

// %PRECOMPILE units are compiled next to their source, so the test dir must
// be brought back to .pp-only state afterwards; a .tmp copy can appear too
// when the main compile decides to recompile the unit (-FU points there)
procedure CleanupUnitArtifacts(const UnitSrc: String);
begin
  if UnitSrc = '' then Exit;
  var exts: array of String := ['.ppu', '.o'];
  var tmpStem := IncludeTrailingPathDelimiter(GTempDir) +
                 ChangeFileExt(ExtractFileName(UnitSrc), '');
  for var e in exts do
  begin
    if FileExists(ChangeFileExt(UnitSrc, e)) then
      DeleteFile(ChangeFileExt(UnitSrc, e));
    if FileExists(tmpStem + e) then
      DeleteFile(tmpStem + e);
  end;
end;

procedure CleanupTempArtifacts(const SrcPath, PatchedSrc: String; Failed: Boolean);
begin
  if GKeepTemp and Failed then Exit;
  var exts: array of String := ['.exe', '.o', '.ppu', '.lst', '.res', '.compiled', '.rsj'];
  var base := if PatchedSrc <> '' then PatchedSrc else SrcPath;
  var stem := IncludeTrailingPathDelimiter(GTempDir) +
              ChangeFileExt(ExtractFileName(base), '');
  for var e in exts do
    if FileExists(stem + e) then
      DeleteFile(stem + e);
  if (PatchedSrc <> '') and FileExists(PatchedSrc) then
    DeleteFile(PatchedSrc);
end;

function FormatVerdict(const R: TResult): String;
begin
  Result := (if R.Verdict = vPass then AnsiGreen + 'PASS'
             else if R.Verdict = vSkip then AnsiYellow + 'SKIP'
             else AnsiRed + 'FAIL') + AnsiReset;
end;

// scan ExePath for substrings; mutates R to FAIL with a note on first violation
procedure CheckBinaryContents(const ExePath: String; const Has, Lacks: TStringArray;
                              var R: TResult);
begin
  if (Length(Has) = 0) and (Length(Lacks) = 0) then Exit;
  if not FileExists(ExePath) then
  begin
    R.Verdict := vFail;
    R.Phase := 'checkbin';
    R.Notes := 'binary not found for inspection: ' + ExePath;
    Exit;
  end;
  var fs := autofree TFileStream.Create(ExePath, fmOpenRead or fmShareDenyNone);
  var data: AnsiString;
  data := '';
  if fs.Size > 0 then
  begin
    SetLength(data, fs.Size);
    fs.Read(data[1], fs.Size);
  end;
  for var s in Has do
    if Pos(s, data) = 0 then
    begin
      R.Verdict := vFail;
      R.Phase := 'checkbin';
      R.Notes := '%CHECKBIN_HAS missed: `' + s + '`';
      Exit;
    end;
  for var s in Lacks do
    if Pos(s, data) > 0 then
    begin
      R.Verdict := vFail;
      R.Phase := 'checkbin';
      R.Notes := '%CHECKBIN_LACKS hit: `' + s + '`';
      Exit;
    end;
end;

procedure RunSingleTest(const SrcPath: String; var R: TResult);
begin
  R := Default(TResult);
  R.SrcPath := SrcPath;
  R.RelPath := ExtractRelativePath(IncludeTrailingPathDelimiter(GTestfilesDir), SrcPath);
  R.Timestamp := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);

  var comment := ExtractFirstFlagComment(ReadFileHead(SrcPath, ReadChunkSize));
  ParseFlags(comment, R.Flags);

  // %CPU gate: the test only applies to the listed target cpus
  if Length(R.Flags.Cpu) > 0 then
  begin
    var cpuOk := false;
    for var c in R.Flags.Cpu do
      if SameText(c, GTargetCPU) then cpuOk := true;
    if not cpuOk then
    begin
      R.Verdict := vSkip;
      R.Phase := 'skip';
      R.Notes := 'target cpu ' + GTargetCPU + ' not in %CPU list';
      Exit;
    end;
  end;

  var needsCmdLineMode: Boolean;
  var patched := PreparePatchedSource(SrcPath, needsCmdLineMode);
  defer CleanupTempArtifacts(SrcPath, patched, R.Verdict = vFail);

  var timeoutSec := if R.Flags.Timeout > 0 then R.Flags.Timeout else GTimeoutSec;

  // %PRECOMPILE=unit.pas: compile a helper unit in its own compiler
  // invocation, so the main compile loads it back from the ppu (exercising
  // the ppu roundtrip) instead of reusing in-memory defs
  var preUnitSrc := if R.Flags.Precompile <> '' then
    ExtractFilePath(SrcPath) + R.Flags.Precompile else '';
  defer CleanupUnitArtifacts(preUnitSrc);
  if preUnitSrc <> '' then
  begin
    var preDir := ExcludeTrailingPathDelimiter(ExtractFilePath(SrcPath));
    var preExit: Integer;
    var preOut: String;
    var preTimedOut: Boolean;
    // codegen flags must match BuildCompileArgs, otherwise the main compile
    // recompiles the unit in-process and the ppu is never loaded back
    RunCmd(GCompilerPath, ['-FE' + preDir, '-FU' + preDir, '-T' + GTargetOS, '-P' + GTargetCPU,
           '-g-', '-CX', '-XX', '-Xs', preUnitSrc],
           GBaseDir, timeoutSec, preExit, preOut, preTimedOut);
    if preTimedOut or (preExit <> 0) then
    begin
      R.Verdict := vFail;
      R.Phase := 'precompile';
      R.ExitCode := preExit;
      R.Notes := if preTimedOut then
        Format('precompile exceeded %d seconds', [timeoutSec]) else preOut;
      Exit;
    end;
  end;

  var args := BuildCompileArgs(SrcPath, R.Flags, patched, needsCmdLineMode);
  var compileExit: Integer;
  var compilerOut: String;
  var compileTimedOut: Boolean;
  RunCmd(GCompilerPath, args, GBaseDir, timeoutSec, compileExit, compilerOut, compileTimedOut);

  // compile timed out
  if compileTimedOut then
  begin
    R.Verdict := vFail;
    R.Phase := 'compile-timeout';
    R.ExitCode := compileExit;
    R.Notes := Format('compile exceeded %d seconds', [timeoutSec]);
    Exit;
  end;

  // %EXPECTMSG: the compiler output must carry the text, whatever the verdict
  if (R.Flags.ExpectMsg <> '') and (Pos(R.Flags.ExpectMsg, compilerOut) = 0) then
  begin
    R.Verdict := vFail;
    R.Phase := 'compile';
    R.ExitCode := compileExit;
    R.Notes := 'expected compiler output to contain "' + R.Flags.ExpectMsg + '"' + LineEnding + compilerOut;
    Exit;
  end;

  // expected to fail compilation
  if R.Flags.Fail then
  begin
    if compileExit <> 0 then
    begin
      R.Verdict := vPass;
      R.Phase := 'expected-fail';
      R.ExitCode := compileExit;
    end
    else
    begin
      R.Verdict := vFail;
      R.Phase := 'compile';
      R.ExitCode := 0;
      R.Notes := 'expected compilation to fail but it succeeded';
    end;
    Exit;
  end;

  // expected to compile
  if compileExit <> 0 then
  begin
    R.Verdict := vFail;
    R.Phase := 'compile';
    R.ExitCode := compileExit;
    R.Notes := compilerOut;
    Exit;
  end;

  var exePath := ProducedExePath(SrcPath, patched);

  // %NORUN or global --norun: don't run, success on compile
  if R.Flags.NoRun or GForceNoRun then
  begin
    R.Verdict := vPass;
    R.Phase := 'compile';
    R.ExitCode := 0;
    CheckBinaryContents(exePath, R.Flags.CheckBinHas, R.Flags.CheckBinLacks, R);
    Exit;
  end;

  // run the produced exe
  if not FileExists(exePath) then
  begin
    R.Verdict := vFail;
    R.Phase := 'run';
    R.ExitCode := -1;
    R.Notes := 'compiled but exe not found at ' + exePath;
    Exit;
  end;

  var runExit: Integer;
  var runOut: String;
  var runTimedOut: Boolean;
  RunCmd(exePath, [], ExtractFilePath(SrcPath), timeoutSec, runExit, runOut, runTimedOut);
  R.ExitCode := runExit;
  if runTimedOut then
  begin
    R.Verdict := vFail;
    R.Phase := 'run-timeout';
    R.Notes := Format('run exceeded %d seconds', [timeoutSec]);
  end
  else
  begin
    R.Phase := 'run';
    if runExit = 0 then
    begin
      R.Verdict := vPass;
      CheckBinaryContents(exePath, R.Flags.CheckBinHas, R.Flags.CheckBinLacks, R);
    end
    else
    begin
      R.Verdict := vFail;
      R.Notes := runOut;
    end;
  end;
end;

// a unit source without any %-flag comment is a %PRECOMPILE helper for some
// test, not a runnable test; a unit carrying flags (e.g. %NORUN compile-only
// regression) stays a test
function IsUnitSource(const Path: String): Boolean;
begin
  Result := false;
  var head := LowerCase(ReadFileHead(Path, 2048));
  var i := 1;
  while i <= Length(head) do
    if head[i] in [' ', #9, #10, #13] then
      Inc(i)
    else if head[i] = '{' then
    begin
      while (i <= Length(head)) and (head[i] <> '}') do
      begin
        if head[i] = '%' then Exit;
        Inc(i);
      end;
      Inc(i);
    end
    else if (head[i] = '/') and (i < Length(head)) and (head[i + 1] = '/') then
    begin
      while (i <= Length(head)) and not (head[i] in [#10, #13]) do
        Inc(i);
    end
    else
      break;
  Result := (Copy(head, i, 4) = 'unit') and (i + 4 <= Length(head)) and
            (head[i + 4] in [' ', #9, #10, #13]);
end;

procedure DiscoverTests(const Dir: String; List: TStringList);
var
  sr: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') or (sr.Name = TempSub) then
        continue;
      var full := IncludeTrailingPathDelimiter(Dir) + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then
        DiscoverTests(full, List)
      else if EndsText('.pp', sr.Name) or EndsText('.pas', sr.Name) then
      begin
        if (GFilter <> '') and not ContainsText(full, GFilter) then continue;
        if (GExclude <> '') and ContainsText(full, GExclude) then continue;
        if IsUnitSource(full) then continue;
        List.Add(full);
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

// extract test paths from a previous fail.log; lines like
//   [TS] [FAIL] some/test.pp phase=run exit=1 ...
// the rel path lives between '] [FAIL] ' and ' phase='
procedure LoadFailedPaths(const Path: String; Sink: TStringList);
begin
  var raw := autofree TStringList.Create;
  if not FileExists(Path) then Exit;
  raw.LoadFromFile(Path);
  for var i := 0 to raw.Count - 1 do
  begin
    var line := raw[i];
    var p := Pos('] [FAIL] ', line);
    if p = 0 then continue;
    var startPos := p + Length('] [FAIL] ');
    var endPos := PosEx(' phase=', line, startPos);
    if endPos = 0 then continue;
    Sink.Add(Copy(line, startPos, endPos - startPos));
  end;
end;

procedure WipeDir(const Dir: String);
var
  sr: TSearchRec;
begin
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then continue;
      var full := IncludeTrailingPathDelimiter(Dir) + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then
      begin
        WipeDir(full);
        RemoveDir(full);
      end
      else
        DeleteFile(full);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

procedure PrepareTempDirs;
begin
  if not DirectoryExists(GBaseTempDir) then
  begin
    ForceDirectories(GBaseTempDir);
    Exit;
  end;
  WipeDir(GBaseTempDir);
end;

// drop empty worker subdirs at end of run; with --keep-temp, dirs holding
// failed-test artifacts stay (RemoveDir fails silently on non-empty)
procedure FinalizeTempDirs;
var
  sr: TSearchRec;
begin
  if not DirectoryExists(GBaseTempDir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(GBaseTempDir) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then continue;
      if (sr.Attr and faDirectory) <> 0 then
        RemoveDir(IncludeTrailingPathDelimiter(GBaseTempDir) + sr.Name);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  RemoveDir(GBaseTempDir);
end;

procedure AppendFilteredNotes(const Raw: String; Sink: TStringList);
const
  Pad = '  ';
begin
  var lines := autofree TStringList.Create;
  // TStringList.Text splits on both \r\n and \n
  lines.Text := Raw;
  for var i := 0 to lines.Count - 1 do
  begin
    var s := TrimRight(lines[i]);
    var t := TrimLeft(s);
    if t = '' then continue;
    // skip the compiler banner that prefixes every fpc invocation
    if t.StartsWith('Free Pascal Compiler') then continue;
    if t.StartsWith('Copyright') then continue;
    if t.StartsWith('Target OS:') then continue;
    // shorten the absolute `Compiling X:\...\testfiles\...` path to `...\testfiles\...`
    var compIdx := Pos('Compiling ', t);
    if compIdx = 1 then
    begin
      var tfIdx := Pos('\testfiles\', t);
      if tfIdx > 0 then
        t := 'Compiling ...' + Copy(t, tfIdx, MaxInt);
      Sink.Add(Pad + t);
      continue;
    end;
    Sink.Add(Pad + t);
  end;
end;

procedure WriteLogs;
var
  failCount: Integer = 0;
begin
  var testsLog := autofree TStringList.Create;
  var failLog := autofree TStringList.Create;
  for var i := 0 to High(GResults) do
  begin
    var r := GResults[i];
    var head := Format('[%s] [%s] %s phase=%s exit=%d',
                       [r.Timestamp,
                        (if r.Verdict = vPass then 'PASS'
                         else if r.Verdict = vSkip then 'SKIP'
                         else 'FAIL'),
                        r.RelPath, r.Phase, r.ExitCode]);
    if r.Flags.Fail then head += ' (%FAIL)';
    if r.Flags.NoRun then head += ' (%NORUN)';
    if r.Flags.Opt <> '' then head += ' (%OPT=' + r.Flags.Opt + ')';
    if r.Flags.Precompile <> '' then head += ' (%PRECOMPILE=' + r.Flags.Precompile + ')';
    if r.Flags.Timeout > 0 then head += ' (%TIMEOUT=' + IntToStr(r.Flags.Timeout) + ')';
    if Length(r.Flags.CheckBinHas) > 0 then
      head += ' (%CHECKBIN_HAS=' + String.Join(',', r.Flags.CheckBinHas) + ')';
    if Length(r.Flags.CheckBinLacks) > 0 then
      head += ' (%CHECKBIN_LACKS=' + String.Join(',', r.Flags.CheckBinLacks) + ')';
    if Length(r.Flags.Cpu) > 0 then
      head += ' (%CPU=' + String.Join(',', r.Flags.Cpu) + ')';
    testsLog.Add(head);
    if r.Verdict = vFail then
    begin
      Inc(failCount);
      failLog.Add(head);
      if Trim(r.Notes) <> '' then
        AppendFilteredNotes(r.Notes, failLog);
    end;
  end;
  testsLog.SaveToFile(IncludeTrailingPathDelimiter(GBaseDir) + TestsLogName);
  if failCount > 0 then
    failLog.SaveToFile(IncludeTrailingPathDelimiter(GBaseDir) + FailLogName)
  else if FileExists(IncludeTrailingPathDelimiter(GBaseDir) + FailLogName) then
    DeleteFile(IncludeTrailingPathDelimiter(GBaseDir) + FailLogName);
end;

// shared queue state for the worker pool
var
  GTaskCS: TCriticalSection;
  GOutputCS: TCriticalSection;
  GFiles: TStringList;
  GNextTaskIdx: Integer;
  GCompleted: Integer;
  GStopRequested: Boolean;

type
  TTestWorker = class(TThread)
  private
    FIdx: Integer;
    FTempDir: String;
  protected
    procedure Execute; override;
  public
    constructor Create(Idx: Integer; const TempDir: String);
  end;

constructor TTestWorker.Create(Idx: Integer; const TempDir: String);
begin
  FreeOnTerminate := false;
  FIdx := Idx;
  FTempDir := TempDir;
  inherited Create(false);
end;

function NextTaskIndex: Integer;
begin
  GTaskCS.Enter;
  try
    if GStopRequested or (GNextTaskIdx >= GFiles.Count) then Exit(-1);
    Result := GNextTaskIdx;
    Inc(GNextTaskIdx);
  finally
    GTaskCS.Leave;
  end;
end;

procedure TTestWorker.Execute;
begin
  GTempDir := FTempDir;
  ForceDirectories(FTempDir);
  while not Terminated do
  begin
    var idx := NextTaskIndex;
    if idx < 0 then break;
    RunSingleTest(GFiles[idx], GResults[idx]);
    GOutputCS.Enter;
    try
      Inc(GCompleted);
      var rel := ExtractRelativePath(IncludeTrailingPathDelimiter(GTestfilesDir), GFiles[idx]);
      WriteLn(Format('[%d/%d] %s ... %s',
                     [GCompleted, GFiles.Count, rel, FormatVerdict(GResults[idx])]));
      if GFailFast and (GResults[idx].Verdict = vFail) then
        GStopRequested := true;
    finally
      GOutputCS.Leave;
    end;
  end;
end;

procedure RunAllTests(Files: TStringList);
var
  workers: array of TTestWorker;
begin
  GFiles := Files;
  GNextTaskIdx := 0;
  GCompleted := 0;
  GStopRequested := false;
  GTaskCS := TCriticalSection.Create;
  GOutputCS := TCriticalSection.Create;
  try
    var n := GParallel;
    if n > Files.Count then n := Files.Count;
    if n < 1 then n := 1;
    SetLength(workers, n);
    for var i := 0 to High(workers) do
      workers[i] := TTestWorker.Create(i,
        IncludeTrailingPathDelimiter(GBaseTempDir) + 'W' + IntToStr(i));
    for var i := 0 to High(workers) do
    begin
      workers[i].WaitFor;
      workers[i].Free;
    end;
  finally
    GTaskCS.Free;
    GOutputCS.Free;
  end;
end;

procedure PrintHelp;
begin
  WriteLn('testtool - Unleashed Pascal test runner');
  WriteLn;
  WriteLn('usage: testtool [options]');
  WriteLn;
  WriteLn('options:');
  WriteLn('  --fpc=PATH       override the fpc compiler (default: fpc on PATH)');
  WriteLn('  --path=DIR       override testfiles dir (default: testfiles/ next to exe)');
  WriteLn('  --norun          force %NORUN on every test (compile only)');
  WriteLn('  --filter=SUBSTR  run only tests whose path contains SUBSTR');
  WriteLn('  --exclude=SUBSTR skip tests whose path contains SUBSTR (after --filter)');
  WriteLn('  --limit=N        run at most N tests (after --filter)');
  WriteLn('  --list           list discovered tests and exit (do not run)');
  WriteLn('  --no-color       disable ANSI colors (auto-off when piped)');
  WriteLn('  --keep-temp      keep .tmp/ artifacts of failing tests for debugging');
  WriteLn('  --fail-fast      stop at the first failing test');
  WriteLn('  --only-failed    rerun only tests that failed in the previous fail.log');
  WriteLn('  --timeout=N      per-test timeout in seconds (default 30; 0 = no limit)');
  WriteLn('  --parallel=N     run N workers in parallel (default: half of CPU cores)');
  WriteLn('  --mode=NAME      override {$mode} in source (or pass -MNAME if absent)');
  WriteLn('  --modeswitch=L   comma-separated list, e.g. `a+,b-,c`; injected as');
  WriteLn('                   {$modeswitch X+/-} below source modeswitches/{$mode}');
  WriteLn('  --help, -h       show this help');
  WriteLn;
  WriteLn('test file flags (in the first {...} comment of the file):');
  WriteLn('  %NORUN           compile only, do not run');
  WriteLn('  %FAIL            test must NOT compile (compile failure = pass)');
  WriteLn('  %OPT=...         extra args passed to fpc');
  WriteLn('  %TIMEOUT=N       per-test timeout in seconds (overrides --timeout)');
  WriteLn('  %CHECKBIN_HAS=L  comma-separated list; each MUST be present in the exe');
  WriteLn('  %CHECKBIN_LACKS=L  same, but each MUST NOT be present (e.g. striprtti)');
  WriteLn('                   (when set, fpc gets `-Xs -XX -CX` for cleaner binary)');
  WriteLn('  %CPU=L           comma-separated cpu list (e.g. x86_64,aarch64); the');
  WriteLn('                   test is skipped when the target cpu is not listed');
  WriteLn('  %EXPECTMSG=S     the compiler output must contain S (quote it when it');
  WriteLn('                   has spaces); checked for passing and %FAIL tests alike');
  WriteLn;
  WriteLn('logs are written next to testtool.exe:');
  WriteLn('  tests.log  - one line per test');
  WriteLn('  fail.log   - failures only with compiler/runner output (only if any failed)');
end;

procedure ParseCmdLine;
begin
  for var i := 1 to ParamCount do
  begin
    var a := ParamStr(i);
    match
      a.StartsWith('--fpc='):    GCompilerPath := Copy(a, 7, MaxInt);
      a.StartsWith('--path='):   GPathOverride := Copy(a, 8, MaxInt);
      a = '--norun':             GForceNoRun := true;
      a.StartsWith('--filter='):  GFilter := Copy(a, 10, MaxInt);
      a.StartsWith('--exclude='): GExclude := Copy(a, 11, MaxInt);
      a.StartsWith('--limit='):   GLimit := StrToIntDef(Copy(a, 9, MaxInt), 0);
      a = '--list':              GListOnly := true;
      a = '--no-color':          GNoColor := true;
      a = '--keep-temp':         GKeepTemp := true;
      a = '--fail-fast':         GFailFast := true;
      a = '--only-failed':       GOnlyFailed := true;
      a.StartsWith('--timeout='):    GTimeoutSec := StrToIntDef(Copy(a, 11, MaxInt), 30);
      a.StartsWith('--parallel='):   GParallel := StrToIntDef(Copy(a, 12, MaxInt), 0);
      a.StartsWith('--mode='):       GModeOverride := Copy(a, 8, MaxInt);
      a.StartsWith('--modeswitch='): GModeswitches := Copy(a, 14, MaxInt).Split([','], TStringSplitOptions.ExcludeEmpty);
      (a = '--help') or (a = '-h'):
        begin
          PrintHelp;
          Halt(0);
        end;
      _:                         WriteLn('warning: unknown argument: ', a);
    end;
  end;
end;

procedure Main;
begin
  GBaseDir := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  if GBaseDir = '' then
    GBaseDir := GetCurrentDir;

  GBaseTempDir := IncludeTrailingPathDelimiter(GBaseDir) + TempSub;

  ParseCmdLine;

  if GParallel <= 0 then
    GParallel := TThread.ProcessorCount div 2;
  if GParallel < 1 then GParallel := 1;

  if GNoColor or not IsConsoleOutput then
    DisableColor
  else
    EnableVT;

  if GPathOverride <> '' then
    GTestfilesDir := ExpandFileName(GPathOverride)
  else
    GTestfilesDir := IncludeTrailingPathDelimiter(GBaseDir) + TestfilesSub;

  if GCompilerPath = '' then
    GCompilerPath := CompilerDefault;

  // compile for whatever target the compiler reports via -iTO/-iTP, so cross
  // compilers (e.g. ppcross386) get a matching -T/-P pair
  if not QueryCompilerInfo('-iTO', GTargetOS) or
     not QueryCompilerInfo('-iTP', GTargetCPU) then
  begin
    WriteLn(AnsiRed, 'error: cannot query target OS/CPU from compiler: ', GCompilerPath, AnsiReset);
    Halt(2);
  end;

  if not DirectoryExists(GTestfilesDir) then
  begin
    WriteLn(AnsiRed, 'error: testfiles directory not found: ', GTestfilesDir, AnsiReset);
    Halt(2);
  end;

  PrepareTempDirs;

  var files := autofree TStringList.Create;
  files.Sorted := true;
  DiscoverTests(GTestfilesDir, files);
  if files.Count = 0 then
  begin
    WriteLn(AnsiYellow, 'no test files found in ', GTestfilesDir, AnsiReset);
    Halt(0);
  end;

  WriteLn('compiler: ', GCompilerPath);
  WriteLn('target: ', GTargetCPU, '-', GTargetOS);
  WriteLn('tests dir: ', GTestfilesDir);
  WriteLn('discovered ', files.Count, ' test file(s)');
  if GFilter <> '' then
    WriteLn('filter: ', GFilter);
  if GExclude <> '' then
    WriteLn('exclude: ', GExclude);
  if GOnlyFailed then
  begin
    var failedPaths := autofree TStringList.Create;
    failedPaths.Sorted := true;
    failedPaths.Duplicates := dupIgnore;
    LoadFailedPaths(IncludeTrailingPathDelimiter(GBaseDir) + FailLogName, failedPaths);
    if failedPaths.Count = 0 then
    begin
      WriteLn(AnsiYellow, 'no previous fail.log entries to rerun', AnsiReset);
      Halt(0);
    end;
    var before := files.Count;
    for var i := files.Count - 1 downto 0 do
    begin
      var rel := ExtractRelativePath(IncludeTrailingPathDelimiter(GTestfilesDir), files[i]);
      if failedPaths.IndexOf(rel) < 0 then
        files.Delete(i);
    end;
    WriteLn('only-failed: ', files.Count, ' (of ', before, ' discovered, ',
            failedPaths.Count, ' in fail.log)');
  end;
  if (GLimit > 0) and (files.Count > GLimit) then
  begin
    WriteLn('limit: ', GLimit, ' (of ', files.Count, ')');
    while files.Count > GLimit do
      files.Delete(files.Count - 1);
  end;
  if GListOnly then
  begin
    for var i := 0 to files.Count - 1 do
      WriteLn(ExtractRelativePath(IncludeTrailingPathDelimiter(GTestfilesDir), files[i]));
    Halt(0);
  end;
  if GForceNoRun then
    WriteLn('mode: --norun (compile only)');
  if GParallel > 1 then
    WriteLn('parallel: ', GParallel, ' workers');
  WriteLn;

  SetLength(GResults, files.Count);
  var startMs := GetTickCount64;
  RunAllTests(files);
  var totalMs := GetTickCount64 - startMs;

  // workers may have finished fewer than files.Count under --fail-fast
  SetLength(GResults, GCompleted);
  var passed := 0;
  var failed := 0;
  var skipped := 0;
  for var i := 0 to High(GResults) do
    if GResults[i].Verdict = vPass then Inc(passed)
    else if GResults[i].Verdict = vSkip then Inc(skipped)
    else Inc(failed);

  WriteLogs;
  FinalizeTempDirs;

  WriteLn;
  WriteLn(AnsiBold, GCompleted, ' tests, ', AnsiReset,
          AnsiGreen, passed, ' passed', AnsiReset, ', ',
          (if failed = 0 then AnsiGray else AnsiRed), failed, ' failed', AnsiReset,
          (if skipped > 0 then ', ' + AnsiYellow + IntToStr(skipped) + ' skipped' + AnsiReset else ''),
          ' (', totalMs, ' ms)');
  WriteLn('logs: ', IncludeTrailingPathDelimiter(GBaseDir), TestsLogName);
  if failed > 0 then
  begin
    WriteLn('     ', IncludeTrailingPathDelimiter(GBaseDir), FailLogName);
    Halt(1);
  end;
end;

begin
  Main;
end.
