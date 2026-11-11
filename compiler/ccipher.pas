{ Part of the Unleashed Pascal Compiler
  Copyright (c) 2026 Unleashed Pascal Contributors <https://unleashedpascal.org>
  License: MPL-2.0

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can
  obtain one at https://mozilla.org/MPL/2.0/.

  These notices must be kept in copies and modified versions (MPL-2.0 sec. 3.1);
  add yours below. }

{ stream ciphers with a poly1305 tag, used to encrypt embedded files.
  byte order of the host does not matter. }
unit ccipher;

{$i fpcdefs.inc}
{$r-}{$q-}

interface

    type
      tcipherkind = (ck_chacha20_ietf,ck_chacha20,ck_aes);

    const
      cipher_key_size = 32;
      cipher_tag_size = 16;
      cipher_nonce_size : array[tcipherkind] of byte = (12,8,16);

    { encrypts data and returns it followed by the 16-byte tag. key and nonce
      must have their full size. the first 32 bytes of the key stream are the
      poly1305 key; chacha20 drops the rest of that block, so data starts at
      block 1 (for ck_chacha20_ietf this is the aead of rfc 8439 with no
      associated data), aes goes on with the next counter block. the tag
      covers the encrypted data padded with zeros to 16 bytes, 8 zero bytes
      and the data length as 64 bits, low byte first. }
    function cipher_seal(kind:tcipherkind;const key,nonce,data:ansistring):ansistring;

implementation

    type
      tkeystream = record
        kind : tcipherkind;
        { chacha20: constants, key, counter, nonce }
        state : array[0..15] of dword;
        { aes-256: round keys and the counter block }
        rk : array[0..239] of byte;
        ctr : array[0..15] of byte;
        block : array[0..63] of byte;
        blocklen,
        used : longint;
      end;

    const
      aes_sbox : array[0..255] of byte = (
        $63,$7c,$77,$7b,$f2,$6b,$6f,$c5,$30,$01,$67,$2b,$fe,$d7,$ab,$76,
        $ca,$82,$c9,$7d,$fa,$59,$47,$f0,$ad,$d4,$a2,$af,$9c,$a4,$72,$c0,
        $b7,$fd,$93,$26,$36,$3f,$f7,$cc,$34,$a5,$e5,$f1,$71,$d8,$31,$15,
        $04,$c7,$23,$c3,$18,$96,$05,$9a,$07,$12,$80,$e2,$eb,$27,$b2,$75,
        $09,$83,$2c,$1a,$1b,$6e,$5a,$a0,$52,$3b,$d6,$b3,$29,$e3,$2f,$84,
        $53,$d1,$00,$ed,$20,$fc,$b1,$5b,$6a,$cb,$be,$39,$4a,$4c,$58,$cf,
        $d0,$ef,$aa,$fb,$43,$4d,$33,$85,$45,$f9,$02,$7f,$50,$3c,$9f,$a8,
        $51,$a3,$40,$8f,$92,$9d,$38,$f5,$bc,$b6,$da,$21,$10,$ff,$f3,$d2,
        $cd,$0c,$13,$ec,$5f,$97,$44,$17,$c4,$a7,$7e,$3d,$64,$5d,$19,$73,
        $60,$81,$4f,$dc,$22,$2a,$90,$88,$46,$ee,$b8,$14,$de,$5e,$0b,$db,
        $e0,$32,$3a,$0a,$49,$06,$24,$5c,$c2,$d3,$ac,$62,$91,$95,$e4,$79,
        $e7,$c8,$37,$6d,$8d,$d5,$4e,$a9,$6c,$56,$f4,$ea,$65,$7a,$ae,$08,
        $ba,$78,$25,$2e,$1c,$a6,$b4,$c6,$e8,$dd,$74,$1f,$4b,$bd,$8b,$8a,
        $70,$3e,$b5,$66,$48,$03,$f6,$0e,$61,$35,$57,$b9,$86,$c1,$1d,$9e,
        $e1,$f8,$98,$11,$69,$d9,$8e,$94,$9b,$1e,$87,$e9,$ce,$55,$28,$df,
        $8c,$a1,$89,$0d,$bf,$e6,$42,$68,$41,$99,$2d,$0f,$b0,$54,$bb,$16);
      aes_rcon : array[1..7] of byte = ($01,$02,$04,$08,$10,$20,$40);


    function le32(p:pbyte):dword;
      begin
        le32:=dword(p[0]) or (dword(p[1]) shl 8) or (dword(p[2]) shl 16) or (dword(p[3]) shl 24);
      end;


    procedure put_le32(p:pbyte;v:dword);
      begin
        p[0]:=byte(v);
        p[1]:=byte(v shr 8);
        p[2]:=byte(v shr 16);
        p[3]:=byte(v shr 24);
      end;


