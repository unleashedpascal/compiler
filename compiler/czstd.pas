{ Part of the Unleashed Pascal Compiler
  Copyright (c) 2026 Unleashed Pascal Contributors <https://unleashedpascal.org>
  License: MPL-2.0

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can
  obtain one at https://mozilla.org/MPL/2.0/.

  These notices must be kept in copies and modified versions (MPL-2.0 sec. 3.1);
  add yours below. }

unit czstd;

{$i fpcdefs.inc}

{ the hashes rely on wrapping integer arithmetic }
{$r-}{$q-}

interface

    { packs src into one zstandard frame with a content checksum; level
      runs from 1 (fastest) to 9 (smallest); the frame header carries the
      content size unless src exceeds the window of the level (512 KiB at
      level 1 up to 16 MiB at level 9) by 1 MiB or more }
    function zstd_pack(const src: ansistring; level: longint): ansistring;

implementation

    const
      { input bytes consumed per block }
      block_src = 128*1024;
      { longest huffman code the format allows }
      huf_maxbits = 11;

      ll_base: array[0..35] of dword = (
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
        16,18,20,22,24,28,32,40,48,64,128,256,512,1024,2048,4096,
        8192,16384,32768,65536);
      ll_xtra: array[0..35] of byte = (
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        1,1,1,1,2,2,3,3,4,6,7,8,9,10,11,12,
        13,14,15,16);
      ml_base: array[0..52] of dword = (
        3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,
        19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,
        35,37,39,41,43,47,51,59,67,83,99,131,259,515,1027,2051,
        4099,8195,16387,32771,65539);
      ml_xtra: array[0..52] of byte = (
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        1,1,1,1,2,2,3,3,4,4,5,7,8,9,10,11,
        12,13,14,15,16);

      { literal length to code, lengths below 64 }
      ll_small: array[0..63] of byte = (
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
        16,16,17,17,18,18,19,19,20,20,20,20,21,21,21,21,
        22,22,22,22,22,22,22,22,23,23,23,23,23,23,23,23,
        24,24,24,24,24,24,24,24,24,24,24,24,24,24,24,24);
      { match length minus 3 to code, values below 128 }
      ml_small: array[0..127] of byte = (
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
        16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
        32,32,33,33,34,34,35,35,36,36,36,36,37,37,37,37,
        38,38,38,38,38,38,38,38,39,39,39,39,39,39,39,39,
        40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,
        41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,
        42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,
        42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42);

      { predefined distributions, -1 marks "less than 1" }
      def_ll: array[0..35] of smallint = (
        4,3,2,2,2,2,2,2,2,2,2,2,2,1,1,1,
        2,2,2,2,2,2,2,2,2,3,2,1,1,1,1,1,
        -1,-1,-1,-1);
      def_ml: array[0..52] of smallint = (
        1,4,3,2,2,2,2,2,2,1,1,1,1,1,1,1,
        1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,
        -1,-1,-1,-1,-1);
      def_of: array[0..28] of smallint = (
        1,1,1,1,1,1,2,2,2,1,1,1,1,1,1,1,
        1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1);

      xxp1 = qword($9e3779b185ebca87);
      xxp2 = qword($c2b2ae3d27d4eb4f);
      xxp3 = qword($165667b19e3779f9);
      xxp4 = qword($85ebca77c2b2ae63);
      xxp5 = qword($27d4eb2f165667c5);

    type
      tlevel = record
        wlog,tries,nicelen: longint;
        lazy: boolean;
      end;

    const
      { per-level effort: window log, chain depth, nice length, lazy matching }
      levels: array[1..9] of tlevel = (
        (wlog: 19; tries: 4; nicelen: 16; lazy: false),
        (wlog: 20; tries: 8; nicelen: 24; lazy: false),
        (wlog: 21; tries: 16; nicelen: 32; lazy: false),
        (wlog: 21; tries: 24; nicelen: 48; lazy: true),
        (wlog: 22; tries: 32; nicelen: 64; lazy: true),
        (wlog: 22; tries: 48; nicelen: 96; lazy: true),
        (wlog: 23; tries: 64; nicelen: 128; lazy: true),
        (wlog: 24; tries: 96; nicelen: 192; lazy: true),
        (wlog: 24; tries: 128; nicelen: 273; lazy: true));

    type
      { forward bit writer }
      tbitwriter = record
        dst: pbyte;
        pos: sizeint;
        acc: qword;
        cnt: longint;
      end;

      thuflens = array[0..255] of byte;
      thufcodes = array[0..255] of word;

      { fse coding table: per-symbol transforms and the rank to state map }
      tfseenc = record
        acclog: longint;
        statetab: array[0..511] of word;
        dbits,dstate: array[0..52] of longint;
      end;

      tzstdencoder = class
        { level parameters }
        wlog,tries,nicelen: longint;
        lazy: boolean;
        { window: back-reference data followed by the unprocessed input }
        win: pbyte;
        winsize,winlen,procpos,blockcap: sizeint;
        { match finder: hash4 chain heads, hash3 slots, chain links; -1 = empty }
        head,head3,chain: array of longint;
        chainmask,inspos: sizeint;
        hbits: longint;
        { recent offsets, and their state before the current block }
        reps,blockreps: array[0..2] of sizeint;
        { per-block scratch }
        litbuf,streams,blk,llcodes,mlcodes,ofcodes: array of byte;
        litcnt: sizeint;
        seqll,seqml,seqov: array of dword;
        seqcnt: longint;
        { entropy state the decoder keeps across the blocks of a frame }
        phuflen: thuflens;
        phufcode: thufcodes;
        phuflive: boolean;
        { literal length, offset and match length tables }
        pseqenc: array[0..2] of tfseenc;
        pseqnorm: array[0..2,0..63] of smallint;
        { 0 = none, 1 = table, 2 = rle }
        pseqkind: array[0..2] of longint;
        pseqacc: array[0..2] of longint;
        pseqrle: array[0..2] of byte;
        { output }
        outbuf: pbyte;
        outlen: sizeint;
        procedure put_le(v: dword; n: longint);
        procedure put_block_header(btype: dword; size: sizeint; last: boolean);
        procedure start_frame(known: boolean; size: sizeint);
        procedure slide_window;
        procedure index_up_to(limit: sizeint);
        function best_match(p,srcend: sizeint; out dist: sizeint): longint;
        function best_rep(p,srcend: sizeint; out ri: longint): longint;
        procedure parse_block(srcend: sizeint);
        function build_literals: sizeint;
        function build_sequences(pos: sizeint): sizeint;
        procedure flush_block(srclen: sizeint; last: boolean);
        function pack(src: pbyte; len: sizeint; level: longint; dst: pbyte): sizeint;
      end;


    function bit_top(v: dword): longint; inline;
      begin
        result:=bsrdword(v);
      end;


    function read_le32(p: pbyte): dword; inline;
      begin
        result:=leton(unaligned(pdword(p)^));
      end;


    function read_le64(p: pbyte): qword; inline;
      begin
        result:=leton(unaligned(pqword(p)^));
      end;


    function ll_code(v: dword): longint; inline;
      begin
        if v<64 then
          result:=ll_small[v]
        else
          result:=bit_top(v)+19;
      end;


    function ml_code(v: dword): longint; inline;
      begin
        if v<128 then
          result:=ml_small[v]
        else
          result:=bit_top(v)+36;
      end;


