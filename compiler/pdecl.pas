{
    Copyright (c) 1998-2002 by Florian Klaempfl

    Does declaration (but not type) parsing for Free Pascal

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

 ****************************************************************************
}
unit pdecl;

{$i fpcdefs.inc}

interface

    uses
      { common }
      cclasses,
      { global }
      globtype,
      { symtable }
      symsym,symdef,symtype,
      { pass_1 }
      node;

    function  readconstant(const orgname:string;const filepos:tfileposinfo; out nodetype: tnodetype):tconstsym;

    procedure const_dec(out had_generic:boolean);
    procedure consts_dec(in_structure, allow_typed_const: boolean;out had_generic:boolean);
    procedure static_dec(out had_generic:boolean);
    procedure threadstatic_dec(out had_generic:boolean);
    procedure label_dec;
    procedure type_dec(out had_generic:boolean);
    procedure types_dec(in_structure: boolean;out had_generic:boolean;var rtti_attrs_def: trtti_attribute_list);
    procedure var_dec(out had_generic:boolean);
    procedure threadvar_dec(out had_generic:boolean);
    procedure property_dec;
    procedure resourcestring_dec(out had_generic:boolean);
    procedure parse_rttiattributes(var rtti_attrs_def:trtti_attribute_list);
    function parse_forward_declaration(sym:tsym;gentypename,genorgtypename:tidstring;genericdef:tdef;generictypelist:tfphashobjectlist;out newtype:ttypesym):tdef;