{*****************************************************************************
                                  chacha20
*****************************************************************************}

    procedure chacha_quarter(var a,b,c,d:dword);
      begin
        a:=a+b;
        d:=roldword(d xor a,16);
        c:=c+d;
        b:=roldword(b xor c,12);
        a:=a+b;
        d:=roldword(d xor a,8);
        c:=c+d;
        b:=roldword(b xor c,7);
      end;


    procedure chacha_block(var ks:tkeystream);
      var
        x : array[0..15] of dword;
        i : longint;
      begin
        x:=ks.state;
        for i:=1 to 10 do
          begin
            chacha_quarter(x[0],x[4],x[8],x[12]);
            chacha_quarter(x[1],x[5],x[9],x[13]);
            chacha_quarter(x[2],x[6],x[10],x[14]);
            chacha_quarter(x[3],x[7],x[11],x[15]);
            chacha_quarter(x[0],x[5],x[10],x[15]);
            chacha_quarter(x[1],x[6],x[11],x[12]);
            chacha_quarter(x[2],x[7],x[8],x[13]);
            chacha_quarter(x[3],x[4],x[9],x[14]);
          end;
        for i:=0 to 15 do
          put_le32(@ks.block[i*4],x[i]+ks.state[i]);
        inc(ks.state[12]);
        { the counter of the original cipher is 64 bits wide }
        if (ks.kind=ck_chacha20) and (ks.state[12]=0) then
          inc(ks.state[13]);
      end;


{*****************************************************************************
                                  aes-256
*****************************************************************************}

    function aes_xtime(x:byte):byte;
      begin
        if (x and $80)<>0 then
          aes_xtime:=byte((x shl 1) xor $1b)
        else
          aes_xtime:=byte(x shl 1);
      end;


    procedure aes_expand_key(var ks:tkeystream;key:pbyte);
      var
        i,k : longint;
        t : array[0..3] of byte;
        b : byte;
      begin
        move(key^,ks.rk[0],32);
        for i:=8 to 59 do
          begin
            move(ks.rk[(i-1)*4],t[0],4);
            if (i and 7)=0 then
              begin
                b:=t[0];
                t[0]:=aes_sbox[t[1]] xor aes_rcon[i shr 3];
                t[1]:=aes_sbox[t[2]];
                t[2]:=aes_sbox[t[3]];
                t[3]:=aes_sbox[b];
              end
            else if (i and 7)=4 then
              for k:=0 to 3 do
                t[k]:=aes_sbox[t[k]];
            for k:=0 to 3 do
              ks.rk[i*4+k]:=ks.rk[(i-8)*4+k] xor t[k];
          end;
      end;


    procedure aes_block(var ks:tkeystream);
      var
        s,t : array[0..15] of byte;
        round,i,c : longint;
        a0,a1,a2,a3,x : byte;
      begin
        for i:=0 to 15 do
          s[i]:=ks.ctr[i] xor ks.rk[i];
        for round:=1 to 14 do
          begin
            { substitute, then rotate row r left by r }
            for i:=0 to 15 do
              t[i]:=aes_sbox[s[((i and 3)+4*((i shr 2)+(i and 3))) and 15]];
            if round<14 then
              for c:=0 to 3 do
                begin
                  a0:=t[4*c];
                  a1:=t[4*c+1];
                  a2:=t[4*c+2];
                  a3:=t[4*c+3];
                  x:=a0 xor a1 xor a2 xor a3;
                  t[4*c]:=a0 xor x xor aes_xtime(a0 xor a1);
                  t[4*c+1]:=a1 xor x xor aes_xtime(a1 xor a2);
                  t[4*c+2]:=a2 xor x xor aes_xtime(a2 xor a3);
                  t[4*c+3]:=a3 xor x xor aes_xtime(a3 xor a0);
                end;
            for i:=0 to 15 do
              s[i]:=t[i] xor ks.rk[round*16+i];
          end;
        move(s[0],ks.block[0],16);
        { the counter block counts up as one 128-bit number, high byte first }
        for i:=15 downto 0 do
          begin
            inc(ks.ctr[i]);
            if ks.ctr[i]<>0 then
              break;
          end;
      end;