{****************************************************************************
                                 Bit writer
****************************************************************************}

    procedure bw_open(out bw: tbitwriter; dst: pbyte; pos: sizeint);
      begin
        bw.dst:=dst;
        bw.pos:=pos;
        bw.acc:=0;
        bw.cnt:=0;
      end;


    procedure bw_put(var bw: tbitwriter; v: dword; n: longint);
      begin
        bw.acc:=bw.acc or ((v and ((qword(1) shl n)-1)) shl bw.cnt);
        inc(bw.cnt,n);
        while bw.cnt>=8 do
          begin
            bw.dst[bw.pos]:=byte(bw.acc);
            inc(bw.pos);
            bw.acc:=bw.acc shr 8;
            dec(bw.cnt,8);
          end;
      end;


    { entropy streams end with a sentinel bit, padded with zeros to a byte }
    procedure bw_close(var bw: tbitwriter);
      begin
        bw_put(bw,1,1);
        if bw.cnt>0 then
          begin
            bw.dst[bw.pos]:=byte(bw.acc);
            inc(bw.pos);
          end;
      end;


{****************************************************************************
                                 FSE encoder
****************************************************************************}

    { scales raw counts to a power-of-two total; -1 marks "less than 1" }
    function fse_normalize(const count: array of dword; total,nsym,acclog: longint; var norm: array of smallint): boolean;
      var
        size,left,lowt,big,bigsym,n,s,pick: longint;
      begin
        result:=false;
        size:=1 shl acclog;
        left:=size;
        lowt:=total shr acclog;
        big:=-1;
        bigsym:=-1;
        for s:=0 to nsym-1 do
          begin
            norm[s]:=0;
            if count[s]=0 then
              continue;
            if longint(count[s])<=lowt then
              begin
                norm[s]:=-1;
                dec(left);
              end
            else
              begin
                n:=(qword(count[s])*qword(size)) div qword(total);
                if n=0 then
                  n:=1;
                norm[s]:=n;
                dec(left,n);
                if longint(count[s])>big then
                  begin
                    big:=count[s];
                    bigsym:=s;
                  end;
              end;
          end;
        { nothing above the low threshold }
        if bigsym<0 then
          exit;
        if left>0 then
          norm[bigsym]:=norm[bigsym]+left
        else
          while left<0 do
            begin
              { shave the overflow off the heaviest entries, never below 1 }
              pick:=-1;
              for s:=0 to nsym-1 do
                if (norm[s]>1) and ((pick<0) or (norm[s]>norm[pick])) then
                  pick:=s;
              if pick<0 then
                exit;
              norm[pick]:=norm[pick]-1;
              inc(left);
            end;
        result:=true;
      end;


    { serializes the distribution to dst[pos..]; returns the bytes written }
    function fse_write_spec(const norm: array of smallint; nsym,acclog: longint; dst: pbyte; pos: sizeint): sizeint;
      var
        bw: tbitwriter;
        remain,s,bits,small,val,run: longint;
      begin
        bw_open(bw,dst,pos);
        bw_put(bw,acclog-5,4);
        remain:=(1 shl acclog)+1;
        s:=0;
        while remain>1 do
          begin
            bits:=bit_top(remain)+1;
            small:=(1 shl bits)-1-remain;
            { 0 encodes "less than 1" }
            val:=norm[s]+1;
            if val<small then
              bw_put(bw,val,bits-1)
            else if val<(1 shl (bits-1)) then
              bw_put(bw,val,bits)
            else
              bw_put(bw,val+small,bits);
            if norm[s]>0 then
              dec(remain,norm[s])
            else if norm[s]<0 then
              dec(remain);
            inc(s);
            { a zero probability is followed by run length flags }
            if (val=1) and (remain>1) then
              begin
                run:=0;
                while (s+run<nsym) and (norm[s+run]=0) do
                  inc(run);
                while run>=3 do
                  begin
                    bw_put(bw,3,2);
                    inc(s,3);
                    dec(run,3);
                  end;
                bw_put(bw,run,2);
                inc(s,run);
              end;
          end;
        { round up to whole bytes, the reader counts the bits itself }
        if bw.cnt>0 then
          begin
            dst[bw.pos]:=byte(bw.acc);
            inc(bw.pos);
          end;
        result:=bw.pos-pos;
      end;


    function fse_build_enc(out e: tfseenc; const norm: array of smallint; nsym,acclog: longint): boolean;
      var
        size,hicells,pos,step,mask,total,freq,s,i,mb: longint;
        spread: array[0..511] of byte;
        cumul: array[0..53] of longint;
      begin
        result:=false;
        size:=1 shl acclog;
        e.acclog:=acclog;
        { every cell in use is written below, this only settles the data
          flow analysis }
        spread[0]:=0;
        { same layout as the decoder: low probability symbols park at the top }
        hicells:=0;
        for s:=0 to nsym-1 do
          if norm[s]=-1 then
            begin
              inc(hicells);
              spread[size-hicells]:=s;
            end;
        step:=(size shr 1)+(size shr 3)+3;
        mask:=size-1;
        pos:=0;
        for s:=0 to nsym-1 do
          for i:=1 to norm[s] do
            begin
              spread[pos]:=s;
              repeat
                pos:=(pos+step) and mask;
              until pos<size-hicells;
            end;
        if pos<>0 then
          exit;
        { rank to state mapping }
        cumul[0]:=0;
        for s:=0 to nsym-1 do
          begin
            freq:=norm[s];
            if freq<0 then
              freq:=1;
            cumul[s+1]:=cumul[s]+freq;
          end;
        for i:=0 to size-1 do
          begin
            s:=spread[i];
            e.statetab[cumul[s]]:=size+i;
            inc(cumul[s]);
          end;
        { per-symbol transforms }
        total:=0;
        for s:=0 to nsym-1 do
          case norm[s] of
            0:
              begin
                { never used }
                e.dbits[s]:=((acclog+1) shl 16)-size;
                e.dstate[s]:=0;
              end;
            -1,1:
              begin
                e.dbits[s]:=(acclog shl 16)-size;
                e.dstate[s]:=total-1;
                inc(total);
              end;
            else
              begin
                mb:=acclog-bit_top(norm[s]-1);
                e.dbits[s]:=(mb shl 16)-(norm[s] shl mb);
                e.dstate[s]:=total-norm[s];
                inc(total,norm[s]);
              end;
          end;
        result:=true;
      end;


    function fse_enc_init(const e: tfseenc; sym: longint): longint; inline;
      var
        nb: longint;
      begin
        nb:=(e.dbits[sym]+32768) shr 16;
        result:=e.statetab[(((nb shl 16)-e.dbits[sym]) shr nb)+e.dstate[sym]];
      end;


    procedure fse_enc_push(const e: tfseenc; var bw: tbitwriter; var state: longint; sym: longint); inline;
      var
        nb: longint;
      begin
        nb:=(state+e.dbits[sym]) shr 16;
        bw_put(bw,state,nb);
        state:=e.statetab[(state shr nb)+e.dstate[sym]];
      end;


    { entropy cost of a histogram under a normalized table, in 1/256 bits }
    function fse_cost(const count: array of dword; const norm: array of smallint; nsym,acclog: longint): qword;
      var
        s,p: longint;
        frac: dword;
      begin
        result:=0;
        for s:=0 to nsym-1 do
          begin
            if count[s]=0 then
              continue;
            { not representable }
            if norm[s]=0 then
              exit(high(qword));
            p:=norm[s];
            if p<0 then
              p:=1;
            result:=result+qword(count[s])*dword((acclog-bit_top(p))*256);
            { fractional part of log2, linear between powers of two }
            frac:=((dword(p) shl 8) shr bit_top(p))-256;
            result:=result-((qword(count[s])*frac*184) shr 8);
          end;
      end;


