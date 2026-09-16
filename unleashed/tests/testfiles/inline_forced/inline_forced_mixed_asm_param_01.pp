{ %CPU=i386,x86_64 }
program inline_forced_mixed_asm_param_01;
{$mode unleashed}
{$asmmode intel}

// a value parameter referenced from an asm statement: the whole parameter is
// routed through the backing symbol so Pascal and asm sides share storage

function dbl_inl(x: dword): dword; inline;
begin
  asm
    mov eax, [x]
    add eax, eax
    mov [x], eax
  end;
  Result := x;
end;

begin
  if dbl_inl(21) <> 42 then Halt(1);
  if dbl_inl(100) <> 200 then Halt(2);
end.
