program composable_records_bitpacked_cstyle_signed_convert_01;

{$mode unleashed}

// a C-style bitfield of an unsigned default type converted to a signed
// integer of the same size must zero-extend; the field at bit 0 used to
// come out sign-extended because its type width, not its bit width, decided
// whether the access was bitpacked
type
  TW = bitpacked record of LongWord
    lo: 5;
    mid: 11;
    hi: 16;
  end;

  TB = bitpacked record of Byte
    x: 3;
    y: 5;
  end;

var
  u: LongWord = $FFFFFFFF;
  b: Byte = $FF;

begin
  var d: integer := TW(u).lo;
  if d <> 31 then halt(1);
  d := TW(u).mid;
  if d <> 2047 then halt(2);
  d := TW(u).hi;
  if d <> 65535 then halt(3);
  var i64: int64 := TW(u).lo;
  if i64 <> 31 then halt(4);
  var s: shortint := TB(b).x;
  if s <> 7 then halt(5);
  s := TB(b).y;
  if s <> 31 then halt(6);
  var w: TW;
  w.lo := 31;
  w.mid := 0;
  w.hi := 0;
  d := w.lo;
  if d <> 31 then halt(7);
end.