{****************************************************************************
                                  Huffman
****************************************************************************}

    { counts to code lengths (0 = absent) by package-merge, so the lengths
      are optimal under huf_maxbits; returns the number of present symbols }
    function huf_lengths(const count: array of dword; nsym: longint; var len: array of byte): longint;
      var
        { leaves in ascending weight order }
        lw: array[0..255] of dword;
        ls: array[0..255] of byte;
        { item weights of the current and of the next list }
        wts: array[boolean,0..511] of qword;
        { item symbols of every list, -1 = package }
        lists: array[1..huf_maxbits,0..511] of smallint;
        listlen: array[1..huf_maxbits] of longint;
        nleaves,s,i,j,k,lvl,npk,li,pk,take: longint;
        w: dword;
        pw: qword;
        cur: boolean;
      begin
        { the scratch arrays are written as far as they are read, this only
          settles the data flow analysis }
        lw[0]:=0;
        ls[0]:=0;
        wts[false,0]:=0;
        lists[1,0]:=0;
        nleaves:=0;
        for s:=0 to nsym-1 do
          begin
            len[s]:=0;
            if count[s]>0 then
              begin
                lw[nleaves]:=count[s];
                ls[nleaves]:=s;
                inc(nleaves);
              end;
          end;
        result:=nleaves;
        if nleaves<2 then
          begin
            if nleaves=1 then
              len[ls[0]]:=1;
            exit;
          end;
        { stable insertion sort, equal weights stay in symbol order }
        for i:=1 to nleaves-1 do
          begin
            w:=lw[i];
            s:=ls[i];
            j:=i-1;
            while (j>=0) and (lw[j]>w) do
              begin
                lw[j+1]:=lw[j];
                ls[j+1]:=ls[j];
                dec(j);
              end;
            lw[j+1]:=w;
            ls[j+1]:=s;
          end;
        { build the package lists from the deepest level up }
        cur:=false;
        for i:=0 to nleaves-1 do
          begin
            wts[cur,i]:=lw[i];
            lists[huf_maxbits,i]:=ls[i];
          end;
        listlen[huf_maxbits]:=nleaves;
        for lvl:=huf_maxbits-1 downto 1 do
          begin
            { package pairs of the list below, then merge with the leaves }
            npk:=listlen[lvl+1] div 2;
            li:=0;
            pk:=0;
            k:=0;
            while (li<nleaves) or (pk<npk) do
              begin
                pw:=0;
                if pk<npk then
                  pw:=wts[cur,2*pk]+wts[cur,2*pk+1];
                if (pk>=npk) or ((li<nleaves) and (lw[li]<=pw)) then
                  begin
                    wts[not cur,k]:=lw[li];
                    lists[lvl,k]:=ls[li];
                    inc(li);
                  end
                else
                  begin
                    wts[not cur,k]:=pw;
                    lists[lvl,k]:=-1;
                    inc(pk);
                  end;
                inc(k);
              end;
            listlen[lvl]:=k;
            cur:=not cur;
          end;
        { walk back down: level 1 contributes 2(n-1) items, every package
          taken pulls two items of the level below }
        take:=2*(nleaves-1);
        for lvl:=1 to huf_maxbits do
          begin
            if take>listlen[lvl] then
              take:=listlen[lvl];
            pk:=0;
            for i:=0 to take-1 do
              if lists[lvl,i]<0 then
                inc(pk)
              else
                inc(len[lists[lvl,i]]);
            take:=2*pk;
          end;
      end;


    { code lengths to canonical code values in the order the decoder
      rebuilds them: ascending weight, then symbol }
    procedure huf_canon_codes(const hlen: array of byte; lastsym,maxbits: longint; var code: array of word);
      var
        cur,w,s: longint;
      begin
        cur:=0;
        for w:=1 to maxbits do
          for s:=0 to lastsym do
            begin
              if (hlen[s]=0) or (maxbits+1-hlen[s]<>w) then
                continue;
              code[s]:=cur shr (w-1);
              inc(cur,1 shl (w-1));
            end;
      end;


    { serializes nw huffman weights (the last weight is implied) as direct
      nibbles or fse-compressed, whichever is shorter; returns the bytes
      written or 0 when not encodable }
    function huf_write_desc(const weights: array of byte; nw: longint; dst: pbyte): sizeint;
      var
        wcount: array[0..15] of dword;
        wnorm: array[0..15] of smallint;
        enc: tfseenc;
        bw: tbitwriter;
        acclog,maxw,distinct,s1,s2,i: longint;
        fsebody: array[0..511] of byte;
      begin
        result:=0;
        for i:=0 to high(wcount) do
          wcount[i]:=0;
        maxw:=0;
        for i:=0 to nw-1 do
          begin
            inc(wcount[weights[i]]);
            if weights[i]>maxw then
              maxw:=weights[i];
          end;
        { fse-compressed weights, two interleaved states }
        if nw>=2 then
          begin
            distinct:=0;
            for i:=0 to maxw do
              if wcount[i]>0 then
                inc(distinct);
            acclog:=6;
            while (1 shl (acclog-1))>nw do
              dec(acclog);
            if acclog<5 then
              acclog:=5;
            if (distinct>=2) and fse_normalize(wcount,nw,maxw+1,acclog,wnorm) and
               fse_build_enc(enc,wnorm,maxw+1,acclog) then
              begin
                bw_open(bw,@fsebody[0],fse_write_spec(wnorm,maxw+1,acclog,@fsebody[0],0));
                if odd(nw) then
                  begin
                    s1:=fse_enc_init(enc,weights[nw-1]);
                    s2:=fse_enc_init(enc,weights[nw-2]);
                  end
                else
                  begin
                    s2:=fse_enc_init(enc,weights[nw-1]);
                    s1:=fse_enc_init(enc,weights[nw-2]);
                  end;
                for i:=nw-3 downto 0 do
                  if odd(i) then
                    fse_enc_push(enc,bw,s2,weights[i])
                  else
                    fse_enc_push(enc,bw,s1,weights[i]);
                bw_put(bw,s2,acclog);
                bw_put(bw,s1,acclog);
                bw_close(bw);
                if (bw.pos<=127) and (1+bw.pos<1+(nw+1) div 2) then
                  begin
                    dst[0]:=bw.pos;
                    move(fsebody[0],dst[1],bw.pos);
                    exit(1+bw.pos);
                  end;
              end;
          end;
        { direct nibbles only reach up to symbol 127 }
        if nw>128 then
          exit;
        dst[0]:=127+nw;
        for i:=0 to nw-1 do
          if odd(i) then
            dst[1+i div 2]:=dst[1+i div 2] or weights[i]
          else
            dst[1+i div 2]:=weights[i] shl 4;
        result:=1+(nw+1) div 2;
      end;


