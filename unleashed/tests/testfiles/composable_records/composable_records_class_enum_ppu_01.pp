{ %PRECOMPILE=ucomposable_records_class_enum_ppu_01.pas }
program composable_records_class_enum_ppu_01;

// a unit compiled with composable records keeps a class-scoped enum inside
// the class symtable; loading that PPU from a non-composable mode must not
// try to redirect the enum into the unit scope
{$mode objfpc}

uses ucomposable_records_class_enum_ppu_01;

var
  s: TShape;
begin
  s := TShape.Create;
  s.kind := TShape.skBox;
  if s.kindIndex <> 2 then halt(1);
  s.Free;
end.
