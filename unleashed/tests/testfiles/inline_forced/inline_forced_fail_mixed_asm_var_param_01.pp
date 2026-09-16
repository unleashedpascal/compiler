{ %FAIL %CPU=i386,x86_64 }
program inline_forced_fail_mixed_asm_var_param_01;
{$mode unleashed}
{$asmmode intel}

// a by-reference parameter referenced from an asm statement cannot be
// redirected to caller storage

procedure bump(var v: dword); inline;
begin
  asm
    mov eax, [v]
    inc eax
    mov [v], eax
  end;
end;

var
  x: dword;
begin
  x := 5;
  bump(x);
  writeln(x);
end.