{****************************************************************************
                                  xxhash64
****************************************************************************}

    function rol64(v: qword; n: longint): qword; inline;
      begin
        result:=(v shl n) or (v shr (64-n));
      end;


    function xx_round(acc,v: qword): qword; inline;
      begin
        result:=rol64(acc+v*xxp2,31)*xxp1;
      end;


    function xxh64(p: pbyte; len: sizeint): qword;
      var
        h,total,v1,v2,v3,v4: qword;
      begin
        total:=len;
        if len>=32 then
          begin
            { xxp1+xxp2, xxp2, 0 and -xxp1 }
            v1:=qword($60ea27eeadc0b5d6);
            v2:=xxp2;
            v3:=0;
            v4:=qword($61c8864e7a143579);
            repeat
              v1:=xx_round(v1,read_le64(p));
              v2:=xx_round(v2,read_le64(p+8));
              v3:=xx_round(v3,read_le64(p+16));
              v4:=xx_round(v4,read_le64(p+24));
              inc(p,32);
              dec(len,32);
            until len<32;
            h:=rol64(v1,1)+rol64(v2,7)+rol64(v3,12)+rol64(v4,18);
            h:=(h xor xx_round(0,v1))*xxp1+xxp4;
            h:=(h xor xx_round(0,v2))*xxp1+xxp4;
            h:=(h xor xx_round(0,v3))*xxp1+xxp4;
            h:=(h xor xx_round(0,v4))*xxp1+xxp4;
          end
        else
          h:=xxp5;
        h:=h+total;
        while len>=8 do
          begin
            h:=rol64(h xor xx_round(0,read_le64(p)),27)*xxp1+xxp4;
            inc(p,8);
            dec(len,8);
          end;
        if len>=4 then
          begin
            h:=rol64(h xor (read_le32(p)*xxp1),23)*xxp2+xxp3;
            inc(p,4);
            dec(len,4);
          end;
        while len>0 do
          begin
            h:=rol64(h xor (p^*xxp5),11)*xxp1;
            inc(p);
            dec(len);
          end;
        h:=h xor (h shr 33);
        h:=h*xxp2;
        h:=h xor (h shr 29);
        h:=h*xxp3;
        h:=h xor (h shr 32);
        result:=h;
      end;


