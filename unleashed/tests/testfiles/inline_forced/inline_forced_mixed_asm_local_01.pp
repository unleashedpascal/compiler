{ %CPU=i386,x86_64 }
program inline_forced_mixed_asm_local_01;
{$mode unleashed}
{$asmmode intel}

// a Pascal body with an embedded asm statement referencing a local: the local
// gets symbol-backed storage per expansion and the asm operand is redirected

function get_inl(seed: dword): dword; inline;
var d: dword;
begin
  d := seed;
  asm
    mov eax, [d]
    add eax, 100
    mov [d], eax
  end;
  Result := d;
end;

function get_call(seed: dword): dword;
var d: dword;
begin
  d := seed;
  asm
    mov eax, [d]
    add eax, 100
    mov [d], eax
  end;
  Result := d;
end;

procedure proc_host;
var a, b: dword;
begin
  // two expansions in one routine -> two distinct backing symbols
  a := get_inl(1);
  b := get_inl(20);
  if a <> get_call(1) then Halt(1);
  if b <> get_call(20) then Halt(2);
end;

var p: dword;
begin
  proc_host;
  // the main program block hosts the backing symbol as a static
  p := get_inl(5);
  if p <> 105 then Halt(3);
end.