{*****************************************************************************
                                 key stream
*****************************************************************************}

    procedure ks_init(out ks:tkeystream;kind:tcipherkind;key,nonce:pbyte);
      var
        i : longint;
      begin
        fillchar(ks,sizeof(ks),0);
        ks.kind:=kind;
        if kind=ck_aes then
          begin
            ks.blocklen:=16;
            aes_expand_key(ks,key);
            move(nonce^,ks.ctr[0],16);
          end
        else
          begin
            ks.blocklen:=64;
            { "expand 32-byte k" }
            ks.state[0]:=$61707865;
            ks.state[1]:=$3320646e;
            ks.state[2]:=$79622d32;
            ks.state[3]:=$6b206574;
            for i:=0 to 7 do
              ks.state[4+i]:=le32(key+i*4);
            if kind=ck_chacha20_ietf then
              for i:=0 to 2 do
                ks.state[13+i]:=le32(nonce+i*4)
            else
              for i:=0 to 1 do
                ks.state[14+i]:=le32(nonce+i*4);
          end;
        ks.used:=ks.blocklen;
      end;


    procedure ks_xor(var ks:tkeystream;p:pbyte;len:ptruint);
      begin
        while len>0 do
          begin
            if ks.used>=ks.blocklen then
              begin
                if ks.kind=ck_aes then
                  aes_block(ks)
                else
                  chacha_block(ks);
                ks.used:=0;
              end;
            p^:=p^ xor ks.block[ks.used];
            inc(ks.used);
            inc(p);
            dec(len);
          end;
      end;


