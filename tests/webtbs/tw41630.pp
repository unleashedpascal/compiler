{ %norun }
{ %cpu=x86_64 }

{$mode delphi}
{$asmmode intel}

procedure LoadStore(Buffer: Pointer); assembler;
asm
  movss xmm2, [Buffer]
  movss [Buffer], xmm2
  vmovss xmm2, [Buffer]
  vmovss [Buffer], xmm2
end;

begin
end.
