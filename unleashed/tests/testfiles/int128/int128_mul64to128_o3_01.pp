{ %OPT=-O3 }
program int128_mul64to128_o3_01;

{ a product of two 64 bit operands widened to 128 bit goes through a single
  MUL/IMUL; its result must match the full 128 x 128 bit multiplication }

{$mode unleashed}

function mulUU(a, b: UInt64): UInt128;
begin
  result := UInt128(a) * b;
end;

function mulSS(a, b: Int64): Int128;
begin
  result := Int128(a) * b;
end;

function mulSU32(a: Int64; b: LongWord): Int128;
begin
  result := Int128(a) * b;
end;

function mulU16U(a: Word; b: UInt64): UInt128;
begin
  result := UInt128(a) * b;
end;

function mulUConst(a: UInt64): UInt128;
begin
  result := UInt128(a) * 10000000000000000000;
end;

function mulConstS(a: Int64): Int128;
begin
  result := -3 * Int128(a);
end;

{ memory operands }
function mulRef(const a, b: UInt64): UInt128;
begin
  result := UInt128(a) * b;
end;

{ mixed signedness stays on the full multiplication }
function mulSU(a: Int64; b: UInt64): Int128;
begin
  result := Int128(a) * b;
end;

{ reference: operands already 128 bit }
function fullUU(a, b: UInt64): UInt128;
begin
  var x: UInt128 := a;
  var y: UInt128 := b;
  result := x * y;
end;

function fullSS(a, b: Int64): Int128;
begin
  var x: Int128 := a;
  var y: Int128 := b;
  result := x * y;
end;

function fullSU(a: Int64; b: UInt64): Int128;
begin
  var x: Int128 := a;
  var y: Int128 := b;
  result := x * y;
end;

const
  uvals: array[7] of UInt64 = (0, 1, 2, $FFFFFFFFFFFFFFFF, $8000000000000000, 10000000000000000000, $123456789ABCDEF0);
  svals: array[7] of Int64 = (0, 1, -1, High(Int64), Low(Int64), -3, $123456789ABCDEF0);

var
  gu: UInt64 = $FFFFFFFFFFFFFFFF;
  gs: Int64 = Low(Int64);

begin
  for var i := 0 to 6 do
    for var j := 0 to 6 do
    begin
      if mulUU(uvals[i], uvals[j]) <> fullUU(uvals[i], uvals[j]) then halt(1);
      if mulRef(uvals[i], uvals[j]) <> fullUU(uvals[i], uvals[j]) then halt(2);
      if mulSS(svals[i], svals[j]) <> fullSS(svals[i], svals[j]) then halt(3);
      if mulSU32(svals[i], LongWord(uvals[j])) <> fullSS(svals[i], LongWord(uvals[j])) then halt(4);
      if mulU16U(Word(uvals[i]), uvals[j]) <> fullUU(Word(uvals[i]), uvals[j]) then halt(5);
      if mulSU(svals[i], uvals[j]) <> fullSU(svals[i], uvals[j]) then halt(6);
    end;
  for var i := 0 to 6 do
  begin
    if mulUConst(uvals[i]) <> fullUU(uvals[i], 10000000000000000000) then halt(7);
    if mulConstS(svals[i]) <> fullSS(svals[i], -3) then halt(8);
  end;

  { hand checked products }
  if mulUU($FFFFFFFFFFFFFFFF, $FFFFFFFFFFFFFFFF) <> 340282366920938463426481119284349108225 then halt(9);
  if mulSS(Low(Int64), Low(Int64)) <> 85070591730234615865843651857942052864 then halt(10);
  if mulSS(-1, 1) <> -1 then halt(11);
  if mulSS(-2, 3) <> -6 then halt(12);
  if mulUConst(10000000000000000000) <> 100000000000000000000000000000000000000 then halt(13);

  { globals, memory operands straight into the instruction }
  if UInt128(gu) * gu <> 340282366920938463426481119284349108225 then halt(14);
  if Int128(gs) * gs <> 85070591730234615865843651857942052864 then halt(15);

  { product feeding further 128 bit arithmetic }
  var acc: UInt128 := 0;
  for var i := 0 to 6 do
    acc := acc + UInt128(uvals[i]) * uvals[6 - i];
  var ref: UInt128 := 0;
  for var i := 0 to 6 do
    ref := ref + fullUU(uvals[i], uvals[6 - i]);
  if acc <> ref then halt(16);
  if UInt64(acc shr 64) <> UInt64(ref shr 64) then halt(17);
end.
