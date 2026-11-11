program embedstr_encrypt_known_answer_16;

{$mode unleashed}

// key and nonce are given, so every build makes the same bytes; the expected
// values come from an independent implementation of the three ciphers
{$embedstr ietf 'embed_fixture.dat' encrypt seed='fixed test key' nullnonce}
{$embedstr orig 'embed_fixture.dat' encrypt=chacha20 seed='fixed test key' nonce='abc'}
{$embedstr aes 'embed_fixture.dat' encrypt=aes seed='fixed test key' nonce='abc'}

function hex(const s: string): string;
begin
  result := '';
  for var c in s do result += HexStr(ord(c), 2);
end;

begin
  if hex(ietf) <> '000000000000000000000000909705E856D2FC1EE1B3EECB25DB518FA5F3DB3697A49B19E91841D3FF5445E9' then halt(1);
  if hex(orig) <> '6162630000000000CBCDC4D57935140A41D412CB226EC8CF526C829140C7EB6DD5DB120B2E220E9B' then halt(2);
  if hex(aes) <> '61626300000000000000000000000000A978F04BD10A997641523CF513EA854DCB833F71235896C86392D805BA5D477A' then halt(3);
end.
