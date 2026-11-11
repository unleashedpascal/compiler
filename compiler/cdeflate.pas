{ Part of the Unleashed Pascal Compiler
  Copyright (c) 2026 Unleashed Pascal Contributors <https://unleashedpascal.org>
  License: MPL-2.0

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can
  obtain one at https://mozilla.org/MPL/2.0/.

  These notices must be kept in copies and modified versions (MPL-2.0 sec. 3.1);
  add yours below. }
unit cdeflate;

{$i fpcdefs.inc}
{$R-}{$Q-}

interface

    type
      tdeflatecontainer = (dc_raw, dc_zlib, dc_gzip);

    { compresses src into one deflate stream (RFC 1951), bare or wrapped in a
      zlib (RFC 1950) or gzip (RFC 1952) container; the state lives in unit
      variables, so this is not reentrant; returns an empty string if src
      is 2 GiB or larger }
    function deflate_pack(const src : ansistring;container : tdeflatecontainer) : ansistring;

implementation

    const
      { base values and extra bit counts of the length and distance codes }
      len_base : array[0..28] of word = (
        3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,
        131,163,195,227,258);
      len_extra : array[0..28] of byte = (
        0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0);
      dist_base : array[0..29] of word = (
        1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,
        1537,2049,3073,4097,6145,8193,12289,16385,24577);
      dist_extra : array[0..29] of byte = (
        0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13);
      { order in which a dynamic block stores the lengths of the code length
        codes }
      cl_order : array[0..18] of byte = (
        16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15);

      hash_size = 1 shl 15;
      hash_mask = hash_size-1;
      { window size, the farthest a match may reach back }
      win_size = 32768;
      win_mask = win_size-1;
      { longest hash chain walked for one position }
      max_chain = 256;

    var
      inp : pbyte;
      inlen : longint;
      { output buffer, bytes used and bytes allocated }
      outbuf : pbyte;
      outpos,
      outcap : longint;
      { pending output bits and their count }
      bitbuf,
      bitcnt : longint;
      { start of the match returned by find_match }
      match_start : longint;
      { false: count the symbols, true: write their codes }
      emit : boolean;
      { newest position per hash and the position before it per window slot }
      head : array[0..hash_size-1] of longint;
      prev : array[0..win_mask] of longint;
      { literal/length and distance symbol counts }
      lfreq : array[0..285] of longint;
      dfreq : array[0..29] of longint;
      { code lengths and codes of the block being written }
      llen : array[0..287] of byte;
      dlen : array[0..29] of byte;
      lcode : array[0..287] of word;
      dcode : array[0..29] of word;
      { code lengths of the fixed codes }
      fixl : array[0..287] of byte;
      fixd : array[0..29] of byte;
      { code length alphabet }
      clfreq : array[0..18] of longint;
      cllen : array[0..18] of byte;
      clcode : array[0..18] of word;
      lcount,
      dcount,
      clcount : longint;
      { run length coded code lengths: symbol, extra bits value and count }
      rlesym,
      rleext,
      rlebits : array[0..315] of byte;
      rlecount : longint;
      { scratch of make_lengths: leaf symbols, node weights, parents, depths
        and the number of codes per length }
      hsym : array[0..287] of word;
      hfrq : array[0..575] of longint;
      hdad,
      hdep : array[0..575] of word;
      hbl : array[0..16] of word;


    { reverses the low n bits of v }
    function rev(v,n : longint) : longint;
      var
        i : longint;
      begin
        result:=0;
        for i:=0 to n-1 do
          begin
            result:=(result shl 1) or (v and 1);
            v:=v shr 1;
          end;
      end;


    procedure put_byte(b : longint);
      begin
        if outpos>=outcap then
          begin
            if outcap=0 then
              outcap:=256
            else
              outcap:=outcap*2;
            reallocmem(outbuf,outcap);
          end;
        outbuf[outpos]:=b;
        inc(outpos);
      end;


    { writes the low n bits of v, lowest bit first }
    procedure put_bits(v,n : longint);
      begin
        bitbuf:=bitbuf or (v shl bitcnt);
        inc(bitcnt,n);
        while bitcnt>=8 do
          begin
            put_byte(bitbuf and $ff);
            bitbuf:=bitbuf shr 8;
            dec(bitcnt,8);
          end;
      end;


    { pads the output to a byte boundary }
    procedure flush_bits;
      begin
        if bitcnt>0 then
          begin
            put_byte(bitbuf and $ff);
            bitbuf:=0;
            bitcnt:=0;
          end;
      end;


    { computes huffman code lengths of at most maxbits bits for the n counts
      in freq and stores them in lens; at least two symbols get a code, so
      the code is always complete }
    procedure make_lengths(freq : plongint;n,maxbits : longint;lens : pbyte);
      var
        i,j,k,f,s,a,b,
        leaves,lo,iq,nodes,deepest,over : longint;

      { takes the lighter of the next unused leaf and the next unused
        inner node }
      function next_node : longint;
        begin
          if (lo<leaves) and ((iq>=nodes) or (hfrq[lo]<=hfrq[iq])) then
            begin
              result:=lo;
              inc(lo);
            end
          else
            begin
              result:=iq;
              inc(iq);
            end;
        end;

      begin
        for i:=0 to n-1 do
          lens[i]:=0;
        leaves:=0;
        for i:=0 to n-1 do
          if freq[i]>0 then
            begin
              hsym[leaves]:=i;
              hfrq[leaves]:=freq[i];
              inc(leaves);
            end;
        i:=0;
        while leaves<2 do
          begin
            if freq[i]=0 then
              begin
                hsym[leaves]:=i;
                hfrq[leaves]:=1;
                inc(leaves);
              end;
            inc(i);
          end;
        { sort the leaves by ascending count }
        for i:=1 to leaves-1 do
          begin
            f:=hfrq[i];
            s:=hsym[i];
            j:=i-1;
            while (j>=0) and (hfrq[j]>f) do
              begin
                hfrq[j+1]:=hfrq[j];
                hsym[j+1]:=hsym[j];
                dec(j);
              end;
            hfrq[j+1]:=f;
            hsym[j+1]:=s;
          end;
        { the sorted leaves and the inner nodes, which come out sorted as
          well, form two queues; join the two lightest nodes until one is
          left }
        lo:=0;
        iq:=leaves;
        nodes:=leaves;
        for i:=1 to leaves-1 do
          begin
            a:=next_node;
            b:=next_node;
            hfrq[nodes]:=hfrq[a]+hfrq[b];
            hdad[a]:=nodes;
            hdad[b]:=nodes;
            inc(nodes);
          end;
        { the code length of a leaf is its depth; a parent always follows
          its children }
        hdep[nodes-1]:=0;
        for i:=nodes-2 downto 0 do
          hdep[i]:=hdep[hdad[i]]+1;
        deepest:=0;
        for i:=0 to leaves-1 do
          if hdep[i]>deepest then
            deepest:=hdep[i];
        if deepest>maxbits then
          begin
            { cut the tree at maxbits and move leaves down until the code is
              complete again }
            for i:=0 to maxbits do
              hbl[i]:=0;
            over:=0;
            for i:=0 to nodes-1 do
              begin
                if hdep[i]>maxbits then
                  begin
                    hdep[i]:=maxbits;
                    inc(over);
                  end;
                if i<leaves then
                  inc(hbl[hdep[i]]);
              end;
            repeat
              j:=maxbits-1;
              while hbl[j]=0 do
                dec(j);
              dec(hbl[j]);
              inc(hbl[j+1],2);
              dec(hbl[maxbits]);
              dec(over,2);
            until over<=0;
            { the rarest leaves come first and take the longest codes }
            k:=0;
            for i:=maxbits downto 1 do
              while hbl[i]>0 do
                begin
                  hdep[k]:=i;
                  inc(k);
                  dec(hbl[i]);
                end;
          end;
        for i:=0 to leaves-1 do
          lens[hsym[i]]:=hdep[i];
      end;


    { assigns canonical codes to the n code lengths in lens; the codes are
      stored bit reversed, the way put_bits needs them }
    procedure make_codes(lens : pbyte;n : longint;codes : pword);
      var
        count,
        next : array[0..15] of longint;
        i,c : longint;
      begin
        for i:=0 to 15 do
          count[i]:=0;
        for i:=0 to n-1 do
          inc(count[lens[i]]);
        count[0]:=0;
        c:=0;
        for i:=1 to 15 do
          begin
            c:=(c+count[i-1]) shl 1;
            next[i]:=c;
          end;
        for i:=0 to n-1 do
          if lens[i]<>0 then
            begin
              codes[i]:=rev(next[lens[i]],lens[i]);
              inc(next[lens[i]]);
            end
          else
            codes[i]:=0;
      end;


    { returns the highest index up to hi whose base value does not exceed v }
    function find_code(v : longint;base : pword;hi : longint) : longint;
      var
        i : longint;
      begin
        for i:=hi downto 0 do
          if v>=base[i] then
            exit(i);
        result:=0;
      end;


    procedure put_literal(b : longint);
      begin
        if emit then
          put_bits(lcode[b],llen[b])
        else
          inc(lfreq[b]);
      end;


    procedure put_match(len,dist : longint);
      var
        li,di : longint;
      begin
        li:=find_code(len,@len_base[0],28);
        di:=find_code(dist,@dist_base[0],29);
        if emit then
          begin
            put_bits(lcode[257+li],llen[257+li]);
            if len_extra[li]>0 then
              put_bits(len-len_base[li],len_extra[li]);
            put_bits(dcode[di],dlen[di]);
            if dist_extra[di]>0 then
              put_bits(dist-dist_base[di],dist_extra[di]);
          end
        else
          begin
            inc(lfreq[257+li]);
            inc(dfreq[di]);
          end;
      end;


    { hash of the three bytes at p }
    function hash_at(p : longint) : longint;inline;
      begin
        result:=((inp[p] shl 10) xor (inp[p+1] shl 5) xor inp[p+2]) and hash_mask;
      end;


    { adds position p to the hash chains; needs three bytes at p }
    procedure hash_insert(p : longint);
      var
        h : longint;
      begin
        h:=hash_at(p);
        prev[p and win_mask]:=head[h];
        head[h]:=p;
      end;


    { adds position p to the hash chains and returns the length of the
      longest earlier match for it, or 2 if there is none; match_start is
      set to where that match starts; needs three bytes at p }
    function find_match(p : longint) : longint;
      var
        h,cand,best,limit,walked,l : longint;
      begin
        h:=hash_at(p);
        cand:=head[h];
        prev[p and win_mask]:=cand;
        head[h]:=p;
        best:=2;
        limit:=inlen-p;
        if limit>258 then
          limit:=258;
        walked:=0;
        while (cand>=0) and (walked<max_chain) do
          begin
            if p-cand>=win_size then
              break;
            if (inp[cand+best]=inp[p+best]) and (inp[cand]=inp[p]) then
              begin
                l:=0;
                while (l<limit) and (inp[cand+l]=inp[p+l]) do
                  inc(l);
                if l>best then
                  begin
                    best:=l;
                    match_start:=cand;
                    if l>=limit then
                      break;
                  end;
              end;
            cand:=prev[cand and win_mask];
            inc(walked);
          end;
        result:=best;
      end;


    { splits the input into literals and matches; a match is held back for
      one byte and dropped for a literal if the next position starts a
      longer one; both passes get the same symbols }
    procedure scan;
      var
        i,len,stop,
        held_len,held_start : longint;
        held : boolean;
      begin
        fillchar(head,sizeof(head),$ff);
        i:=0;
        held_len:=2;
        held_start:=0;
        held:=false;
        while i<inlen do
          begin
            len:=2;
            if i+3<=inlen then
              len:=find_match(i);
            if (held_len>=3) and (len<=held_len) then
              begin
                { the match held at i-1 wins: write it and skip its bytes }
                put_match(held_len,i-1-held_start);
                stop:=i-1+held_len;
                inc(i);
                while (i<stop) and (i+3<=inlen) do
                  begin
                    hash_insert(i);
                    inc(i);
                  end;
                i:=stop;
                held_len:=2;
                held:=false;
              end
            else
              begin
                { hold position i; the byte before it becomes a literal }
                if held then
                  put_literal(inp[i-1]);
                held_len:=len;
                held_start:=match_start;
                held:=true;
                inc(i);
              end;
          end;
        if held then
          put_literal(inp[i-1]);
      end;


    { run length codes the literal/length and distance code lengths with
      the code length alphabet and counts its symbols }
    procedure code_lengths;
      var
        comb : array[0..315] of byte;
        i,j,total,cur,run : longint;

      procedure add(sym,ext,bits : longint);
        begin
          rlesym[rlecount]:=sym;
          rleext[rlecount]:=ext;
          rlebits[rlecount]:=bits;
          inc(clfreq[sym]);
          inc(rlecount);
        end;

      { covers what is left of the run with repeat codes of least to most
        lengths each }
      procedure add_repeats(sym,least,most,bits : longint);
        var
          take : longint;
        begin
          while run>=least do
            begin
              take:=run;
              if take>most then
                take:=most;
              add(sym,take-least,bits);
              dec(run,take);
            end;
        end;

      begin
        for i:=0 to lcount-1 do
          comb[i]:=llen[i];
        for i:=0 to dcount-1 do
          comb[lcount+i]:=dlen[i];
        total:=lcount+dcount;
        fillchar(clfreq,sizeof(clfreq),0);
        rlecount:=0;
        i:=0;
        while i<total do
          begin
            cur:=comb[i];
            j:=i+1;
            while (j<total) and (comb[j]=cur) do
              inc(j);
            run:=j-i;
            if cur=0 then
              begin
                add_repeats(18,11,138,7);
                add_repeats(17,3,10,3);
              end
            else
              begin
                add(cur,0,0);
                dec(run);
                add_repeats(16,3,6,2);
              end;
            while run>0 do
              begin
                add(cur,0,0);
                dec(run);
              end;
            i:=j;
          end;
      end;


    { size in bits of all symbols and the end of block code with the given
      code lengths }
    function symbol_bits(ll,dl : pbyte) : int64;
      var
        i : longint;
      begin
        result:=0;
        for i:=0 to 285 do
          result:=result+int64(lfreq[i])*ll[i];
        for i:=0 to 28 do
          result:=result+int64(lfreq[257+i])*len_extra[i];
        for i:=0 to 29 do
          result:=result+int64(dfreq[i])*dl[i]+int64(dfreq[i])*dist_extra[i];
      end;


    { writes the input as stored blocks }
    procedure put_stored;
      var
        p,n,i : longint;
      begin
        p:=0;
        while p<inlen do
          begin
            n:=inlen-p;
            if n>65535 then
              n:=65535;
            { final block flag, block type 0, then up to a byte boundary }
            put_bits(ord(p+n>=inlen),3);
            flush_bits;
            put_byte(n and $ff);
            put_byte(n shr 8);
            put_byte((not n) and $ff);
            put_byte(((not n) shr 8) and $ff);
            for i:=0 to n-1 do
              put_byte(inp[p+i]);
            inc(p,n);
          end;
      end;


    { writes the input as one block with dynamic or fixed codes, or as
      stored blocks, whichever is smallest }
    procedure compress;
      var
        dyn_bits,fix_bits,stored_bytes,best_bits : int64;
        i,hdr_bits : longint;
        dyn : boolean;
      begin
        fillchar(fixl[0],144,8);
        fillchar(fixl[144],112,9);
        fillchar(fixl[256],24,7);
        fillchar(fixl[280],8,8);
        fillchar(fixd,sizeof(fixd),5);

        { first pass: count the symbols }
        fillchar(lfreq,sizeof(lfreq),0);
        fillchar(dfreq,sizeof(dfreq),0);
        emit:=false;
        scan;
        inc(lfreq[256]);

        { dynamic codes and their description in the block header }
        make_lengths(@lfreq[0],286,15,@llen[0]);
        make_lengths(@dfreq[0],30,15,@dlen[0]);
        lcount:=286;
        while (lcount>257) and (llen[lcount-1]=0) do
          dec(lcount);
        dcount:=30;
        while (dcount>1) and (dlen[dcount-1]=0) do
          dec(dcount);
        code_lengths;
        make_lengths(@clfreq[0],19,7,@cllen[0]);
        clcount:=19;
        while (clcount>4) and (cllen[cl_order[clcount-1]]=0) do
          dec(clcount);
        make_codes(@llen[0],286,@lcode[0]);
        make_codes(@dlen[0],30,@dcode[0]);
        make_codes(@cllen[0],19,@clcode[0]);

        { sizes of the three block types }
        hdr_bits:=3+5+5+4+3*clcount;
        for i:=0 to rlecount-1 do
          hdr_bits:=hdr_bits+cllen[rlesym[i]]+rlebits[i];
        dyn_bits:=symbol_bits(@llen[0],@dlen[0])+hdr_bits;
        fix_bits:=symbol_bits(@fixl[0],@fixd[0])+3;
        stored_bytes:=((int64(inlen)+65534) div 65535)*5+inlen;
        best_bits:=dyn_bits;
        dyn:=true;
        if fix_bits<dyn_bits then
          begin
            best_bits:=fix_bits;
            dyn:=false;
          end;

        if stored_bytes<(best_bits+7) div 8 then
          put_stored
        else
          begin
            { final block flag }
            put_bits(1,1);
            if dyn then
              begin
                put_bits(2,2);
                put_bits(lcount-257,5);
                put_bits(dcount-1,5);
                put_bits(clcount-4,4);
                for i:=0 to clcount-1 do
                  put_bits(cllen[cl_order[i]],3);
                for i:=0 to rlecount-1 do
                  begin
                    put_bits(clcode[rlesym[i]],cllen[rlesym[i]]);
                    if rlebits[i]>0 then
                      put_bits(rleext[i],rlebits[i]);
                  end;
              end
            else
              begin
                put_bits(1,2);
                move(fixl,llen,sizeof(llen));
                move(fixd,dlen,sizeof(dlen));
                make_codes(@llen[0],288,@lcode[0]);
                make_codes(@dlen[0],30,@dcode[0]);
              end;
            { second pass: write the symbols and the end of block code }
            emit:=true;
            scan;
            put_bits(lcode[256],llen[256]);
          end;
      end;


    function crc32(p : pbyte;len : dword) : dword;
      var
        i : longint;
      begin
        result:=$ffffffff;
        while len>0 do
          begin
            result:=result xor p^;
            for i:=0 to 7 do
              if (result and 1)<>0 then
                result:=(result shr 1) xor $edb88320
              else
                result:=result shr 1;
            inc(p);
            dec(len);
          end;
        result:=not result;
      end;


    function adler32(p : pbyte;len : dword) : dword;
      var
        a,b : dword;
      begin
        a:=1;
        b:=0;
        while len>0 do
          begin
            a:=(a+p^) mod 65521;
            b:=(b+a) mod 65521;
            inc(p);
            dec(len);
          end;
        result:=(b shl 16) or a;
      end;


    { writes v as four bytes, highest byte first if big is set }
    procedure put_dword(v : dword;big : boolean);
      var
        i : longint;
      begin
        for i:=0 to 3 do
          if big then
            put_byte((v shr (24-8*i)) and $ff)
          else
            put_byte((v shr (8*i)) and $ff);
      end;


    function deflate_pack(const src : ansistring;container : tdeflatecontainer) : ansistring;
      var
        len : dword;
        i : longint;
      begin
        result:='';
        { positions and counts are kept in longints }
        if int64(length(src))>high(longint) then
          exit;
        len:=length(src);
        inp:=pbyte(pointer(src));
        inlen:=len;
        outbuf:=nil;
        outpos:=0;
        outcap:=0;
        bitbuf:=0;
        bitcnt:=0;
        case container of
          dc_zlib:
            begin
              { deflate with a 32 KiB window, marked as best compression }
              put_byte($78);
              put_byte($da);
            end;
          dc_gzip:
            begin
              { magic, deflate, no flags, no time stamp, unknown system }
              put_byte($1f);
              put_byte($8b);
              put_byte(8);
              for i:=0 to 5 do
                put_byte(0);
              put_byte($ff);
            end;
          else
            ;
        end;
        if len=0 then
          begin
            { a final block with fixed codes holding just the end of block
              code }
            put_bits(1,1);
            put_bits(1,2);
            put_bits(0,7);
          end
        else
          compress;
        flush_bits;
        case container of
          dc_zlib:
            put_dword(adler32(inp,len),true);
          dc_gzip:
            begin
              put_dword(crc32(inp,len),false);
              put_dword(len,false);
            end;
          else
            ;
        end;
        setlength(result,outpos);
        move(outbuf^,pointer(result)^,outpos);
        freemem(outbuf);
      end;

end.