{****************************************************************************
                                Match finder
****************************************************************************}

    function hash4(p: pbyte; bits: longint): dword; inline;
      begin
        result:=dword(read_le32(p)*dword(2654435761)) shr (32-bits);
      end;


    function hash3(p: pbyte): dword; inline;
      begin
        result:=dword((p[0] or (dword(p[1]) shl 8) or (dword(p[2]) shl 16))*dword(506832829)) shr (32-14);
      end;


    function match_len(a,b: pbyte; cap: sizeint): sizeint; inline;
      var
        n: sizeint;
      begin
        n:=0;
        while (n+8<=cap) and (unaligned(pqword(a+n)^)=unaligned(pqword(b+n)^)) do
          inc(n,8);
        while (n<cap) and (a[n]=b[n]) do
          inc(n);
        result:=n;
      end;


    procedure rebase(var a: array of longint; delta: longint);
      var
        i: sizeint;
      begin
        for i:=0 to high(a) do
          if a[i]>=delta then
            dec(a[i],delta)
          else
            a[i]:=-1;
      end;


    { drops everything older than the window and rebases all indexes }
    procedure tzstdencoder.slide_window;
      var
        delta: sizeint;
      begin
        if procpos<=winsize+6*block_src then
          exit;
        delta:=procpos-winsize;
        inc(win,delta);
        dec(winlen,delta);
        dec(procpos,delta);
        dec(inspos,delta);
        rebase(head,delta);
        rebase(head3,delta);
        rebase(chain,delta);
      end;


    { indexes the window positions inspos..limit-1 }
    procedure tzstdencoder.index_up_to(limit: sizeint);
      var
        slot: plongint;
      begin
        if limit>winlen-3 then
          limit:=winlen-3;
        while inspos<limit do
          begin
            slot:=@head[hash4(win+inspos,hbits)];
            chain[inspos and chainmask]:=slot^;
            slot^:=inspos;
            head3[hash3(win+inspos)]:=inspos;
            inc(inspos);
          end;
      end;


    { best chain match at p; a length of 0 means nothing usable }
    function tzstdencoder.best_match(p,srcend: sizeint; out dist: sizeint): longint;
      var
        cap,q,d,l,maxd: sizeint;
        budget: longint;
      begin
        result:=0;
        dist:=0;
        cap:=srcend-p;
        if cap<3 then
          exit;
        { short match through the 3-byte slot, close range only }
        q:=head3[hash3(win+p)];
        if (q>=0) and (q<p) and (p-q<=4096) and (win[q]=win[p]) and
           (win[q+1]=win[p+1]) and (win[q+2]=win[p+2]) then
          begin
            result:=match_len(win+q,win+p,cap);
            dist:=p-q;
          end;
        if cap<4 then
          exit;
        q:=head[hash4(win+p,hbits)];
        budget:=tries;
        maxd:=winsize;
        if p<maxd then
          maxd:=p;
        while (q>=0) and (budget>0) and (result<cap) do
          begin
            d:=p-q;
            if d>maxd then
              break;
            if (d>0) and (win[q+result]=win[p+result]) then
              begin
                l:=match_len(win+q,win+p,cap);
                if (l>result) and ((l>=4) or (d<=4096)) then
                  begin
                    result:=l;
                    dist:=d;
                    if l>=nicelen then
                      break;
                  end;
              end;
            q:=chain[q and chainmask];
            dec(budget);
          end;
        if result<3 then
          begin
            result:=0;
            dist:=0;
          end;
      end;


    { longest repeat offset match at p; ri tells which offset won }
    function tzstdencoder.best_rep(p,srcend: sizeint; out ri: longint): longint;
      var
        cap,d,l,maxd: sizeint;
        r: longint;
      begin
        result:=0;
        ri:=-1;
        cap:=srcend-p;
        if cap<3 then
          exit;
        maxd:=winsize;
        if p<maxd then
          maxd:=p;
        for r:=0 to 2 do
          begin
            d:=reps[r];
            if (d<=0) or (d>maxd) or (win[p-d]<>win[p]) then
              continue;
            l:=match_len(win+p-d,win+p,cap);
            { the newer offsets cost less }
            if (l>=3) and (l>result+ord(r>0)) then
              begin
                result:=l;
                ri:=r;
              end;
          end;
      end;


    { turns the window bytes procpos..srcend-1 into literals and sequences }
    procedure tzstdencoder.parse_block(srcend: sizeint);
      var
        p,anchor,mlen,rlen,dist,gain,g,litlen: sizeint;
        mlen2,rlen2,dist2,gain2: sizeint;
        ri,ri2: longint;
        userep: boolean;
        ofv: dword;

      procedure take_literals(upto: sizeint);
        begin
          if upto>anchor then
            begin
              move(win[anchor],litbuf[litcnt],upto-anchor);
              inc(litcnt,upto-anchor);
            end;
        end;

      begin
        blockreps:=reps;
        p:=procpos;
        anchor:=procpos;
        index_up_to(p);
        while p<srcend do
          begin
            rlen:=best_rep(p,srcend,ri);
            mlen:=best_match(p,srcend,dist);
            if (rlen<3) and (mlen<3) then
              begin
                inc(p);
                if p>inspos then
                  index_up_to(p);
                continue;
              end;
            { pick by gain: repeat codes cost almost no offset bits }
            gain:=-1000;
            if mlen>=3 then
              gain:=4*mlen-bit_top(dword(dist)+3);
            userep:=false;
            if rlen>=3 then
              begin
                g:=4*rlen-bit_top(dword(ri)+2)+1;
                if g>=gain then
                  begin
                    userep:=true;
                    gain:=g;
                    mlen:=rlen;
                  end;
              end;
            { one-step lazy: deferring costs a literal, demand a real win }
            if lazy and (p+1<srcend) and (mlen<nicelen) then
              begin
                index_up_to(p+1);
                rlen2:=best_rep(p+1,srcend,ri2);
                mlen2:=best_match(p+1,srcend,dist2);
                gain2:=-1000;
                if mlen2>=3 then
                  gain2:=4*mlen2-bit_top(dword(dist2)+3);
                if rlen2>=3 then
                  begin
                    g:=4*rlen2-bit_top(dword(ri2)+2)+1;
                    if g>gain2 then
                      gain2:=g;
                  end;
                if gain2>gain+4 then
                  begin
                    { the current byte becomes a literal, retry behind it }
                    inc(p);
                    continue;
                  end;
              end;
            take_literals(p);
            litlen:=p-anchor;
            { pick the offset value and update the recent offsets exactly
              the way the decoder replays them }
            if userep then
              dist:=reps[ri];
            if userep and ((litlen>0) or (ri>0)) then
              begin
                { without literals the repeat codes shift down by one }
                ofv:=ri+ord(litlen>0);
                if ri=2 then
                  reps[2]:=reps[1];
                if ri>=1 then
                  begin
                    reps[1]:=reps[0];
                    reps[0]:=dist;
                  end;
              end
            else
              begin
                { plain offset; also the first repeat offset without
                  literals, which has no repeat code }
                ofv:=dword(dist)+3;
                reps[2]:=reps[1];
                reps[1]:=reps[0];
                reps[0]:=dist;
              end;
            seqll[seqcnt]:=litlen;
            seqml[seqcnt]:=mlen;
            seqov[seqcnt]:=ofv;
            inc(seqcnt);
            inc(p,mlen);
            anchor:=p;
            index_up_to(p);
          end;
        take_literals(srcend);
        procpos:=srcend;
      end;


