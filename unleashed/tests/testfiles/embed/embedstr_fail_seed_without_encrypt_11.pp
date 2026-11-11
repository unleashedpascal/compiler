{ %FAIL }
program embedstr_fail_seed_without_encrypt_11;

{$mode unleashed}

// seed has nothing to key
{$embedstr src 'embed_fixture.dat' compress seed='abc'}

begin
end.
