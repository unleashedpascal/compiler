{ %OPT=-O3 -Sew -vw }
{ %NORUN }

{ a fill or move with a small constant size is expanded into direct stores;
  an uninitialized destination must still be reported by a hint only, like
  any other variable passed to a var parameter }

program tb0731;

{$mode objfpc}

type
  tpair = record
    first, second: array[0..3] of dword;
  end;

function fill_whole(n: longint): dword;
var
  buf: array[0..15] of dword;
begin
  fillchar(buf, sizeof(buf), 0);
  buf[n] := 1;
  result := buf[0] + buf[n];
end;

function fill_field(n: longint): dword;
var
  pair: tpair;
begin
  fillchar(pair.second, sizeof(pair.second), 0);
  pair.first[n] := 1;
  result := pair.first[n] + pair.second[n];
end;

function fill_after_branch(n: longint): dword;
var
  buf: array[0..3] of dword;
begin
  if n > 0 then
    buf[0] := 1;
  fillchar(buf, sizeof(buf), 0);
  result := buf[n];
end;

function move_whole(n: longint): dword;
var
  src, dst: array[0..3] of dword;
begin
  src[0] := 1;
  src[1] := 2;
  src[2] := 3;
  src[3] := 4;
  move(src, dst, sizeof(dst));
  result := dst[n];
end;

begin
  if fill_whole(3) + fill_field(1) + fill_after_branch(2) + move_whole(0) <> 3 then
    halt(1);
end.