{****************************************************************************
                               Block encoding
****************************************************************************}

    { writes the literals section to blk; returns its size }
    function tzstdencoder.build_literals: sizeint;
      var
        count: array[0..255] of dword;
        hlen,weights: thuflens;
        code: thufcodes;
        treedesc: array[0..128] of byte;
        treelen,total,per,n,comp,hdr,i: sizeint;
        distinct,maxbits,lastsym,littype,s: longint;
        bitsold,bitsnew,v: qword;
        oldok,four: boolean;

      { raw (kind 0) or rle (kind 1) literals }
      function plain_section(kind: byte): sizeint;
        begin
          if litcnt<32 then
            begin
              blk[0]:=byte(litcnt shl 3) or kind;
              result:=1;
            end
          else if litcnt<4096 then
            begin
              blk[0]:=byte(litcnt shl 4) or $04 or kind;
              blk[1]:=byte(litcnt shr 4);
              result:=2;
            end
          else
            begin
              blk[0]:=byte(litcnt shl 4) or $0c or kind;
              blk[1]:=byte(litcnt shr 4);
              blk[2]:=byte(litcnt shr 12);
              result:=3;
            end;
          if kind=1 then
            begin
              blk[result]:=litbuf[0];
              inc(result);
            end
          else
            begin
              move(litbuf[0],blk[result],litcnt);
              inc(result,litcnt);
            end;
        end;

      { writes cnt literals from first on as one huffman stream, the last
        literal first; returns the stream size }
      function put_stream(first,cnt,pos: sizeint): sizeint;
        var
          bw: tbitwriter;
          i: sizeint;
        begin
          bw_open(bw,@streams[0],pos);
          for i:=first+cnt-1 downto first do
            bw_put(bw,code[litbuf[i]],hlen[litbuf[i]]);
          bw_close(bw);
          result:=bw.pos-pos;
        end;

      begin
        for s:=0 to high(count) do
          count[s]:=0;
        for i:=0 to litcnt-1 do
          inc(count[litbuf[i]]);
        distinct:=0;
        lastsym:=0;
        for s:=0 to 255 do
          if count[s]>0 then
            begin
              inc(distinct);
              lastsym:=s;
            end;
        if distinct=1 then
          exit(plain_section(1));
        { too small for a tree to pay off }
        if litcnt<32 then
          exit(plain_section(0));
        huf_lengths(count,lastsym+1,hlen);
        maxbits:=0;
        for s:=0 to lastsym do
          if hlen[s]>maxbits then
            maxbits:=hlen[s];
        { the first assignment only settles the data flow analysis }
        weights[0]:=0;
        for s:=0 to lastsym do
          if hlen[s]>0 then
            weights[s]:=maxbits+1-hlen[s]
          else
            weights[s]:=0;
        huf_canon_codes(hlen,lastsym,maxbits,code);
        treelen:=huf_write_desc(weights,lastsym,@treedesc[0]);
        if treelen=0 then
          exit(plain_section(0));
        { the tree of the previous block may beat a fresh tree and its
          description }
        littype:=2;
        if phuflive then
          begin
            bitsold:=0;
            bitsnew:=qword(treelen)*8;
            oldok:=true;
            for s:=0 to lastsym do
              if count[s]>0 then
                begin
                  if phuflen[s]=0 then
                    begin
                      oldok:=false;
                      break;
                    end;
                  bitsold:=bitsold+qword(count[s])*phuflen[s];
                  bitsnew:=bitsnew+qword(count[s])*hlen[s];
                end;
            if oldok and (bitsold<=bitsnew) then
              begin
                littype:=3;
                treelen:=0;
                hlen:=phuflen;
                code:=phufcode;
              end;
          end;
        { one stream, or four streams behind a jump table }
        four:=litcnt>256;
        if not four then
          total:=put_stream(0,litcnt,0)
        else
          begin
            per:=(litcnt+3) div 4;
            total:=6;
            for i:=0 to 2 do
              begin
                n:=put_stream(i*per,per,total);
                streams[2*i]:=byte(n);
                streams[2*i+1]:=byte(n shr 8);
                inc(total,n);
              end;
            inc(total,put_stream(3*per,litcnt-3*per,total));
          end;
        comp:=treelen+total;
        { header layout by sizes }
        if (litcnt<=1023) and (comp<=1023) then
          hdr:=3
        else if four and (litcnt<=16383) and (comp<=16383) then
          hdr:=4
        else if four then
          hdr:=5
        else
          exit(plain_section(0));
        { not worth it }
        if hdr+comp>=litcnt+3 then
          exit(plain_section(0));
        v:=qword(littype) or (qword(hdr-3+ord(four)) shl 2) or (qword(litcnt) shl 4) or
           (qword(comp) shl (4*hdr+2));
        for i:=0 to hdr-1 do
          blk[i]:=byte(v shr (8*i));
        move(treedesc[0],blk[hdr],treelen);
        move(streams[0],blk[hdr+treelen],total);
        if littype=2 then
          begin
            { the decoder remembers this tree from now on }
            fillchar(phuflen,sizeof(phuflen),0);
            fillchar(phufcode,sizeof(phufcode),0);
            for s:=0 to lastsym do
              begin
                phuflen[s]:=hlen[s];
                phufcode[s]:=code[s];
              end;
            phuflive:=true;
          end;
        result:=hdr+comp;
      end;


    { appends the sequences section to blk at pos; returns the new end or
      -1 when the sequences cannot be coded }
    function tzstdencoder.build_sequences(pos: sizeint): sizeint;
      var
        llcount: array[0..35] of dword;
        mlcount: array[0..52] of dword;
        ofcount: array[0..31] of dword;
        llnorm,mlnorm,ofnorm: array[0..63] of smallint;
        llmode,mlmode,ofmode,llacc,mlacc,ofacc: longint;
        llstate,mlstate,ofstate,total,i: longint;
        bw: tbitwriter;

      { picks predefined (0), rle (1), fresh fse (2) or repeat (3) coding
        for channel ch, -1 when nothing fits; acc returns the accuracy
        log, for rle the lone symbol }
      function choose_mode(ch: longint; const cnt: array of dword; nsym: longint; const defnorm: array of smallint;
                           defnsym,defacc,maxacc: longint; var norm: array of smallint; out acc: longint): longint;
        var
          distinct,last,s: longint;
          costdef,costfse,costrep: qword;
          tmp: array[0..255] of byte;
          ok: boolean;
        begin
          distinct:=0;
          last:=0;
          for s:=0 to nsym-1 do
            if cnt[s]>0 then
              begin
                inc(distinct);
                last:=s;
              end;
          if distinct=1 then
            begin
              acc:=last;
              { the same single symbol again is a free repeat }
              if (pseqkind[ch]=2) and (pseqrle[ch]=last) then
                exit(3);
              exit(1);
            end;
          { the predefined table does not cover every symbol }
          costdef:=high(qword);
          if last<defnsym then
            costdef:=fse_cost(cnt,defnorm,defnsym,defacc);
          { the table of the last block needs no description }
          costrep:=high(qword);
          if pseqkind[ch]=1 then
            costrep:=fse_cost(cnt,pseqnorm[ch],nsym,pseqacc[ch]);
          costfse:=high(qword);
          acc:=bit_top(total-1)-2;
          if acc<bit_top(distinct-1)+1 then
            acc:=bit_top(distinct-1)+1;
          if acc<5 then
            acc:=5;
          if acc>maxacc then
            acc:=maxacc;
          ok:=fse_normalize(cnt,total,nsym,acc,norm);
          if ok then
            costfse:=fse_cost(cnt,norm,nsym,acc)+qword(fse_write_spec(norm,last+1,acc,@tmp[0],0))*8*256;
          if (costrep<=costfse) and (costrep<=costdef) then
            exit(3);
          if (costdef=high(qword)) and not ok then
            exit(-1);
          if costdef<=costfse then
            begin
              for s:=0 to nsym-1 do
                if s<defnsym then
                  norm[s]:=defnorm[s]
                else
                  norm[s]:=0;
              acc:=defacc;
              exit(0);
            end;
          result:=2;
        end;

      { writes the table of channel ch and makes it the current one, which
        is what the decoder holds for this channel from now on }
      procedure put_table(ch,mode: longint; const norm: array of smallint; nsym,acc: longint);
        var
          s: longint;
        begin
          if mode=1 then
            begin
              { single state table of accuracy log 0, every step moves
                zero bits }
              blk[pos]:=acc;
              inc(pos);
              pseqenc[ch].acclog:=0;
              pseqenc[ch].statetab[0]:=1;
              pseqenc[ch].dbits[acc]:=-1;
              pseqenc[ch].dstate[acc]:=-1;
              pseqkind[ch]:=2;
              pseqrle[ch]:=acc;
            end
          else if mode<>3 then
            begin
              if mode=2 then
                inc(pos,fse_write_spec(norm,nsym,acc,@blk[0],pos));
              fse_build_enc(pseqenc[ch],norm,nsym,acc);
              pseqkind[ch]:=1;
              for s:=0 to 63 do
                if s<nsym then
                  pseqnorm[ch,s]:=norm[s]
                else
                  pseqnorm[ch,s]:=0;
              pseqacc[ch]:=acc;
            end;
        end;

      procedure put_extra_bits(n: longint);
        begin
          bw_put(bw,seqll[n]-ll_base[llcodes[n]],ll_xtra[llcodes[n]]);
          bw_put(bw,seqml[n]-ml_base[mlcodes[n]],ml_xtra[mlcodes[n]]);
          bw_put(bw,seqov[n]-(dword(1) shl ofcodes[n]),ofcodes[n]);
        end;

      begin
        total:=seqcnt;
        { sequence count, 1 to 3 bytes }
        if total<128 then
          begin
            blk[pos]:=total;
            inc(pos);
          end
        else if total<$7f00 then
          begin
            blk[pos]:=(total shr 8)+$80;
            blk[pos+1]:=byte(total);
            inc(pos,2);
          end
        else
          begin
            blk[pos]:=255;
            blk[pos+1]:=byte(total-$7f00);
            blk[pos+2]:=byte((total-$7f00) shr 8);
            inc(pos,3);
          end;
        if total=0 then
          exit(pos);
        { per-sequence codes and their histograms }
        for i:=0 to high(llcount) do
          llcount[i]:=0;
        for i:=0 to high(mlcount) do
          mlcount[i]:=0;
        for i:=0 to high(ofcount) do
          ofcount[i]:=0;
        for i:=0 to total-1 do
          begin
            llcodes[i]:=ll_code(seqll[i]);
            mlcodes[i]:=ml_code(seqml[i]-3);
            ofcodes[i]:=bit_top(seqov[i]);
            inc(llcount[llcodes[i]]);
            inc(mlcount[mlcodes[i]]);
            inc(ofcount[ofcodes[i]]);
          end;
        llmode:=choose_mode(0,llcount,36,def_ll,36,6,9,llnorm,llacc);
        ofmode:=choose_mode(1,ofcount,32,def_of,29,5,8,ofnorm,ofacc);
        mlmode:=choose_mode(2,mlcount,53,def_ml,53,6,9,mlnorm,mlacc);
        if (llmode<0) or (ofmode<0) or (mlmode<0) then
          exit(-1);
        blk[pos]:=(llmode shl 6) or (ofmode shl 4) or (mlmode shl 2);
        inc(pos);
        put_table(0,llmode,llnorm,36,llacc);
        put_table(1,ofmode,ofnorm,32,ofacc);
        put_table(2,mlmode,mlnorm,53,mlacc);
        { interleaved bitstream, written forward, read backward }
        bw_open(bw,@blk[0],pos);
        i:=total-1;
        mlstate:=fse_enc_init(pseqenc[2],mlcodes[i]);
        ofstate:=fse_enc_init(pseqenc[1],ofcodes[i]);
        llstate:=fse_enc_init(pseqenc[0],llcodes[i]);
        put_extra_bits(i);
        for i:=total-2 downto 0 do
          begin
            fse_enc_push(pseqenc[1],bw,ofstate,ofcodes[i]);
            fse_enc_push(pseqenc[2],bw,mlstate,mlcodes[i]);
            fse_enc_push(pseqenc[0],bw,llstate,llcodes[i]);
            put_extra_bits(i);
          end;
        bw_put(bw,mlstate,pseqenc[2].acclog);
        bw_put(bw,ofstate,pseqenc[1].acclog);
        bw_put(bw,llstate,pseqenc[0].acclog);
        bw_close(bw);
        result:=bw.pos;
      end;


    { writes the low n bytes of v, least significant first }
    procedure tzstdencoder.put_le(v: dword; n: longint);
      begin
        while n>0 do
          begin
            outbuf[outlen]:=byte(v);
            inc(outlen);
            v:=v shr 8;
            dec(n);
          end;
      end;


    procedure tzstdencoder.put_block_header(btype: dword; size: sizeint; last: boolean);
      begin
        put_le(dword(ord(last)) or (btype shl 1) or (dword(size) shl 3),3);
      end;


    { assembles one block from the gathered literals and sequences and
      writes it as an rle, compressed or raw block, whichever is smallest }
    procedure tzstdencoder.flush_block(srclen: sizeint; last: boolean);
      var
        src: pbyte;
        i,bodylen: sizeint;
      begin
        src:=win+procpos-srclen;
        i:=1;
        while (i<srclen) and (src[i]=src[0]) do
          inc(i);
        if (i=srclen) and (srclen>3) then
          begin
            { the whole block is one byte value; the decoder sees no
              sequences, so its recent offsets stay as they were }
            reps:=blockreps;
            put_block_header(1,srclen,last);
            put_le(src[0],1);
          end
        else
          begin
            bodylen:=build_sequences(build_literals);
            if (bodylen<0) or (bodylen>=srclen) or (bodylen>blockcap) then
              begin
                { raw block: the tables built above and the sequences never
                  reach the decoder, so stop relying on them }
                reps:=blockreps;
                phuflive:=false;
                pseqkind[0]:=0;
                pseqkind[1]:=0;
                pseqkind[2]:=0;
                put_block_header(0,srclen,last);
                move(src^,outbuf[outlen],srclen);
                inc(outlen,srclen);
              end
            else
              begin
                put_block_header(2,bodylen,last);
                move(blk[0],outbuf[outlen],bodylen);
                inc(outlen,bodylen);
              end;
          end;
        litcnt:=0;
        seqcnt:=0;
      end;


