program strinterp_charconst_glue_01;
// `#nn` char constants after the closing quote glue to the literal and a
// quote after them reopens it, as in `'a'#10'b'`

{$mode unleashed}

begin
  var name := 'Bob';
  var s := $'hi {name}!'#10'bye';
  if s <> 'hi Bob!'#10'bye' then halt(1);

  s := $'{name}'#13#10;
  if s <> 'Bob'#13#10 then halt(2);

  s := $'a{name}'#$41#&102#%1000011'z{name}';
  if s <> 'aBobABCzBob' then halt(3);

  s := $'it''s {name}'#10'x';
  if s <> 'it''s Bob'#10'x' then halt(4);

  s := $'plain'#10'text';
  if s <> 'plain'#10'text' then halt(5);
end.
