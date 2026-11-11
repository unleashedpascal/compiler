{ %FAIL }
program embedstr_fail_unknown_encrypt_value_13;

{$mode unleashed}

// not one of chacha20_ietf, chacha20, aes
{$embedstr src 'embed_fixture.dat' encrypt=rc4}

begin
end.
