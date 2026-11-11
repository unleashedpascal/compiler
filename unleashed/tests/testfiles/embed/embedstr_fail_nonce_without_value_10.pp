{ %FAIL }
program embedstr_fail_nonce_without_value_10;

{$mode unleashed}

// nonce needs a value, even an empty one
{$embedstr src 'embed_fixture.dat' encrypt nonce}

begin
end.
