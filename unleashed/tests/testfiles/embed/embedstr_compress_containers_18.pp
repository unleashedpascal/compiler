program embedstr_compress_containers_18;

{$mode unleashed}

{$embedstr plain 'embedstr_compress_containers_18.pp'}
{$embedstr raw 'embedstr_compress_containers_18.pp' compress}
{$embedstr rawNamed 'embedstr_compress_containers_18.pp' compress=deflate}
{$embedstr zlib 'embedstr_compress_containers_18.pp' compress=zlib}
{$embedstr gzip 'embedstr_compress_containers_18.pp' compress=gzip}
{$embedstr zstd 'embedstr_compress_containers_18.pp' compress=zstd}
{$embedstr sealed 'embedstr_compress_containers_18.pp' encrypt compress}

// filler so that the file is worth packing:
// aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
// aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
// aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

begin
  if raw <> rawNamed then halt(1);
  if length(raw) >= length(plain) then halt(2);
  // zlib: two header bytes and four of Adler-32 around the same stream
  if length(zlib) <> length(raw)+6 then halt(3);
  if ((ord(zlib[1]) and $0F) <> 8) or (((ord(zlib[1])*256+ord(zlib[2])) mod 31) <> 0) then halt(4);
  if copy(zlib, 3, length(raw)) <> raw then halt(5);
  // gzip: ten header bytes, then CRC-32 and the size of the file
  if length(gzip) <> length(raw)+18 then halt(6);
  if (gzip[1] <> #$1F) or (gzip[2] <> #$8B) or (gzip[3] <> #8) then halt(7);
  if PDWord(@gzip[length(gzip)-3])^ <> NtoLE(dword(length(plain))) then halt(8);
  // zstd: the frame magic
  if copy(zstd, 1, 4) <> #$28#$B5#$2F#$FD then halt(10);
  if length(zstd) >= length(plain) then halt(11);
  // packing runs before encryption whatever the order of the parameters
  if length(sealed) <> 32+12+length(raw)+16 then halt(9);
end.
