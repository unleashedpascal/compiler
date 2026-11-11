{ %FAIL }
program embedstr_fail_nonce_and_nullnonce_09;

{$mode unleashed}

// nonce and nullnonce exclude each other
{$embedstr src 'embed_fixture.dat' encrypt nonce='abc' nullnonce}

begin
end.
