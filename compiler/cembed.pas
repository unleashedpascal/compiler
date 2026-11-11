{ Part of the Unleashed Pascal Compiler
  Copyright (c) 2026 Unleashed Pascal Contributors <https://unleashedpascal.org>
  License: MPL-2.0

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can
  obtain one at https://mozilla.org/MPL/2.0/.

  These notices must be kept in copies and modified versions (MPL-2.0 sec. 3.1);
  add yours below. }

{ the parameters written after the path of $embedstr / $embedbytes }
unit cembed;

{$i fpcdefs.inc}

interface

    { packs and encrypts data as the parameters in params say:

        compress[=deflate|zlib|gzip|zstd]       deflate when no value
        encrypt[=chacha20_ietf|chacha20|aes]    chacha20_ietf when no value
        seed=text     key: the text padded with zero bytes or cut to 32 bytes
        nonce=text    nonce, padded or cut the same way
        nullnonce     nonce of zero bytes

      a value with spaces goes in quotes. packing runs first. encrypted data
      is laid out as: key (only when no seed is given, random then), nonce
      (random without nonce / nullnonce), encrypted data, tag.
      returns false and the reason in err when the parameters are wrong. }
    function embed_apply_params(params:ansistring;var data:ansistring;out err:ansistring):boolean;

implementation

    uses
      sysutils,
      cutils,cdeflate,czstd,ccipher;

    const
      zstd_level = 9;

    var
      random_key : ansistring = '';
      random_count : dword = 0;


    function fit(const s:ansistring;size:longint):ansistring;
      begin
        result:=copy(s,1,size);
        while length(result)<size do
          result:=result+#0;
      end;


    { n random bytes: the chacha20 key stream under a key made once per run
      of the compiler from the clock, the process id and a stack address, so
      two compilers started in the same moment still differ }
    function random_bytes(n:longint):ansistring;
      var
        t : tdatetime;
        ticks : qword;
        pid : dword;
        addr : ptruint;
        nonce : ansistring;
      begin
        if random_key='' then
          begin
            random_key:=fit('',cipher_key_size);
            t:=now;
            ticks:=gettickcount64;
            pid:=dword(getprocessid);
            addr:=ptruint(@t);
            move(t,random_key[1],sizeof(t));
            move(ticks,random_key[9],sizeof(ticks));
            move(pid,random_key[17],sizeof(pid));
            move(addr,random_key[21],sizeof(addr));
          end;
        inc(random_count);
        nonce:=fit('',cipher_nonce_size[ck_chacha20_ietf]);
        move(random_count,nonce[1],sizeof(random_count));
        result:=copy(cipher_seal(ck_chacha20_ietf,random_key,nonce,fit('',n)),1,n);
      end;


    { takes the next `name` or `name=value` off params. a doubled quote
      inside a quoted value stands for one }
    function next_param(var params:ansistring;out name,value:ansistring;out hasvalue:boolean;out err:ansistring):boolean;
      var
        i,n : longint;
        quote : char;
      begin
        result:=false;
        name:='';
        value:='';
        err:='';
        hasvalue:=false;
        n:=length(params);
        i:=1;
        while (i<=n) and not (params[i] in [' ',#9,'=']) do
          begin
            name:=name+params[i];
            inc(i);
          end;
        if (i<=n) and (params[i]='=') then
          begin
            hasvalue:=true;
            inc(i);
            if (i<=n) and (params[i] in ['''','"']) then
              begin
                quote:=params[i];
                inc(i);
                repeat
                  if i>n then
                    begin
                      err:='missing closing quote';
                      exit;
                    end;
                  if params[i]=quote then
                    begin
                      inc(i);
                      if (i>n) or (params[i]<>quote) then
                        break;
                    end;
                  value:=value+params[i];
                  inc(i);
                until false;
              end
            else
              while (i<=n) and not (params[i] in [' ',#9]) do
                begin
                  value:=value+params[i];
                  inc(i);
                end;
          end;
        delete(params,1,i-1);
        result:=true;
      end;


    function embed_apply_params(params:ansistring;var data:ansistring;out err:ansistring):boolean;
      type
        tparam = (ep_compress,ep_encrypt,ep_seed,ep_nonce,ep_nullnonce);
      const
        param_names : array[tparam] of string[9] = ('compress','encrypt','seed','nonce','nullnonce');
      var
        seen : set of tparam;
        values : array[tparam] of ansistring;
        name,value,key,nonce : ansistring;
        hasvalue,found : boolean;
        p,q : tparam;
        container : tdeflatecontainer;
        cipher : tcipherkind;
      begin
        result:=false;
        err:='';
        seen:=[];
        container:=dc_raw;
        cipher:=ck_chacha20_ietf;
        params:=trimspace(params);
        while params<>'' do
          begin
            if not next_param(params,name,value,hasvalue,err) then
              exit;
            found:=false;
            p:=low(tparam);
            for q:=low(tparam) to high(tparam) do
              if lower(name)=param_names[q] then
                begin
                  p:=q;
                  found:=true;
                end;
            if not found then
              err:='unknown parameter "'+name+'"'
            else if p in seen then
              err:='parameter "'+param_names[p]+'" given twice'
            else if (p=ep_nullnonce) and hasvalue then
              err:='"nullnonce" takes no value'
            else if (p in [ep_seed,ep_nonce]) and not hasvalue then
              err:='"'+param_names[p]+'" needs a value, as in '+param_names[p]+'=...';
            if err<>'' then
              exit;
            include(seen,p);
            values[p]:=value;
            params:=trimspace(params);
          end;

        if (ep_nonce in seen) and (ep_nullnonce in seen) then
          err:='"nonce" and "nullnonce" exclude each other'
        else if not (ep_encrypt in seen) then
          for p:=ep_seed to ep_nullnonce do
            if (p in seen) and (err='') then
              err:='"'+param_names[p]+'" needs "encrypt"';
        if err<>'' then
          exit;

        if ep_compress in seen then
          begin
            value:=lower(values[ep_compress]);
            if value='zlib' then
              container:=dc_zlib
            else if value='gzip' then
              container:=dc_gzip
            else if (value<>'') and (value<>'deflate') and (value<>'zstd') then
              begin
                err:='unknown value "'+values[ep_compress]+'" for "compress"';
                exit;
              end;
          end;
        if ep_encrypt in seen then
          begin
            value:=lower(values[ep_encrypt]);
            if value='chacha20' then
              cipher:=ck_chacha20
            else if value='aes' then
              cipher:=ck_aes
            else if (value<>'') and (value<>'chacha20_ietf') then
              begin
                err:='unknown value "'+values[ep_encrypt]+'" for "encrypt"';
                exit;
              end;
          end;

        if ep_compress in seen then
          begin
            if lower(values[ep_compress])='zstd' then
              data:=zstd_pack(data,zstd_level)
            else
              data:=deflate_pack(data,container);
          end;
        if ep_encrypt in seen then
          begin
            if ep_seed in seen then
              key:=fit(values[ep_seed],cipher_key_size)
            else
              key:=random_bytes(cipher_key_size);
            if ep_nonce in seen then
              nonce:=fit(values[ep_nonce],cipher_nonce_size[cipher])
            else if ep_nullnonce in seen then
              nonce:=fit('',cipher_nonce_size[cipher])
            else
              nonce:=random_bytes(cipher_nonce_size[cipher]);
            data:=nonce+cipher_seal(cipher,key,nonce,data);
            if not (ep_seed in seen) then
              data:=key+data;
          end;
        result:=true;
      end;

end.
