{ %FAIL }
program embedstr_fail_nullnonce_with_value_14;

{$mode unleashed}

// nullnonce takes no value
{$embedstr src 'embed_fixture.dat' encrypt nullnonce=1}

begin
end.
