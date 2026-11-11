program embedstr_encrypt_layout_17;

{$mode unleashed}

{$embedstr plain 'embed_fixture.dat'}
// random key and nonce: key, nonce, data, tag
{$embedstr a 'embed_fixture.dat' encrypt}
{$embedstr b 'embed_fixture.dat' encrypt}
{$embedstr c 'embed_fixture.dat' encrypt=chacha20}
{$embedstr d 'embed_fixture.dat' encrypt=aes}
// a given key is not stored
{$embedstr e 'embed_fixture.dat' encrypt seed=}
{$embedstr f 'embed_fixture.dat' encrypt seed='' nonce=}
{$embedstr g 'embed_fixture.dat' ENCRYPT=ChaCha20_IETF Seed="" NullNonce}
{$embedbytes h 'embed_fixture.dat' encrypt seed= nullnonce}

begin
  if length(a) <> 32+12+length(plain)+16 then halt(1);
  if length(c) <> 32+8+length(plain)+16 then halt(2);
  if length(d) <> 32+16+length(plain)+16 then halt(3);
  if length(e) <> 12+length(plain)+16 then halt(4);
  // two random keys never give the same bytes
  if a = b then halt(5);
  // an empty seed and an empty nonce are zero bytes, like nullnonce
  if f <> g then halt(6);
  if copy(f, 1, 12) <> StringOfChar(#0, 12) then halt(7);
  if length(h) <> length(f) then halt(8);
  for var i := 0 to high(h) do if h[i] <> ord(f[i+1]) then halt(9);
  // the 1-arg forms take parameters too
  if {$embedstr 'embed_fixture.dat' encrypt seed= nullnonce} <> f then halt(10);
  if length({$embedbytes 'embed_fixture.dat' compress}) <> length({$embedstr 'embed_fixture.dat' compress=deflate}) then halt(11);
end.
