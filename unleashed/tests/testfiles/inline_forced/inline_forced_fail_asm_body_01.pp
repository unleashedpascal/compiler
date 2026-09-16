{ %FAIL %CPU=i386,x86_64 }
program inline_forced_fail_asm_body_01;
{$mode unleashed}
{$asmmode intel}

// the function result referenced from an asm block cannot be redirected to
// the inline result location (locals and value parameters can - see
// inline_forced_mixed_asm_*)

function GetVal: Int64; inline;
begin
  asm
    mov rax, 42
    mov GetVal, rax
  end;
end;

begin
  writeln(GetVal);
end.