implementation

    uses
       SysUtils,
       { common }
       cutils,
       { global }
       globals,tokens,verbose,widestr,constexp,
       systems,aasmdata,fmodule,compinnr,
       { symtable }
       symconst,symbase,symcpu,symcreat,defutil,defcmp,symtable,symutil,
       { pass 1 }
       ninl,ncon,nobj,ngenutil,nld,nmem,ncal,nset,nbas,nflw,nmat,pass_1,
       { parser }
       scanner,
       pbase,pexpr,ptype,ptconst,pdecsub,pdecvar,pdecobj,pgenutil,pparautl,
       procdefutil,
       { codegen }
       procinfo,
{$ifdef jvm}
       pjvm,
{$endif}
       { cpu-information }
       cpuinfo
       ;

    function is_system_custom_attribute_descendant(def:tdef):boolean;
    begin
      if not assigned(class_tcustomattribute) then
        class_tcustomattribute:=tobjectdef(search_system_type('TCUSTOMATTRIBUTE').typedef);
      Result:=def_is_related(def,class_tcustomattribute);
    end;

    function readconstant(const orgname:string;const filepos:tfileposinfo; out nodetype: tnodetype):tconstsym;
      var
        hp : tconstsym;
        p : tnode;
        ps : pconstset;
        pd : pbestreal;
        pg : pguid;
        sp : pchar;
        pw : tcompilerwidestring;
        storetokenpos : tfileposinfo;
      begin
        readconstant:=nil;
        if orgname='' then
         internalerror(9584582);
        hp:=nil;
        p:=comp_expr([ef_accept_equal]);
        nodetype:=p.nodetype;
        storetokenpos:=current_tokenpos;
        current_tokenpos:=filepos;
        case p.nodetype of
           ordconstn:
             begin
               if p.resultdef.typ=pointerdef then
                 hp:=cconstsym.create_ordptr(orgname,constpointer,tordconstnode(p).value.uvalue,p.resultdef)
               else
                 hp:=cconstsym.create_ord(orgname,constord,tordconstnode(p).value,p.resultdef);
             end;
           stringconstn:
             begin
               if is_wide_or_unicode_string(p.resultdef) then
                 begin
                   initwidestring(pw);
                   copywidestring(tstringconstnode(p).valuews,pw);
                   hp:=cconstsym.create_wstring(orgname,constwstring,pw);
                 end
               else
                 begin
                   getmem(sp,tstringconstnode(p).len+1);
                   sp[tstringconstnode(p).len]:=#0;
                   if tstringconstnode(p).len>0 then
                     move(tstringconstnode(p).valueas[0],sp^,tstringconstnode(p).len+1);
                   { if a non-default ansistring code page has been specified,
                     keep it }
                   if is_ansistring(p.resultdef) and
                      (tstringdef(p.resultdef).encoding<>0) then
                     hp:=cconstsym.create_string(orgname,conststring,sp,tstringconstnode(p).len,p.resultdef)
                   else
                     hp:=cconstsym.create_string(orgname,conststring,sp,tstringconstnode(p).len,nil);
                 end;
             end;
           realconstn :
             begin
                new(pd);
                pd^:=trealconstnode(p).value_real;
                hp:=cconstsym.create_ptr(orgname,constreal,pd,p.resultdef);
             end;
           setconstn :
             begin
               new(ps);
               if assigned(tsetconstnode(p).value_set) then
                 ps^:=tsetconstnode(p).value_set^
               else
                 ps^:=[];
               hp:=cconstsym.create_ptr(orgname,constset,ps,p.resultdef);
             end;
           pointerconstn :
             begin
               hp:=cconstsym.create_ordptr(orgname,constpointer,tpointerconstnode(p).value,p.resultdef);
             end;
           niln :
             begin
               hp:=cconstsym.create_ord(orgname,constnil,0,p.resultdef);
             end;
           typen :
             begin
               if is_interface(p.resultdef) then
                begin
                  if assigned(tobjectdef(p.resultdef).iidguid) then
                   begin
                     new(pg);
                     pg^:=tobjectdef(p.resultdef).iidguid^;
                     hp:=cconstsym.create_ptr(orgname,constguid,pg,p.resultdef);
                   end
                  else
                   Message1(parser_e_interface_has_no_guid,tobjectdef(p.resultdef).objrealname^);
                end
               else
                Message(parser_e_illegal_expression);
             end;
           inlinen:
             begin
               { this situation only happens if a intrinsic is parsed that has a
                 generic type as its argument. As we don't know certain
                 information about the final type yet, we need to use safe
                 values (mostly 0, except for (Bit)SizeOf()) }
               if not parse_generic then
                 Message(parser_e_cannot_evaluate_expression_at_compile_time);
               case tinlinenode(p).inlinenumber of
                 in_sizeof_x:
                   begin
                     hp:=cconstsym.create_ord(orgname,constord,1,p.resultdef);
                   end;
                 in_bitsizeof_x:
                   begin
                     hp:=cconstsym.create_ord(orgname,constord,8,p.resultdef);
                   end;
                 { add other cases here if necessary }
                 else
                   Message(parser_e_illegal_expression);
               end;
             end;
           else
             begin
               { the node is from a generic parameter constant and is
                 untyped so we need to pass a placeholder constant
                 instead of givng an error }
               if nf_generic_para in p.flags then
                 hp:=cconstsym.create_ord(orgname,constnil,0,p.resultdef)
               else
                 Message(parser_e_illegal_expression);
             end;
        end;
        { transfer generic param flag from node to symbol }
        if nf_generic_para in p.flags then
          begin
            include(hp.symoptions,sp_generic_const);
            include(hp.symoptions,sp_generic_para);
          end;
        current_tokenpos:=storetokenpos;
        p.free;
        p := nil;
        readconstant:=hp;
      end;

    procedure const_dec(out had_generic:boolean);
      begin
        consume(_CONST);
        consts_dec(false,true,had_generic);
      end;

    procedure consts_dec(in_structure, allow_typed_const: boolean;out had_generic:boolean);
      var
         orgname : TIDString;
         hdef : tdef;
         sym : tsym;
         flags : thccflags;
         dummysymoptions : tsymoptions;
         deprecatedmsg : pshortstring;
         storetokenpos,filepos : tfileposinfo;
         nodetype : tnodetype;
         old_block_type : tblock_type;
         first,
         isgeneric,
         expect_directive,
         skip_initialiser : boolean;
         varspez : tvarspez;
         asmtype : tasmlisttype;
         names : array of TIDString;
         positions : array of tfileposinfo;
         syms : array of tsym;
         namecount,ni : longint;
         tokenbuf : tdynamicarray;
         already_recording : boolean;
      begin
         old_block_type:=block_type;
         block_type:=bt_const;
         had_generic:=false;
         first:=true;
         repeat
           { collect one or more names separated by commas }
           namecount:=0;
           names:=nil;
           positions:=nil;
           syms:=nil;
           repeat
             setlength(names,namecount+1);
             setlength(positions,namecount+1);
             names[namecount]:=current_scanner.orgpattern;
             positions[namecount]:=current_tokenpos;
             inc(namecount);
             consume(_ID);
           until not((m_multi_var_init in current_settings.modeswitches) and
                     try_to_consume(_COMMA));
           orgname:=names[0];
           filepos:=positions[0];
           isgeneric:=not (m_implicit_generics in current_settings.modeswitches) and (namecount=1) and (current_scanner.idtoken=_GENERIC);
           case current_scanner.token of

             _EQ:
                begin
                   if namecount>1 then
                     Message(parser_e_initialized_only_one_var);
                   consume(_EQ);
                   sym:=readconstant(orgname,filepos,nodetype);
                   { Support hint directives }
                   dummysymoptions:=[];
                   deprecatedmsg:=nil;
                   try_consume_hintdirective(dummysymoptions,deprecatedmsg);
                   if assigned(sym) then
                     begin
                       sym.symoptions:=sym.symoptions+dummysymoptions;
                       sym.deprecatedmsg:=deprecatedmsg;
                       sym.visibility:=symtablestack.top.currentvisibility;
                       symtablestack.top.insertsym(sym);
                       sym.register_sym;
{$ifdef jvm}
                       { for the JVM target, some constants need to be
                         initialized at run time (enums, sets) -> create fake
                         typed const to do so (at least if they are visible
                         outside this routine, since we won't directly access
                         these symbols in the generated code) }
                       if (symtablestack.top.symtablelevel<normal_function_level) and
                          assigned(tconstsym(sym).constdef) and
                          (tconstsym(sym).constdef.typ in [enumdef,setdef]) then
                         jvm_add_typed_const_initializer(tconstsym(sym));
{$endif}
                     end
                   else
                     stringdispose(deprecatedmsg);
                   consume(_SEMICOLON);
                end;

             _COLON:
                begin
                   if not allow_typed_const then
                     begin
                       Message(parser_e_no_typed_const);
                       consume_all_until(_SEMICOLON);
                     end;
                   { set the blocktype first so a consume also supports a
                     caret, to support const s : ^string = nil }
                   block_type:=bt_const_type;
                   consume(_COLON);
                   read_anon_type(hdef,false,nil);
                   block_type:=bt_const;
                   if not (cs_typed_const_writable in current_settings.localswitches) then
                     begin
                       varspez:=vs_const;
                       asmtype:=al_rotypedconsts;
                     end
                   else
                     begin
                       varspez:=vs_value;
                       asmtype:=al_typedconsts;
                     end;
                   { create symbol(s) }
                   setlength(syms,namecount);
                   for ni:=0 to namecount-1 do
                     begin
                       storetokenpos:=current_tokenpos;
                       current_tokenpos:=positions[ni];
                       { if we are dealing with structure const then we need to handle it as a
                         structure static variable: create a symbol in unit symtable and a reference
                         to it from the structure or linking will fail }
                       if symtablestack.top.symtabletype in [recordsymtable,ObjectSymtable] then
                         begin
                           { note: we keep hdef so that we might at least read the
                                   constant data correctly for error recovery }
                           check_allowed_for_var_or_const(hdef,false);
                           syms[ni]:=cfieldvarsym.create(names[ni],varspez,hdef,[]);
                           symtablestack.top.insertsym(syms[ni]);
                           syms[ni]:=make_field_static(symtablestack.top,tfieldvarsym(syms[ni]));
                         end
                       else
                         begin
                           syms[ni]:=cstaticvarsym.create(names[ni],varspez,hdef,[]);
                           syms[ni].visibility:=symtablestack.top.currentvisibility;
                           symtablestack.top.insertsym(syms[ni]);
                         end;
                       syms[ni].register_sym;
                       current_tokenpos:=storetokenpos;
                     end;
                   sym:=syms[0];
                   skip_initialiser:=false;
                   { Anonymous proctype definitions can have proc directives }
                   if (
                         (hdef.typ=procvardef) or
                         is_funcref(hdef)
                       ) and
                       (hdef.typesym=nil) then
                    begin
                      { Either "procedure; stdcall" or "procedure stdcall" }
                      expect_directive:=try_to_consume(_SEMICOLON);
                      if check_proc_directive(true) then
                        parse_proctype_directives(hdef)
                      else if expect_directive then
                       begin
                         Message(parser_e_proc_directive_expected);
                         skip_initialiser:=true;
                       end;
                      { add default calling convention }
                      if hdef.typ=procvardef then
                        flags:=hcc_default_actions_intf
                      else
                        flags:=hcc_default_actions_intf_struct;
                      handle_calling_convention(hdef,flags);
                    end;
                   { Parse the initialiser }
                   if not skip_initialiser then
                    begin
                      consume(_EQ);
                      if namecount=1 then
                        begin
                          maybe_guarantee_record_typesym(tstaticvarsym(sym).vardef,tstaticvarsym(sym).vardef.owner);
                          read_typed_const(current_asmdata.asmlists[asmtype],tstaticvarsym(sym),in_structure);
                        end
                      else
                        begin
                          { record tokens for replay }
                          already_recording:=current_scanner.is_recording_tokens;
                          tokenbuf:=tdynamicarray.create(256);
                          if not already_recording then
                            current_scanner.startrecordtokens(tokenbuf);
                          maybe_guarantee_record_typesym(tstaticvarsym(sym).vardef,tstaticvarsym(sym).vardef.owner);
                          read_typed_const(current_asmdata.asmlists[asmtype],tstaticvarsym(sym),in_structure);
                          if not already_recording then
                            current_scanner.stoprecordtokens;
                          for ni:=1 to namecount-1 do
                            begin
                              maybe_guarantee_record_typesym(tstaticvarsym(syms[ni]).vardef,tstaticvarsym(syms[ni]).vardef.owner);
                              tokenbuf.seek(0);
                              current_scanner.startreplaytokens(tokenbuf,false);
                              read_typed_const(current_asmdata.asmlists[asmtype],tstaticvarsym(syms[ni]),in_structure);
                            end;
                          tokenbuf.free;
                        end;
                    end;
                end;

              else
                if not first and isgeneric and (current_scanner.token in [_PROCEDURE,_FUNCTION,_CLASS]) then
                  begin
                    had_generic:=true;
                    break;
                  end
                else
                  { generate an error }
                  consume(_EQ);
           end;

           first:=false;
         until (current_scanner.token<>_ID) or
               (in_structure and
                ((current_scanner.idtoken in [_PRIVATE,_PROTECTED,_PUBLIC,_PUBLISHED,_STRICT]) or
                 ((m_final_fields in current_settings.modeswitches) and
                  (current_scanner.idtoken=_FINAL))));
         block_type:=old_block_type;
      end;


    { static section: writeable typed-const-style declarations with optional
      initializer (zero-init when absent) and := type inference. Permitted
      only inside function/procedure bodies, where it gives a local-scoped
      variable with program lifetime, equivalent to C's static locals. }
    procedure static_dec(out had_generic:boolean);
      var
         orgname : TIDString;
         hdef : tdef;
         sym : tstaticvarsym;
         storetokenpos,filepos : tfileposinfo;
         old_block_type : tblock_type;
         old_writable : boolean;
         names : array of TIDString;
         positions : array of tfileposinfo;
         syms : array of tstaticvarsym;
         namecount,ni : longint;
         tokenbuf : tdynamicarray;
         already_recording : boolean;
         initexpr : tnode;
      begin
         had_generic:=false;
         { consume the soft 'static' keyword (lives in scanner as _ID + idtoken=_STATIC) }
         consume(_ID);
         { only meaningful in function/procedure bodies; not at unit/program top level }
         if (not assigned(current_procinfo)) or
            (current_procinfo.procdef.localst.symtablelevel<normal_function_level) then
           begin
             Comment(V_Error,'static is only allowed in function/procedure bodies');
             consume_all_until(_SEMICOLON);
             exit;
           end;
         old_block_type:=block_type;
         block_type:=bt_const;
         { force writeable typed-constants in this section, restore on exit }
         old_writable:=cs_typed_const_writable in current_settings.localswitches;
         include(current_settings.localswitches,cs_typed_const_writable);
         try
           repeat
             { collect one or more names separated by commas }
             namecount:=0;
             names:=nil;
             positions:=nil;
             repeat
               setlength(names,namecount+1);
               setlength(positions,namecount+1);
               names[namecount]:=current_scanner.orgpattern;
               positions[namecount]:=current_tokenpos;
               inc(namecount);
               consume(_ID);
             until not try_to_consume(_COMMA);
             orgname:=names[0];
             filepos:=positions[0];
             case current_scanner.token of
               _COLON:
                 begin
                   { name [, name2, ...] : Type [ = Value ] }
                   block_type:=bt_const_type;
                   consume(_COLON);
                   read_anon_type(hdef,false,nil);
                   block_type:=bt_const;
                   setlength(syms,namecount);
                   for ni:=0 to namecount-1 do
                     begin
                       storetokenpos:=current_tokenpos;
                       current_tokenpos:=positions[ni];
                       check_allowed_for_var_or_const(hdef,false);
                       syms[ni]:=cstaticvarsym.create(names[ni],vs_value,hdef,[]);
                       { data segment storage is zero-filled, so a read before
                         any write is not an uninitialized access }
                       syms[ni].varstate:=vs_initialised;
                       syms[ni].visibility:=symtablestack.top.currentvisibility;
                       symtablestack.top.insertsym(syms[ni]);
                       syms[ni].register_sym;
                       current_tokenpos:=storetokenpos;
                     end;
                   if try_to_consume(_EQ) then
                     begin
                       { explicit value via typed-const parser }
                       if namecount=1 then
                         begin
                           maybe_guarantee_record_typesym(syms[0].vardef,syms[0].vardef.owner);
                           read_typed_const(current_asmdata.asmlists[al_typedconsts],syms[0],false);
                         end
                       else
                         begin
                           already_recording:=current_scanner.is_recording_tokens;
                           tokenbuf:=tdynamicarray.create(256);
                           if not already_recording then
                             current_scanner.startrecordtokens(tokenbuf);
                           maybe_guarantee_record_typesym(syms[0].vardef,syms[0].vardef.owner);
                           read_typed_const(current_asmdata.asmlists[al_typedconsts],syms[0],false);
                           if not already_recording then
                             current_scanner.stoprecordtokens;
                           for ni:=1 to namecount-1 do
                             begin
                               maybe_guarantee_record_typesym(syms[ni].vardef,syms[ni].vardef.owner);
                               tokenbuf.seek(0);
                               current_scanner.startreplaytokens(tokenbuf,false);
                               read_typed_const(current_asmdata.asmlists[al_typedconsts],syms[ni],false);
                             end;
                           tokenbuf.free;
                         end;
                     end
                   else
                     begin
                       { no value -> BSS zero-init for each sym, RTL handles managed types }
                       for ni:=0 to namecount-1 do
                         cnodeutils.insertbssdata(syms[ni]);
                       consume(_SEMICOLON);
                     end;
                 end;

               _ASSIGNMENT:
                 begin
                   { name := Value with type inference (single name only) }
                   if namecount>1 then
                     Message(parser_e_initialized_only_one_var);
                   consume(_ASSIGNMENT);
                   { record tokens of the value expression, infer type via
                     speculative expr(), then replay through read_typed_const
                     to emit the initialized data segment entry }
                   already_recording:=current_scanner.is_recording_tokens;
                   tokenbuf:=tdynamicarray.create(256);
                   if not already_recording then
                     current_scanner.startrecordtokens(tokenbuf);
                   block_type:=old_block_type;
                   initexpr:=comp_expr([ef_accept_equal]);
                   if not already_recording then
                     current_scanner.stoprecordtokens;
                   block_type:=bt_const;
                   if (not assigned(initexpr.resultdef)) or (initexpr.resultdef=generrordef) then
                     begin
                       Comment(V_Error,'cannot infer type for static declaration');
                       initexpr.free;
                       tokenbuf.free;
                       consume(_SEMICOLON);
                       continue;
                     end;
                   hdef:=initexpr.resultdef;
                   { same inference rules as inline-var: char literal promotes to default
                     string type, sub-32-bit integers promote to LongInt }
                   if is_conststring_array(hdef) or
                      (not(nf_explicit in initexpr.flags) and (initexpr.nodetype=ordconstn) and is_char(hdef)) then
                     begin
                       if m_default_unicodestring in current_settings.modeswitches then
                         hdef:=cunicodestringtype
                       else if m_default_ansistring in current_settings.modeswitches then
                         hdef:=getansistringdef
                       else
                         hdef:=cshortstringtype;
                     end;
                   if not(nf_explicit in initexpr.flags) and is_integer(hdef) and
                      (torddef(hdef).ordtype in [s8bit,u8bit,s16bit,u16bit]) then
                     hdef:=s32inttype;
                   initexpr.free;
                   storetokenpos:=current_tokenpos;
                   current_tokenpos:=filepos;
                   sym:=cstaticvarsym.create(orgname,vs_value,hdef,[]);
                   sym.visibility:=symtablestack.top.currentvisibility;
                   symtablestack.top.insertsym(sym);
                   sym.register_sym;
                   current_tokenpos:=storetokenpos;
                   maybe_guarantee_record_typesym(sym.vardef,sym.vardef.owner);
                   { replay tokens through typed-const parser to materialize the
                     value in the data segment; parse_tail=false because we
                     consume the trailing semicolon ourselves below }
                   tokenbuf.seek(0);
                   current_scanner.startreplaytokens(tokenbuf,false);
                   read_typed_const(current_asmdata.asmlists[al_typedconsts],sym,false,false);
                   tokenbuf.free;
                   consume(_SEMICOLON);
                 end;

               else
                 begin
                   Message(parser_e_syntax_error);
                   consume_all_until(_SEMICOLON);
                   if current_scanner.token=_SEMICOLON then
                     consume(_SEMICOLON);
                 end;
             end;
           until current_scanner.token<>_ID;
         finally
           if not old_writable then
             exclude(current_settings.localswitches,cs_typed_const_writable);
           block_type:=old_block_type;
         end;
      end;


    procedure threadstatic_dec(out had_generic:boolean);
      var
         orgname : TIDString;
         hdef : tdef;
         sym : tstaticvarsym;
         old_block_type : tblock_type;
         names : array of TIDString;
         positions : array of tfileposinfo;
         syms : array of tstaticvarsym;
         namecount,ni : longint;
         initexpr : tnode;
         curstat : tstatementnode;

      { create a per-thread static var in the current localst (regular Pascal
        scoping) and register it on the module list so InsertThreadvars walks
        it into FPC_THREADVARTABLES - without that the BSS slot keeps a zero
        TLS handle and FPC_THREADVAR_RELOCATE returns garbage }
      function make_tsvar(const aname:TIDString;adef:tdef;const apos:tfileposinfo):tstaticvarsym;
        var
          storepos : tfileposinfo;
        begin
          storepos:=current_tokenpos;
          current_tokenpos:=apos;
          result:=cstaticvarsym.create(aname,vs_value,adef,[]);
          result.visibility:=symtablestack.top.currentvisibility;
          result.varstate:=vs_initialised;
          include(result.varoptions,vo_is_typed_const);
          include(result.varoptions,vo_is_thread_var);
          symtablestack.top.insertsym(result);
          if not assigned(current_module.extra_threadvar_syms) then
            current_module.extra_threadvar_syms:=tfplist.create;
          current_module.extra_threadvar_syms.add(result);
          result.register_sym;
          cnodeutils.insertbssdata(result);
          current_tokenpos:=storepos;
        end;

      { emit `if not guard then begin guard:=true; v:=ie end` and append it to
        the routine's threadstatic init code; the guard is itself a threadvar
        so each thread runs the init once on first entry }
      procedure emit_guarded_init(v:tstaticvarsym;ie:tnode);
        var
          gsym : tstaticvarsym;
          ib : tblocknode;
          ist : tstatementnode;
        begin
          gsym:=cstaticvarsym.create('$threadstatic_guard_'+v.realname,vs_value,pasbool8type,[]);
          include(gsym.symoptions,sp_internal);
          include(gsym.varoptions,vo_is_internal);
          include(gsym.varoptions,vo_is_typed_const);
          include(gsym.varoptions,vo_is_thread_var);
          symtablestack.top.insertsym(gsym);
          current_module.extra_threadvar_syms.add(gsym);
          gsym.register_sym;
          gsym.varstate:=vs_initialised;
          cnodeutils.insertbssdata(gsym);
          ib:=internalstatements(ist);
          addstatement(ist,cassignmentnode.create(
            cloadnode.create(gsym,gsym.owner),
            cordconstnode.create(1,pasbool8type,false)));
          addstatement(ist,cassignmentnode.create(
            cloadnode.create(v,v.owner),
            ie));
          if not assigned(current_procinfo.threadstatic_initcode) then
            current_procinfo.threadstatic_initcode:=internalstatements(curstat)
          else
            curstat:=laststatement(tblocknode(current_procinfo.threadstatic_initcode));
          addstatement(curstat,cifnode.create(
            cnotnode.create(cloadnode.create(gsym,gsym.owner)),
            ib,nil));
        end;

      begin
         had_generic:=false;
         { consume the soft 'threadstatic' keyword (scanner: _ID + idtoken=_THREADSTATIC) }
         consume(_ID);
         { per-thread storage only makes sense inside a routine body; at unit /
           program level a plain `threadvar` already gives the same lifetime }
         if (not assigned(current_procinfo)) or
            (current_procinfo.procdef.localst.symtablelevel<normal_function_level) then
           begin
             Comment(V_Error,'threadstatic is only allowed in function/procedure bodies');
             consume_all_until(_SEMICOLON);
             exit;
           end;
         old_block_type:=block_type;
         block_type:=bt_var;
         try
           repeat
             namecount:=0;
             names:=nil;
             positions:=nil;
             repeat
               setlength(names,namecount+1);
               setlength(positions,namecount+1);
               names[namecount]:=current_scanner.orgpattern;
               positions[namecount]:=current_tokenpos;
               inc(namecount);
               consume(_ID);
             until not try_to_consume(_COMMA);
             orgname:=names[0];
             case current_scanner.token of
               _COLON:
                 begin
                   { name [, name2, ...] : Type [ = Value ] }
                   block_type:=bt_var_type;
                   consume(_COLON);
                   read_anon_type(hdef,false,nil);
                   block_type:=bt_var;
                   setlength(syms,namecount);
                   for ni:=0 to namecount-1 do
                     begin
                       check_allowed_for_var_or_const(hdef,false);
                       syms[ni]:=make_tsvar(names[ni],hdef,positions[ni]);
                     end;
                   if try_to_consume(_EQ) then
                     begin
                       { runtime per-thread init for each name; no data-segment
                         fast path because TLS has no per-thread template }
                       block_type:=old_block_type;
                       initexpr:=comp_expr([ef_accept_equal]);
                       block_type:=bt_var;
                       if is_zerobytes_const(initexpr) then
                         { all-zero value already provided by per-thread BSS }
                         initexpr.free
                       else
                         for ni:=0 to namecount-1 do
                           if ni<namecount-1 then
                             emit_guarded_init(syms[ni],initexpr.getcopy)
                           else
                             emit_guarded_init(syms[ni],initexpr);
                     end;
                   { no value -> per-thread BSS zero-init handled by the RTL }
                   consume(_SEMICOLON);
                 end;

               _ASSIGNMENT:
                 begin
                   { name := Value with type inference (single name only) }
                   if namecount>1 then
                     Message(parser_e_initialized_only_one_var);
                   consume(_ASSIGNMENT);
                   block_type:=old_block_type;
                   initexpr:=comp_expr([ef_accept_equal]);
                   block_type:=bt_var;
                   if (not assigned(initexpr.resultdef)) or (initexpr.resultdef=generrordef) then
                     begin
                       Comment(V_Error,'cannot infer type for threadstatic declaration');
                       initexpr.free;
                       consume(_SEMICOLON);
                       continue;
                     end;
                   hdef:=initexpr.resultdef;
                   { same inference rules as inline var: char literal promotes to default
                     string type, sub-32-bit integers promote to LongInt }
                   if is_conststring_array(hdef) or
                      (not(nf_explicit in initexpr.flags) and (initexpr.nodetype=ordconstn) and is_char(hdef)) then
                     begin
                       if m_default_unicodestring in current_settings.modeswitches then
                         hdef:=cunicodestringtype
                       else if m_default_ansistring in current_settings.modeswitches then
                         hdef:=getansistringdef
                       else
                         hdef:=cshortstringtype;
                     end;
                   if not(nf_explicit in initexpr.flags) and is_integer(hdef) and
                      (torddef(hdef).ordtype in [s8bit,u8bit,s16bit,u16bit]) then
                     hdef:=s32inttype;
                   sym:=make_tsvar(orgname,hdef,positions[0]);
                   if is_zerobytes_const(initexpr) then
                     initexpr.free
                   else
                     emit_guarded_init(sym,initexpr);
                   consume(_SEMICOLON);
                 end;

               else
                 begin
                   Message(parser_e_syntax_error);
                   consume_all_until(_SEMICOLON);
                   if current_scanner.token=_SEMICOLON then
                     consume(_SEMICOLON);
                 end;
             end;
           until current_scanner.token<>_ID;
         finally
           block_type:=old_block_type;
         end;
      end;


    procedure label_dec;
      var
        labelsym : tlabelsym;
        sentinel : tlabelsym;
        labname  : TIDString;
        lo, hi, i : longint;
        strval   : ansistring;
        p        : tnode;
        lv, hv   : TConstExprInt;
        elemcount : longint;
        singleval : boolean;
        sv       : longint;

      function const_to_longint(const v: TConstExprInt; out i: longint): boolean;
        begin
          if (v<low(longint)) or (v>high(longint)) then
            begin
              Message(parser_e_array_range_out_of_bounds);
              result:=false;
            end
          else
            begin
              i:=longint(int64(v));
              result:=true;
            end;
        end;

      function set_bounds_from_type(def: tdef; out l, h: longint): boolean;
        begin
          if not is_ordinal(def) then
            begin
              Message(type_e_ordinal_expr_expected);
              result:=false;
              exit;
            end;
          getrange(def,lv,hv);
          result:=const_to_longint(lv,l) and const_to_longint(hv,h);
        end;

      function get_const_ord_value(n: tnode; out v: TConstExprInt): boolean;
        begin
          if not is_constnode(n) then
            begin
              Message(type_e_constant_expr_expected);
              result:=false;
              exit;
            end;
          if n.nodetype<>ordconstn then
            begin
              Message(type_e_ordinal_expr_expected);
              result:=false;
              exit;
            end;
          v:=tordconstnode(n).value;
          result:=true;
        end;

      { Create and insert a single label symbol with name n. }
      procedure insert_one_label(const n: TIDString; member: boolean=false);
        begin
          labelsym:=clabelsym.create(n);
          labelsym.arraylabel_member:=member;
          symtablestack.top.insertsym(labelsym);
          if m_non_local_goto in current_settings.modeswitches then
            begin
              if symtablestack.top.symtabletype=localsymtable then
                begin
                  labelsym.jumpbuf:=clocalvarsym.create('LABEL$_'+labelsym.name,vs_value,rec_jmp_buf,[]);
                  symtablestack.top.insertsym(labelsym.jumpbuf);
                end
              else
                begin
                  labelsym.jumpbuf:=cstaticvarsym.create('LABEL$_'+labelsym.name,vs_value,rec_jmp_buf,[]);
                  symtablestack.top.insertsym(labelsym.jumpbuf);
                  cnodeutils.insertbssdata(tstaticvarsym(labelsym.jumpbuf));
                end;
              include(labelsym.jumpbuf.symoptions,sp_internal);
              { the buffer will be setup later, but avoid a hint }
              tabstractvarsym(labelsym.jumpbuf).varstate:=vs_written;
            end;
        end;

      begin
         consume(_LABEL);
         if not(cs_support_goto in current_settings.moduleswitches) then
           Message(sym_e_goto_and_label_not_supported);
         repeat
           if not(current_scanner.token in [_ID,_INTCONST]) then
             consume(_ID)
           else
             begin
                if current_scanner.token=_ID then
                  labname:=current_scanner.orgpattern
                else
                  begin
                    { strip leading 0's in iso mode }
                    if (([m_iso,m_extpas]*current_settings.modeswitches)<>[]) then
                      while (length(current_scanner.pattern)>1) and (current_scanner.pattern[1]='0') do
                        delete(current_scanner.pattern,1,1);
                    labname:=current_scanner.pattern;
                  end;
                consume(current_scanner.token);

                { Array label syntax: label name[1..N] or name['s1','s2'] }
                if (cs_support_goto in current_settings.moduleswitches) and
                   (current_scanner.token=_LECKKLAMMER) then
                  begin
                    consume(_LECKKLAMMER);
                    { Insert sentinel so that "goto name[i]" can find the base name }
                    labelsym:=clabelsym.create(labname);
                    labelsym.arraylabel:=true;
                    sentinel:=labelsym;  { save before insert_one_label overwrites labelsym }
                    symtablestack.top.insertsym(labelsym);

                    if current_scanner.token=_CSTRING then
                      begin
                        { String list: ['str1', 'str2', ...] }
                        repeat
                          strval:=upper(current_scanner.cstringpattern);
                          consume(_CSTRING);
                          insert_one_label(labname+'$'+strval,true);
                          { store string index on sentinel for variable goto }
                          i:=length(sentinel.arraylabel_strings);
                          setlength(sentinel.arraylabel_strings,i+1);
                          sentinel.arraylabel_strings[i]:=strval;
                          if current_scanner.token=_COMMA then
                            consume(_COMMA)
                          else
                            break;
                        until false;
                      end
                    else
                      begin
                        { Ordinal type or constant expression list/ranges:
                            [byte]
                            [0..3-1]
                            [a..b]
                            [1,2,3]
                        }
                        sentinel.arraylabel_lo:=high(longint);
                        sentinel.arraylabel_hi:=low(longint);
                        elemcount:=0;
                        singleval:=false;
                        sv:=0;
                        repeat
                          inc(elemcount);
                          p:=expr(true);
                          { ensure constant expressions like 3-1 in ranges are folded }
                          if (p.nodetype=rangen) and not assigned(p.resultdef) then
                            do_typecheckpass(p);
                          if p.nodetype=typen then
                            begin
                              if set_bounds_from_type(p.resultdef,lo,hi) then
                                begin
                                  for i:=lo to hi do
                                    insert_one_label(labname+'$'+tostr(i),true);
                                  sentinel.arraylabel_lo:=lo;
                                  sentinel.arraylabel_hi:=hi;
                                end;
                              p.free;
                              p:=nil;
                              if current_scanner.token=_COMMA then
                                Message(sym_e_ill_label_decl);
                              break;
                            end
                          else if p.nodetype=rangen then
                            begin
                              if get_const_ord_value(trangenode(p).left,lv) and
                                 get_const_ord_value(trangenode(p).right,hv) and
                                 const_to_longint(lv,lo) and
                                 const_to_longint(hv,hi) then
                                begin
                                  if lo>hi then
                                    Message(parser_e_array_lower_less_than_upper_bound)
                                  else
                                    for i:=lo to hi do
                                      insert_one_label(labname+'$'+tostr(i),true);
                                  if lo<sentinel.arraylabel_lo then
                                    sentinel.arraylabel_lo:=lo;
                                  if hi>sentinel.arraylabel_hi then
                                    sentinel.arraylabel_hi:=hi;
                                end;
                            end
                          else
                            begin
                              if get_const_ord_value(p,lv) and
                                 const_to_longint(lv,lo) then
                                begin
                                  insert_one_label(labname+'$'+tostr(lo),true);
                                  if lo<sentinel.arraylabel_lo then
                                    sentinel.arraylabel_lo:=lo;
                                  if lo>sentinel.arraylabel_hi then
                                    sentinel.arraylabel_hi:=lo;
                                  singleval:=true;
                                  sv:=lo;
                                end;
                            end;
                          p.free;
                          p:=nil;
                          if current_scanner.token=_COMMA then
                            consume(_COMMA)
                          else
                            break;
                        until false;
                        { a lone bare value is rejected: next to array[N] it reads
                          as a count, but here it would mean a single index }
                        if (elemcount=1) and singleval then
                          Message1(sym_e_label_index_single_value,tostr(sv));
                        if sentinel.arraylabel_lo>sentinel.arraylabel_hi then
                          begin
                            sentinel.arraylabel_lo:=0;
                            sentinel.arraylabel_hi:=0;
                          end;
                      end;
                    consume(_RECKKLAMMER);
                  end
                else
                  { Normal single label }
                  insert_one_label(labname);
             end;
           if current_scanner.token<>_SEMICOLON then consume(_COMMA);
         until not(current_scanner.token in [_ID,_INTCONST]);
         consume(_SEMICOLON);
      end;

    function find_create_constructor(objdef:tobjectdef):tsymentry;
      begin
         while assigned(objdef) do
           begin
             result:=objdef.symtable.Find('CREATE');
             if assigned(result) then
               exit;
             objdef:=objdef.childof;
           end;
         // A class without a constructor called 'create'?!?
         internalerror(2012111101);
      end;

    procedure parse_rttiattributes(var rtti_attrs_def:trtti_attribute_list);

      function read_attr_paras:tnode;
        var
          old_block_type : tblock_type;
        begin
          if try_to_consume(_LKLAMMER) then
            begin
              { we only want constants here }
              old_block_type:=block_type;
              block_type:=bt_const;
              result:=parse_paras(false,false,_RKLAMMER);
              block_type:=old_block_type;
              consume(_RKLAMMER);
            end
          else
            result:=nil;
        end;

      var
        p,paran,pcalln,ptmp : tnode;
        ecnt : longint;
        i,pcount : sizeint;
        paras : array of tnode;
        od : tobjectdef;
        constrsym : tsymentry;
        typesym : ttypesym;
        parasok : boolean;
      begin
        consume(_LECKKLAMMER);

        repeat
          { Parse attribute type }
          p:=factor(false,[ef_type_only,ef_check_attr_suffix]);
          if p.nodetype=typen then
            begin
              typesym:=ttypesym(ttypenode(p).typesym);
              od:=tobjectdef(ttypenode(p).typedef);

              { Check if the attribute class is related to TCustomAttribute }
              if not is_system_custom_attribute_descendant(od) then
                begin
                  incompatibletypes(od,class_tcustomattribute);
                  read_attr_paras.free; // no nil needed
                  continue;
                end;

              paran:=read_attr_paras;

              { Search the tprocdef of the constructor which has to be called. }
              constrsym:=find_create_constructor(od);
              if constrsym.typ<>procsym then
                internalerror(2018102301);

              pcalln:=ccallnode.create(paran,tprocsym(constrsym),od.symtable,cloadvmtaddrnode.create(p),[cnf_no_convert_procvar],nil);
              p:=nil;
              ecnt:=errorcount;
              typecheckpass(pcalln);

              if (pcalln.nodetype=calln) and assigned(tcallnode(pcalln).procdefinition) and not codegenerror then
                begin
                  { TODO: once extended RTTI for methods is supported, reject a
                          constructor if it doesn't have extended RTTI enabled }

                  { collect the parameters of the call node as there might be
                    compile time type conversions (e.g. a Byte parameter being
                    passed a value > 255) }
                  paran:=tcallnode(pcalln).left;

                  { only count visible parameters (thankfully open arrays are not
                    supported, otherwise we'd need to handle those as well) }
                  parasok:=true;
                  paras:=nil;
                  if assigned(paran) then
                    begin
                      ptmp:=paran;
                      pcount:=0;
                      while assigned(ptmp) do
                        begin
                          if not (vo_is_hidden_para in tcallparanode(ptmp).parasym.varoptions) then
                            inc(pcount);
                          ptmp:=tcallparanode(ptmp).right;
                        end;
                      setlength(paras,pcount);
                      ptmp:=paran;
                      pcount:=0;
                      while assigned(ptmp) do
                        begin
                          if not (vo_is_hidden_para in tcallparanode(ptmp).parasym.varoptions) then
                            begin
                              if not is_constnode(tcallparanode(ptmp).left) then
                                begin
                                  parasok:=false;
                                  messagepos(tcallparanode(ptmp).left.fileinfo,type_e_constant_expr_expected);
                                end;
                              paras[high(paras)-pcount]:=tcallparanode(ptmp).left.getcopy;
                              inc(pcount);
                            end;
                          ptmp:=tcallparanode(ptmp).right;
                        end;
                    end;

                  if parasok then
                    begin
                      { Add attribute to attribute list which will be added
                        to the property which is defined next. }
                      if not assigned(rtti_attrs_def) then
                        rtti_attrs_def:=trtti_attribute_list.create;
                      rtti_attrs_def.addattribute(typesym,tcallnode(pcalln).procdefinition,pcalln,paras);
                    end
                  else
                    begin
                      { cleanup }
                      pcalln.free;
                      pcalln := nil;
                      for i:=0 to high(paras) do
                        FreeAndNil(paras[i]);
                    end;
                end
              else begin
                { provide *some* error in case there hasn't been one }
                if errorcount=ecnt then
                  message(parser_e_illegal_expression);
                pcalln.free;
                pcalln := nil;
              end;
            end
          else
            begin
              Message(type_e_type_id_expected);
              { try to recover by nevertheless reading the parameters (if any) }
              read_attr_paras.free; // no nil needed
            end;

          p.free;
          p := nil;
        until not try_to_consume(_COMMA);

        consume(_RECKKLAMMER);
      end;


    function parse_forward_declaration(sym:tsym;gentypename,genorgtypename:tidstring;genericdef:tdef;generictypelist:tfphashobjectlist;out newtype:ttypesym):tdef;
      var
        wasforward : boolean;
        objecttype : tobjecttyp;
        gendef : tstoreddef;
      begin
        newtype:=nil;
        wasforward:=false;
        if ((current_scanner.token=_CLASS) or
            (current_scanner.token=_INTERFACE) or
            (current_scanner.token=_DISPINTERFACE) or
            (current_scanner.token=_OBJCCLASS) or
            (current_scanner.token=_OBJCPROTOCOL) or
            (current_scanner.token=_OBJCCATEGORY)) and
           (assigned(ttypesym(sym).typedef)) and
           is_implicit_pointer_object_type(ttypesym(sym).typedef) and
           (oo_is_forward in tobjectdef(ttypesym(sym).typedef).objectoptions) then
         begin
           wasforward:=true;
           objecttype:=odt_none;
           case current_scanner.token of
             _CLASS :
               objecttype:=default_class_type;
             _INTERFACE :
               case current_settings.interfacetype of
                 it_interfacecom:
                   objecttype:=odt_interfacecom;
                 it_interfacecorba:
                   objecttype:=odt_interfacecorba;
                 it_interfacejava:
                   objecttype:=odt_interfacejava;
               end;
             _DISPINTERFACE :
               objecttype:=odt_dispinterface;
             _OBJCCLASS,
             _OBJCCATEGORY :
               objecttype:=odt_objcclass;
             _OBJCPROTOCOL :
               objecttype:=odt_objcprotocol;
             else
               internalerror(200811072);
           end;
           consume(current_scanner.token);
           if assigned(genericdef) then
             gendef:=tstoreddef(genericdef)
           else
             { determine the generic def in case we are in a nested type
               of a specialization }
             gendef:=determine_generic_def(gentypename);
           { we can ignore the result, the definition is modified }
           object_dec(objecttype,genorgtypename,newtype,gendef,generictypelist,tobjectdef(ttypesym(sym).typedef),ht_none);
           if wasforward and
             (tobjectdef(ttypesym(sym).typedef).objecttype<>objecttype) then
             Message1(type_e_forward_interface_type_does_not_match,tobjectdef(ttypesym(sym).typedef).GetTypeName);
           newtype:=ttypesym(sym);
           result:=newtype.typedef;
         end
        else
          begin
            message1(parser_h_type_redef,genorgtypename);
            result:=generrordef;
          end;
      end;

    { From http://clang.llvm.org/docs/LanguageExtensions.html#objective-c-features :
      To determine whether a method has an inferred related result type, the first word in the camel-case selector
      (e.g., “init” in “initWithObjects”) is considered, and the method will have a related result type if its return
      type is compatible with the type of its class and if:
        * the first word is "alloc" or "new", and the method is a class method, or
        * the first word is "autorelease", "init", "retain", or "self", and the method is an instance method.

      If a method with a related result type is overridden by a subclass method, the subclass method must also return
      a type that is compatible with the subclass type.
    }
    procedure pd_set_objc_related_result(def: tobject; para: pointer);
      var
        pd: tprocdef;
        i, firstcamelend: longint;
        inferresult: boolean;
      begin
        if tdef(def).typ<>procdef then
          exit;
        pd:=tprocdef(def);
        if not(po_msgstr in pd.procoptions) then
          internalerror(2019082401);
        firstcamelend:=length(pd.messageinf.str^);
        for i:=1 to length(pd.messageinf.str^) do
          if pd.messageinf.str^[i] in ['A'..'Z'] then
            begin
              firstcamelend:=pred(i);
              break;
            end;
        case copy(pd.messageinf.str^,1,firstcamelend) of
          'alloc',
          'new':
             inferresult:=po_classmethod in pd.procoptions;
          'autorelease',
          'init',
          'retain',
          'self':
             inferresult:=not(po_classmethod in pd.procoptions);
          else
            inferresult:=false;
        end;
        if inferresult and
           def_is_related(tdef(pd.procsym.owner.defowner),pd.returndef) then
          include(pd.procoptions,po_objc_related_result_type);
      end;

    procedure types_dec(in_structure: boolean;out had_generic:boolean;var rtti_attrs_def: trtti_attribute_list);

      procedure finalize_class_external_status(od: tobjectdef);
        begin
          if  [oo_is_external,oo_is_forward] <= od.objectoptions then
            begin
              { formal definition: x = objcclass external; }
              exclude(od.objectoptions,oo_is_forward);
              include(od.objectoptions,oo_is_formal);
            end;
        end;

      var
         typename,orgtypename,
         gentypename,genorgtypename : TIDString;
         newtype  : ttypesym;
         dummysym,
         sym      : tsym;
         hdef,
         hdef2    : tdef;
         defpos,storetokenpos : tfileposinfo;
         old_block_type : tblock_type;
         old_checkforwarddefs: TFPObjectList;
         flags : thccflags;
         setdummysym,
         first,
         isgeneric,
         isunique,
         istyperenaming,
         expose_this : boolean;
         generictypelist : tfphashobjectlist;
         localgenerictokenbuf : tdynamicarray;
         p:tnode;
         gendef : tstoreddef;
         s : shortstring;
         i : longint;
{$ifdef x86}
         segment_register: string;
{$endif x86}
      begin
         old_block_type:=block_type;
         { save unit container of forward declarations -
           we can be inside nested class type block }
         old_checkforwarddefs:=current_module.checkforwarddefs;
         current_module.checkforwarddefs:=TFPObjectList.Create(false);
         block_type:=bt_type;
         hdef:=nil;
         first:=true;
         had_generic:=false;
         storetokenpos:=Default(tfileposinfo);
         repeat
           defpos:=current_tokenpos;
           istyperenaming:=false;
           setdummysym:=false;
           expose_this:=false;
           generictypelist:=nil;
           localgenerictokenbuf:=nil;

           { class attribute definitions? }
           if m_prefixed_attributes in current_settings.modeswitches then
             while current_scanner.token=_LECKKLAMMER do
               parse_rttiattributes(rtti_attrs_def);

           { fpc generic declaration? }
           if first then
             had_generic:=not(m_implicit_generics in current_settings.modeswitches) and try_to_consume(_GENERIC);
           isgeneric:=had_generic;

           typename:=current_scanner.pattern;
           orgtypename:=current_scanner.orgpattern;
           consume(_ID);

           { unleashed: `expose <typename> = ...` whitelists the type from
             m_strip_rtti. `expose` stays a regular identifier so `var expose:
             integer;` keeps compiling; only when we read it before another
             identifier in a type block do we treat it as a prefix }
           if (m_unleashed in current_settings.modeswitches) and
              (typename='EXPOSE') and (current_scanner.token=_ID) then
             begin
               expose_this:=true;
               typename:=current_scanner.pattern;
               orgtypename:=current_scanner.orgpattern;
               consume(_ID);
             end;

           { delphi generic declaration? }
           if (m_implicit_generics in current_settings.modeswitches) then
             isgeneric:=current_scanner.token=_LSHARPBRACKET;

           { Generic type declaration? }
           if isgeneric then
             begin
               { unleashed allows nested generic declarations (generic method
                 inside a generic class, generic type inside a generic body) }
               if assigned(current_genericdef) and
                  not (m_unleashed in current_settings.modeswitches) then
                 Message(parser_f_no_generic_inside_generic);

               consume(_LSHARPBRACKET);
               generictypelist:=parse_generic_parameters(true);
               consume(_RSHARPBRACKET);

               str(generictypelist.Count,s);
               gentypename:=typename+'$'+s;
               genorgtypename:=orgtypename+'$'+s;
             end
           else
             begin
               gentypename:=typename;
               genorgtypename:=orgtypename;
             end;

           consume(_EQ);

           { support 'ttype=type word' syntax }
           isunique:=try_to_consume(_TYPE);

           { MacPas object model is more like Delphi's than like TP's, but }
           { uses the object keyword instead of class                      }
           if (m_mac in current_settings.modeswitches) and
              (current_scanner.token = _OBJECT) then
             current_scanner.token := _CLASS;

           { Start recording a generic template }
           if assigned(generictypelist) then
             begin
               localgenerictokenbuf:=tdynamicarray.create(256);
               current_scanner.startrecordtokens(localgenerictokenbuf);
             end;

           { is the type already defined? -- must be in the current symtable,
             not in a nested symtable or one higher up the stack -> don't
             use searchsym & friends! }
           sym:=tsym(symtablestack.top.find(gentypename));
           newtype:=nil;
           { found a symbol with this name? }
           if assigned(sym) then
            begin
              if (sym.typ=typesym) and
                 { this should not be a symbol that was created by a generic
                   that was declared earlier }
                 not (
                   (ttypesym(sym).typedef.typ=undefineddef) and
                   (sp_generic_dummy in sym.symoptions)
                 ) then
               begin
                 hdef:=parse_forward_declaration(sym,gentypename,genorgtypename,nil,generictypelist,newtype);
               end;
            end;
           { no old type reused ? Then insert this new type }
           if not assigned(newtype) then
            begin
              if isgeneric then
                begin
                  { we are not freeing the type parameters, so register them }
                  for i:=0 to generictypelist.count-1 do
                    begin
                       tstoredsym(generictypelist[i]).register_sym;
                       if tstoredsym(generictypelist[i]).typ=typesym then
                         tstoreddef(ttypesym(generictypelist[i]).typedef).register_def;
                    end;
                end;

              { insert the new type first with an errordef, so that
                referencing the type before it's really set it
                will give an error (PFV) }
              hdef:=generrordef;
              gendef:=nil;
              storetokenpos:=current_tokenpos;
              if isgeneric then
                begin
                  { for generics we need to check whether a non-generic type
                    already exists and if not we need to insert a symbol with
                    the non-generic name (available in (org)typename) that is a
                    undefineddef, so that inline specializations can be used }
                  sym:=tsym(symtablestack.top.Find(typename));
                  if not assigned(sym) then
                    begin
                      sym:=ctypesym.create(orgtypename,cundefineddef.create(true));
                      Include(sym.symoptions,sp_generic_dummy);
                      ttypesym(sym).typedef.typesym:=sym;
                      sym.visibility:=symtablestack.top.currentvisibility;
                      { add as dummy symbol before adding it to the symtable stack }
                      add_generic_dummysym(sym,typename);
                      symtablestack.top.insertsym(sym);
                      ttypesym(sym).typedef.owner:=sym.owner;
                    end
                  else
                    { this is not allowed in non-Delphi modes }
                    if not (m_implicit_generics in current_settings.modeswitches) then
                      Message1(sym_e_duplicate_id,genorgtypename)
                    else
                      begin
                        { we need to find this symbol even if it's a variable or
                          something else when doing an inline specialization }
                        Include(sym.symoptions,sp_generic_dummy);
                        add_generic_dummysym(sym,'');
                      end;
                end
              else
                begin
                  if assigned(sym) and (sym.typ=typesym) and
                      (ttypesym(sym).typedef.typ=undefineddef) and
                      (sp_generic_dummy in sym.symoptions) then
                    begin
                      { this is a symbol that was added by an earlier generic
                        declaration, reuse it }
                      newtype:=ttypesym(sym);
                      newtype.typedef:=hdef;
                      { use the correct casing }
                      newtype.RealName:=genorgtypename;
                      sym:=nil;
                    end;

                  { determine the generic def in case we are in a nested type
                    of a specialization }
                  gendef:=determine_generic_def(gentypename);
                end;
              { insert a new type if we don't reuse an existing symbol }
              if not assigned(newtype) then
                begin
                  newtype:=ctypesym.create(genorgtypename,hdef);
                  newtype.visibility:=symtablestack.top.currentvisibility;
                  symtablestack.top.insertsym(newtype);
                end;
              current_tokenpos:=defpos;
              current_tokenpos:=storetokenpos;
              { read the type definition }
              read_named_type(hdef,newtype,gendef,generictypelist,false,isunique);
              { update the definition of the type }
              if assigned(hdef) then
                begin
                  if assigned(hdef.typesym) then
                    begin
                      istyperenaming:=true;
                      include(newtype.symoptions,sp_explicitrename);
                    end;
                  if isunique then
                    begin
                      if is_objc_class_or_protocol(hdef) or
                         is_java_class_or_interface(hdef) then
                        Message(parser_e_unique_unsupported);

                      if is_object(hdef) or
                         is_class_or_interface_or_dispinterface(hdef) then
                        begin
                          { just create a copy that is a child of the original class class type; this is
                            Delphi-compatible }
                          hdef2:=tstoreddef(hdef).getcopy;
                          tobjectdef(hdef2).childof:=tobjectdef(hdef);
                          tstoreddef(hdef2).orgdef:=tstoreddef(hdef);
                          hdef:=hdef2;
                        end
                      else
                        begin
                          hdef2:=tstoreddef(hdef).getcopy;
                          tstoreddef(hdef2).orgdef:=tstoreddef(hdef);
                          hdef:=hdef2;
                          { check if it is an ansistring(codepage) declaration }
                          if is_ansistring(hdef) and try_to_consume(_LKLAMMER) then
                            begin
                              p:=comp_expr([ef_accept_equal]);
                              consume(_RKLAMMER);
                              if not is_constintnode(p) then
                                begin
                                  Message(parser_e_illegal_expression);
                                  { error recovery }
                                end
                              else
                                begin
                                  if (tordconstnode(p).value<0) or (tordconstnode(p).value>65535) then
                                    begin
                                      Message(parser_e_invalid_codepage);
                                      tordconstnode(p).value:=0;
                                    end;
                                  tstringdef(hdef).encoding:=int64(tordconstnode(p).value);
                                end;
                              p.free;
                              p := nil;
                            end;
                          if (hdef.typ in [pointerdef,classrefdef]) and
                             (tabstractpointerdef(hdef).pointeddef.typ=forwarddef) then
                            current_module.checkforwarddefs.add(hdef);
                        end;

                      include(hdef.defoptions,df_unique);

                      { update object's real name for better error messages }
                      if hdef is tabstractrecorddef then
                        tabstractrecorddef(hdef).setobjrealname(newtype.RealName);
                    end;
                  if not assigned(hdef.typesym) then
                    begin
                      hdef.typesym:=newtype;
                      if sp_generic_dummy in newtype.symoptions then
                        add_generic_dummysym(newtype,'');
                    end;
                end;
              { in non-Delphi modes we need a reference to the generic def
                without the generic suffix, so it can be found easily when
                parsing method implementations }
              if isgeneric and assigned(sym) and
                  not (m_implicit_generics in current_settings.modeswitches) and
                  (ttypesym(sym).typedef.typ=undefineddef) then
                begin
                  { don't free the undefineddef as the defids rely on the count
                    of the defs in the def list of the module}
                  ttypesym(sym).typedef:=hdef;
                  setdummysym:=true;
                end;
              newtype.typedef:=hdef;
              { ensure that the type is registered when no specialization is
                currently done }
              if (current_scanner.replay_stack_depth=0) and
                  (
                    (hdef.typ<>procvardef) or
                    not (po_is_function_ref in tabstractprocdef(hdef).procoptions)
                  ) then
                hdef.register_def;
              { KAZ: handle TGUID declaration in system unit }
              if (cs_compilesystem in current_settings.moduleswitches) and
                 assigned(hdef) and
                 (hdef.typ=recorddef) then
                begin
                  if not assigned(rec_tguid) and
                     (gentypename='TGUID') and
                     (hdef.size=16) then
                    rec_tguid:=trecorddef(hdef)
                  else if not assigned(rec_jmp_buf) and
                     (gentypename='JMP_BUF') then
                    rec_jmp_buf:=trecorddef(hdef)
                  else if not assigned(rec_exceptaddr) and
                     (gentypename='TEXCEPTADDR') then
                    rec_exceptaddr:=trecorddef(hdef);
                end;
            end;
           if assigned(hdef) then
            begin
              case hdef.typ of
                pointerdef :
                  begin
                    try_consume_hintdirective(newtype.symoptions,newtype.deprecatedmsg);
                    consume(_SEMICOLON);
{$ifdef x86}
  {$ifdef i8086}
                    if try_to_consume(_HUGE) then
                     begin
                       tcpupointerdef(hdef).x86pointertyp:=x86pt_huge;
                       consume(_SEMICOLON);
                     end
                    else
  {$endif i8086}
                    if try_to_consume(_FAR) then
                     begin
  {$if defined(i8086)}
                       tcpupointerdef(hdef).x86pointertyp:=x86pt_far;
  {$elseif defined(i386)}
                       tcpupointerdef(hdef).x86pointertyp:=x86pt_near_fs;
  {$elseif defined(x86_64)}
                       { for compatibility with previous versions of fpc,
                         far pointer = regular pointer on x86_64 }
                       Message1(parser_w_ptr_type_ignored,'FAR');
  {$endif}
                       consume(_SEMICOLON);
                     end
                    else
                      if try_to_consume(_NEAR) then
                       begin
                         if current_scanner.token <> _SEMICOLON then
                           begin
                             segment_register:=get_stringconst;
                             case UpCase(segment_register) of
                               'CS': tcpupointerdef(hdef).x86pointertyp:=x86pt_near_cs;
                               'DS': tcpupointerdef(hdef).x86pointertyp:=x86pt_near_ds;
                               'SS': tcpupointerdef(hdef).x86pointertyp:=x86pt_near_ss;
                               'ES': tcpupointerdef(hdef).x86pointertyp:=x86pt_near_es;
                               'FS': tcpupointerdef(hdef).x86pointertyp:=x86pt_near_fs;
                               'GS': tcpupointerdef(hdef).x86pointertyp:=x86pt_near_gs;
                               else
                                 Message(asmr_e_invalid_register);
                             end;
                           end
                         else
                           tcpupointerdef(hdef).x86pointertyp:=x86pt_near;
                         consume(_SEMICOLON);
                       end;
{$else x86}
                    { Previous versions of FPC support declaring a pointer as
                      far even on non-x86 platforms. }
                    if try_to_consume(_FAR) then
                     begin
                       Message1(parser_w_ptr_type_ignored,'FAR');
                       consume(_SEMICOLON);
                     end;
{$endif x86}
                  end;
                procvardef :
                  begin
                    { in case of type renaming, don't parse proc directives }
                    if istyperenaming then
                      begin
                        try_consume_hintdirective(newtype.symoptions,newtype.deprecatedmsg);
                        consume(_SEMICOLON);
                      end
                    else
                     begin
                       if not check_proc_directive(true) then
                         begin
                           try_consume_hintdirective(newtype.symoptions,newtype.deprecatedmsg);
                           consume(_SEMICOLON);
                         end;
                       parse_proctype_directives(tprocvardef(hdef));
                       if po_is_function_ref in tprocvardef(hdef).procoptions then
                         begin
                           if not (m_function_references in current_settings.modeswitches) and
                               not (po_is_block in tprocvardef(hdef).procoptions) then
                             messagepos(storetokenpos,sym_e_error_in_type_def)
                           else
                             begin
                               if setdummysym then
                                 dummysym:=sym
                               else
                                 dummysym:=nil;
                               adjust_funcref(hdef,newtype,dummysym);
                             end;
                           if current_scanner.replay_stack_depth=0 then
                             hdef.register_def;
                         end;
                       if hdef.typ=procvardef then
                         flags:=hcc_default_actions_intf
                       else
                         flags:=hcc_default_actions_intf_struct;
                       handle_calling_convention(hdef,flags);
                       if (hdef.typ=procvardef) and (po_is_function_ref in tprocvardef(hdef).procoptions) then
                         begin
                           if (po_is_block in tprocvardef(hdef).procoptions) and
                              not (tprocvardef(hdef).proccalloption in [pocall_cdecl,pocall_mwpascal]) then
                             message(type_e_cblock_callconv);
                         end;
                       if try_consume_hintdirective(newtype.symoptions,newtype.deprecatedmsg) then
                         consume(_SEMICOLON);
                     end;
                  end;
                objectdef :
                  begin
                    if is_funcref(hdef) then
                      begin
                        if not check_proc_directive(true) then
                          begin
                            try_consume_hintdirective(newtype.symoptions,newtype.deprecatedmsg);
                            consume(_SEMICOLON);
                          end;
                        parse_proctype_directives(hdef);
                        if try_consume_hintdirective(newtype.symoptions,newtype.deprecatedmsg) then
                          consume(_SEMICOLON);
                      end
                    else
                      begin
                        try_consume_hintdirective(newtype.symoptions,newtype.deprecatedmsg);
                        consume(_SEMICOLON);
                      end;

                    { change a forward and external class declaration into
                      formal external definition, so the compiler does not
                      expect an real definition later }
                    if is_objc_class_or_protocol(hdef) or
                       is_java_class_or_interface(hdef) then
                      finalize_class_external_status(tobjectdef(hdef));

                    { Build VMT indexes, skip for type renaming and forward classes }
                    if not istyperenaming and
                       not(oo_is_forward in tobjectdef(hdef).objectoptions) then
                      if not (oo_inherits_not_specialized in tobjectdef(hdef).objectoptions) then
                        build_vmt(tobjectdef(hdef))
                      else
                      { update the procdevs to add hidden self param }
                      insert_struct_hidden_paras(tobjectdef(hdef));

                    { In case of an objcclass, verify that all methods have a message
                      name set. We only check this now, because message names can be set
                      during the protocol (interface) mapping. At the same time, set the
                      mangled names (these depend on the "external" name of the class),
                      and mark private fields of external classes as "used" (to avoid
                      bogus notes about them being unused)
                    }
                    { watch out for crashes in case of errors }
                    if is_objc_class_or_protocol(hdef) and
                       (not is_objccategory(hdef) or
                        assigned(tobjectdef(hdef).childof)) then
                      begin
                        tobjectdef(hdef).finish_objc_data;
                        tobjectdef(hdef).symtable.DefList.ForEachCall(@pd_set_objc_related_result,nil);
                      end;

                    if is_cppclass(hdef) then
                      tobjectdef(hdef).finish_cpp_data;
                  end;
                recorddef :
                  begin
                    try_consume_hintdirective(newtype.symoptions,newtype.deprecatedmsg);
                    consume(_SEMICOLON);
                  end;
                else
                  begin
                    try_consume_hintdirective(newtype.symoptions,newtype.deprecatedmsg);
                    consume(_SEMICOLON);
                  end;
              end;

              { if we have a real type definition or a unique type we may bind
                attributes to this def }
              if not istyperenaming or isunique then
                trtti_attribute_list.bind(rtti_attrs_def,tstoreddef(hdef).rtti_attribute_list);

              if df_generic in hdef.defoptions then
                { flag parent symtables that they now contain a generic }
                hdef.owner.includeoption(sto_has_generic);
            end;

           if assigned(hdef) and (hdef is tstoreddef) and
              (expose_this or rtti_should_expose(orgtypename)) then
             include(tstoreddef(hdef).defoptions,df_expose_rtti);

           if isgeneric and (not(hdef.typ in [objectdef,recorddef,arraydef,procvardef])
               or is_objectpascal_helper(hdef)) then
             begin
               newtype.typedef:=generrordef;
               message(parser_e_cant_create_generics_of_this_type);
             end;

           { Stop recording a generic template }
           if assigned(generictypelist) then
             begin
               current_scanner.stoprecordtokens;
               tstoreddef(hdef).generictokenbuf:=localgenerictokenbuf;
               { Generic is never a type renaming }
               hdef.typesym:=newtype;
               { reusing a forward declared type also reuses the type parameters,
                 so free them if they haven't been used }
               for i:=0 to generictypelist.count-1 do
                 begin
                   if (tstoredsym(generictypelist[i]).typ=typesym) and
                       not ttypesym(generictypelist[i]).typedef.is_registered then
                     FreeAndNil(ttypesym(generictypelist[i]).typedef);
                   if not tstoredsym(generictypelist[i]).is_registered then
                     tstoredsym(generictypelist[i]).free; // no nil needed
                 end;
               generictypelist.free;
               generictypelist := nil;
             end;

           if not (m_implicit_generics in current_settings.modeswitches) and
               (current_scanner.token=_ID) and (current_scanner.idtoken=_GENERIC) then
             begin
               had_generic:=true;
               consume(_ID);
               if current_scanner.token in [_PROCEDURE,_FUNCTION,_CLASS] then
                 break;
             end
           else
             had_generic:=false;
           first:=false;
           if assigned(rtti_attrs_def) and (rtti_attrs_def.get_attribute_count>0) then
             Message1(parser_e_unbound_attribute,trtti_attribute(rtti_attrs_def.rtti_attributes[0]).typesym.prettyname);

 {$ifdef DEBUG_NODE_XML}
          if Assigned(hdef) then
            hdef.XMLPrintDef(newtype);
 {$endif DEBUG_NODE_XML}

         until ((current_scanner.token<>_ID) and (current_scanner.token<>_LECKKLAMMER)) or
               (in_structure and
                ((current_scanner.idtoken in [_PRIVATE,_PROTECTED,_PUBLIC,_PUBLISHED,_STRICT]) or
                 ((m_final_fields in current_settings.modeswitches) and
                  (current_scanner.idtoken=_FINAL))));
         { resolve type block forward declarations and restore a unit
           container for them }
         resolve_forward_types;
         current_module.checkforwarddefs.free;
         current_module.checkforwarddefs:=old_checkforwarddefs;
         block_type:=old_block_type;
      end;


    { reads a type declaration to the symbol table }
    procedure type_dec(out had_generic:boolean);
      var
        rtti_attrs_def: trtti_attribute_list;
      begin
        consume(_TYPE);
        rtti_attrs_def := nil;
        types_dec(false,had_generic,rtti_attrs_def);
        rtti_attrs_def.free;
        rtti_attrs_def := nil;
      end;


    procedure var_dec(out had_generic:boolean);
    { parses variable declarations and inserts them in }
    { the top symbol table of symtablestack         }
      begin
        consume(_VAR);
        read_var_decls([vd_check_generic],had_generic);
      end;


    procedure property_dec;
    { parses a global property (fpc mode feature) }
      var
         old_block_type: tblock_type;
         autopropfield: tfieldvarsym;
      begin
         consume(_PROPERTY);
         if not(symtablestack.top.symtabletype in [staticsymtable,globalsymtable]) then
           message(parser_e_property_only_sgr);
         old_block_type:=block_type;
         block_type:=bt_const;
         repeat
           read_property_dec(false, nil, autopropfield);
           consume(_SEMICOLON);
         until current_scanner.token<>_ID;
         block_type:=old_block_type;
      end;


    procedure threadvar_dec(out had_generic:boolean);
    { parses thread variable declarations and inserts them in }
    { the top symbol table of symtablestack                }
      begin
        consume(_THREADVAR);
        if not(symtablestack.top.symtabletype in [staticsymtable,globalsymtable]) then
          message(parser_e_threadvars_only_sg);
        if f_threading in features then
          read_var_decls([vd_threadvar,vd_check_generic],had_generic)
        else
          begin
            Message1(parser_f_unsupported_feature,featurestr[f_threading]);
            read_var_decls([vd_check_generic],had_generic);
          end;
      end;


    procedure resourcestring_dec(out had_generic:boolean);
      var
         orgname : TIDString;
         p : tnode;
         dummysymoptions : tsymoptions;
         deprecatedmsg : pshortstring;
         storetokenpos,filepos : tfileposinfo;
         old_block_type : tblock_type;
         sp : pchar;
         sym : tsym;
         first,
         isgeneric : boolean;
         pw : tcompilerwidestring;

      begin
         if target_info.system in systems_managed_vm then
           message(parser_e_feature_unsupported_for_vm);
         consume(_RESOURCESTRING);
         if not(symtablestack.top.symtabletype in [staticsymtable,globalsymtable]) then
           message(parser_e_resourcestring_only_sg);
         first:=true;
         had_generic:=false;
         old_block_type:=block_type;
         block_type:=bt_const;
         repeat
           orgname:=current_scanner.orgpattern;
           filepos:=current_tokenpos;
           isgeneric:=not (m_implicit_generics in current_settings.modeswitches) and (current_scanner.token=_ID) and (current_scanner.idtoken=_GENERIC);
           consume(_ID);
           case current_scanner.token of
             _EQ:
                begin
                   consume(_EQ);
                   p:=comp_expr([ef_accept_equal]);
                   storetokenpos:=current_tokenpos;
                   current_tokenpos:=filepos;
                   sym:=nil;
                   case p.nodetype of
                      ordconstn:
                        begin
                           if is_constcharnode(p) then
                             begin
                                if not is_systemunit_unicode then
                                  begin
                                  getmem(sp,2);
                                  sp[0]:=chr(tordconstnode(p).value.svalue);
                                  sp[1]:=#0;
                                  sym:=cconstsym.create_string(orgname,constresourcestring,sp,1,nil);
                                  end
                                else
                                  begin
                                  initwidestring(pw);
                                  setlengthwidestring(pw,1);
                                  pw.data[0]:=tordconstnode(p).value.svalue;
                                  sym:=cconstsym.create_wstring(orgname,constwresourcestring,pw);
                                  end;
                             end
                           else
                             Message(parser_e_illegal_expression);
                        end;
                      stringconstn:
                        with Tstringconstnode(p) do
                          begin
                             if not is_systemunit_unicode  then
                               begin
                               if cst_type in [cst_widestring,cst_unicodestring] then
                                 changestringtype(getansistringdef);
                               getmem(sp,len+1);
                               sp[len]:=#0;
                               if len>0 then
                                 move(valueas[0],sp^,len);
                               sym:=cconstsym.create_string(orgname,constresourcestring,sp,len,nil);
                               end
                             else
                               begin
                               // For unicode rtl, resourcestrings are unicodestrings
                               if cst_type in [cst_conststring,cst_longstring, cst_shortstring,cst_ansistring] then
                                 changestringtype(cunicodestringtype);
                               initwidestring(pw);
                               copywidestring(valuews,pw);
                               sym:=cconstsym.create_wstring(orgname,constwresourcestring,pw);
                               end;
                          end;
                      else
                        Message(parser_e_illegal_expression);
                   end;
                   current_tokenpos:=storetokenpos;
                   { Support hint directives }
                   dummysymoptions:=[];
                   deprecatedmsg:=nil;
                   try_consume_hintdirective(dummysymoptions,deprecatedmsg);
                   if assigned(sym) then
                     begin
                       sym.symoptions:=sym.symoptions+dummysymoptions;
                       sym.deprecatedmsg:=deprecatedmsg;
                       symtablestack.top.insertsym(sym);
                     end
                   else
                     stringdispose(deprecatedmsg);
                   consume(_SEMICOLON);
                   p.free;
                   p := nil;
                end;
              else
                if not first and isgeneric and
                    (current_scanner.token in [_PROCEDURE, _FUNCTION, _CLASS]) then
                  begin
                    had_generic:=true;
                    break;
                  end
                else
                  consume(_EQ);
           end;
           first:=false;
         until current_scanner.token<>_ID;
         block_type:=old_block_type;
      end;

end.
