{ %OPT="-gw3 -Xs-" %CHECKBIN_LACKS=$compose$ }
program composable_records_dwarf_flattened_01;
{$mode unleashed}
// the debug info of a composed record lists the embedded and inline
// anonymous members directly, at their flattened offsets; the internal
// carrier fields never appear in it
type
  TBase = record
    x, y: Integer;
  end;
  TMid = record
    embed TBase;
    m: Byte;
  end;
  TDerived = record
    embed TMid;
    z: Integer;
    record
      a, b: Word;
    end;
  end;

begin
  var dd: TDerived;
  dd.x := 2;
  dd.y := 3;
  dd.m := 4;
  dd.z := 1;
  dd.a := 5;
  dd.b := 6;
  if dd.x + dd.y + dd.m + dd.z + dd.a + dd.b <> 21 then halt(1);
end.