{*****************************************************************************
                                  poly1305
*****************************************************************************}

    { tag of `blocks` whole 16-byte blocks at m under a 32-byte one-time key;
      five 26-bit limbs, 64-bit products }
    procedure poly1305_tag(key,m:pbyte;blocks:ptruint;tag:pbyte);
      var
        r0,r1,r2,r3,r4,
        s1,s2,s3,s4,
        h0,h1,h2,h3,h4,
        g0,g1,g2,g3,g4,
        c,mask : dword;
        d0,d1,d2,d3,d4,f : qword;
      begin
        r0:=le32(key) and $3ffffff;
        r1:=(le32(key+3) shr 2) and $3ffff03;
        r2:=(le32(key+6) shr 4) and $3ffc0ff;
        r3:=(le32(key+9) shr 6) and $3f03fff;
        r4:=(le32(key+12) shr 8) and $00fffff;
        s1:=r1*5;
        s2:=r2*5;
        s3:=r3*5;
        s4:=r4*5;
        h0:=0;
        h1:=0;
        h2:=0;
        h3:=0;
        h4:=0;
        while blocks>0 do
          begin
            { h += m }
            h0:=h0+(le32(m) and $3ffffff);
            h1:=h1+((le32(m+3) shr 2) and $3ffffff);
            h2:=h2+((le32(m+6) shr 4) and $3ffffff);
            h3:=h3+((le32(m+9) shr 6) and $3ffffff);
            h4:=h4+((le32(m+12) shr 8) or (dword(1) shl 24));
            { h *= r mod 2^130-5 }
            d0:=qword(h0)*r0+qword(h1)*s4+qword(h2)*s3+qword(h3)*s2+qword(h4)*s1;
            d1:=qword(h0)*r1+qword(h1)*r0+qword(h2)*s4+qword(h3)*s3+qword(h4)*s2;
            d2:=qword(h0)*r2+qword(h1)*r1+qword(h2)*r0+qword(h3)*s4+qword(h4)*s3;
            d3:=qword(h0)*r3+qword(h1)*r2+qword(h2)*r1+qword(h3)*r0+qword(h4)*s4;
            d4:=qword(h0)*r4+qword(h1)*r3+qword(h2)*r2+qword(h3)*r1+qword(h4)*r0;
            h0:=dword(d0) and $3ffffff;
            d1:=d1+(d0 shr 26);
            h1:=dword(d1) and $3ffffff;
            d2:=d2+(d1 shr 26);
            h2:=dword(d2) and $3ffffff;
            d3:=d3+(d2 shr 26);
            h3:=dword(d3) and $3ffffff;
            d4:=d4+(d3 shr 26);
            h4:=dword(d4) and $3ffffff;
            f:=qword(h0)+(d4 shr 26)*5;
            h0:=dword(f) and $3ffffff;
            h1:=h1+dword(f shr 26);
            inc(m,16);
            dec(blocks);
          end;
        { carry h fully }
        c:=h1 shr 26;
        h1:=h1 and $3ffffff;
        h2:=h2+c;
        c:=h2 shr 26;
        h2:=h2 and $3ffffff;
        h3:=h3+c;
        c:=h3 shr 26;
        h3:=h3 and $3ffffff;
        h4:=h4+c;
        c:=h4 shr 26;
        h4:=h4 and $3ffffff;
        h0:=h0+c*5;
        c:=h0 shr 26;
        h0:=h0 and $3ffffff;
        h1:=h1+c;
        { g = h - p }
        g0:=h0+5;
        c:=g0 shr 26;
        g0:=g0 and $3ffffff;
        g1:=h1+c;
        c:=g1 shr 26;
        g1:=g1 and $3ffffff;
        g2:=h2+c;
        c:=g2 shr 26;
        g2:=g2 and $3ffffff;
        g3:=h3+c;
        c:=g3 shr 26;
        g3:=g3 and $3ffffff;
        g4:=h4+c-(dword(1) shl 26);
        { keep h when h < p, else take g }
        mask:=(g4 shr 31)-1;
        h0:=(h0 and not mask) or (g0 and mask);
        h1:=(h1 and not mask) or (g1 and mask);
        h2:=(h2 and not mask) or (g2 and mask);
        h3:=(h3 and not mask) or (g3 and mask);
        h4:=(h4 and not mask) or (g4 and mask);
        { h mod 2^128, then add the second half of the key }
        h0:=h0 or (h1 shl 26);
        h1:=(h1 shr 6) or (h2 shl 20);
        h2:=(h2 shr 12) or (h3 shl 14);
        h3:=(h3 shr 18) or (h4 shl 8);
        f:=qword(h0)+le32(key+16);
        put_le32(tag,dword(f));
        f:=qword(h1)+le32(key+20)+(f shr 32);
        put_le32(tag+4,dword(f));
        f:=qword(h2)+le32(key+24)+(f shr 32);
        put_le32(tag+8,dword(f));
        f:=qword(h3)+le32(key+28)+(f shr 32);
        put_le32(tag+12,dword(f));
      end;


    function cipher_seal(kind:tcipherkind;const key,nonce,data:ansistring):ansistring;
      var
        ks : tkeystream;
        polykey : array[0..31] of byte;
        mac : ansistring;
        n,padded : ptruint;
      begin
        result:='';
        mac:='';
        ks_init(ks,kind,pbyte(key),pbyte(nonce));
        fillchar(polykey,sizeof(polykey),0);
        ks_xor(ks,@polykey[0],sizeof(polykey));
        if kind<>ck_aes then
          ks.used:=ks.blocklen;
        n:=length(data);
        padded:=(n+15) and not ptruint(15);
        setlength(mac,padded+16);
        fillchar(mac[1],padded+16,0);
        if n>0 then
          begin
            move(data[1],mac[1],n);
            ks_xor(ks,pbyte(mac),n);
          end;
        put_le32(pbyte(mac)+padded+8,dword(n));
        put_le32(pbyte(mac)+padded+12,dword(qword(n) shr 32));
        setlength(result,n+cipher_tag_size);
        if n>0 then
          move(mac[1],result[1],n);
        poly1305_tag(@polykey[0],pbyte(mac),(padded+16) shr 4,pbyte(result)+n);
      end;

end.