{****************************************************************************
                                   Frame
****************************************************************************}

    { writes the frame header and sizes the window and the match finder;
      the header carries the content size when known is set }
    procedure tzstdencoder.start_frame(known: boolean; size: sizeint);
      var
        single: boolean;
        efflog,fcs: longint;
      begin
        put_le($fd2fb528,4);
        single:=known and (size<=8*1024*1024);
        if single then
          begin
            { the window equals the content }
            winsize:=size;
            if winsize<1 then
              winsize:=1;
            efflog:=bit_top(winsize)+1;
            if (sizeint(1) shl (efflog-1))=winsize then
              dec(efflog);
            if efflog>wlog then
              efflog:=wlog;
          end
        else
          begin
            efflog:=wlog;
            winsize:=sizeint(1) shl efflog;
          end;
        { content size field of 1, 2 or 4 bytes }
        if not single or (size>65791) then
          fcs:=2
        else if size>=256 then
          fcs:=1
        else
          fcs:=0;
        { descriptor: content size code, single segment and checksum flags }
        if single then
          put_le($24 or (fcs shl 6),1)
        else
          begin
            put_le($04 or (ord(known) shl 7),1);
            { window descriptor, exponent only }
            put_le((efflog-10) shl 3,1);
          end;
        if known and (fcs=1) then
          put_le(size-256,2)
        else if known then
          put_le(size,1 shl fcs);
        blockcap:=winsize;
        if blockcap>block_src then
          blockcap:=block_src;
        { nothing to compress }
        if size=0 then
          exit;
        hbits:=efflog-2;
        if hbits<13 then
          hbits:=13;
        if hbits>18 then
          hbits:=18;
        setlength(head,1 shl hbits);
        fillchar(head[0],length(head)*sizeof(head[0]),$ff);
        setlength(head3,1 shl 14);
        fillchar(head3[0],length(head3)*sizeof(head3[0]),$ff);
        chainmask:=(sizeint(1) shl (efflog+1))-1;
        if chainmask<4*block_src-1 then
          chainmask:=4*block_src-1;
        setlength(chain,chainmask+1);
        reps[0]:=1;
        reps[1]:=4;
        reps[2]:=8;
        setlength(litbuf,block_src+8);
        setlength(streams,block_src+(block_src shr 1)+128);
        setlength(llcodes,block_src div 3+16);
        setlength(mlcodes,block_src div 3+16);
        setlength(ofcodes,block_src div 3+16);
        setlength(seqll,block_src div 3+16);
        setlength(seqml,block_src div 3+16);
        setlength(seqov,block_src div 3+16);
        { the sequences can outgrow the source }
        setlength(blk,8*block_src);
      end;


    { packs len bytes at src into dst, which must have room for the worst
      case; returns the frame size }
    function tzstdencoder.pack(src: pbyte; len: sizeint; level: longint; dst: pbyte): sizeint;
      var
        known: boolean;
        rest: sizeint;
      begin
        if level<1 then
          level:=1;
        if level>9 then
          level:=9;
        wlog:=levels[level].wlog;
        tries:=levels[level].tries;
        nicelen:=levels[level].nicelen;
        lazy:=levels[level].lazy;
        win:=src;
        winlen:=len;
        outbuf:=dst;
        { input that reaches the window size plus eight blocks is framed
          like a stream of unknown length: no content size in the header,
          the window sized by the level, and an empty block to close the
          frame when the input ends on a block boundary }
        known:=len<(sizeint(1) shl wlog)+8*block_src;
        start_frame(known,len);
        while winlen-procpos>=block_src do
          begin
            parse_block(procpos+blockcap);
            flush_block(blockcap,known and (winlen=procpos));
            slide_window;
          end;
        rest:=winlen-procpos;
        if rest>0 then
          begin
            parse_block(winlen);
            flush_block(rest,true);
          end
        else if (len=0) or not known then
          { close with an empty raw block }
          put_block_header(0,0,true);
        put_le(dword(xxh64(src,len)),4);
        result:=outlen;
      end;


    function zstd_pack(const src: ansistring; level: longint): ansistring;
      var
        enc: tzstdencoder;
        len: sizeint;
      begin
        result:='';
        len:=length(src);
        { a block never grows by more than its 3 byte header }
        setlength(result,len+3*(len shr 17)+32);
        enc:=tzstdencoder.create;
        len:=enc.pack(pointer(src),len,level,pointer(result));
        enc.free;
        setlength(result,len);
      end;

end.
