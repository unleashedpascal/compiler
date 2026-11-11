{ %FAIL }
program embedstr_fail_unknown_compress_value_12;

{$mode unleashed}

// not one of deflate, zlib, gzip, zstd
{$embedstr src 'embed_fixture.dat' compress=lz4}

begin
end.
