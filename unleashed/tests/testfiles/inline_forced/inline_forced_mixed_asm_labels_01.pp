{ %CPU=i386,x86_64 }
program inline_forced_mixed_asm_labels_01;
{$mode unleashed}
{$asmmode intel}

// local labels inside the embedded asm must be renamed per expansion

function clamp_inl(x: longint): longint; inline;
var r: longint;
begin
  r := x;
  asm
    mov eax, [r]
    test eax, eax
    jns @@pos
    xor eax, eax
    mov [r], eax
@@pos:
  end;
  Result := r;
end;

begin
  if clamp_inl(7) <> 7 then Halt(1);
  if clamp_inl(-3) <> 0 then Halt(2);
end.
