{
    Copyright (c) 1998-2002 by Florian Klaempfl

    Does parsing of expression for Free Pascal

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
unit pexpr;

{$i fpcdefs.inc}

interface

    uses
      symtype,symdef,symbase,
      node,ncal,compinnr,
      tokens,globtype,globals,constexp,
      pgentype;

    type
      texprflag = (
        ef_accept_equal,
        ef_type_only,
        ef_had_specialize,
        ef_check_attr_suffix,
        { opt-in for the lazy-label creation path: when set, an unknown
          identifier followed by `:` is auto-registered as a label sym
          (used by the unleashed lazy-label feature in statement context).
          Default OFF so that expression parsers (case patterns, match
          patterns, format spec, array index const, named params, ...) get
          a proper "Identifier not found" instead of a silently created
          label that swallows the `:` and confuses the parser }
        ef_allow_lazy_label
      );
      texprflags = set of texprflag;

    { reads a whole expression; `flags` are forwarded to sub_expr }
    function expr(dotypecheck:boolean; flags:texprflags = []) : tnode;

    { reads an expression without assignments and .. }
    function comp_expr(flags:texprflags):tnode;

    { reads a single factor }
    function factor(getaddr:boolean;flags:texprflags) : tnode;

    { parses the body of a `sync` statement (`sync` already consumed) }
    function parse_sync_block:tnode;

    procedure string_dec(var def: tdef; allowtypedef: boolean);

    function parse_paras(__colon,__namedpara : boolean;end_of_paras : ttoken;__outvar : boolean=true) : tnode;

    { the ID token has to be consumed before calling this function }
    procedure do_member_read(structh:tabstractrecorddef;getaddr:boolean;sym:tsym;var p1:tnode;var again:boolean;callflags:tcallnodeflags;spezcontext:tspecializationcontext);

    function get_intconst:TConstExprInt;
    function get_stringconst:string;

    { Does some postprocessing for a generic type (especially when nested types
      of the specialization are used) }
    procedure post_comp_expr_gendef(var def: tdef);

    { unleashed: parse the `(expr)` body of the compile-time Type() intrinsic.
      caller has already consumed the leading `Type` keyword. consumes the
      parentheses and returns the static type of the inner expression without
      evaluating it (no codegen, no side effects). returns generrordef on a
      parse or typecheck error. }
    function parse_type_intrinsic_body: tdef;

    { expand `SwapValues(a,b)` through a temporary when an operand has no
      address. returns nil (leaving `paras` untouched) when both operands are
      addressable and the in-place swap applies }
    function try_swapvalues_property_expand(paras:tnode):tnode;

implementation

    uses
       { common }
       cutils,cclasses,
       { global }
       verbose,
       systems,widestr,
       { symtable }
       symconst,symtable,symsym,symcpu,defutil,defcmp,
       { module }
       fmodule,ppu,
       { pass 1 }
       pass_1,htypechk,
       nmat,nadd,nmem,nset,ncnv,ninl,ncon,nld,nflw,nbas,nutils,
       { parser }
       scanner,
       pbase,pstatmnt,pinline,ptype,pgenutil,psub,procdefutil,procinfo,cpuinfo
       ;

    type
      { what value, if any, an inc/dec property rewrite yields }
      tincdecpropvalue = (ipv_none,ipv_pre,ipv_post);

    function sub_expr(pred_level:Toperator_precedence;flags:texprflags;factornode:tnode):tnode;forward;
    function exit_tuple_body(out block:tnode;out single_expr:tnode):boolean;forward;
    function try_inc_dec_property_rewrite(getter_call:tcallnode;delta:tnode;is_dec:boolean;valuekind:tincdecpropvalue):tnode;forward;
    function inline_prepost_incdec(innr:tinlinenumber):tnode;forward;

    var
       { true, if the inherited call is anonymous }
       anon_inherited : boolean = false;
       { last def found, only used by anon. inherited calls to insert proper type casts }
       srdef : tdef = nil;

    procedure string_dec(var def:tdef; allowtypedef: boolean);
    { reads a string type with optional length }
    { and returns a pointer to the string      }
    { definition                               }
      var
         p : tnode;
      begin
         def:=cshortstringtype;
         consume(_STRING);
         if current_scanner.token=_LECKKLAMMER then
           begin
             if not(allowtypedef) then
               Message(parser_e_no_local_para_def);
             consume(_LECKKLAMMER);
             p:=comp_expr([ef_accept_equal]);
             if not is_constintnode(p) then
               begin
                 Message(parser_e_illegal_expression);
                 { error recovery }
                 consume(_RECKKLAMMER);
               end
             else
               begin
                { the node is a generic param while parsing a generic def
                  so disable the range checking for the string }
                if parse_generic and
                  (nf_generic_para in p.flags) then
                  tordconstnode(p).value:=255;
                if tordconstnode(p).value<=0 then
                  begin
                     Message(parser_e_invalid_string_size);
                     tordconstnode(p).value:=255;
                  end;
                if tordconstnode(p).value>255 then
                  begin
                    { longstring is currently unsupported (CEC)! }
{                    t:=cstringdef.createlong(tordconstnode(p).value))}
                    Message(parser_e_invalid_string_size);
                    tordconstnode(p).value:=255;
                    def:=cstringdef.createshort(int64(tordconstnode(p).value),true);
                  end
                else
                  if tordconstnode(p).value<>255 then
                    def:=cstringdef.createshort(int64(tordconstnode(p).value),true);
                consume(_RECKKLAMMER);
              end;
             p.free;
             p := nil;
           end
          else
            begin
             // string[x] is allowed in system unit since it is a shortstring.
             if cs_compilesystem in current_settings.moduleswitches then
               Message(parser_e_nostringaliasinsystem);
              if cs_refcountedstrings in current_settings.localswitches then
                begin
                  if m_default_unicodestring in current_settings.modeswitches then
                    def:=cunicodestringtype
                  else
                    def:=cansistringtype
                end
              else
                def:=cshortstringtype;
            end;
       end;


    { Parse an inline out-variable or discard at a call-argument position:
        foo(var x)      -> declares block-scoped `x`, type inferred from the out/var parameter
        foo(var x: T)   -> same, with an explicit type; required at an untyped parameter
        foo(var x := e) -> seeded with `e`; only meaningful at a var parameter
        foo(_)          -> discard, a hidden local stands in for the out/var parameter
      Without an annotation the variable is created with a placeholder type
      (generrordef); bind_parasym fixes it up to the matched parameter's type
      after overload resolution. The callparanode is flagged cpf_outvar_decl so
      candidate matching accepts it only at an out or var parameter and binding
      knows to set its type. }
    function parse_outvar_para(prev:tnode; discard:boolean) : tnode;
      var
         vs       : tabstractnormalvarsym;
         sym_name : string;
         vardef   : tdef;
         ld,seed  : tnode;
         cp       : tcallparanode;
      begin
         if discard then
           consume(_ID)
         else
           consume(_VAR);

         if not (symtablestack.top.symtabletype in [localsymtable,staticsymtable,blocksymtable]) then
           begin
             Message(parser_e_syntax_error);
             if (not discard) and (current_scanner.token=_ID) then
               consume(_ID);
             result:=ccallparanode.create(cerrornode.create,prev);
             exit;
           end;

         if discard then
           sym_name:='$outdiscard$'+tostr(symtablestack.top.SymList.count)
         else
           begin
             if current_scanner.token<>_ID then
               begin
                 consume(_ID);
                 result:=ccallparanode.create(cerrornode.create,prev);
                 exit;
               end;
             sym_name:=current_scanner.orgpattern;
           end;

         vardef:=generrordef;
         seed:=nil;
         if not discard then
           begin
             consume(_ID);
             { optional explicit type: the only way to bind an untyped
               parameter, and a match requirement at a typed one }
             if current_scanner.token=_COLON then
               begin
                 consume(_COLON);
                 read_anon_type(vardef,false,nil);
               end;
             if current_scanner.token=_ASSIGNMENT then
               begin
                 consume(_ASSIGNMENT);
                 seed:=comp_expr([ef_accept_equal]);
               end;
           end;

         { the symbol is created after the seed is parsed, so a seed naming
           the declared variable resolves in the outer scope instead of
           hitting the placeholder-typed variable being declared }
         if symtablestack.top.symtabletype=staticsymtable then
           vs:=cstaticvarsym.create(sym_name,vs_value,vardef,[])
         else
           vs:=clocalvarsym.create(sym_name,vs_value,vardef,[]);
         vs.register_sym;
         symtablestack.top.insertsym(vs);

         ld:=cloadnode.create(vs,vs.owner);
         cp:=ccallparanode.create(ld,prev);
         include(cp.callparaflags,cpf_outvar_decl);
         cp.outvarseed:=seed;
         result:=cp;
      end;


    { __outvar=false disables the out-var/discard argument syntax: intrinsics
      like write/read/str have no out parameters to bind the type against }
    function parse_paras(__colon,__namedpara : boolean;end_of_paras : ttoken;__outvar : boolean=true) : tnode;
      var
         p1,p2,argname : tnode;
         srsym : tsym;
         srsymtable : TSymtable;
         prev_in_args,
         old_named_args_allowed : boolean;
      begin
         if current_scanner.token=end_of_paras then
           begin
              parse_paras:=nil;
              exit;
           end;
         { save old values }
         prev_in_args:=in_args;
         old_named_args_allowed:=named_args_allowed;
         { set para parsing values }
         in_args:=true;
         named_args_allowed:=false;
         p2:=nil;
         repeat
           if __namedpara then
             begin
               if current_scanner.token=_COMMA then
                 begin
                   { empty parameter }
                   p2:=ccallparanode.create(cnothingnode.create,p2);
                 end
               else
                 begin
                   named_args_allowed:=true;
                   p1:=comp_expr([ef_accept_equal]);
                   named_args_allowed:=false;
                   if found_arg_name then
                     begin
                       argname:=p1;
                       p1:=comp_expr([ef_accept_equal]);
                       p2:=ccallparanode.create(p1,p2);
                       tcallparanode(p2).parametername:=argname;
                     end
                   else
                     p2:=ccallparanode.create(p1,p2);
                   found_arg_name:=false;
                 end;
             end
           else if __outvar and (m_out_var in current_settings.modeswitches) and
                   (current_scanner.token=_VAR) then
             p2:=parse_outvar_para(p2,false)
           { a lone `_` is a discard only when it does not resolve to a
             symbol in scope: code that declares `_` keeps meaning it }
           else if __outvar and (m_out_var in current_settings.modeswitches) and
                   (current_scanner.token=_ID) and (current_scanner.pattern='_') and
                   not searchsym('_',srsym,srsymtable) then
             p2:=parse_outvar_para(p2,true)
           else
             begin
               p1:=comp_expr([ef_accept_equal]);
               p2:=ccallparanode.create(p1,p2);
             end;
           { it's for the str(l:5,s); }
           if __colon and (current_scanner.token=_COLON) then
             begin
               consume(_COLON);
               p1:=comp_expr([ef_accept_equal]);
               p2:=ccallparanode.create(p1,p2);
               include(tcallparanode(p2).callparaflags,cpf_is_colon_para);
               if try_to_consume(_COLON) then
                 begin
                   p1:=comp_expr([ef_accept_equal]);
                   p2:=ccallparanode.create(p1,p2);
                   include(tcallparanode(p2).callparaflags,cpf_is_colon_para);
                 end
             end;
         until not try_to_consume(_COMMA);
         in_args:=prev_in_args;
         named_args_allowed:=old_named_args_allowed;
         parse_paras:=p2;
      end;


     function gen_c_style_operator(ntyp:tnodetype;p1,p2:tnode) : tnode;
       function create_assignop_node(ntyp: tnodetype; left, right: tnode): tnode;
         begin
           case ntyp of
             divn,
             modn:
               result:=cmoddivnode.create(ntyp,left,right);
             shln,
             shrn:
               result:=cshlshrnode.create(ntyp,left,right);
             else
               result:=caddnode.create(ntyp,left,right);
           end;
         end;
       var
         hdef  : tdef;
         temp  : ttempcreatenode;
         newstatement : tstatementnode;
       begin
         { Properties are not allowed, because the write can
           be different from the read }
         if (nf_isproperty in p1.flags) then
           begin
             Message(type_e_variable_id_expected);
             { We can continue with the loading,
               it'll not create errors. Only the expected
               result can be wrong }
           end;

        if might_have_sideeffects(p1,[]) then
           begin
             typecheckpass(p1);
             result:=internalstatements(newstatement);
             hdef:=cpointerdef.getreusable(p1.resultdef);
             temp:=ctempcreatenode.create(hdef,sizeof(pint),tt_persistent,false);
             addstatement(newstatement,temp);
             addstatement(newstatement,cassignmentnode.create(ctemprefnode.create(temp),caddrnode.create_internal(p1)));
             addstatement(newstatement,cassignmentnode.create(
                 cderefnode.create(ctemprefnode.create(temp)),
                 create_assignop_node(ntyp,
                     cderefnode.create(ctemprefnode.create(temp)),
                     p2)));
             addstatement(newstatement,ctempdeletenode.create(temp));
           end
         else
           result:=cassignmentnode.create(p1,create_assignop_node(ntyp,p1.getcopy,p2));
       end;


     { Walks a Write/WriteLn callparanode chain and expands any tuple
       arguments into per-field subscript nodes so that WriteLn(t)
       becomes WriteLn(t._1, t._2, ...). Returns the (possibly new)
       head of the chain. }
     function expand_tuple_write_paras(head:tnode):tnode;
       var
         cur,prev,next,newhead,tail : tcallparanode;
         recdef : trecorddef;
         sym : tsym;
         fsym : tfieldvarsym;
         i : longint;
         sub : tnode;
         first_new,last_new : tcallparanode;
       begin
         result:=head;
         prev:=nil;
         cur:=tcallparanode(head);
         while assigned(cur) do
           begin
             next:=tcallparanode(cur.right);
             { skip colon-format params }
             if cpf_is_colon_para in cur.callparaflags then
               begin
                 prev:=cur;
                 cur:=next;
                 continue;
               end;
             typecheckpass(cur.left);
             if assigned(cur.left.resultdef) and
                (cur.left.resultdef.typ=recorddef) and
                (df_tuple in cur.left.resultdef.defoptions) then
               begin
                 recdef:=trecorddef(cur.left.resultdef);
                 { build chain with fields prepended so that Write
                   (which consumes back-to-front) prints them in order }
                 first_new:=nil;
                 for i:=0 to recdef.symtable.symlist.count-1 do
                   begin
                     sym:=tsym(recdef.symtable.symlist[i]);
                     if sym.typ<>fieldvarsym then
                       continue;
                     fsym:=tfieldvarsym(sym);
                     sub:=csubscriptnode.create(fsym,cur.left.getcopy);
                     { separator between fields (before non-first) }
                     if i>0 then
                       first_new:=ccallparanode.create(
                         cstringconstnode.createstr(', '),
                         first_new);
                     first_new:=ccallparanode.create(sub,first_new);
                   end;
                 last_new:=first_new;
                 if assigned(last_new) then
                   while assigned(last_new.right) do
                     last_new:=tcallparanode(last_new.right);
                 if assigned(first_new) then
                   begin
                     last_new.right:=next;
                     if assigned(prev) then
                       prev.right:=first_new
                     else
                       result:=first_new;
                     cur.left.free;
                     cur.left:=nil;
                     cur.right:=nil;
                     cur.free;
                     cur:=first_new;
                     prev:=last_new;
                     cur:=next;
                     continue;
                   end;
               end;
             prev:=cur;
             cur:=next;
           end;
       end;

     function statement_syssym(l : tinlinenumber) : tnode;
      var
        p1,p2,paras  : tnode;
        err,
        prev_in_args : boolean;
        def : tdef;
        exit_procinfo: tprocinfo;
        tuple_block  : tnode;
        tuple_last   : tstatementnode;
      begin
        prev_in_args:=in_args;
        case l of

          in_new_x :
            begin
              if afterassignment or in_args then
               statement_syssym:=new_function
              else
               statement_syssym:=new_dispose_statement(true);
            end;

          in_dispose_x :
            begin
              statement_syssym:=new_dispose_statement(false);
            end;

          in_ord_x,
          in_chr_byte:
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              consume(_RKLAMMER);
              p1:=geninlinenode(l,false,p1);
              statement_syssym := p1;
            end;

          in_exit :
            begin
              statement_syssym:=nil;
              p1:=nil;
              tuple_block:=nil;
              if try_to_consume(_LKLAMMER) then
                begin
                  if not (m_mac in current_settings.modeswitches) then
                    begin
                      if not(try_to_consume(_RKLAMMER)) then
                        begin
                          { tuple Exit shorthand: Exit(a,b,...) or Exit(n:v,...) }
                          if (m_tuples in current_settings.modeswitches) and
                             assigned(current_procinfo) and
                             (current_procinfo.procdef.returndef.typ=recorddef) and
                             (df_tuple in current_procinfo.procdef.returndef.defoptions) then
                            begin
                              if exit_tuple_body(tuple_block,p1) then
                                begin
                                  tuple_last:=laststatement(tblocknode(tuple_block));
                                  addstatement(tuple_last,cexitnode.create(nil));
                                  statement_syssym:=tuple_block;
                                  p1:=nil;
                                end;
                              { else single expression, p1 was set and _RKLAMMER consumed }
                            end
                          else
                            begin
                              p1:=comp_expr([ef_accept_equal]);
                              consume(_RKLAMMER);
                            end;
                          if assigned(p1) and
                             (not assigned(current_procinfo) or
                              (current_procinfo.procdef.proctypeoption in [potype_constructor,potype_destructor]) or
                              is_void(current_procinfo.procdef.returndef)) then
                            begin
                              Message(parser_e_void_function);
                              { recovery }
                              p1.free;
                              p1:=nil;
                            end;
                        end
                      else
                        p1:=nil;
                    end
                  else
                    begin
                      { non local exit ? }
                      if current_procinfo.procdef.procsym.name<>current_scanner.pattern then
                        begin
                          exit_procinfo:=current_procinfo.parent;
                          while assigned(exit_procinfo) do
                            begin
                              if exit_procinfo.procdef.procsym.name=current_scanner.pattern then
                                break;
                              exit_procinfo:=exit_procinfo.parent;
                            end;
                          if assigned(exit_procinfo) then
                            begin
                              if not(assigned(exit_procinfo.nestedexitlabel)) then
                                begin
                                  include(current_procinfo.flags,pi_has_nested_exit);
                                  { when inline is forced keep po_inline so checknodeinlining reports it }
                                  if not(pio_forceinline in current_procinfo.procdef.implprocoptions) then
                                    exclude(current_procinfo.procdef.procoptions,po_inline);
                                  if is_nested_pd(current_procinfo.procdef) then
                                    current_procinfo.set_needs_parentfp(exit_procinfo.procdef.parast.symtablelevel);

                                  exit_procinfo.nestedexitlabel:=clabelsym.create('$nestedexit');

                                  { the compiler is responsible to define this label }
                                  exit_procinfo.nestedexitlabel.defined:=true;
                                  exit_procinfo.nestedexitlabel.used:=true;

                                  exit_procinfo.nestedexitlabel.jumpbuf:=clocalvarsym.create('LABEL$_'+exit_procinfo.nestedexitlabel.name,vs_value,rec_jmp_buf,[]);
                                  exit_procinfo.procdef.localst.insertsym(exit_procinfo.nestedexitlabel);
                                  exit_procinfo.procdef.localst.insertsym(exit_procinfo.nestedexitlabel.jumpbuf);
                                end;

                              statement_syssym:=cgotonode.create(exit_procinfo.nestedexitlabel);
                              tgotonode(statement_syssym).labelsym:=exit_procinfo.nestedexitlabel;
                            end
                          else
                            Message(parser_e_macpas_exit_wrong_param);
                        end;
                      consume(_ID);
                      consume(_RKLAMMER);
                      p1:=nil;
                    end
                end
              else
                p1:=nil;
              if not assigned(statement_syssym) then
                statement_syssym:=cexitnode.create(p1);
            end;

          in_break :
            begin
              statement_syssym:=cbreaknode.create
            end;

          in_continue :
            begin
              statement_syssym:=ccontinuenode.create
            end;

          in_leave :
            begin
              if [m_mac,m_match]*current_settings.modeswitches<>[] then
                statement_syssym:=cbreaknode.create
              else
                begin
                  Message1(sym_e_id_not_found, current_scanner.orgpattern);
                  statement_syssym:=cerrornode.create;
                end;
            end;

          in_cycle :
            begin
              if m_mac in current_settings.modeswitches then
                statement_syssym:=ccontinuenode.create
              else
                begin
                  Message1(sym_e_id_not_found, current_scanner.orgpattern);
                  statement_syssym:=cerrornode.create;
                end;
            end;

          in_typeof_x :
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              consume(_RKLAMMER);
              if p1.nodetype=typen then
                ttypenode(p1).allowed:=true;
              { Allow classrefdef, which is required for
                Typeof(self) in static class methods }
              if not(is_objc_class_or_protocol(p1.resultdef)) and
                 not(is_java_class_or_interface(p1.resultdef)) and
                 ((p1.resultdef.typ = objectdef) or
                  (assigned(current_procinfo) and
                   ((po_classmethod in current_procinfo.procdef.procoptions) or
                    (po_staticmethod in current_procinfo.procdef.procoptions)) and
                   (p1.resultdef.typ=classrefdef))) then
               statement_syssym:=geninlinenode(in_typeof_x,false,p1)
              else
               begin
                 Message(parser_e_class_id_expected);
                 p1.free;
                 p1 := nil;
                 statement_syssym:=cerrornode.create;
               end;
            end;

          in_sizeof_x,
          in_bitsizeof_x :
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              consume(_RKLAMMER);
              if ((p1.nodetype<>typen) and
                 (
                  (is_object(p1.resultdef) and
                   (oo_has_constructor in tobjectdef(p1.resultdef).objectoptions)) or
                  is_open_array(p1.resultdef) or
                  is_array_of_const(p1.resultdef) or
                  is_open_string(p1.resultdef)
                 )) or
                 { keep the function call if it is a type parameter to avoid arithmetic errors due to constant folding }
                 is_typeparam(p1.resultdef) then
                begin
                  statement_syssym:=geninlinenode(in_sizeof_x,false,p1);
                  { no packed bit support for these things }
                  if l=in_bitsizeof_x then
                    statement_syssym:=caddnode.create(muln,statement_syssym,cordconstnode.create(8,sizesinttype,true));
                  { type sym is a generic parameter }
                  if assigned(p1.resultdef.typesym) and (sp_generic_para in p1.resultdef.typesym.symoptions) then
                    include(statement_syssym.flags,nf_generic_para);
                end
              else
               begin
                 { allow helpers for SizeOf and BitSizeOf }
                 if p1.nodetype=typen then
                   ttypenode(p1).helperallowed:=true;
                 if (p1.resultdef.typ=forwarddef) then
                   Message1(type_e_type_is_not_completly_defined,tforwarddef(p1.resultdef).tosymname^);
{$ifdef wasm}
                 if is_wasm_reference_type(p1.resultdef) then
                   Message(type_e_cannot_determine_size_of_wasm_reference_type);
{$endif wasm}
                 if (l = in_sizeof_x) or
                    (not((p1.nodetype = vecn) and
                         is_packed_array(tvecnode(p1).left.resultdef)) and
                     not((p1.nodetype = subscriptn) and
                         is_packed_record_or_object(tsubscriptnode(p1).left.resultdef))) then
                   begin
                     { composablerecords: a field with an explicit `size N`
                       override occupies exactly N bytes in the surrounding
                       record, regardless of the declared type's natural size.
                       `SizeOf(record.field)` now reflects the slot, matching
                       what `OffsetOf` of the next field implies. }
                     if (p1.nodetype = subscriptn) and
                        (tsubscriptnode(p1).vs.custom_size <> -1) then
                       statement_syssym:=genintconstnode(tsubscriptnode(p1).vs.custom_size,sizesinttype)
                     else
                       statement_syssym:=genintconstnode(p1.resultdef.size,sizesinttype);
                     if (l = in_bitsizeof_x) then
                       statement_syssym:=caddnode.create(muln,statement_syssym,cordconstnode.create(8,sizesinttype,true));
                   end
                 { composablerecords: a field with an explicit `bitsize N`
                   override occupies exactly N bits, regardless of the
                   declared type's natural packed bit width }
                 else if (p1.nodetype = subscriptn) and
                         (tsubscriptnode(p1).vs.custom_bitsize > 0) then
                   statement_syssym:=genintconstnode(tsubscriptnode(p1).vs.custom_bitsize,sizesinttype)
                 else
                   statement_syssym:=genintconstnode(p1.resultdef.packedbitsize,sizesinttype);
                 { type def is a struct with generic fields }
                 if df_has_generic_fields in p1.resultdef.defoptions then
                    include(statement_syssym.flags,nf_generic_para);
                 { p1 not needed !}
                 p1.free;
                 p1 := nil;
               end;
            end;

          in_typeinfo_x,
          in_objc_encode_x,
          in_gettypekind_x,
          in_ismanagedtype_x:
            begin
              if (l in [in_typeinfo_x,in_gettypekind_x,in_ismanagedtype_x]) or
                 (m_objectivec1 in current_settings.modeswitches) then
                begin
                  consume(_LKLAMMER);
                  in_args:=true;
                  p1:=comp_expr([ef_accept_equal]);
                  { When reading a class type it is parsed as loadvmtaddrn,
                    typeinfo only needs the type so we remove the loadvmtaddrn }
                  if p1.nodetype=loadvmtaddrn then
                    begin
                      p2:=tloadvmtaddrnode(p1).left;
                      tloadvmtaddrnode(p1).left:=nil;
                      p1.free;
                      p1:=p2;
                    end;
                  if p1.nodetype=typen then
                  begin
                    ttypenode(p1).allowed:=true;
                    { allow helpers for TypeInfo }
                    if l in [in_typeinfo_x,in_gettypekind_x,in_ismanagedtype_x] then
                      ttypenode(p1).helperallowed:=true;
                  end;
    {              else
                    begin
                       p1.free;
                       p1:=cerrornode.create;
                       Message(parser_e_illegal_parameter_list);
                    end;}
                  consume(_RKLAMMER);
                  p2:=geninlinenode(l,false,p1);
                  statement_syssym:=p2;
                end
              else
                begin
                  Message1(sym_e_id_not_found, current_scanner.orgpattern);
                  statement_syssym:=cerrornode.create;
                end;
            end;

          in_isconstvalue_x:
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              consume(_RKLAMMER);
              p2:=geninlinenode(l,false,p1);
              statement_syssym:=p2;
            end;

          in_aligned_x,
          in_unaligned_x,
          in_volatile_x:
            begin
              err:=false;
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              p2:=ccallparanode.create(p1,nil);
              p2:=geninlinenode(l,false,p2);
              consume(_RKLAMMER);
              statement_syssym:=p2;
            end;

          in_assigned_x :
            begin
              err:=false;
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              { When reading a class type it is parsed as loadvmtaddrn,
                typeinfo only needs the type so we remove the loadvmtaddrn }
              if p1.nodetype=loadvmtaddrn then
                begin
                  p2:=tloadvmtaddrnode(p1).left;
                  tloadvmtaddrnode(p1).left:=nil;
                  p1.free;
                  p1:=p2;
                end;
              if not codegenerror then
               begin
                 case p1.resultdef.typ of
                   procdef, { procvar }
                   pointerdef,
                   procvardef,
                   classrefdef : ;
                   objectdef :
                     if not is_implicit_pointer_object_type(p1.resultdef) then
                       begin
                         Message(parser_e_illegal_parameter_list);
                         err:=true;
                       end;
                   arraydef :
                     if not is_dynamic_array(p1.resultdef) then
                       begin
                         Message(parser_e_illegal_parameter_list);
                         err:=true;
                       end;
                   else
                     if p1.resultdef.typ<>undefineddef then
                       begin
                         Message(parser_e_illegal_parameter_list);
                         err:=true;
                       end;
                 end;
               end
              else
               err:=true;
              if not err then
               begin
                 p2:=ccallparanode.create(p1,nil);
                 p2:=geninlinenode(in_assigned_x,false,p2);
               end
              else
               begin
                 p1.free;
                 p1 := nil;
                 p2:=cerrornode.create;
               end;
              consume(_RKLAMMER);
              statement_syssym:=p2;
            end;

          in_addr_x :
            begin
              consume(_LKLAMMER);
              got_addrn:=true;
              p1:=factor(true,[]);
              { inside parentheses a full expression is allowed, see also tests\webtbs\tb27517.pp }
              if current_scanner.token<>_RKLAMMER then
                p1:=sub_expr(opcompare,[ef_accept_equal],p1);
              p1:=caddrnode.create(p1);
              got_addrn:=false;
              consume(_RKLAMMER);
              statement_syssym:=p1;
            end;

{$ifdef i8086}
          in_faraddr_x :
            begin
              consume(_LKLAMMER);
              got_addrn:=true;
              p1:=factor(true,[]);
              { inside parentheses a full expression is allowed, see also tests\webtbs\tb27517.pp }
              if current_scanner.token<>_RKLAMMER then
                p1:=sub_expr(opcompare,[ef_accept_equal],p1);
              p1:=geninlinenode(in_faraddr_x,false,p1);
              got_addrn:=false;
              consume(_RKLAMMER);
              statement_syssym:=p1;
            end;
{$endif i8086}

          in_ofs_x :
            begin
              if target_info.system in systems_managed_vm then
                message(parser_e_feature_unsupported_for_vm);
              consume(_LKLAMMER);
              got_addrn:=true;
              p1:=factor(true,[]);
              { inside parentheses a full expression is allowed, see also tests\webtbs\tb27517.pp }
              if current_scanner.token<>_RKLAMMER then
                p1:=sub_expr(opcompare,[ef_accept_equal],p1);
              p1:=caddrnode.create(p1);
              include(taddrnode(p1).addrnodeflags,anf_ofs);
              got_addrn:=false;
              { Ofs() returns a cardinal/qword, not a pointer }
              inserttypeconv_internal(p1,uinttype);
              consume(_RKLAMMER);
              statement_syssym:=p1;
            end;

          in_seg_x :
            begin
              consume(_LKLAMMER);
              got_addrn:=true;
              p1:=factor(true,[]);
              { inside parentheses a full expression is allowed, see also tests\webtbs\tb27517.pp }
              if current_scanner.token<>_RKLAMMER then
                p1:=sub_expr(opcompare,[ef_accept_equal],p1);
              p1:=geninlinenode(in_seg_x,false,p1);
              got_addrn:=false;
              consume(_RKLAMMER);
              statement_syssym:=p1;
            end;

          in_high_x,
          in_low_x :
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              p2:=geninlinenode(l,false,p1);
              consume(_RKLAMMER);
              statement_syssym:=p2;
            end;

          in_succ_x,
          in_pred_x :
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              p2:=geninlinenode(l,false,p1);
              consume(_RKLAMMER);
              statement_syssym:=p2;
            end;

          in_inc_x,
          in_dec_x :
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              if try_to_consume(_COMMA) then
                p2:=comp_expr([ef_accept_equal])
              else
                p2:=nil;
              consume(_RKLAMMER);
              statement_syssym:=nil;
              { unleashed: rewrite inc/dec on a procsym-getter property as a
                setter call carrying getter +/- delta }
              if (m_unleashed in current_settings.modeswitches) and
                 (nf_isproperty in p1.flags) and
                 (p1.nodetype=calln) then
                statement_syssym:=try_inc_dec_property_rewrite(tcallnode(p1),p2,l=in_dec_x,ipv_none);
              if not assigned(statement_syssym) then
                begin
                  if assigned(p2) then
                    p2:=ccallparanode.create(p2,nil);
                  p2:=ccallparanode.create(p1,p2);
                  statement_syssym:=geninlinenode(l,false,p2);
                end;
            end;

          in_slice_x:
            begin
              if not(in_args) then
                begin
                  message(parser_e_illegal_slice);
                  consume(_LKLAMMER);
                  in_args:=true;
                  comp_expr([ef_accept_equal]).free; // no nil needed
                  if try_to_consume(_COMMA) then
                    comp_expr([ef_accept_equal]).free; // no nil needed
                  statement_syssym:=cerrornode.create;
                  consume(_RKLAMMER);
                end
              else
                begin
                  consume(_LKLAMMER);
                  in_args:=true;
                  p1:=comp_expr([ef_accept_equal]);
                  Consume(_COMMA);
                  if not(codegenerror) then
                    p2:=ccallparanode.create(comp_expr([ef_accept_equal]),nil)
                  else
                    p2:=cerrornode.create;
                  p2:=ccallparanode.create(p1,p2);
                  statement_syssym:=geninlinenode(l,false,p2);
                  consume(_RKLAMMER);
                end;
            end;

          in_initialize_x:
            begin
              statement_syssym:=inline_initialize;
            end;

          in_finalize_x:
            begin
              statement_syssym:=inline_finalize;
            end;

          in_copy_x:
            begin
              statement_syssym:=inline_copy;
            end;

          in_concat_x :
            begin
              statement_syssym:=inline_concat;
            end;

          in_read_x,
          in_readln_x,
          in_readstr_x:
            begin
              if try_to_consume(_LKLAMMER) then
               begin
                 paras:=parse_paras(false,false,_RKLAMMER,false);
                 consume(_RKLAMMER);
               end
              else
               paras:=nil;
              p1:=geninlinenode(l,false,paras);
              statement_syssym := p1;
            end;

          in_setlength_x:
            begin
              statement_syssym := inline_setlength;
            end;

          in_objc_selector_x:
            begin
              if (m_objectivec1 in current_settings.modeswitches) then
                begin
                  consume(_LKLAMMER);
                  in_args:=true;
                  { don't turn procsyms into calls (getaddr = true) }
                  p1:=factor(true,[]);
                  p2:=geninlinenode(l,false,p1);
                  consume(_RKLAMMER);
                  statement_syssym:=p2;
                end
              else
                begin
                  Message1(sym_e_id_not_found, current_scanner.orgpattern);
                  statement_syssym:=cerrornode.create;
                end;
            end;

          in_length_x:
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              p2:=geninlinenode(l,false,p1);
              consume(_RKLAMMER);
              statement_syssym:=p2;
            end;

          in_write_x,
          in_writeln_x,
          in_writestr_x :
            begin
              if try_to_consume(_LKLAMMER) then
               begin
                 paras:=parse_paras(true,false,_RKLAMMER,false);
                 consume(_RKLAMMER);
                 if (m_tuples in current_settings.modeswitches) and
                    assigned(paras) then
                   paras:=expand_tuple_write_paras(tnode(paras));
               end
              else
               paras:=nil;
              p1 := geninlinenode(l,false,paras);
              statement_syssym := p1;
            end;

          in_str_x_string :
            begin
              consume(_LKLAMMER);
              paras:=parse_paras(true,false,_RKLAMMER,false);
              consume(_RKLAMMER);
              p1 := geninlinenode(l,false,paras);
              statement_syssym := p1;
            end;

          in_val_x:
            Begin
              consume(_LKLAMMER);
              in_args := true;
              p1:= ccallparanode.create(comp_expr([ef_accept_equal]), nil);
              consume(_COMMA);
              p2 := ccallparanode.create(comp_expr([ef_accept_equal]),p1);
              if try_to_consume(_COMMA) then
                p2 := ccallparanode.create(comp_expr([ef_accept_equal]),p2);
              consume(_RKLAMMER);
              p2 := geninlinenode(l,false,p2);
              statement_syssym := p2;
            End;

          in_include_x_y,
          in_exclude_x_y :
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              consume(_COMMA);
              p2:=comp_expr([ef_accept_equal]);
              statement_syssym:=geninlinenode(l,false,ccallparanode.create(p1,ccallparanode.create(p2,nil)));
              consume(_RKLAMMER);
            end;

          in_pack_x_y_z,
          in_unpack_x_y_z :
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              consume(_COMMA);
              p2:=comp_expr([ef_accept_equal]);
              consume(_COMMA);
              paras:=comp_expr([ef_accept_equal]);
              statement_syssym:=geninlinenode(l,false,ccallparanode.create(p1,ccallparanode.create(p2,ccallparanode.create(paras,nil))));
              consume(_RKLAMMER);
            end;

          in_assert_x_y :
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              if try_to_consume(_COMMA) then
                 p2:=comp_expr([ef_accept_equal])
              else
               begin
                 { then insert an empty string }
                 p2:=cstringconstnode.createstr('');
               end;
              statement_syssym:=geninlinenode(l,false,ccallparanode.create(p1,ccallparanode.create(p2,nil)));
              consume(_RKLAMMER);
            end;
          in_get_frame:
            begin
              statement_syssym:=geninlinenode(l,false,nil);
            end;
(*
          in_get_caller_frame:
            begin
              if try_to_consume(_LKLAMMER) then
                begin
                  {You used to call get_caller_frame as get_caller_frame(get_frame),
                   however, as a stack frame may not exist, it does more harm than
                   good, so ignore it.}
                  in_args:=true;
                  p1:=comp_expr([ef_accept_equal]);
                  p1.free;
                  p1 := nil;
                  consume(_RKLAMMER);
                end;
              statement_syssym:=geninlinenode(l,false,nil);
            end;
*)
          in_default_x:
            begin
              consume(_LKLAMMER);
              in_args:=true;
              def:=nil;
              single_type(def,[stoAllowSpecialization]);
              statement_syssym:=cerrornode.create;
              if def<>generrordef then
                { "type expected" error is already done by single_type }
                if def.typ=forwarddef then
                  Message1(type_e_type_is_not_completly_defined,tforwarddef(def).tosymname^)
                else
                  begin
                    statement_syssym.free;
                    statement_syssym:=geninlinenode(in_default_x,false,ctypenode.create(def));
                  end;
              { consume the right bracket here for a nicer error position }
              consume(_RKLAMMER);
            end;

          in_setstring_x_y_z:
            begin
              statement_syssym := inline_setstring;
            end;

          in_delete_x_y_z:
            begin
              statement_syssym:=inline_delete;
            end;

          in_insert_x_y_z:
            begin
              statement_syssym:=inline_insert;
            end;
          in_const_eh_return_data_regno:
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              p2:=geninlinenode(l,true,p1);
              consume(_RKLAMMER);
              statement_syssym:=p2;
            end;

          in_atomic_inc,
          in_atomic_dec:
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              if try_to_consume(_COMMA) then
                begin
                  p2:=ccallparanode.create(comp_expr([ef_accept_equal]),nil);
                end
              else
                p2:=nil;
              statement_syssym:=geninlinenode(l,false,ccallparanode.create(p1,p2));
              consume(_RKLAMMER);
            end;

          in_atomic_xchg:
            begin
              consume(_LKLAMMER);
              in_args:=true;
              p1:=comp_expr([ef_accept_equal]);
              consume(_COMMA);
              p2:=comp_expr([ef_accept_equal]);
              statement_syssym:=geninlinenode(l,false,ccallparanode.create(p1,ccallparanode.create(p2,nil)));
              consume(_RKLAMMER);
            end;

          in_atomic_cmp_xchg:
            begin
              consume(_LKLAMMER);
              in_args:=true;
              paras:=ccallparanode.create(comp_expr([ef_accept_equal]),nil);
              consume(_COMMA);
              tcallparanode(paras).right:=ccallparanode.create(comp_expr([ef_accept_equal]),nil);
              consume(_COMMA);
              tcallparanode(tcallparanode(paras).right).right:=ccallparanode.create(comp_expr([ef_accept_equal]),nil);
              if try_to_consume(_COMMA) then
                begin
                  tcallparanode(tcallparanode(tcallparanode(paras).right).right).right:=ccallparanode.create(comp_expr([ef_accept_equal]),nil);
                end;
              statement_syssym:=geninlinenode(l,false,paras);
              consume(_RKLAMMER);
            end;

          else
            internalerror(15);

        end;
        in_args:=prev_in_args;
      end;


    function maybe_load_methodpointer(st:TSymtable;var p1:tnode):boolean;
      var
        pd: tprocdef;
      begin
        maybe_load_methodpointer:=false;
        if not assigned(p1) then
         begin
           case st.symtabletype of
             withsymtable :
               begin
                 if (st.defowner.typ=objectdef) then
                   p1:=tnode(twithsymtable(st).withrefnode).getcopy;
               end;
             ObjectSymtable,
             recordsymtable:
               begin
                 { Escape nested procedures }
                 if assigned(current_procinfo) then
                   begin
                     pd:=current_procinfo.get_normal_proc.procdef;
                     { We are calling from the static class method which has no self node }
                     if assigned(pd) and pd.no_self_node then
                       if st.symtabletype=recordsymtable then
                         p1:=ctypenode.create(pd.struct)
                       else
                         p1:=cloadvmtaddrnode.create(ctypenode.create(pd.struct))
                     else
                       p1:=load_self_node;
                   end
                 else
                   p1:=load_self_node;
                 { don't try to call the invokable again }
                 if is_invokable(tdef(st.defowner)) then
                   include(p1.flags,nf_load_procvar);
                 { We are calling a member }
                 maybe_load_methodpointer:=true;
               end;
             else
               ;
           end;
         end;
      end;


    { reads the parameter for a subroutine call }
    procedure do_proc_call(sym:tsym;st:TSymtable;obj:tabstractrecorddef;getaddr:boolean;var again : boolean;var p1:tnode;callflags:tcallnodeflags;spezcontext:tspecializationcontext);
      var
         membercall,
         prevafterassn : boolean;
         i        : integer;
         para,p2  : tnode;
         currpara : tparavarsym;
         aprocdef : tprocdef;
      begin
         prevafterassn:=afterassignment;
         afterassignment:=false;
         membercall:=false;
         aprocdef:=nil;

         { when it is a call to a member we need to load the
           methodpointer first
         }
         membercall:=maybe_load_methodpointer(st,p1);

         { When we are expecting a procvar we also need
           to get the address in some cases }
         if assigned(getprocvardef) or assigned(getfuncrefdef) then
          begin
            if (block_type=bt_const) or
               getaddr then
             begin
               if assigned(getfuncrefdef) then
                 aprocdef:=Tprocsym(sym).Find_procdef_byfuncrefdef(getfuncrefdef)
               else
                 aprocdef:=Tprocsym(sym).Find_procdef_byprocvardef(getprocvardef);
               getaddr:=true;
             end
            else
             if ((m_tp_procvar in current_settings.modeswitches) or
                 (m_mac_procvar in current_settings.modeswitches)) and
                not(current_scanner.token in [_CARET,_POINT,_LKLAMMER]) then
              begin
                if assigned(getfuncrefdef) then
                  aprocdef:=Tprocsym(sym).Find_procdef_byfuncrefdef(getfuncrefdef)
                else
                  aprocdef:=Tprocsym(sym).Find_procdef_byprocvardef(getprocvardef);
                if assigned(aprocdef) then
                 getaddr:=true;
              end;
          end;

         { only need to get the address of the procedure? Check token because
           in the case of opening parenthesis is possible to get pointer to
           function result (lack of checking for token was the reason of
           tw10933.pp test failure) }
         if getaddr and (current_scanner.token<>_LKLAMMER) then
           begin
             { for now we don't support pointers to generic functions, but since
               this is only temporary we use a non translated message }
             if assigned(spezcontext) then
               begin
                 comment(v_error, 'Pointers to generics functions not implemented');
                 p1:=cerrornode.create;
                 spezcontext.free;
                 spezcontext := nil;
                 exit;
               end;

             { Retrieve info which procvar to call. For tp_procvar the
               aprocdef is already loaded above so we can reuse it }
             if not assigned(aprocdef) and
                assigned(getprocvardef) then
               aprocdef:=Tprocsym(sym).Find_procdef_byprocvardef(getprocvardef);
             if not assigned(aprocdef) and
                assigned(getfuncrefdef) then
               aprocdef:=Tprocsym(sym).Find_procdef_byfuncrefdef(getfuncrefdef);

             { ensure that the correct function is considered as captured }
             if assigned(current_procinfo) and
                 assigned(aprocdef) and
                 (aprocdef.parast.symtablelevel<=current_procinfo.procdef.parast.symtablelevel) and
                 (aprocdef.parast.symtablelevel>normal_function_level) and
                 (current_procinfo.procdef.parast.symtablelevel>normal_function_level) then
               current_procinfo.add_captured_sym(sym,aprocdef,current_filepos);

             { generate a methodcallnode or proccallnode }
             { we shouldn't convert things like @tcollection.load }
             p2:=cloadnode.create_procvar(sym,aprocdef,st);
             if assigned(p1) then
              begin
                { for loading methodpointer of an inherited function
                  we use self as instance and load the address of
                  the function directly and not through the vmt (PFV) }
                if (cnf_inherited in callflags) then
                  begin
                    include(tloadnode(p2).loadnodeflags,loadnf_inherited);
                    p1.free;
                    p1:=load_self_node;
                  end;
                if (p1.nodetype<>typen) then
                  tloadnode(p2).set_mp(p1)
                else
                  begin
                    typecheckpass(p1);
                    if (p1.resultdef.typ=classrefdef) and
                       (
                         assigned(getprocvardef) or
                         assigned(getfuncrefdef)
                       ) then
                      begin
                        p1:=cloadvmtaddrnode.create(p1);
                        tloadnode(p2).set_mp(p1);
                      end
                    else if (p1.resultdef.typ=objectdef) then
                      { so we can create the correct  method pointer again in case
                        this is a "objectprocvar:=@classname.method" expression }
                      tloadnode(p2).symtable:=tobjectdef(p1.resultdef).symtable
                    else
                      p1.free; // no nil needed
                  end;
              end;
             p1:=p2;

             { no postfix operators }
             again:=false;
           end
         else
           begin
             para:=nil;
             if anon_inherited then
              begin
                if not assigned(current_procinfo) then
                  internalerror(200305054);
                for i:=0 to current_procinfo.procdef.paras.count-1 do
                  begin
                    currpara:=tparavarsym(current_procinfo.procdef.paras[i]);
                    if not(vo_is_hidden_para in currpara.varoptions) then
                      begin
                        { inheritance by msgint? }
                        if assigned(srdef) then
                          { anonymous inherited via msgid calls only require a var parameter for
                            both methods, so we need some type casting here }
                          para:=ccallparanode.create(ctypeconvnode.create_internal(ctypeconvnode.create_internal(
                            cloadnode.create(currpara,currpara.owner),cformaltype),tparavarsym(tprocdef(srdef).paras[i]).vardef),
                          para)
                        else
                          para:=ccallparanode.create(cloadnode.create(currpara,currpara.owner),para);
                      end;
                 end;
              end
             else
              begin
                if try_to_consume(_LKLAMMER) then
                 begin
                   para:=parse_paras(false,false,_RKLAMMER);
                   consume(_RKLAMMER);
                 end;
              end;
             { indicate if this call was generated by a member and
               no explicit self is used, this is needed to determine
               how to handle a destructor call (PFV) }
             if membercall then
               include(callflags,cnf_member_call);
             if assigned(obj) then
               begin
                 if not (st.symtabletype in [ObjectSymtable,recordsymtable]) then
                   internalerror(200310031);
                 p1:=ccallnode.create(para,tprocsym(sym),obj.symtable,p1,callflags,spezcontext);
               end
             else
               p1:=ccallnode.create(para,tprocsym(sym),st,p1,callflags,spezcontext);
             { in case of calling an anonymous function we already know the concrete
               procdef that is going to be called }
             if (tprocsym(sym).ProcdefList.count=1) and (po_anonymous in tprocdef(tprocsym(sym).procdeflist[0]).procoptions) then
               tcallnode(p1).procdefinition:=tprocdef(tprocsym(sym).procdeflist[0]);
           end;
         afterassignment:=prevafterassn;
      end;


    procedure handle_procvar(pv : tprocvardef;var p2 : tnode);
      var
        hp,hp2 : tnode;
        hpp    : ^tnode;
        currprocdef : tprocdef;
      begin
        if not assigned(pv) then
         internalerror(200301121);
        if (m_tp_procvar in current_settings.modeswitches) or
           (m_mac_procvar in current_settings.modeswitches) then
         begin
           hp:=p2;
           hpp:=@p2;
           while assigned(hp) and
                 (hp.nodetype=typeconvn) do
            begin
              hp:=ttypeconvnode(hp).left;
              { save original address of the old tree so we can replace the node }
              hpp:=@hp;
            end;
           if (hp.nodetype=calln) and
              { a procvar can't have parameters! }
              not assigned(tcallnode(hp).left) then
            begin
              currprocdef:=tcallnode(hp).symtableprocentry.Find_procdef_byprocvardef(pv);
              if assigned(currprocdef) then
               begin
                 hp2:=cloadnode.create_procvar(tprocsym(tcallnode(hp).symtableprocentry),currprocdef,tcallnode(hp).symtableproc);
                 if (po_methodpointer in pv.procoptions) then
                   tloadnode(hp2).set_mp(tcallnode(hp).methodpointer.getcopy);
                 hp.free;
                 hp := nil;
                 { replace the old callnode with the new loadnode }
                 hpp^:=hp2;
               end;
            end;
         end;
      end;


    procedure handle_funcref(fr:tobjectdef;var p2:tnode);
      var
        hp,hp2 : tnode;
        hpp    : ^tnode;
        currprocdef : tprocdef;
      begin
        if not assigned(fr) then
          internalerror(2022032401);
        if not is_invokable(fr) then
          internalerror(2022032402);
        if (m_tp_procvar in current_settings.modeswitches) or
           (m_mac_procvar in current_settings.modeswitches) then
         begin
           hp:=p2;
           hpp:=@p2;
           while assigned(hp) and
                 (hp.nodetype=typeconvn) do
            begin
              hp:=ttypeconvnode(hp).left;
              { save original address of the old tree so we can replace the node }
              hpp:=@hp;
            end;
           if (hp.nodetype=calln) and
              { a procvar can't have parameters! }
              not assigned(tcallnode(hp).left) then
            begin
              currprocdef:=tcallnode(hp).symtableprocentry.Find_procdef_byfuncrefdef(fr);
              if assigned(currprocdef) then
               begin
                 hp2:=cloadnode.create_procvar(tprocsym(tcallnode(hp).symtableprocentry),currprocdef,tcallnode(hp).symtableproc);
                 hp.free;
                 hp := nil;
                 { replace the old callnode with the new loadnode }
                 hpp^:=hp2;
               end;
            end;
         end;
      end;


    { maps a compound assignment token to the equivalent binary operator node type }
    function compound_assign_op(t: ttoken): tnodetype;
      begin
        case t of
          _PLUSASN  : result:=addn;
          _MINUSASN : result:=subn;
          _STARASN  : result:=muln;
          _SLASHASN : result:=slashn;
          _ANDASN   : result:=andn;
          _ORASN    : result:=orn;
          _XORASN   : result:=xorn;
          _MODASN   : result:=modn;
          _DIVASN   : result:=divn;
          _SHLASN   : result:=shln;
          _SHRASN   : result:=shrn;
          else        result:=errorn;
        end;
      end;


    { unleashed-mode expansion of `prop OP= rhs` into `prop := prop OP rhs`,
      issuing the getter and setter calls explicitly so the rewrite is the
      same node tree as if the user had typed it out }
    procedure handle_property_compound_assign(propsym: tpropertysym; st: TSymtable; var p1: tnode);
      var
        pal_r, pal_w : tpropaccesslist;
        instance_for_write : tnode;
        rhs, combined : tnode;
        op : tnodetype;
        op_token : ttoken;
        sym : tsym;
        callflags : tcallnodeflags;
        membercall : boolean;
      begin
        propsym.getpropaccesslist(palt_read,pal_r);
        propsym.getpropaccesslist(palt_write,pal_w);
        op_token:=current_scanner.token;
        op:=compound_assign_op(op_token);
        // C-style compound operators still require {$coperators on}
        if (op_token in [_PLUSASN,_MINUSASN,_STARASN,_SLASHASN]) and
           not(cs_support_c_operators in current_settings.moduleswitches) then
          Message(parser_e_coperators_off);
        { duplicate the instance reference for the setter; the read access
          will consume the original p1 }
        instance_for_write:=p1.getcopy;
        sym:=pal_r.firstsym^.sym;
        case sym.typ of
          fieldvarsym :
            begin
              if not handle_staticfield_access(sym,p1) then
                propaccesslist_to_node(p1,st,pal_r);
              include(p1.flags,nf_isproperty);
            end;
          procsym :
            begin
              callflags:=[];
              membercall:=maybe_load_methodpointer(st,p1);
              if membercall then
                include(callflags,cnf_member_call);
              p1:=ccallnode.create(nil,tprocsym(sym),st,p1,callflags,nil);
              addsymref(sym);
              include(p1.flags,nf_isproperty);
            end;
          else
            begin
              p1.free;
              p1:=cerrornode.create;
              instance_for_write.free;
              Message(parser_e_no_procedure_to_access_property);
              exit;
            end;
        end;
        consume(op_token);
        rhs:=comp_expr([ef_accept_equal]);
        case op of
          divn,modn :
            combined:=cmoddivnode.create(op,p1,rhs);
          shln,shrn :
            combined:=cshlshrnode.create(op,p1,rhs);
          else
            combined:=caddnode.create(op,p1,rhs);
        end;
        sym:=pal_w.firstsym^.sym;
        case sym.typ of
          procsym :
            begin
              callflags:=[];
              membercall:=maybe_load_methodpointer(st,instance_for_write);
              if membercall then
                include(callflags,cnf_member_call);
              instance_for_write:=ccallnode.create(nil,tprocsym(sym),st,instance_for_write,callflags,nil);
              addsymref(sym);
              tcallnode(instance_for_write).left:=ccallparanode.create(combined,tcallnode(instance_for_write).left);
              include(instance_for_write.flags,nf_isproperty);
              p1:=instance_for_write;
            end;
          fieldvarsym :
            begin
              if not handle_staticfield_access(sym,instance_for_write) then
                propaccesslist_to_node(instance_for_write,st,pal_w);
              include(instance_for_write.flags,nf_isproperty);
              p1:=cassignmentnode.create(instance_for_write,combined);
            end;
          else
            begin
              combined.free;
              instance_for_write.free;
              p1:=cerrornode.create;
              Message(parser_e_no_procedure_to_access_property);
            end;
        end;
      end;


    { unleashed-mode rewrite of `inc(prop, n)` / `dec(prop, n)` into a setter
      call carrying `getter + n` (or `getter - n`). Returns nil if the input
      isn't a procsym-getter call to a non-indexed read+write property; the
      caller falls back to the standard inline path in that case.
      with valuekind ipv_pre/ipv_post the rewrite also yields a value through
      a temp: the updated one (pre) or the one read before the update (post) }
    function try_inc_dec_property_rewrite(getter_call: tcallnode; delta: tnode; is_dec: boolean; valuekind: tincdecpropvalue): tnode;
      var
        propsym : tpropertysym;
        owner_st : TSymtable;
        sym : tsym;
        pal_r, pal_w : tpropaccesslist;
        i : longint;
        instance, combined : tnode;
        op : tnodetype;
        setter_proc : tprocsym;
        callflags : tcallnodeflags;
        membercall : boolean;
        setter_node : tnode;
        valtmp : ttempcreatenode;
        newstatement : tstatementnode;
        newblock : tblocknode;
        setter_arg : tnode;
      begin
        result:=nil;
        propsym:=nil;
        if not assigned(getter_call.symtableprocentry) then
          exit;
        owner_st:=getter_call.symtableprocentry.owner;
        if not assigned(owner_st) then
          exit;
        for i:=0 to owner_st.symlist.count-1 do
          begin
            sym:=tsym(owner_st.symlist[i]);
            if sym.typ<>propertysym then
              continue;
            if tpropertysym(sym).getpropaccesslist(palt_read,pal_r) and
               assigned(pal_r.firstsym) and
               (pal_r.firstsym^.sym=getter_call.symtableprocentry) then
              begin
                propsym:=tpropertysym(sym);
                break;
              end;
          end;
        if not assigned(propsym) then
          exit;
        if (ppo_hasparameters in propsym.propoptions) or
           (ppo_indexed in propsym.propoptions) then
          begin
            Message1(type_e_property_modify_indexed,propsym.realname);
            getter_call.free;
            if assigned(delta) then
              delta.free;
            result:=cerrornode.create;
            exit;
          end;
        { mirror the type set stock inc/dec accept on regular variables }
        if not((propsym.propdef.typ in [enumdef,pointerdef]) or
               is_ordinal(propsym.propdef) or
               is_currency(propsym.propdef)) then
          begin
            Message2(type_e_inc_dec_property_type,propsym.realname,propsym.propdef.typename);
            getter_call.free;
            if assigned(delta) then
              delta.free;
            result:=cerrornode.create;
            exit;
          end;
        if not propsym.getpropaccesslist(palt_write,pal_w) then
          begin
            Message1(type_e_property_no_writer,propsym.realname);
            getter_call.free;
            if assigned(delta) then
              delta.free;
            result:=cerrornode.create;
            exit;
          end;
        if pal_w.firstsym^.sym.typ<>procsym then
          exit;
        setter_proc:=tprocsym(pal_w.firstsym^.sym);
        if not assigned(getter_call.methodpointer) then
          exit;
        instance:=getter_call.methodpointer.getcopy;
        if is_dec then
          op:=subn
        else
          op:=addn;
        if not assigned(delta) then
          delta:=cordconstnode.create(1,sinttype,true);
        newblock:=nil;
        valtmp:=nil;
        if valuekind<>ipv_none then
          begin
            newblock:=internalstatements(newstatement);
            valtmp:=ctempcreatenode.create(propsym.propdef,propsym.propdef.size,tt_persistent,true);
            addstatement(newstatement,valtmp);
          end;
        if valuekind=ipv_post then
          { capture the getter value before the update; the arithmetic below
            then runs on the temp instead of a second getter call }
          addstatement(newstatement,cassignmentnode.create(ctemprefnode.create(valtmp),getter_call));
        { addn does not accept enum + int directly. For enum properties cast
          the getter result to an ordinal type, do the arithmetic, then cast
          the sum back to the enum type for the setter call. Pointer and
          plain ordinal property types take the native addn path. }
        if valuekind=ipv_post then
          combined:=ctemprefnode.create(valtmp)
        else
          combined:=getter_call;
        if propsym.propdef.typ=enumdef then
          begin
            combined:=ctypeconvnode.create_internal(combined,sinttype);
            combined:=caddnode.create(op,combined,delta);
            combined:=ctypeconvnode.create_internal(combined,propsym.propdef);
          end
        else
          combined:=caddnode.create(op,combined,delta);
        if valuekind=ipv_pre then
          begin
            { the setter writes the already-updated temp, which is also the
              yielded value }
            addstatement(newstatement,cassignmentnode.create(ctemprefnode.create(valtmp),combined));
            setter_arg:=ctemprefnode.create(valtmp);
          end
        else
          setter_arg:=combined;
        callflags:=[];
        membercall:=maybe_load_methodpointer(getter_call.symtableproc,instance);
        if membercall then
          include(callflags,cnf_member_call);
        setter_node:=ccallnode.create(nil,setter_proc,getter_call.symtableproc,instance,callflags,nil);
        addsymref(setter_proc);
        tcallnode(setter_node).left:=ccallparanode.create(setter_arg,tcallnode(setter_node).left);
        include(setter_node.flags,nf_isproperty);
        if valuekind=ipv_none then
          result:=setter_node
        else
          begin
            addstatement(newstatement,setter_node);
            addstatement(newstatement,ctempdeletenode.create_normal_temp(valtmp));
            addstatement(newstatement,ctemprefnode.create(valtmp));
            result:=newblock;
          end;
      end;


    { parse `PreInc(x[, n])` / `PostInc` / `PreDec` / `PostDec`; the parser
      only reaches this when no user symbol of that name is in scope. the
      identifier itself is not yet consumed }
    function inline_prepost_incdec(innr: tinlinenumber): tnode;
      var
        p1,p2 : tnode;
        is_dec : boolean;
        valuekind : tincdecpropvalue;
      begin
        consume(_ID);
        consume(_LKLAMMER);
        p1:=comp_expr([ef_accept_equal]);
        if try_to_consume(_COMMA) then
          p2:=comp_expr([ef_accept_equal])
        else
          p2:=nil;
        consume(_RKLAMMER);
        is_dec:=(innr=in_predec_x) or (innr=in_postdec_x);
        if (innr=in_postinc_x) or (innr=in_postdec_x) then
          valuekind:=ipv_post
        else
          valuekind:=ipv_pre;
        { a procsym-getter property goes through the getter+setter rewrite }
        if (nf_isproperty in p1.flags) and
           (p1.nodetype=calln) then
          begin
            result:=try_inc_dec_property_rewrite(tcallnode(p1),p2,is_dec,valuekind);
            if assigned(result) then
              exit;
          end;
        if assigned(p2) then
          p2:=ccallparanode.create(p2,nil);
        result:=cinlinenode.create(innr,false,ccallparanode.create(p1,p2));
      end;


    type
      { one SwapValues operand. anything below it that must not be evaluated
        twice (the instance, the property parameters, the address of a plain
        lvalue) is hoisted into a temp before the swap statements are built,
        so `n` can be copied freely for the read and the write }
      tswapoperand = record
        prop      : tpropertysym;  // nil for a plain addressable operand
        st        : TSymtable;     // symtable the accessors are reached through
        callflags : tcallnodeflags;
        n         : tnode;         // read template
        subs      : tnode;         // innermost subscript of a field-backed read
        def       : tdef;
      end;


    { the property in `st` whose read accessor is `getter`, nil if there is none }
    function find_property_for_getter(st: TSymtable; getter: tsym): tpropertysym;
      var
        i : longint;
        sym : tsym;
        pal : tpropaccesslist;
      begin
        result:=nil;
        if not assigned(st) or not assigned(st.symlist) or not assigned(getter) then
          exit;
        for i:=0 to st.symlist.count-1 do
          begin
            sym:=tsym(st.symlist[i]);
            if sym.typ<>propertysym then
              continue;
            if tpropertysym(sym).getpropaccesslist(palt_read,pal) and
               assigned(pal.firstsym) and (pal.firstsym^.sym=getter) then
              begin
                result:=tpropertysym(sym);
                break;
              end;
          end;
      end;


    { true when the subscript chain of the field-backed property read node `n`
      spells out exactly the fields of `pal`; pal lists the fields
      innermost-first, the node chain is outermost-first }
    function pal_matches_subscripts(pal: tpropaccesslist; n: tnode): boolean;
      var
        chain : tfplist;
        plist : ppropaccesslistitem;
        p : tnode;
        i : longint;
      begin
        result:=false;
        chain:=tfplist.create;
        p:=n;
        while p.nodetype=subscriptn do
          begin
            chain.add(tsubscriptnode(p).vs);
            p:=tsubscriptnode(p).left;
          end;
        plist:=pal.firstsym;
        i:=chain.count;
        while assigned(plist) and (i>0) do
          begin
            if not(plist^.sltype in [sl_load,sl_subscript]) or
               (plist^.sym<>tsym(chain[i-1])) then
              break;
            dec(i);
            plist:=plist^.next;
          end;
        result:=(i=0) and not assigned(plist);
        chain.free;
      end;


    { the property whose read accessor produced the field-backed read node `n`,
      searched in the class hierarchy (or record) of the instance below the
      subscript chain; `subs` returns the innermost subscript, whose left side
      is the instance }
    function find_property_for_fields(n: tnode; out st: TSymtable; out subs: tnode): tpropertysym;
      var
        p : tnode;
        objdef : tobjectdef;
        srst : TSymtable;
        i : longint;
        sym : tsym;
        pal : tpropaccesslist;
      begin
        result:=nil;
        st:=nil;
        subs:=n;
        while tsubscriptnode(subs).left.nodetype=subscriptn do
          subs:=tsubscriptnode(subs).left;
        p:=tsubscriptnode(subs).left;
        if not assigned(p.resultdef) then
          exit;
        objdef:=nil;
        srst:=nil;
        if p.resultdef.typ=objectdef then
          objdef:=tobjectdef(p.resultdef)
        else if p.resultdef.typ=recorddef then
          srst:=trecorddef(p.resultdef).symtable
        else
          exit;
        repeat
          if assigned(objdef) then
            srst:=objdef.symtable;
          for i:=0 to srst.symlist.count-1 do
            begin
              sym:=tsym(srst.symlist[i]);
              if sym.typ<>propertysym then
                continue;
              if tpropertysym(sym).getpropaccesslist(palt_read,pal) and
                 pal_matches_subscripts(pal,n) then
                begin
                  result:=tpropertysym(sym);
                  st:=srst;
                  exit;
                end;
            end;
          if assigned(objdef) then
            objdef:=objdef.childof
          else
            exit;
        until not assigned(objdef);
      end;


    { true when the read and write access lists of `prop` name the same fields }
    function same_swap_accessors(prop: tpropertysym): boolean;
      var
        pal_r,pal_w : tpropaccesslist;
        pr,pw : ppropaccesslistitem;
      begin
        result:=false;
        if not prop.getpropaccesslist(palt_read,pal_r) or
           not prop.getpropaccesslist(palt_write,pal_w) then
          exit;
        pr:=pal_r.firstsym;
        pw:=pal_w.firstsym;
        while assigned(pr) and assigned(pw) do
          begin
            if not(pr^.sltype in [sl_load,sl_subscript]) or
               not(pw^.sltype in [sl_load,sl_subscript]) or
               (pr^.sym<>pw^.sym) then
              exit;
            pr:=pr^.next;
            pw:=pw^.next;
          end;
        result:=not assigned(pr) and not assigned(pw);
      end;


    { classify one SwapValues operand; false on a hard error (reported) }
    function analyze_swap_operand(n: tnode; out op: tswapoperand): boolean;
      var
        pal_w : tpropaccesslist;
        haswriter : boolean;
      begin
        result:=true;
        fillchar(op,sizeof(op),0);
        op.n:=n;
        op.def:=n.resultdef;
        if (n.nodetype=calln) and (nf_isproperty in n.flags) then
          begin
            op.st:=tcallnode(n).symtableproc;
            op.prop:=find_property_for_getter(op.st,tcallnode(n).symtableprocentry);
            if not assigned(op.prop) and assigned(tcallnode(n).symtableprocentry) then
              begin
                op.st:=tcallnode(n).symtableprocentry.owner;
                op.prop:=find_property_for_getter(op.st,tcallnode(n).symtableprocentry);
              end;
            { unrecognized shape: leave the operand to the in-place diagnosis }
            if not assigned(op.prop) then
              exit;
            op.callflags:=tcallnode(n).callnodeflags*[cnf_member_call];
            op.def:=op.prop.propdef;
          end
        else if (n.nodetype=subscriptn) and (nf_isproperty in n.flags) then
          begin
            op.prop:=find_property_for_fields(n,op.st,op.subs);
            if not assigned(op.prop) then
              begin
                op.subs:=nil;
                exit;
              end;
            op.def:=op.prop.propdef;
          end
        else
          exit;
        haswriter:=op.prop.getpropaccesslist(palt_write,pal_w) and
          assigned(pal_w.firstsym) and
          (pal_w.firstsym^.sym.typ in [procsym,fieldvarsym]);
        if not haswriter then
          begin
            MessagePos1(n.fileinfo,type_e_property_no_writer,op.prop.realname);
            result:=false;
            exit;
          end;
        { a field-backed property reading and writing the same field is an
          addressable lvalue in property clothing: strip the property marks
          so it takes the in-place swap like a direct field access }
        if assigned(op.subs) and same_swap_accessors(op.prop) then
          begin
            exclude(n.flags,nf_no_lvalue);
            exclude(n.flags,nf_isproperty);
            op.prop:=nil;
            op.subs:=nil;
          end;
      end;


    { evaluate `n` once into a value temp }
    procedure hoist_swap_value(var n: tnode; var stmt: tstatementnode; temps: tfplist);
      var
        tmp : ttempcreatenode;
      begin
        tmp:=ctempcreatenode.create(n.resultdef,n.resultdef.size,tt_persistent,true);
        addstatement(stmt,tmp);
        addstatement(stmt,cassignmentnode.create(ctemprefnode.create(tmp),n));
        temps.add(tmp);
        n:=ctemprefnode.create(tmp);
        { the surrounding tree is already typechecked and will not descend
          into the replacement, so typecheck it here }
        do_typecheckpass(n);
      end;


    { capture the address of `n` once and replace it with a typed dereference }
    procedure hoist_swap_addr(var n: tnode; var stmt: tstatementnode; temps: tfplist);
      var
        ptr : ttempcreatenode;
        deref : tnode;
        def : tdef;
      begin
        def:=n.resultdef;
        ptr:=ctempcreatenode.create(voidpointertype,voidpointertype.size,tt_persistent,true);
        addstatement(stmt,ptr);
        addstatement(stmt,cassignmentnode.create(ctemprefnode.create(ptr),
          caddrnode.create_internal(n)));
        temps.add(ptr);
        deref:=cderefnode.create(ctemprefnode.create(ptr));
        inserttypeconv_internal(deref,def);
        n:=deref;
        { the surrounding tree is already typechecked and will not descend
          into the replacement, so typecheck it here }
        do_typecheckpass(n);
      end;


    { evaluate an accessor instance expression once. pointer-like instances
      (class, interface) are captured by value; an addressable record or
      object instance by address, so the write goes to the original }
    procedure hoist_swap_instance(var n: tnode; var stmt: tstatementnode; temps: tfplist);
      begin
        if node_complexity(n)<=1 then
          exit;
        if not is_implicit_pointer_object_type(n.resultdef) and
           (n.resultdef.typ<>classrefdef) and
           valid_for_addr(n,false) then
          hoist_swap_addr(n,stmt,temps)
        else
          hoist_swap_value(n,stmt,temps);
      end;


    { emit the hoist code for one operand }
    procedure prepare_swap_operand(var op: tswapoperand; var stmt: tstatementnode; temps: tfplist);
      var
        para : tcallparanode;
      begin
        if not assigned(op.prop) then
          begin
            { an addressable operand is read and written through its address so
              that a side-effecting index expression in it runs once }
            if (node_complexity(op.n)>3) and valid_for_addr(op.n,false) then
              hoist_swap_addr(op.n,stmt,temps);
            exit;
          end;
        if assigned(op.subs) then
          hoist_swap_instance(tsubscriptnode(op.subs).left,stmt,temps)
        else
          begin
            if assigned(tcallnode(op.n).methodpointer) then
              hoist_swap_instance(tcallnode(op.n).methodpointer,stmt,temps);
            para:=tcallparanode(tcallnode(op.n).left);
            while assigned(para) do
              begin
                if not(assigned(para.parasym) and
                       (vo_is_hidden_para in para.parasym.varoptions)) and
                   (node_complexity(para.left)>1) then
                  hoist_swap_value(para.left,stmt,temps);
                para:=tcallparanode(para.right);
              end;
          end;
        MessagePos1(op.n.fileinfo,type_h_swapvalues_not_inplace,op.prop.realname);
      end;


    function swap_operand_read(const op: tswapoperand): tnode;
      begin
        result:=op.n.getcopy;
      end;


    function swap_operand_write(const op: tswapoperand; value: tnode): tnode;
      var
        pal_w : tpropaccesslist;
        sym : tsym;
        instance,paras : tnode;
        getter,setter : tcallnode;
        para : tcallparanode;
        vis : tfplist;
        i : longint;
        callflags : tcallnodeflags;
      begin
        if not assigned(op.prop) then
          begin
            result:=cassignmentnode.create(op.n.getcopy,value);
            exit;
          end;
        op.prop.getpropaccesslist(palt_write,pal_w);
        sym:=pal_w.firstsym^.sym;
        if assigned(op.subs) then
          instance:=tsubscriptnode(op.subs).left.getcopy
        else
          begin
            getter:=tcallnode(op.n);
            if assigned(getter.methodpointer) then
              instance:=getter.methodpointer.getcopy
            else
              instance:=nil;
          end;
        if sym.typ=procsym then
          begin
            { the getter's visible parameters (array property indexes, the
              `index N` constant) carry over to the setter; the hidden ones
              belong to the getter alone }
            paras:=nil;
            if not assigned(op.subs) then
              begin
                vis:=tfplist.create;
                para:=tcallparanode(tcallnode(op.n).left);
                while assigned(para) do
                  begin
                    if not(assigned(para.parasym) and
                           (vo_is_hidden_para in para.parasym.varoptions)) then
                      vis.add(para);
                    para:=tcallparanode(para.right);
                  end;
                for i:=vis.count-1 downto 0 do
                  paras:=ccallparanode.create(tcallparanode(vis[i]).left.getcopy,paras);
                vis.free;
              end;
            callflags:=op.callflags;
            if maybe_load_methodpointer(op.st,instance) then
              include(callflags,cnf_member_call);
            setter:=ccallnode.create(paras,tprocsym(sym),op.st,instance,callflags,nil);
            addsymref(sym);
            setter.left:=ccallparanode.create(value,setter.left);
            include(setter.flags,nf_isproperty);
            result:=setter;
          end
        else
          begin
            if not handle_staticfield_access(sym,instance) then
              propaccesslist_to_node(instance,op.st,pal_w);
            include(instance.flags,nf_isproperty);
            result:=cassignmentnode.create(instance,value);
          end;
      end;


    function try_swapvalues_property_expand(paras: tnode): tnode;
      var
        p1,p2 : tcallparanode;
        n1,n2 : tnode;
        op1,op2 : tswapoperand;
        newblock : tblocknode;
        stmt : tstatementnode;
        tmp : ttempcreatenode;
        temps : tfplist;
        i : longint;
      begin
        result:=nil;
        { exactly two parameters; parse_paras hands them back last one first }
        if paras.nodetype<>callparan then
          exit;
        p2:=tcallparanode(paras);
        if not assigned(p2.right) or (p2.right.nodetype<>callparan) or
           assigned(tcallparanode(p2.right).right) then
          exit;
        p1:=tcallparanode(p2.right);
        n1:=p1.left;
        n2:=p2.left;
        if (n1.nodetype=errorn) or (n2.nodetype=errorn) or
           not assigned(n1.resultdef) or not assigned(n2.resultdef) then
          exit;
        { a generic body is not typechecked; the specialization re-parses and
          gets the expansion with concrete types }
        if assigned(current_procinfo) and
           (df_generic in current_procinfo.procdef.defoptions) then
          exit;
        if not analyze_swap_operand(n1,op1) or
           not analyze_swap_operand(n2,op2) then
          begin
            paras.free;
            result:=cerrornode.create;
            exit;
          end;
        if not assigned(op1.prop) and not assigned(op2.prop) then
          exit;
        if not equal_defs(op1.def,op2.def) then
          begin
            CGMessagePos(n2.fileinfo,type_e_mismatch);
            paras.free;
            result:=cerrornode.create;
            exit;
          end;
        p1.left:=nil;
        p2.left:=nil;
        paras.free;
        temps:=tfplist.create;
        newblock:=internalstatements(stmt);
        prepare_swap_operand(op1,stmt,temps);
        prepare_swap_operand(op2,stmt,temps);
        tmp:=ctempcreatenode.create(op1.def,op1.def.size,tt_persistent,true);
        addstatement(stmt,tmp);
        addstatement(stmt,cassignmentnode.create(ctemprefnode.create(tmp),
          swap_operand_read(op1)));
        addstatement(stmt,swap_operand_write(op1,swap_operand_read(op2)));
        addstatement(stmt,swap_operand_write(op2,ctemprefnode.create(tmp)));
        addstatement(stmt,ctempdeletenode.create(tmp));
        for i:=temps.count-1 downto 0 do
          addstatement(stmt,ctempdeletenode.create(ttempcreatenode(temps[i])));
        temps.free;
        { the operand templates were only copied from }
        op1.n.free;
        op2.n.free;
        result:=newblock;
      end;


    { the following procedure handles the access to a property symbol }
    procedure handle_propertysym(propsym : tpropertysym;st : TSymtable;var p1 : tnode);
      var
         paras : tnode;
         p2    : tnode;
         membercall : boolean;
         callflags  : tcallnodeflags;
         propaccesslist : tpropaccesslist;
         sym: tsym;
      begin
         { property parameters? read them only if the property really }
         { has parameters                                             }
         paras:=nil;
         if (ppo_hasparameters in propsym.propoptions) then
           begin
             if try_to_consume(_LECKKLAMMER) then
               begin
                 paras:=parse_paras(false,false,_RECKKLAMMER);
                 consume(_RECKKLAMMER);
               end;
           end;
         { indexed property }
         if (ppo_indexed in propsym.propoptions) then
           begin
             p2:=cordconstnode.create(propsym.index,propsym.indexdef,true);
             paras:=ccallparanode.create(p2,paras);
           end;
         { compound assignment on a plain read+write property in unleashed mode }
         if (m_unleashed in current_settings.modeswitches) and
            (current_scanner.token in [_PLUSASN,_MINUSASN,_STARASN,_SLASHASN,
                                       _ANDASN,_ORASN,_XORASN,_MODASN,_DIVASN,
                                       _SHLASN,_SHRASN]) then
           begin
             if (ppo_hasparameters in propsym.propoptions) or
                (ppo_indexed in propsym.propoptions) then
               begin
                 Message1(type_e_property_modify_indexed,propsym.realname);
                 consume(current_scanner.token);
                 comp_expr([ef_accept_equal]).free;
                 if assigned(paras) then
                   paras.free;
                 p1.free;
                 p1:=cerrornode.create;
                 exit;
               end;
             if not propsym.getpropaccesslist(palt_write,propaccesslist) then
               begin
                 Message1(type_e_property_no_writer,propsym.realname);
                 consume(current_scanner.token);
                 comp_expr([ef_accept_equal]).free;
                 if assigned(paras) then
                   paras.free;
                 p1.free;
                 p1:=cerrornode.create;
                 exit;
               end;
             if not propsym.getpropaccesslist(palt_read,propaccesslist) then
               begin
                 Message(parser_e_no_procedure_to_access_property);
                 consume(current_scanner.token);
                 comp_expr([ef_accept_equal]).free;
                 if assigned(paras) then
                   paras.free;
                 p1.free;
                 p1:=cerrornode.create;
                 exit;
               end;
             handle_property_compound_assign(propsym,st,p1);
             exit;
           end;
         { we need only a write property if a := follows }
         { if not(afterassignment) and not(in_args) then }
         if current_scanner.token=_ASSIGNMENT then
           begin
              if propsym.getpropaccesslist(palt_write,propaccesslist) then
                begin
                   sym:=propaccesslist.firstsym^.sym;
                   case sym.typ of
                     procsym :
                       begin
                         callflags:=[];
                         { generate the method call }
                         membercall:=maybe_load_methodpointer(st,p1);
                         if membercall then
                           include(callflags,cnf_member_call);
                         p1:=ccallnode.create(paras,tprocsym(sym),st,p1,callflags,nil);
                         addsymref(sym);
                         paras:=nil;
                         consume(_ASSIGNMENT);
                         { read the expression }
                         if propsym.propdef.typ=procvardef then
                           getprocvardef:=tprocvardef(propsym.propdef)
                         else if is_invokable(propsym.propdef) then
                           getfuncrefdef:=tobjectdef(propsym.propdef);
                         p2:=comp_expr([ef_accept_equal]);
                         if assigned(getprocvardef) then
                           handle_procvar(getprocvardef,p2)
                         else if assigned(getfuncrefdef) then
                           handle_funcref(getfuncrefdef,p2);
                         tcallnode(p1).left:=ccallparanode.create(p2,tcallnode(p1).left);
                         { mark as property, both the tcallnode and the real call block }
                         include(p1.flags,nf_isproperty);
                         getprocvardef:=nil;
                         getfuncrefdef:=nil;
                       end;
                     fieldvarsym :
                       begin
                         { generate access code }
                         if not handle_staticfield_access(sym,p1) then
                           propaccesslist_to_node(p1,st,propaccesslist);
                         include(p1.flags,nf_isproperty);
                         consume(_ASSIGNMENT);
                         { read the expression }
                         if propsym.propdef.typ=procvardef then
                           getprocvardef:=tprocvardef(propsym.propdef)
                         else if is_invokable(propsym.propdef) then
                           getfuncrefdef:=tobjectdef(propsym.propdef);
                         p2:=comp_expr([ef_accept_equal]);
                         if assigned(getprocvardef) then
                           handle_procvar(getprocvardef,p2)
                         else if assigned(getfuncrefdef) then
                           handle_funcref(getfuncrefdef,p2);
                         getprocvardef:=nil;
                         getfuncrefdef:=nil;
                         p1:=cassignmentnode.create(p1,p2);
                      end
                    else
                      begin
                        p1:=cerrornode.create;
                        Message(parser_e_no_procedure_to_access_property);
                      end;
                  end;
                end
              else
                begin
                   p1:=cerrornode.create;
                   if propsym.getpropaccesslist(palt_read,propaccesslist) then
                     Message1(parser_e_property_is_read_only,propsym.realname)
                   else
                     Message(parser_e_no_procedure_to_access_property);
                end;
           end
         else
           begin
              if propsym.getpropaccesslist(palt_read,propaccesslist) then
                begin
                   sym := propaccesslist.firstsym^.sym;
                   case sym.typ of
                     fieldvarsym :
                       begin
                         { generate access code }
                         if not handle_staticfield_access(sym,p1) then
                           propaccesslist_to_node(p1,st,propaccesslist);
                         include(p1.flags,nf_isproperty);
                         { catch expressions like "(propx):=1;" }
                         include(p1.flags,nf_no_lvalue);
                       end;
                     procsym :
                       begin
                          callflags:=[];
                          { generate the method call }
                          membercall:=maybe_load_methodpointer(st,p1);
                          if membercall then
                            include(callflags,cnf_member_call);
                          p1:=ccallnode.create(paras,tprocsym(sym),st,p1,callflags,nil);
                          paras:=nil;
                          include(p1.flags,nf_isproperty);
                          include(p1.flags,nf_no_lvalue);
                       end
                     else
                       begin
                          p1:=cerrornode.create;
                          Message(type_e_mismatch);
                       end;
                  end;
                end
              else
                begin
                   { error, no function to read property }
                   p1:=cerrornode.create;
                   if propsym.getpropaccesslist(palt_write,propaccesslist) then
                     Message1(parser_e_property_is_write_only,propsym.realname)
                   else
                     Message(parser_e_no_procedure_to_access_property);
                end;
           end;
        { release paras if not used }
        if assigned(paras) then
          paras.free; // no nil needed
      end;


    { the ID token has to be consumed before calling this function }
    procedure do_member_read(structh:tabstractrecorddef;getaddr:boolean;sym:tsym;var p1:tnode;var again:boolean;callflags:tcallnodeflags;spezcontext:tspecializationcontext);
      var
        isclassref:boolean;
        isrecordtype:boolean;
        isobjecttype:boolean;
        ishelpertype:boolean;
      begin
         if sym=nil then
           begin
              { current_scanner.pattern is still valid unless
              there is another ID just after the ID of sym }
              Message1(sym_e_id_no_member,current_scanner.orgpattern);
              p1.free;
              p1:=cerrornode.create;
              { try to clean up }
              spezcontext.free;
              spezcontext := nil;
              again:=false;
           end
         else
           begin
              if assigned(p1) then
               begin
                 if not assigned(p1.resultdef) then
                   do_typecheckpass(p1);
                 isclassref:=(p1.resultdef.typ=classrefdef);
                 isrecordtype:=(p1.nodetype=typen) and (p1.resultdef.typ=recorddef);
                 isobjecttype:=(p1.nodetype=typen) and is_object(p1.resultdef);
                 ishelpertype:=is_objectpascal_helper(tdef(sym.owner.defowner)) and
                               (p1.nodetype=typen) and
                               not is_objectpascal_helper(p1.resultdef)
                                {and
                               not (cnf_inherited in callflags)};
               end
              else
                begin
                  isclassref:=false;
                  isrecordtype:=false;
                  isobjecttype:=false;
                  ishelpertype:=false;
                end;

              if assigned(spezcontext) and not (sym.typ=procsym) then
                internalerror(2015091801);

              { we assume, that only procsyms and varsyms are in an object }
              { symbol table, for classes, properties are allowed          }
              case sym.typ of
                 procsym:
                   begin
                      do_proc_call(sym,sym.owner,structh,
                                   (getaddr and not(current_scanner.token in [_CARET,_POINT])),
                                   again,p1,callflags,spezcontext);
                      { we need to know which procedure is called }
                      do_typecheckpass(p1);

                      { We are loading... }
                      if p1.nodetype=loadn then
                       begin
                         { an instance method }
                         if not (po_classmethod in tloadnode(p1).procdef.procoptions) and
                             { into a method pointer (not just taking a code address) }
                             not getaddr and
                             { and the selfarg is... }
                             (
                               { either a record/object/helper type, }
                               not assigned(tloadnode(p1).left) or
                               { or a class/metaclass type, or a class reference }
                               (tloadnode(p1).left.resultdef.typ=classrefdef)
                             ) then
                           Message(parser_e_only_class_members_via_class_ref);
                       end
                      { calling using classref? }
                      else if (
                            isclassref or
                            (
                              (isobjecttype or
                               isrecordtype or
                               ishelpertype) and
                              not (cnf_inherited in callflags)
                            )
                          ) and
                         (p1.nodetype=calln) and
                         assigned(tcallnode(p1).procdefinition) then
                        begin
                          if not isobjecttype then
                            begin
                              if not(po_classmethod in tcallnode(p1).procdefinition.procoptions) and
                                 not(tcallnode(p1).procdefinition.proctypeoption=potype_constructor) then
                                Message(parser_e_only_class_members_via_class_ref);
                            end
                          else
                            begin
                              { with objects, you can also do this:
                                  type
                                    tparent = object
                                      procedure test;
                                    end;

                                    tchild = object(tchild)
                                      procedure test;
                                    end;

                                    procedure tparent.test;
                                      begin
                                      end;

                                    procedure tchild.test;
                                      begin
                                        tparent.test;
                                      end;
                              }
                              if (tcallnode(p1).procdefinition.proctypeoption<>potype_constructor) and
                                 not(po_staticmethod in tcallnode(p1).procdefinition.procoptions) and
                                 (not assigned(current_structdef) or
                                  not def_is_related(current_structdef,structh)) then
                                begin
                                  p1.free;
                                  p1:=cerrornode.create;
                                  Message(parser_e_only_static_members_via_object_type);
                                  exit;
                                end;
                            end;
                          { in Java, constructors are not automatically inherited
                            -> calling a constructor from a parent type will create
                               an instance of that parent type! }
                          if is_javaclass(structh) and
                             (tcallnode(p1).procdefinition.proctypeoption=potype_constructor) and
                             (tcallnode(p1).procdefinition.owner.defowner<>find_real_class_definition(tobjectdef(structh),false)) then
                            Message(parser_e_java_no_inherited_constructor);
                          { Provide a warning if we try to create an instance of a
                            abstract class using the type name of that class. We
                            must not provide a warning if we use a "class of"
                            variable of that type though as we don't know the
                            type of the class
                            Note: structh might be Nil in case of a type helper }
                          if assigned(structh) and
                              (tcallnode(p1).procdefinition.proctypeoption=potype_constructor) and
                              (oo_is_abstract in structh.objectoptions) and
                              assigned(tcallnode(p1).methodpointer) and
                              (tcallnode(p1).methodpointer.nodetype=loadvmtaddrn) then
                            Message1(type_w_instance_abstract_class,structh.RttiName);
                        end
                   end;
                 fieldvarsym:
                   begin
                      if not handle_staticfield_access(sym,p1) then
                        begin
                          if isclassref then
                            if assigned(p1) and
                              (
                                is_self_node(p1) or
                                (assigned(current_procinfo) and (current_procinfo.get_normal_proc.procdef.no_self_node) and
                                (current_procinfo.procdef.struct=structh))) then
                              Message(parser_e_only_class_members)
                            else
                              Message(parser_e_only_class_members_via_class_ref);
                          p1:=csubscriptnode.create(sym,p1);
                        end;
                   end;
                 propertysym:
                   begin
                      if isclassref and not (sp_static in sym.symoptions) then
                        Message(parser_e_only_class_members_via_class_ref);
                      handle_propertysym(tpropertysym(sym),sym.owner,p1);
                   end;
                 typesym:
                   begin
                     p1.free;
                     if try_to_consume(_LKLAMMER) then
                      begin
                        p1:=comp_expr([ef_accept_equal]);
                        consume(_RKLAMMER);
                        p1:=ctypeconvnode.create_explicit(p1,ttypesym(sym).typedef);
                      end
                     else
                       begin
                         p1:=ctypenode.create(ttypesym(sym).typedef);
                         if (is_class(ttypesym(sym).typedef) or
                             is_objcclass(ttypesym(sym).typedef) or
                             is_javaclass(ttypesym(sym).typedef)) and
                            not(block_type in [bt_type,bt_const_type,bt_var_type]) then
                           p1:=cloadvmtaddrnode.create(p1);
                       end;
                   end;
                 constsym:
                   begin
                     p1.free;
                     p1:=genconstsymtree(tconstsym(sym));
                   end;
                 staticvarsym:
                   begin
                     { typed constant is a staticvarsym
                       now they are absolutevarsym }
                     p1.free;
                     p1:=cloadnode.create(sym,sym.Owner);
                   end;
                 absolutevarsym:
                   begin
                     p1.free;
                     p1:=nil;
                     { typed constants are absolutebarsyms now to handle storage properly }
                     propaccesslist_to_node(p1,nil,tabsolutevarsym(sym).ref);
                   end;
                 enumsym:
                   begin
                     { composablerecords scopes anonymous enum constants
                       to the surrounding record, so `TRec.kVal` reaches
                       them through this dot-access path. wrap as a
                       plain enum node, no carrier offset involved. }
                     p1.free;
                     p1:=genenumnode(tenumsym(sym));
                   end
                 else
                   internalerror(16);
              end;
           end;
      end;


    function handle_specialize_inline_specialization(var srsym:tsym;enforce_unit:boolean;out srsymtable:tsymtable;out spezcontext:tspecializationcontext):boolean;
      var
        spezdef : tdef;
      begin
        result:=false;
        spezcontext:=nil;
        srsymtable:=nil;
        if not assigned(srsym) then
          message1(sym_e_id_no_member,current_scanner.orgpattern)
        else
          if not (srsym.typ in [typesym,procsym]) then
            message(type_e_type_id_expected)
          else
            begin
              if srsym.typ=typesym then
                spezdef:=ttypesym(srsym).typedef
              else if tprocsym(srsym).procdeflist.count>0 then
                spezdef:=tdef(tprocsym(srsym).procdeflist[0])
              else
                spezdef:=nil;
              spezdef:=generate_specialization_phase1(spezcontext,spezdef,enforce_unit,srsym.realname,srsym.owner);
              case spezdef.typ of
                errordef:
                  begin
                    spezcontext.free;
                    spezcontext:=nil;
                    srsym:=generrorsym;
                  end;
                procdef:
                  begin
                    if block_type<>bt_body then
                      begin
                        message(parser_e_illegal_expression);
                        spezcontext.free;
                        spezcontext:=nil;
                        srsym:=generrorsym;
                      end
                    else
                      begin
                        srsym:=tprocdef(spezdef).procsym;
                        srsymtable:=srsym.owner;
                        result:=true;
                      end;
                  end;
                objectdef,
                recorddef,
                arraydef,
                procvardef:
                  begin
                    spezdef:=generate_specialization_phase2(spezcontext,tstoreddef(spezdef),false,'');
                    spezcontext.free;
                    spezcontext:=nil;
                    if spezdef<>generrordef then
                      begin
                        srsym:=spezdef.typesym;
                        srsymtable:=srsym.owner;
                        check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg);
                        result:=true;
                      end;
                  end;
                else
                  internalerror(2015070302);
              end;
            end;
      end;


    function handle_factor_typenode(hdef:tdef;getaddr:boolean;var again:boolean;sym:tsym;typeonly:boolean):tnode;
      var
        srsym : tsym;
        srsymtable : tsymtable;
        erroroutresult,
        isspecialize : boolean;
        spezcontext : tspecializationcontext;
        savedfilepos : tfileposinfo;
      begin
         spezcontext:=nil;
         if sym=nil then
           sym:=hdef.typesym;
         { allow Ordinal(Value) for type declarations since it
           can be an enumeration declaration or a set lke:
           (OrdinalType(const1)..OrdinalType(const2) }
         if (not typeonly or is_ordinal(hdef)) and
            try_to_consume(_LKLAMMER) then
          begin
            result:=comp_expr([ef_accept_equal]);
            consume(_RKLAMMER);
            { type casts to class helpers aren't allowed }
            if is_objectpascal_helper(hdef) then
              Message(parser_e_no_category_as_types)
              { recovery by not creating a conversion node }
            else
              result:=ctypeconvnode.create_explicit(result,hdef);
          end
         { not LKLAMMER }
         else if (current_scanner.token=_POINT) and
            (is_object(hdef) or is_record(hdef)) then
           begin
             consume(_POINT);
             { handles calling methods declared in parent objects
               using "parentobject.methodname()" }
             if assigned(current_structdef) and
                not(getaddr) and
                def_is_related(current_structdef,hdef) then
               begin
                 result:=ctypenode.create(hdef);
                 ttypenode(result).typesym:=sym;
                 if not (m_implicit_generics in current_settings.modeswitches) and
                     (block_type in inline_specialization_block_types) and
                     (current_scanner.token=_ID) and
                     (current_scanner.idtoken=_SPECIALIZE) then
                   begin
                     consume(_ID);
                     if current_scanner.token<>_ID then
                       message(type_e_type_id_expected);
                     isspecialize:=true;
                   end
                 else
                   isspecialize:=false;
                 { search also in inherited methods }
                 searchsym_in_class(tobjectdef(hdef),tobjectdef(current_structdef),current_scanner.pattern,srsym,srsymtable,[ssf_search_helper]);
                 if isspecialize then
                   begin
                     consume(_ID);
                     if not handle_specialize_inline_specialization(srsym,false,srsymtable,spezcontext) then
                       begin
                         result.free;
                         result:=cerrornode.create;
                       end;
                   end
                 else
                   begin
                     if assigned(srsym) then
                       check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg);
                     consume(_ID);
                   end;
                 if result.nodetype<>errorn then
                   do_member_read(tabstractrecorddef(hdef),false,srsym,result,again,[],spezcontext)
                 else begin
                   spezcontext.free;
                   spezcontext := nil;
                 end;
               end
             else
              begin
                { handles:
                    * @TObject.Load
                    * static methods and variables }
                result:=ctypenode.create(hdef);
                ttypenode(result).typesym:=sym;
                if not (m_implicit_generics in current_settings.modeswitches) and
                    (block_type in inline_specialization_block_types) and
                    (current_scanner.token=_ID) and
                    (current_scanner.idtoken=_SPECIALIZE) then
                  begin
                    consume(_ID);
                    if current_scanner.token<>_ID then
                      message(type_e_type_id_expected);
                    isspecialize:=true;
                  end
                else
                  isspecialize:=false;
                erroroutresult:=true;
                { TP allows also @TMenu.Load if Load is only }
                { defined in an ancestor class               }
                srsym:=search_struct_member(tabstractrecorddef(hdef),current_scanner.pattern);
                if isspecialize and assigned(srsym) then
                  begin
                    consume(_ID);
                    if handle_specialize_inline_specialization(srsym,false,srsymtable,spezcontext) then
                      erroroutresult:=false;
                  end
                else
                  begin
                    if assigned(srsym) then
                      begin
                        savedfilepos:=current_filepos;
                        consume(_ID);
                        if not (sp_generic_dummy in srsym.symoptions) or
                            not (current_scanner.token in [_LT,_LSHARPBRACKET]) then
                          check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg,savedfilepos)
                        else
                          result:=cspecializenode.create(result,getaddr,srsym,false);
                        erroroutresult:=false;
                      end
                    else
                      Message1(sym_e_id_no_member,current_scanner.orgpattern);
                  end;
                if erroroutresult then
                  begin
                    result.free;
                    result:=cerrornode.create;
                  end
                else
                  if result.nodetype<>specializen then
                    do_member_read(tabstractrecorddef(hdef),getaddr,srsym,result,again,[],spezcontext);
              end;
           end
         else
          begin
            { Normally here would be the check against the usage
              of "TClassHelper.Something", but as that might be
              used inside of system symbols like sizeof and
              typeinfo this check is put into ttypenode.pass_1
              (for "TClassHelper" alone) and tcallnode.pass_1
              (for "TClassHelper.Something") }
            { class reference ? }
            if is_class(hdef) or
               is_objcclass(hdef) or
               { Java interfaces also can have loadvmtaddrnodes,
                 e.g. for expressions such as JLClass(intftype) }
               is_java_class_or_interface(hdef) then
             begin
               if getaddr and (current_scanner.token=_POINT) and
                  not is_javainterface(hdef) then
                begin
                  consume(_POINT);
                  { allows @Object.Method }
                  { also allows static methods and variables }
                  result:=ctypenode.create(hdef);
                  ttypenode(result).typesym:=sym;
                  { TP allows also @TMenu.Load if Load is only }
                  { defined in an ancestor class               }
                  srsym:=search_struct_member(tobjectdef(hdef),current_scanner.pattern);
                  if assigned(srsym) then
                   begin
                     check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg);
                     consume(_ID);
                     { in case of @Object.Method1.Method2, we have to call
                       Method1 -> create a loadvmtaddr node as self instead of
                       a typen (the typenode would be changed to self of the
                       current method in case Method1 is a constructor, see
                       mantis #24844) }
                     if not(block_type in [bt_type,bt_const_type,bt_var_type]) and
                        (srsym.typ=procsym) and
                        (current_scanner.token in [_CARET,_POINT]) then
                       result:=cloadvmtaddrnode.create(result);
                     do_member_read(tabstractrecorddef(hdef),getaddr,srsym,result,again,[],nil);
                   end
                  else
                   begin
                     Message1(sym_e_id_no_member,current_scanner.orgpattern);
                     consume(_ID);
                   end;
                end
               else
                begin
                  result:=ctypenode.create(hdef);
                  ttypenode(result).typesym:=sym;
                  { For a type block we simply return only
                    the type. For all other blocks we return
                    a loadvmt node }
                  if not(block_type in [bt_type,bt_const_type,bt_var_type]) then
                    result:=cloadvmtaddrnode.create(result);
                end;
             end
            else
              begin
                result:=ctypenode.create(hdef);
                ttypenode(result).typesym:=sym;
              end;
          end;
      end;

{****************************************************************************
                               Factor
****************************************************************************}


    function real_const_node_from_pattern(const s:string):tnode;
      var
        d : bestreal;
        code : integer;
        cur : currency;
      begin
        val(s,d,code);
        if code<>0 then
         begin
           Message(parser_e_error_in_real);
           d:=1.0;
         end;
        if current_settings.fputype=fpu_none then
          begin
            Message(parser_e_unsupported_real);
            result:=cerrornode.create;
            exit;
          end;
        if (current_settings.minfpconstprec=s32real) and
           (d = single(d)) then
          result:=crealconstnode.create(d,s32floattype)
        else if (current_settings.minfpconstprec=s64real) and
                (d = double(d)) then
          result:=crealconstnode.create(d,s64floattype)
        else
          result:=crealconstnode.create(d,pbestrealtype^);
        val(current_scanner.pattern,cur,code);
        if code=0 then
          trealconstnode(result).value_currency:=cur;
      end;

{---------------------------------------------
               PostFixOperators
---------------------------------------------}

    { returns whether or not p1 has been changed }
    function postfixoperators(var p1:tnode;var again:boolean;getaddr:boolean): boolean;

      { tries to avoid syntax errors after invalid qualifiers }
      procedure recoverconsume_postfixops;
       begin
         repeat
           if not try_to_consume(_CARET) then
             if try_to_consume(_POINT) then
               try_to_consume(_ID)
             else if try_to_consume(_LECKKLAMMER) then
               begin
                 repeat
                   comp_expr([ef_accept_equal]);
                 until not try_to_consume(_COMMA);
                 consume(_RECKKLAMMER);
               end
             else if try_to_consume(_LKLAMMER) then
               begin
                 repeat
                   comp_expr([ef_accept_equal]);
                 until not try_to_consume(_COMMA);
                 consume(_RKLAMMER);
               end
             else
               break;
         until false;
       end;


      procedure handle_variantarray;
       var
         p4 : tnode;
         newstatement : tstatementnode;
         tempresultvariant,
         temp    : ttempcreatenode;
         paras : tcallparanode;
         newblock : tnode;
         countindices : longint;
         elements: tfplist;
         arraydef: tdef;
       begin
         { create statements with call initialize the arguments and
           call fpc_dynarr_setlength }
         newblock:=internalstatements(newstatement);

         { store all indices in a temporary array }
         countindices:=0;
         elements:=tfplist.Create;
         repeat
           p4:=comp_expr([ef_accept_equal]);
           elements.add(p4);
         until not try_to_consume(_COMMA);

         arraydef:=carraydef.getreusable(s32inttype,elements.count);
         temp:=ctempcreatenode.create(arraydef,arraydef.size,tt_persistent,false);
         addstatement(newstatement,temp);
         for countindices:=0 to elements.count-1 do
           begin
             addstatement(newstatement,
               cassignmentnode.create(
                 cvecnode.create(
                   ctemprefnode.create(temp),
                   genintconstnode(countindices)
                 ),
                 tnode(elements[countindices])
               )
             );
           end;
         countindices:=elements.count;
         elements.free;
         elements := nil;

         consume(_RECKKLAMMER);

         { we need only a write access if a := follows }
         if current_scanner.token=_ASSIGNMENT then
           begin
             consume(_ASSIGNMENT);
             p4:=comp_expr([ef_accept_equal]);

             { create call to fpc_vararray_put }
             paras:=ccallparanode.create(cordconstnode.create
                   (countindices,s32inttype,true),
                ccallparanode.create(caddrnode.create_internal
               (cvecnode.create(ctemprefnode.create(temp),genintconstnode(0))),
                ccallparanode.create(ctypeconvnode.create_internal(p4,cvarianttype),
                ccallparanode.create(ctypeconvnode.create_internal(p1,cvarianttype)
                  ,nil))));

             addstatement(newstatement,ccallnode.createintern('fpc_vararray_put',paras));
             addstatement(newstatement,ctempdeletenode.create(temp));
           end
         else
           begin
             { create temp for result }
             tempresultvariant:=ctempcreatenode.create(cvarianttype,cvarianttype.size,tt_persistent,true);
             addstatement(newstatement,tempresultvariant);

             { create call to fpc_vararray_get }
             paras:=ccallparanode.create(cordconstnode.create
                   (countindices,s32inttype,true),
                ccallparanode.create(caddrnode.create_internal
               (ctemprefnode.create(temp)),
                ccallparanode.create(p1,
                ccallparanode.create(
                    ctemprefnode.create(tempresultvariant)
                  ,nil))));

             addstatement(newstatement,ccallnode.createintern('fpc_vararray_get',paras));
             addstatement(newstatement,ctempdeletenode.create(temp));
             { the last statement should return the value as
               location and type, this is done be referencing the
               temp and converting it first from a persistent temp to
               normal temp }
             addstatement(newstatement,ctempdeletenode.create_normal_temp(tempresultvariant));
             addstatement(newstatement,ctemprefnode.create(tempresultvariant));
           end;
         p1:=newblock;
       end;

      function parse_array_constructor(arrdef:tarraydef): tnode;
        var
          newstatement,assstatement:tstatementnode;
          arrnode:ttempcreatenode;
          temp2:ttempcreatenode;
          assnode:tnode;
          paracount:integer;
        begin
          result:=internalstatements(newstatement);
          { create temp for result }
          arrnode:=ctempcreatenode.create(arrdef,arrdef.size,tt_persistent,true);
          addstatement(newstatement,arrnode);

          paracount:=0;
          { check arguments and create an assignment calls }
          if try_to_consume(_LKLAMMER) then
            begin
              assnode:=internalstatements(assstatement);
              repeat
                { arr[i] := param_i }
                addstatement(assstatement,
                  cassignmentnode.create(
                    cvecnode.create(
                      ctemprefnode.create(arrnode),
                      cordconstnode.create(paracount,arrdef.rangedef,false)),
                    comp_expr([ef_accept_equal])));
                inc(paracount);
              until not try_to_consume(_COMMA);
              consume(_RKLAMMER);
            end
          else
            assnode:=nil;

          { get temp for array of lengths }
          temp2:=ctempcreatenode.create(sinttype,sinttype.size,tt_persistent,false);
          addstatement(newstatement,temp2);

          { one dimensional }
          addstatement(newstatement,cassignmentnode.create(
              ctemprefnode.create(temp2),
              cordconstnode.create
                 (paracount,s32inttype,true)));
          { create call to fpc_dynarr_setlength }
          addstatement(newstatement,ccallnode.createintern('fpc_dynarray_setlength',
              ccallparanode.create(caddrnode.create_internal
                    (ctemprefnode.create(temp2)),
                 ccallparanode.create(cordconstnode.create
                    (1,s32inttype,true),
                 ccallparanode.create(caddrnode.create_internal
                    (crttinode.create(tstoreddef(arrdef),initrtti,rdt_normal)),
                 ccallparanode.create(
                   ctypeconvnode.create_internal(
                     ctemprefnode.create(arrnode),voidpointertype),
                   nil))))

            ));
          { add assignment statements }
          addstatement(newstatement,ctempdeletenode.create(temp2));
          if assigned(assnode) then
            addstatement(newstatement,assnode);
          { the last statement should return the value as
            location and type, this is done be referencing the
            temp and converting it first from a persistent temp to
            normal temp }
          addstatement(newstatement,ctempdeletenode.create_normal_temp(arrnode));
          addstatement(newstatement,ctemprefnode.create(arrnode));
        end;

      function try_type_helper(var node:tnode;def:tdef):boolean;
        var
          srsym : tsym;
          srsymtable : tsymtable;
          n : tnode;
          newstatement : tstatementnode;
          temp : ttempcreatenode;
          extdef : tdef;
        begin
          result:=false;
          if (current_scanner.token=_ID) and (block_type in [bt_body,bt_general,bt_except,bt_const]) then
            begin
              if not assigned(def) then
                if node.nodetype=addrn then
                  { always use the pointer type for addr nodes as otherwise
                    we'll have an anonymous pointertype with no name }
                  def:=voidpointertype
                else
                  def:=node.resultdef;
              result:=search_objectpascal_helper(def,nil,current_scanner.pattern,srsym,srsymtable);
              if result then
                begin
                  if not (srsymtable.symtabletype=objectsymtable) or
                      not is_objectpascal_helper(tdef(srsymtable.defowner)) then
                    internalerror(2013011401);
                  { convert const node to temp node of the extended type }
                  if node.nodetype in (nodetype_const+[addrn]) then
                    begin
                      extdef:=tobjectdef(srsymtable.defowner).extendeddef;
                      newstatement:=nil;
                      n:=internalstatements(newstatement);
                      temp:=ctempcreatenode.create(extdef,extdef.size,tt_persistent,false);
                      addstatement(newstatement,temp);
                      addstatement(newstatement,cassignmentnode.create(ctemprefnode.create(temp),node));
                      addstatement(newstatement,ctempdeletenode.create_normal_temp(temp));
                      addstatement(newstatement,ctemprefnode.create(temp));
                      node:=n;
                      do_typecheckpass(node)
                    end;
                  check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg);
                  consume(_ID);
                  do_member_read(nil,getaddr,srsym,node,again,[],nil);
                end;
            end;
        end;

    var
     protsym  : tpropertysym;
     p2,p3  : tnode;
     srsym  : tsym;
     srsymtable : TSymtable;
     structh    : tabstractrecorddef;
     { composablerecords: when a flat lookup goes through composition links,
       this is the chain of carriers (outer-most first) we must subscript
       through before reading the target. nil/empty otherwise. owned here. }
     compose_chain : tfplist;
     compose_idx : longint;
     { shouldn't be used that often, so the extra overhead is ok to save
       stack space }
     dispatchstring : ansistring;
     autoderef,
     erroroutp1,
     allowspecialize,
     isspecialize,
     found,
     haderror,
     nodechanged    : boolean;
     calltype: tdispcalltype;
     valstr,expstr : string;
     intval : qword;
     code : integer;
     strdef : tdef;
     spezcontext : tspecializationcontext;
     old_current_filepos : tfileposinfo;
    label
     skipreckklammercheck,
     skippointdefcheck;
    begin
     result:=false;
     again:=true;
     while again do
      begin
        spezcontext:=nil;
        { we need the resultdef }
        do_typecheckpass_changed(p1,nodechanged);
        result:=result or nodechanged;

        if codegenerror then
         begin
           recoverconsume_postfixops;
           exit;
         end;
        { handle token }
        case current_scanner.token of
          _CARET:
             begin
               consume(_CARET);

               { support in tp/mac procvar mode procvar^ if the procvar returns a
                 pointer type }
               if ((m_tp_procvar in current_settings.modeswitches) or
                   (m_mac_procvar in current_settings.modeswitches)) and
                  (p1.resultdef.typ=procvardef) and
                  (tprocvardef(p1.resultdef).returndef.typ=pointerdef) then
                 begin
                   p1:=ccallnode.create_procvar(nil,p1);
                   typecheckpass(p1);
                 end;

               { iso file buf access? }
               if (m_isolike_io in current_settings.modeswitches) and
                 (p1.resultdef.typ=filedef) then
                 begin
                   case tfiledef(p1.resultdef).filetyp of
                     ft_text:
                       begin
                         p1:=cderefnode.create(ccallnode.createintern('fpc_getbuf_text',ccallparanode.create(p1,nil)));
                         typecheckpass(p1);
                       end;
                     ft_typed:
                       begin
                         p1:=cderefnode.create(ctypeconvnode.create_internal(ccallnode.createintern('fpc_getbuf_typedfile',ccallparanode.create(p1,nil)),
                           cpointerdef.getreusable(tfiledef(p1.resultdef).typedfiledef)));
                         typecheckpass(p1);
                       end;
                     else
                       internalerror(2019050530);
                   end;
                 end
               else if not(p1.resultdef.typ in [pointerdef,undefineddef]) then
                 begin
                    { ^ as binary operator is a problem!!!! (FK) }
                    again:=false;
                    Message(parser_e_invalid_qualifier);
                    recoverconsume_postfixops;
                    p1.free;
                    p1:=cerrornode.create;
                 end
               else
                 p1:=cderefnode.create(p1);
             end;

          _LECKKLAMMER:
             begin
               { support in tp/mac procvar mode procvar[] if the procvar returns an
                 array type }
               if ((m_tp_procvar in current_settings.modeswitches) or
                   (m_mac_procvar in current_settings.modeswitches)) and
                  (p1.resultdef.typ=procvardef) and
                  (tprocvardef(p1.resultdef).returndef.typ=arraydef) then
                 begin
                   p1:=ccallnode.create_procvar(nil,p1);
                   typecheckpass(p1);
                 end;

               { tuple[N] indexed access - route to vecnode }
               if (m_tuples in current_settings.modeswitches) and
                  assigned(p1.resultdef) and
                  (p1.resultdef.typ=recorddef) and
                  (df_tuple in p1.resultdef.defoptions) then
                 begin
                   consume(_LECKKLAMMER);
                   p2:=comp_expr([ef_accept_equal]);
                   consume(_RECKKLAMMER);
                   p1:=cvecnode.create(p1,p2);
                 end
               else
               if is_class_or_interface_or_object(p1.resultdef) or
                  is_dispinterface(p1.resultdef) or
                  is_record(p1.resultdef) or
                  is_javaclass(p1.resultdef) then
                 begin
                   { default property }
                   protsym:=search_default_property(tabstractrecorddef(p1.resultdef));
                   if not(assigned(protsym)) then
                     begin
                        p1.free;
                        p1:=cerrornode.create;
                        again:=false;
                        message(parser_e_no_default_property_available);
                     end
                   else
                     begin
                       { The property symbol is referenced indirect }
                       protsym.IncRefCount;
                       handle_propertysym(protsym,protsym.owner,p1);
                     end;
                 end
               else
                 begin
                   consume(_LECKKLAMMER);
                   repeat
                     { in all of the cases below, p1 is changed }
                     case p1.resultdef.typ of
                       pointerdef:
                         begin
                            { support delphi autoderef }
                            if (tpointerdef(p1.resultdef).pointeddef.typ=arraydef) and
                               (m_autoderef in current_settings.modeswitches) then
                              p1:=cderefnode.create(p1);
                            p2:=comp_expr([ef_accept_equal]);
                            { Support Pbytevar[0..9] which returns array [0..9].}
                            if try_to_consume(_POINTPOINT) then
                              p2:=crangenode.create(p2,comp_expr([ef_accept_equal]));
                            p1:=cvecnode.create(p1,p2);
                         end;
                       variantdef:
                         begin
                           handle_variantarray;
                           { the RECKKLAMMER is already read }
                           goto skipreckklammercheck;
                         end;
                       stringdef :
                         begin
                           p2:=comp_expr([ef_accept_equal]);
                           { Support string[0..9] which returns array [0..9] of char.}
                           if try_to_consume(_POINTPOINT) then
                             p2:=crangenode.create(p2,comp_expr([ef_accept_equal]));
                           p1:=cvecnode.create(p1,p2);
                         end;
                       arraydef:
                         begin
                           p2:=comp_expr([ef_accept_equal]);
                           { support SEG:OFS for go32v2/msdos Mem[] }
                           if (target_info.system in [system_i386_go32v2,system_i386_watcom,system_i8086_msdos,system_i8086_win16,system_i8086_embedded]) and
                              (p1.nodetype=loadn) and
                              assigned(tloadnode(p1).symtableentry) and
                              assigned(tloadnode(p1).symtableentry.owner.name) and
                              (tloadnode(p1).symtableentry.owner.name^='SYSTEM') and
                              ((tloadnode(p1).symtableentry.name='MEM') or
                               (tloadnode(p1).symtableentry.name='MEMW') or
                               (tloadnode(p1).symtableentry.name='MEML')) then
                             begin
{$if defined(i8086)}
                               consume(_COLON);
                               inserttypeconv(p2,u16inttype);
                               inserttypeconv_internal(p2,u32inttype);
                               p3:=cshlshrnode.create(shln,p2,cordconstnode.create($10,s16inttype,false));
                               p2:=comp_expr([ef_accept_equal]);
                               inserttypeconv(p2,u16inttype);
                               inserttypeconv_internal(p2,u32inttype);
                               p2:=caddnode.create(addn,p2,p3);
                               case tloadnode(p1).symtableentry.name of
                                 'MEM': p2:=ctypeconvnode.create_internal(p2,bytefarpointertype);
                                 'MEMW': p2:=ctypeconvnode.create_internal(p2,wordfarpointertype);
                                 'MEML': p2:=ctypeconvnode.create_internal(p2,longintfarpointertype);
                                 else
                                   internalerror(2013053102);
                               end;
                               p1:=cderefnode.create(p2);
{$elseif defined(i386)}
                               if try_to_consume(_COLON) then
                                begin
                                  p3:=caddnode.create(muln,cordconstnode.create($10,s32inttype,false),p2);
                                  p2:=comp_expr([ef_accept_equal]);
                                  p2:=caddnode.create(addn,p2,p3);
                                  if try_to_consume(_POINTPOINT) then
                                    { Support mem[$a000:$0000..$07ff] which returns array [0..$7ff] of memtype.}
                                    p2:=crangenode.create(p2,caddnode.create(addn,comp_expr([ef_accept_equal]),p3.getcopy));
                                  p1:=cvecnode.create(p1,p2);
                                  include(tvecnode(p1).vecnodeflags,vnf_memseg);
                                  include(tvecnode(p1).vecnodeflags,vnf_memindex);
                                end
                               else
                                begin
                                  if try_to_consume(_POINTPOINT) then
                                    { Support mem[$80000000..$80000002] which returns array [0..2] of memtype.}
                                    p2:=crangenode.create(p2,comp_expr([ef_accept_equal]));
                                  p1:=cvecnode.create(p1,p2);
                                  include(tvecnode(p1).vecnodeflags,vnf_memindex);
                                end;
{$else}
                               internalerror(2013053105);
{$endif}
                             end
                           else
                             begin
                               if try_to_consume(_POINTPOINT) then
                                 { Support arrayvar[0..9] which returns array [0..9] of arraytype.}
                                 p2:=crangenode.create(p2,comp_expr([ef_accept_equal]));
                               p1:=cvecnode.create(p1,p2);
                             end;
                         end;
                       else
                         begin
                           if p1.resultdef.typ<>undefineddef then
                             Message(parser_e_invalid_qualifier);
                           p1.free;
                           p1:=cerrornode.create;
                           comp_expr([ef_accept_equal]);
                           again:=false;
                         end;
                     end;
                     do_typecheckpass(p1);
                   until not try_to_consume(_COMMA);
                   consume(_RECKKLAMMER);
                   { handle_variantarray eats the RECKKLAMMER and jumps here }
                 skipreckklammercheck:
                 end;
             end;

          _POINT :
             begin
               consume(_POINT);
               allowspecialize:=not (m_implicit_generics in current_settings.modeswitches) and (block_type in inline_specialization_block_types);
               if allowspecialize and (current_scanner.token=_ID) and (current_scanner.idtoken=_SPECIALIZE) then
                 begin
                   //consume(_ID);
                   isspecialize:=true;
                 end
               else
                 isspecialize:=false;
               autoderef:=false;
               if (p1.resultdef.typ=pointerdef) and
                  (m_autoderef in current_settings.modeswitches) and
                  { don't auto-deref objc.id, because then the code
                    below for supporting id.anyobjcmethod isn't triggered }
                  (p1.resultdef<>objc_idtype) then
                 begin
                   p1:=cderefnode.create(p1);
                   do_typecheckpass(p1);
                   autoderef:=true;
                 end;
               { procvar.<something> can never mean anything so always
                 try to call it in case it returns a record/object/... }
               maybe_call_procvar(p1,is_invokable(p1.resultdef) and not is_funcref(p1.resultdef));

               if (p1.nodetype=ordconstn) and
                   not is_boolean(p1.resultdef) and
                   not is_enum(p1.resultdef) then
                 begin
                   { type helpers are checked first }
                   if (current_scanner.token=_ID) and try_type_helper(p1,nil) then
                     goto skippointdefcheck;
                   { only an "e" or "E" can follow an intconst with a ".", the
                     other case (another intconst) is handled by the scanner }
                   if (current_scanner.token=_ID) and (current_scanner.pattern[1]='E') then
                     begin
                       haderror:=false;
                       if length(current_scanner.pattern)>1 then
                         begin
                           expstr:=copy(current_scanner.pattern,2,length(current_scanner.pattern)-1);
                           val(expstr,intval,code);
                           if code<>0 then
                             begin
                               haderror:=true;
                               intval:=intval; // Hackfix the "var assigned but never used" note.
                             end;
                         end
                       else
                         expstr:='';
                       consume(current_scanner.token);
                       if tordconstnode(p1).value.signed then
                         str(tordconstnode(p1).value.svalue,valstr)
                       else
                         str(tordconstnode(p1).value.uvalue,valstr);
                       valstr:=valstr+'.0E';
                       if expstr='' then
                         case current_scanner.token of
                           _MINUS:
                             begin
                               consume(current_scanner.token);
                               if current_scanner.token=_INTCONST then
                                 begin
                                   valstr:=valstr+'-'+current_scanner.pattern;
                                   consume(current_scanner.token);
                                 end
                               else
                                 haderror:=true;
                             end;
                           _PLUS:
                             begin
                               consume(current_scanner.token);
                               if current_scanner.token=_INTCONST then
                                 begin
                                   valstr:=valstr+current_scanner.pattern;
                                   consume(current_scanner.token);
                                 end
                               else
                                 haderror:=true;
                             end;
                           _INTCONST:
                             begin
                               valstr:=valstr+current_scanner.pattern;
                               consume(_INTCONST);
                             end;
                           else
                             haderror:=true;
                         end
                       else
                         valstr:=valstr+expstr;
                       if haderror then
                         begin
                           Message(parser_e_error_in_real);
                           p2:=cerrornode.create;
                         end
                       else
                         p2:=real_const_node_from_pattern(valstr);
                       p1.free;
                       p1:=p2;
                       again:=false;
                       goto skippointdefcheck;
                     end
                   else
                     begin
                       { just convert the ordconst to a realconst }
                       p2:=crealconstnode.create(tordconstnode(p1).value,pbestrealtype^);
                       p1.free;
                       p1:=p2;
                       again:=false;
                       goto skippointdefcheck;
                     end;
                 end;

               if (p1.nodetype=stringconstn) and (current_scanner.token=_ID) then
                 begin
                   strdef:=nil;
                   { the def of a string const is an array }
                   case tstringconstnode(p1).cst_type of
                     cst_conststring:
                       if cs_refcountedstrings in current_settings.localswitches then
                         if m_default_unicodestring in current_settings.modeswitches then
                           strdef:=cunicodestringtype
                         else
                           strdef:=cansistringtype
                       else
                         strdef:=cshortstringtype;
                     cst_shortstring:
                       strdef:=cshortstringtype;
                     cst_ansistring:
                       { use getansistringdef? }
                       strdef:=cansistringtype;
                     cst_widestring:
                       strdef:=cwidestringtype;
                     cst_unicodestring:
                       strdef:=cunicodestringtype;
                     cst_longstring:
                       { let's see when someone stumbles upon this...}
                       internalerror(201301111);
                   end;
                   if try_type_helper(p1,strdef) then
                     goto skippointdefcheck;
                 end;

               { this is skipped if label skippointdefcheck is used }
               case p1.resultdef.typ of
                 recorddef:
                   begin
                     if isspecialize or (current_scanner.token=_ID) then
                       begin
                         erroroutp1:=true;
                         srsym:=nil;
                         structh:=tabstractrecorddef(p1.resultdef);
                         compose_chain:=nil;
                         if isspecialize then
                           begin
                             { consume the specialize }
                             consume(_ID);
                             if current_scanner.token<>_ID then
                               consume(_ID)
                             else
                               begin
                                 searchsym_in_record(structh,current_scanner.pattern,srsym,srsymtable);
                                 consume(_ID);
                                 if handle_specialize_inline_specialization(srsym,false,srsymtable,spezcontext) then
                                   erroroutp1:=false;
                               end;
                           end
                         else
                           begin
                             searchsym_in_record(structh,current_scanner.pattern,srsym,srsymtable);
                             if not assigned(srsym) and
                                (m_composable_records in current_settings.modeswitches) then
                               lookup_in_composition(structh,current_scanner.pattern,srsym,srsymtable,compose_chain);
                             if assigned(srsym) then
                               begin
                                 old_current_filepos:=current_filepos;
                                 consume(_ID);
                                 if not (sp_generic_dummy in srsym.symoptions) or
                                     not (current_scanner.token in [_LT,_LSHARPBRACKET]) then
                                   check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg,old_current_filepos)
                                 else
                                   p1:=cspecializenode.create(p1,getaddr,srsym,false);
                                 erroroutp1:=false;
                               end
                             else
                               begin
                                 Message1(sym_e_id_no_member,current_scanner.orgpattern);
                                 { try to clean up }
                                 consume(_ID);
                               end;
                           end;
                         if erroroutp1 then
                           begin
                             p1.free;
                             p1:=cerrornode.create;
                             if assigned(compose_chain) then
                               begin
                                 compose_chain.free;
                                 compose_chain:=nil;
                               end;
                           end
                         else
                           if p1.nodetype<>specializen then
                             begin
                               { composablerecords: walk the carrier chain so the
                                 final read lands on `record.c1.c2...target` }
                               if assigned(compose_chain) then
                                 begin
                                   for compose_idx:=0 to compose_chain.count-1 do
                                     begin
                                       p1:=csubscriptnode.create(tfieldvarsym(compose_chain[compose_idx]),p1);
                                       structh:=tabstractrecorddef(tfieldvarsym(compose_chain[compose_idx]).vardef);
                                     end;
                                   compose_chain.free;
                                   compose_chain:=nil;
                                 end;
                               do_member_read(structh,getaddr,srsym,p1,again,[],spezcontext);
                             end;
                       end
                     else
                     consume(_ID);
                   end;
                 enumdef:
                   begin
                     if current_scanner.token=_ID then
                       begin
                         srsym:=tsym(tenumdef(p1.resultdef).symtable.Find(current_scanner.pattern));
                         if assigned(srsym) and (srsym.typ=enumsym) and (p1.nodetype=typen) then
                           begin
                             p1.free;
                             check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg);
                             p1:=genenumnode(tenumsym(srsym));
                             consume(_ID);
                           end
                         else
                           if not try_type_helper(p1,nil) then
                             begin
                               p1.free;
                               Message1(sym_e_id_no_member,current_scanner.orgpattern);
                               p1:=cerrornode.create;
                               consume(_ID);
                             end;
                       end
                     else
                       begin
                         p1.free;
                         p1:=cerrornode.create;
                         consume(_ID);
                       end
                   end;
                 arraydef:
                   begin
                     if is_dynamic_array(p1.resultdef) then
                       begin
                         if current_scanner.token=_ID then
                           begin
                             if not try_type_helper(p1,nil) then
                               begin
                                 if p1.nodetype=typen then
                                   begin
                                     if current_scanner.pattern='CREATE' then
                                       begin
                                         consume(_ID);
                                         p2:=parse_array_constructor(tarraydef(p1.resultdef));
                                         p1.free;
                                         p1:=p2;
                                       end
                                     else
                                       begin
                                         Message2(scan_f_syn_expected,'CREATE',current_scanner.pattern);
                                         p1.free;
                                         p1:=cerrornode.create;
                                         consume(_ID);
                                       end;
                                   end
                                 else
                                   begin
                                     Message(parser_e_invalid_qualifier);
                                     p1.free;
                                     p1:=cerrornode.create;
                                     consume(_ID);
                                   end;
                               end;
                           end
                         else
                           begin
                             Message(parser_e_invalid_qualifier);
                             p1.free;
                             p1:=cerrornode.create;
                             consume(_ID);
                           end;
                       end
                     else
                       if (current_scanner.token<>_ID) or not try_type_helper(p1,nil) then
                         begin
                           Message(parser_e_invalid_qualifier);
                           p1.free;
                           p1:=cerrornode.create;
                           consume(_ID);
                         end;
                   end;
                  variantdef:
                    begin
                      { dispatch call? }
                      { lhs := v.ident[parameters] -> property get
                        lhs := v.ident(parameters) -> method call
                        v.ident[parameters] := rhs -> property put
                        v.ident(parameters) := rhs -> also property put }
                      if current_scanner.token=_ID then
                        begin
                          if not try_type_helper(p1,nil) then
                            begin
                              dispatchstring:=current_scanner.orgpattern;
                              consume(_ID);
                              calltype:=dct_method;
                              if try_to_consume(_LKLAMMER) then
                                begin
                                  p2:=parse_paras(false,true,_RKLAMMER);
                                  consume(_RKLAMMER);
                                end
                              else if try_to_consume(_LECKKLAMMER) then
                                begin
                                  p2:=parse_paras(false,true,_RECKKLAMMER);
                                  consume(_RECKKLAMMER);
                                  calltype:=dct_propget;
                                end
                              else
                                p2:=nil;
                              { property setter? }
                              if (current_scanner.token=_ASSIGNMENT) and not(afterassignment) then
                                begin
                                  consume(_ASSIGNMENT);
                                  { read the expression }
                                  p3:=comp_expr([ef_accept_equal]);
                                  { concat value parameter too }
                                  p2:=ccallparanode.create(p3,p2);
                                  p1:=translate_disp_call(p1,p2,dct_propput,dispatchstring,0,voidtype);
                                end
                              else
                              { this is only an approximation
                                setting useresult if not necessary is only a waste of time, no more, no less (FK) }
                              if afterassignment or in_args or (current_scanner.token<>_SEMICOLON) then
                                p1:=translate_disp_call(p1,p2,calltype,dispatchstring,0,cvarianttype)
                              else
                                p1:=translate_disp_call(p1,p2,calltype,dispatchstring,0,voidtype);
                            end;
                        end
                      else { Error }
                        Consume(_ID);
                     end;
                  classrefdef:
                    begin
                      erroroutp1:=true;
                      if current_scanner.token=_ID then
                        begin
                          srsym:=nil;
                          structh:=tobjectdef(tclassrefdef(p1.resultdef).pointeddef);
                          if isspecialize then
                            begin
                              { consume the specialize }
                              consume(_ID);
                              if current_scanner.token<>_ID then
                                consume(_ID)
                              else
                                begin
                                  searchsym_in_class(tobjectdef(structh),tobjectdef(structh),current_scanner.pattern,srsym,srsymtable,[ssf_search_helper]);
                                  consume(_ID);
                                  if handle_specialize_inline_specialization(srsym,false,srsymtable,spezcontext) then
                                    erroroutp1:=false;
                                end;
                            end
                          else
                            begin
                              searchsym_in_class(tobjectdef(structh),tobjectdef(structh),current_scanner.pattern,srsym,srsymtable,[ssf_search_helper]);
                              if assigned(srsym) then
                                begin
                                  old_current_filepos:=current_filepos;
                                  consume(_ID);
                                  if not (sp_generic_dummy in srsym.symoptions) or
                                      not (current_scanner.token in [_LT,_LSHARPBRACKET]) then
                                    check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg,old_current_filepos)
                                  else
                                    p1:=cspecializenode.create(p1,getaddr,srsym,false);
                                  erroroutp1:=false;
                                end
                              else
                                begin
                                  Message1(sym_e_id_no_member,current_scanner.orgpattern);
                                  { try to clean up }
                                  consume(_ID);
                                end;
                            end;
                          if erroroutp1 then
                            begin
                              p1.free;
                              p1:=cerrornode.create;
                            end
                          else
                            if p1.nodetype<>specializen then
                              do_member_read(structh,getaddr,srsym,p1,again,[],spezcontext);
                        end
                      else { Error }
                        Consume(_ID);
                    end;
                  objectdef:
                    begin
                      if isspecialize or (current_scanner.token=_ID) then
                        begin
                          erroroutp1:=true;
                          srsym:=nil;
                          structh:=tobjectdef(p1.resultdef);
                          if isspecialize then
                            begin
                              { consume the "specialize" }
                              consume(_ID);
                              if current_scanner.token<>_ID then
                                consume(_ID)
                              else
                                begin
                                  searchsym_in_class(tobjectdef(structh),tobjectdef(structh),current_scanner.pattern,srsym,srsymtable,[ssf_search_helper]);
                                  consume(_ID);
                                  if handle_specialize_inline_specialization(srsym,false,srsymtable,spezcontext) then
                                    erroroutp1:=false;
                                end;
                            end
                          else
                            begin
                              searchsym_in_class(tobjectdef(structh),tobjectdef(structh),current_scanner.pattern,srsym,srsymtable,[ssf_search_helper]);
                              if assigned(srsym) then
                                begin
                                   old_current_filepos:=current_filepos;
                                   consume(_ID);
                                   if not (sp_generic_dummy in srsym.symoptions) or
                                       not (current_scanner.token in [_LT,_LSHARPBRACKET]) then
                                     check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg,old_current_filepos)
                                   else
                                     p1:=cspecializenode.create(p1,getaddr,srsym,false);
                                   erroroutp1:=false;
                                end
                              else
                                begin
                                   Message1(sym_e_id_no_member,current_scanner.orgpattern);
                                   { try to clean up }
                                   consume(_ID);
                                end;
                            end;
                          if erroroutp1 then
                            begin
                              p1.free;
                              p1:=cerrornode.create;
                            end
                          else
                            if p1.nodetype<>specializen then
                              do_member_read(structh,getaddr,srsym,p1,again,[],spezcontext);
                        end
                      else { Error }
                        Consume(_ID);
                    end;
                  pointerdef:
                    begin
                      if (p1.resultdef=objc_idtype) then
                        begin
                          { objc's id type can be used to call any
                            Objective-C method of any Objective-C class
                            type that's currently in scope }
                          if search_objc_method(current_scanner.pattern,srsym,srsymtable) then
                            begin
                              consume(_ID);
                              do_proc_call(srsym,srsymtable,nil,
                                (getaddr and not(current_scanner.token in [_CARET,_POINT])),
                                again,p1,[cnf_objc_id_call],nil);
                              { we need to know which procedure is called }
                              do_typecheckpass(p1);
                            end
                          else
                            begin
                              consume(_ID);
                              Message(parser_e_methode_id_expected);
                            end;
                        end
                      else
                        begin
                          if not try_type_helper(p1,nil) then
                            begin
                              Message(parser_e_invalid_qualifier);
                              if tpointerdef(p1.resultdef).pointeddef.typ in [recorddef,objectdef,classrefdef] then
                                Message(parser_h_maybe_deref_caret_missing);
                            end;
                        end
                    end;
                  else
                    begin
                      if autoderef then
                        begin
                          { always try with the not dereferenced node }
                          p2:=tderefnode(p1).left;
                          found:=try_type_helper(p2,nil);
                          if found then
                            begin
                              tderefnode(p1).left:=nil;
                              p1.free;
                              p1:=p2;
                            end;
                        end
                      else
                        found:=try_type_helper(p1,nil);
                      if not found then
                        begin
                          if p1.resultdef.typ<>undefineddef then
                            Message(parser_e_invalid_qualifier);
                          p1.free;
                          p1:=cerrornode.create;
                          { Error }
                          consume(_ID);
                        end;
                    end;
               end;
               { processing an ordconstnode avoids the resultdef check }
               skippointdefcheck:
             end;

          else
            begin
              { is this a procedure variable ? }
              if is_invokable(p1.resultdef) and
                  (current_scanner.token=_LKLAMMER) then
                begin
                  if not searchsym_in_class(tobjectdef(p1.resultdef),tobjectdef(p1.resultdef),method_name_funcref_invoke_find,srsym,srsymtable,[]) then
                    internalerror(2021040202);
                  include(p1.flags,nf_load_procvar);
                  do_proc_call(srsym,srsymtable,tabstractrecorddef(p1.resultdef),false,again,p1,[],nil);
                end
              else if assigned(p1.resultdef) and
                 (p1.resultdef.typ=procvardef) then
                begin
                  { Typenode for typecasting or expecting a procvar }
                  if (p1.nodetype=typen) or
                     (
                      assigned(getprocvardef) and
                      equal_defs(p1.resultdef,getprocvardef)
                     ) or
                     (
                      assigned(getfuncrefdef) and
                      equal_defs(p1.resultdef,getfuncrefdef)
                     ) then
                    begin
                      if try_to_consume(_LKLAMMER) then
                        begin
                          p1:=comp_expr([ef_accept_equal]);
                          consume(_RKLAMMER);
                          p1:=ctypeconvnode.create_explicit(p1,p1.resultdef);
                        end
                      else
                        again:=false
                    end
                  else
                    begin
                      if try_to_consume(_LKLAMMER) then
                        begin
                          p2:=parse_paras(false,false,_RKLAMMER);
                          consume(_RKLAMMER);
                          p1:=ccallnode.create_procvar(p2,p1);
                          { proc():= is never possible }
                          if current_scanner.token=_ASSIGNMENT then
                            begin
                              Message(parser_e_illegal_expression);
                              p1.free;
                              p1:=cerrornode.create;
                              again:=false;
                            end;
                        end
                      else
                        again:=false;
                    end;
                end
              else
                again:=false;
             end;
        end;

        { we only try again if p1 was changed }
        if again or
           (p1.nodetype=errorn) then
          result:=true;
      end; { while again }
    end;

    { composablerecords: rediscover the carrier chain that
      `lookup_in_composition` traversed to reach `s` on `recordh`, and
      wrap p1 in a subscript through each carrier so the read lands on
      `with_target.$compose$N. ... .field`. used by `is_member_read`
      for the WithSymtable case. }
    function compose_lookup_walk(recordh: tabstractrecorddef;
                                 const s: TIDString;
                                 var p1: tnode): boolean;
      var
        compose_sym: tsym;
        compose_st: tsymtable;
        chain: tfplist;
        i: longint;
      begin
        result:=false;
        if lookup_in_composition(recordh,s,compose_sym,compose_st,chain) then
          begin
            if assigned(chain) then
              begin
                for i:=0 to chain.count-1 do
                  p1:=csubscriptnode.create(tfieldvarsym(chain[i]),p1);
                chain.free;
              end;
            result:=true;
          end;
      end;

    { composablerecords: a bare name inside a method body resolved
      through a composition carrier - srsym lives in a carrier's
      record, not in hdef. wrap the self load in subscripts through
      the carrier chain and narrow hdef to the carrier's record so
      do_member_read subscripts the right def. builds the self load
      itself when p1 is nil (bare method call case). }
    procedure compose_member_wrap(srsym: tsym; var hdef: tdef; var p1: tnode);
      var
        selfbuilt: boolean;
      begin
        if not assigned(hdef) or
           not (hdef.typ in [recorddef,objectdef]) or
           not (m_composable_records in current_settings.modeswitches) or
           not assigned(srsym.owner) or
           not (srsym.owner.symtabletype in [ObjectSymtable,recordsymtable]) or
           (tdef(srsym.owner.defowner)=hdef) or
           (tabstractrecorddef(hdef).composition_count=0) then
          exit;
        selfbuilt:=false;
        if p1=nil then
          begin
            p1:=load_self_node;
            selfbuilt:=true;
          end
        else if p1.nodetype=typen then
          exit;
        if compose_lookup_walk(tabstractrecorddef(hdef),srsym.name,p1) then
          hdef:=tdef(srsym.owner.defowner)
        else if selfbuilt then
          begin
            p1.free;
            p1:=nil;
          end;
      end;


    function is_member_read(sym: tsym; st: tsymtable; var p1: tnode;
                            out memberparentdef: tdef): boolean;
      var
        hdef : tdef;
      begin
        result:=true;
        memberparentdef:=nil;

        case st.symtabletype of
          ObjectSymtable,
          recordsymtable:
            begin
              memberparentdef:=tdef(st.defowner);
              exit;
            end;
          WithSymtable:
            begin
              if assigned(p1) then
               internalerror(2007012002);

              hdef:=tnode(twithsymtable(st).withrefnode).resultdef;
              p1:=tnode(twithsymtable(st).withrefnode).getcopy;

              { composablerecords: a flat name resolved through a
                composition carrier lives in a record def deeper than
                hdef. walk through the carrier chain so that the
                subscripts land on `with_target.$compose$N. ... .sym`
                before do_member_read receives the inner record def. }
              if (hdef.typ in [recorddef,objectdef]) and
                 (m_composable_records in current_settings.modeswitches) and
                 (sym.typ in [fieldvarsym,procsym,propertysym]) and
                 assigned(sym.owner) and assigned(sym.owner.defowner) and
                 (sym.owner.defowner<>tdef(hdef)) then
                begin
                  if compose_lookup_walk(tabstractrecorddef(hdef),
                       sym.name,p1) then
                    begin
                      memberparentdef:=tdef(sym.owner.defowner);
                      exit;
                    end;
                end;

              if not(hdef.typ in [objectdef,classrefdef]) then
                exit;

              if (hdef.typ=classrefdef) then
                hdef:=tclassrefdef(hdef).pointeddef;
              memberparentdef:=hdef;
            end;
          else
            result:=false;
        end;
      end;

  {$maxfpuregisters 0}


    function factor_handle_sym(srsym:tsym;srsymtable:tsymtable;var again:boolean;getaddr:boolean;unit_found:boolean;flags:texprflags;var spezcontext:tspecializationcontext):tnode;
      var
        hdef : tdef;
        pd : tprocdef;
        callflags : tcallnodeflags;
        tmpgetaddr : boolean;
        arrlabname : TIDString;
        arrlabsuffix : TIDString;
        arrlabisstring : boolean;
        arrlabidx  : longint;
        arrlabcode : word;
        arrlabtmpnode : tnode;
        arrlabmember : tlabelsym;
      begin
        hdef:=nil;
        result:=nil;
        case srsym.typ of
          absolutevarsym :
            begin
              if (tabsolutevarsym(srsym).abstyp=tovar) then
                begin
                  result:=nil;
                  propaccesslist_to_node(result,nil,tabsolutevarsym(srsym).ref);
                  result:=ctypeconvnode.create(result,tabsolutevarsym(srsym).vardef);
                  include(result.flags,nf_absolute);
                end
              else
                result:=cloadnode.create(srsym,srsymtable);
            end;

          staticvarsym,
          localvarsym,
          paravarsym,
          fieldvarsym :
            begin
              { check if we are reading a field of an object/class/   }
              { record. is_member_read() will deal with withsymtables }
              { if needed.                                            }
              result:=nil;
              if is_member_read(srsym,srsymtable,result,hdef) then
                begin
                  { if the field was originally found in an     }
                  { objectsymtable, it means it's part of self  }
                  { if only method from which it was called is  }
                  { not class static                            }
                  if (srsymtable.symtabletype in [ObjectSymtable,recordsymtable]) then
                    { if we are accessing a owner procsym from the nested }
                    { class we need to call it as a class member          }
                    if assigned(current_structdef) and
                        (((current_structdef<>hdef) and is_owned_by(current_structdef,hdef)) or
                         (sp_static in srsym.symoptions)) then
                      if srsymtable.symtabletype=recordsymtable then
                        result:=ctypenode.create(hdef)
                      else
                        result:=cloadvmtaddrnode.create(ctypenode.create(hdef))
                    else
                      begin
                        if assigned(current_procinfo) then
                          begin
                            pd:=current_procinfo.get_normal_proc.procdef;
                            if assigned(pd) and pd.no_self_node then
                              result:=cloadvmtaddrnode.create(ctypenode.create(pd.struct))
                            else
                              result:=load_self_node;
                          end
                        else
                          result:=load_self_node;
                      end;
                  { field reached through a composition carrier: walk the
                    self load through the carrier chain first }
                  compose_member_wrap(srsym,hdef,result);
                  { now, if the field itself is part of an objectsymtab }
                  { (it can be even if it was found in a withsymtable,  }
                  {  e.g., "with classinstance do field := 5"), then    }
                  { let do_member_read handle it                        }
                  if (srsym.owner.symtabletype in [ObjectSymtable,recordsymtable]) then
                    do_member_read(tabstractrecorddef(hdef),getaddr,srsym,result,again,[],nil)
                  else
                    { otherwise it's a regular record subscript }
                    result:=csubscriptnode.create(srsym,result);
                end
              else
                { regular non-field load }
                result:=cloadnode.create(srsym,srsymtable);
            end;

          syssym :
            begin
              result:=statement_syssym(tsyssym(srsym).number);
            end;

          typesym :
            begin
              hdef:=ttypesym(srsym).typedef;
              if not assigned(hdef) then
               begin
                 again:=false;
               end
              else
               begin
                 if (m_implicit_generics in current_settings.modeswitches) and
                     (sp_generic_dummy in srsym.symoptions) and
                     (current_scanner.token in [_LT,_LSHARPBRACKET]) then
                   begin
                     if block_type in [bt_type,bt_const_type,bt_var_type] then
                       begin
                         if not handle_specialize_inline_specialization(srsym,unit_found,srsymtable,spezcontext) or (srsym.typ=procsym) then
                           begin
                             spezcontext.free;
                             spezcontext := nil;
                             result:=cerrornode.create;
                             if try_to_consume(_LKLAMMER) then
                              begin
                                parse_paras(false,false,_RKLAMMER);
                                consume(_RKLAMMER);
                              end;
                           end
                         else
                           begin
                             if srsym.typ<>typesym then
                               internalerror(2015071705);
                             hdef:=ttypesym(srsym).typedef;
                             result:=handle_factor_typenode(hdef,getaddr,again,srsym,ef_type_only in flags);
                           end;
                       end
                     else
                       result:=cspecializenode.create(nil,getaddr,srsym,unit_found)
                   end
                 else
                   begin
                     { We need to know if this unit uses Variants }
                     if ((hdef=cvarianttype) or (hdef=colevarianttype)) and
                        not(cs_compilesystem in current_settings.moduleswitches) then
                       include(current_module.moduleflags,mf_uses_variants);
                     result:=handle_factor_typenode(hdef,getaddr,again,srsym,ef_type_only in flags);
                   end;
               end;
            end;

          enumsym :
            begin
              result:=genenumnode(tenumsym(srsym));
            end;

          constsym :
            begin
              if tconstsym(srsym).consttyp in [constresourcestring,constwresourcestring]then
                begin
                  result:=cloadnode.create(srsym,srsymtable);
                  do_typecheckpass(result);
                  if is_systemunit_unicode then
                    result.resultdef:=cstringdef.createunicode(true)
                  else
                    result.resultdef:=getansistringdef;
                end
              else
                result:=genconstsymtree(tconstsym(srsym));
            end;

          procsym :
            begin
              result:=nil;
              if (m_implicit_generics in current_settings.modeswitches) and
                  (sp_generic_dummy in srsym.symoptions) and
                  (current_scanner.token in [_LT,_LSHARPBRACKET]) then
                begin
                  result:=cspecializenode.create(nil,getaddr,srsym,unit_found)
                end
              { check if it's a method/class method }
              else if is_member_read(srsym,srsymtable,result,hdef) then
                begin
                  { if we are accessing a owner procsym from the nested }
                  { class we need to call it as a class member          }
                  if (srsymtable.symtabletype in [ObjectSymtable,recordsymtable]) and
                    assigned(current_structdef) and (current_structdef<>hdef) and is_owned_by(current_structdef,hdef) then
                    result:=cloadvmtaddrnode.create(ctypenode.create(hdef));
                  { method reached through a composition carrier: build
                    the self load and walk it through the carrier chain }
                  compose_member_wrap(srsym,hdef,result);
                  { not srsymtable.symtabletype since that can be }
                  { withsymtable as well                          }
                  if (srsym.owner.symtabletype in [ObjectSymtable,recordsymtable]) then
                    begin
                      do_member_read(tabstractrecorddef(hdef),getaddr,srsym,result,again,[],spezcontext);
                      spezcontext:=nil;
                    end
                  else
                    { no procsyms in records (yet) }
                    internalerror(2007012006);
                end
              else
                begin
                  { regular procedure/function call }
                  if not unit_found then
                    callflags:=[]
                  else
                    callflags:=[cnf_unit_specified];
                  { TP7 ugliness: @proc^ is parsed as (@proc)^,
                    but @notproc^ is parsed as @(notproc^) }
                  if m_tp_procvar in current_settings.modeswitches then
                    tmpgetaddr:=getaddr and not(current_scanner.token in [_POINT,_LECKKLAMMER])
                  else
                    tmpgetaddr:=getaddr and not(current_scanner.token in [_CARET,_POINT,_LECKKLAMMER]);
                  do_proc_call(srsym,srsymtable,nil,tmpgetaddr,
                               again,result,callflags,spezcontext);
                  spezcontext:=nil;
                end;
            end;

          propertysym :
            begin
              result:=nil;
              { property of a class/object? }
              if is_member_read(srsym,srsymtable,result,hdef) then
                begin
                  if (srsymtable.symtabletype in [ObjectSymtable,recordsymtable]) then
                    { if we are accessing a owner procsym from the nested }
                    { class or from a static class method we need to call }
                    { it as a class member                                }
                    if (assigned(current_structdef) and (current_structdef<>hdef) and is_owned_by(current_structdef,hdef)) or
                       (assigned(current_procinfo) and current_procinfo.get_normal_proc.procdef.no_self_node) then
                      begin
                        result:=ctypenode.create(hdef);
                        if not is_record(hdef) then
                          result:=cloadvmtaddrnode.create(result);
                      end
                    else
                      result:=load_self_node;
                  { property reached through a composition carrier: walk
                    the self load through the carrier chain first }
                  compose_member_wrap(srsym,hdef,result);
                  { not srsymtable.symtabletype since that can be }
                  { withsymtable as well                          }
                  if (srsym.owner.symtabletype in [ObjectSymtable,recordsymtable]) then
                    do_member_read(tabstractrecorddef(hdef),getaddr,srsym,result,again,[],nil)
                  else
                    { no propertysyms in records (yet) }
                    internalerror(2009111510);
                end
              else
              { no method pointer }
                begin
                  handle_propertysym(tpropertysym(srsym),srsymtable,result);
                end;
            end;

          labelsym :
            begin
              { Support @label }
              if getaddr then
                begin
                  if srsym.owner<>current_procinfo.procdef.localst then
                    CGMessage(parser_e_label_outside_proc);
                  if tlabelsym(srsym).arraylabel then
                    begin
                      { @name[index]: address of the indexed member label }
                      if current_scanner.token<>_LECKKLAMMER then
                        begin
                          Message1(sym_e_label_index_expected,srsym.realname);
                          result:=cerrornode.create;
                        end
                      else
                        begin
                          arrlabname:=srsym.name;
                          arrlabsuffix:='';
                          arrlabisstring:=false;
                          arrlabtmpnode:=nil;
                          consume(_LECKKLAMMER);
                          if current_scanner.token=_CSTRING then
                            begin
                              arrlabsuffix:=upper(current_scanner.cstringpattern);
                              arrlabisstring:=true;
                              consume(_CSTRING);
                              consume(_RECKKLAMMER);
                            end
                          else
                            begin
                              arrlabtmpnode:=comp_expr([ef_accept_equal]);
                              consume(_RECKKLAMMER);
                              do_typecheckpass(arrlabtmpnode);
                              if arrlabtmpnode.nodetype=ordconstn then
                                begin
                                  arrlabidx:=longint(int64(tordconstnode(arrlabtmpnode).value));
                                  arrlabsuffix:=tostr(arrlabidx);
                                  arrlabtmpnode.free;
                                  arrlabtmpnode:=nil;
                                end;
                            end;
                          if assigned(arrlabtmpnode) then
                            begin
                              { runtime index: select the member address
                                through a hidden case dispatch }
                              result:=generate_arraylabel_addr(tlabelsym(srsym),arrlabtmpnode);
                              arrlabtmpnode:=nil;
                            end
                          else if (arrlabisstring or (arrlabsuffix<>'')) and
                             get_or_create_indexed_labelsym(arrlabname,arrlabsuffix,arrlabisstring,arrlabidx,arrlabmember,srsymtable) then
                            begin
                              { taking the address counts as a use: a member
                                that is never defined must be a hard error }
                              arrlabmember.used:=true;
                              result:=cloadnode.create(arrlabmember,srsymtable);
                            end
                          else
                            result:=cerrornode.create;
                        end;
                    end
                  else
                    result:=cloadnode.create(srsym,srsym.owner)
                end
              else if tlabelsym(srsym).arraylabel then
                begin
                  { Array label definition: sentinel_name[index]:
                    Handles e.g. lbl[3]: just like regular label: }
                  if current_scanner.token<>_LECKKLAMMER then
                    begin
                      Message1(sym_e_label_index_expected,srsym.realname);
                      { eat the colon, so the missing index does not also
                        report a stray ":" }
                      try_to_consume(_COLON);
                      result:=cerrornode.create;
                    end
                  else
                    begin
                      arrlabname:=srsym.name;
                      arrlabsuffix:='';
                      arrlabisstring:=false;
                      consume(_LECKKLAMMER);
                      if current_scanner.token=_CSTRING then
                        begin
                          arrlabsuffix:=upper(current_scanner.cstringpattern);
                          arrlabisstring:=true;
                          consume(_CSTRING);
                        end
                      else
                        begin
                          { General constant expression: handles integers, -1,
                            true/false, named constants, etc. }
                          arrlabtmpnode:=comp_expr([ef_accept_equal]);
                          do_typecheckpass(arrlabtmpnode);
                          if arrlabtmpnode.nodetype=ordconstn then
                            begin
                              arrlabidx:=longint(int64(tordconstnode(arrlabtmpnode).value));
                              arrlabsuffix:=tostr(arrlabidx);
                            end
                          else
                            Message(type_e_ordinal_expr_expected);
                          arrlabtmpnode.free;
                          arrlabtmpnode:=nil;
                        end;
                      consume(_RECKKLAMMER);
                      consume(_COLON);
                      if (arrlabisstring or (arrlabsuffix<>'')) and
                         get_or_create_indexed_labelsym(arrlabname,arrlabsuffix,arrlabisstring,arrlabidx,arrlabmember,srsymtable) then
                        begin
                          if arrlabmember.defined then
                            Message(sym_e_label_already_defined);
                          if symtablestack.top.symtablelevel<>srsymtable.symtablelevel then
                            begin
                              include(current_procinfo.flags,pi_has_interproclabel);
                              if (current_procinfo.procdef.proctypeoption in
                                  [potype_unitinit,potype_unitfinalize]) then
                                Message(sym_e_interprocgoto_into_init_final_code_not_allowed);
                            end;
                          arrlabmember.defined:=true;
                          result:=clabelnode.create(nil,arrlabmember);
                          arrlabmember.code:=result;
                        end
                      else
                        begin
                          if arrlabisstring or (arrlabsuffix<>'') then
                            Message1(sym_e_label_used_and_not_defined,arrlabname+'$'+arrlabsuffix);
                          result:=cnothingnode.create;
                        end;
                    end;
                end
              else
                begin
                  consume(_COLON);
                  if tlabelsym(srsym).defined then
                    Message(sym_e_label_already_defined);
                  if symtablestack.top.symtablelevel<>srsymtable.symtablelevel then
                    begin
                      include(current_procinfo.flags,pi_has_interproclabel);
                      if (current_procinfo.procdef.proctypeoption in [potype_unitinit,potype_unitfinalize]) then
                        Message(sym_e_interprocgoto_into_init_final_code_not_allowed);
                    end;
                  tlabelsym(srsym).defined:=true;
                  result:=clabelnode.create(nil,tlabelsym(srsym));
                  tlabelsym(srsym).code:=result;
                end;
            end;

          undefinedsym :
            begin
              result:=cnothingnode.Create;
              result.resultdef:=cundefineddef.create(true);
              { clean up previously created dummy symbol }
              srsym.free;
              srsym := nil;
            end;

          errorsym :
            begin
              result:=cerrornode.create;
              if try_to_consume(_LKLAMMER) then
               begin
                 parse_paras(false,false,_RKLAMMER);
                 consume(_RKLAMMER);
               end;
            end;

          else
            begin
              result:=cerrornode.create;
              Message(parser_e_illegal_expression);
            end;
        end; { end case }
      end;


    { recognize a write-style numeric mask: `6` or `8:2` - plain field
      width (and fraction digits) as in write(x:8:2). an all-zero mask
      without a colon (`0`, `000`) is not a width - it stays a FormatFloat
      zero-padding mask }
    function interp_mask_is_width(const mask:ansistring;out w,f:longint;out has_frac:boolean):boolean;
      var
        i,colonpos : longint;
        code : integer;
      begin
        result:=false;
        has_frac:=false;
        w:=0;
        f:=0;
        if mask='' then
          exit;
        colonpos:=0;
        for i:=1 to length(mask) do
          case mask[i] of
            '0'..'9': ;
            ':':
              begin
                { a single colon, neither first nor last }
                if (colonpos<>0) or (i=1) or (i=length(mask)) then
                  exit;
                colonpos:=i;
              end;
            else
              exit;
          end;
        if colonpos=0 then
          begin
            val(mask,w,code);
            if w=0 then
              exit;
          end
        else
          begin
            val(copy(mask,1,colonpos-1),w,code);
            if code=0 then
              val(copy(mask,colonpos+1,length(mask)-colonpos),f,code);
            has_frac:=true;
          end;
        result:=code=0;
      end;


    { build a runtime call for an interpolation format spec: expr as 'mask'.
      dispatches to Format / FormatDateTime / FormatFloat / IntToHex
      based on expr type and mask shape. by default uses locale-invariant
      settings (`.` decimal, `,` thousand, English names); prefix `L` in
      the mask opts into the system locale via DefaultFormatSettings. }
    function handle_interp_format(p:tnode;const inmask:ansistring):tnode;
      var
        funcname,unitname,tname : string;
        srsym,fssym : tsym;
        srsymtable,fsst : tsymtable;
        paras,arrp,fsnode : tnode;
        digits : longint;
        code : integer;
        is_datetime,use_locale : boolean;
        mask : ansistring;
      begin
        result:=p;
        if not assigned(p.resultdef) then
          do_typecheckpass(p);
        if not assigned(p.resultdef) then
          exit;

        mask:=inmask;
        // 'L' prefix = opt into DefaultFormatSettings (locale-aware)
        use_locale:=(length(mask)>=1) and (mask[1]='L');
        if use_locale then
          delete(mask,1,1);

        // TDateTime/TDate/TTime are `type Double` aliases in `system`;
        // route them to FormatDateTime regardless of mask shape
        is_datetime:=false;
        if (p.resultdef.typ=floatdef) and assigned(p.resultdef.typesym) then
          begin
            tname:=upper(p.resultdef.typesym.realname);
            is_datetime:=(tname='TDATETIME') or (tname='TDATE') or (tname='TTIME');
          end;

        { pick function by mask shape and expr type }
        if (length(mask)>0) and (mask[1]='%') then
          funcname:='FORMAT'
        else if is_datetime then
          funcname:='FORMATDATETIME'
        else if is_real(p.resultdef) then
          funcname:='FORMATFLOAT'
        else if is_ordinal(p.resultdef) and (length(mask)>=1) and
                (mask[1] in ['x','X']) then
          funcname:='INTTOHEX'
        else if is_integer(p.resultdef) then
          // numeric masks (0, 000, 0.00, #,##0) on integers go through
          // FormatFloat; the value promotes to Extended (values above
          // 2^53 lose precision - use a %d / %.Nd mask for those)
          funcname:='FORMATFLOAT'
        else if is_stringlike(p.resultdef) and (length(mask)>0) and
                (mask[1]='%') then
          funcname:='FORMAT'
        else
          begin
            Message1(parser_e_interp_fmt_bad_type,mask);
            exit;
          end;

        { map known format functions to their canonical unit for the hint }
        if (funcname='FORMATDATETIME') or (funcname='FORMATFLOAT') or
           (funcname='INTTOHEX') or (funcname='FORMAT') then
          unitname:='SYSUTILS'
        else
          unitname:='';

        if not searchsym(funcname,srsym,srsymtable) or (srsym.typ<>procsym) then
          begin
            Message2(parser_e_interp_fmt_unit,funcname,unitname);
            exit;
          end;

        { build TFormatSettings.Invariant call node if we need the invariant
          overload (IntToHex has no locale arg) }
        fsnode:=nil;
        if (not use_locale) and (funcname<>'INTTOHEX') then
          begin
            if searchsym('TFORMATSETTINGS',fssym,fsst) and (fssym.typ=typesym) then
              fsnode:=ccallnode.createinternmethod(
                ctypenode.create(ttypesym(fssym).typedef),
                'INVARIANT',nil);
          end;

        { parameters prepended in source order: arg1 first, arg2 second, ...
          the chain ends up reversed and reverseparameters flips it back
          when building the call }
        if funcname='INTTOHEX' then
          begin
            { IntToHex(value, digits) - digits from mask[2..] }
            val(copy(mask,2,length(mask)-1),digits,code);
            if (code<>0) or (digits<0) then
              digits:=0;
            paras:=nil;
            paras:=ccallparanode.create(p,paras);
            paras:=ccallparanode.create(cordconstnode.create(digits,s32inttype,false),paras);
          end
        else if funcname='FORMAT' then
          begin
            { Format(mask, [expr][, fs]) }
            arrp:=carrayconstructornode.create(p,nil);
            include(tarrayconstructornode(arrp).arrayconstructornodeflags,acnf_allow_array_constructor);
            paras:=nil;
            paras:=ccallparanode.create(cstringconstnode.createstr(mask),paras);
            paras:=ccallparanode.create(arrp,paras);
            if assigned(fsnode) then
              paras:=ccallparanode.create(fsnode,paras);
          end
        else
          begin
            { FormatDateTime(mask, dt[, fs]) or FormatFloat(mask, val[, fs]) }
            paras:=nil;
            paras:=ccallparanode.create(cstringconstnode.createstr(mask),paras);
            paras:=ccallparanode.create(p,paras);
            if assigned(fsnode) then
              paras:=ccallparanode.create(fsnode,paras);
          end;

        result:=ccallnode.create(paras,tprocsym(srsym),srsymtable,nil,[],nil);
      end;


    // wrap classref / class / record / advanced record / type-helper ToString
    // through `expr.ClassName` or `expr.ToString`, falling back to a compile-
    // time string literal with the typename.
    function build_interp_type_dispatch(p:tnode):tnode;
      var
        sym : tsym;
        symt : tsymtable;
        tn : ansistring;
      begin
        result:=p;
        if p.resultdef.typ=classrefdef then
          begin
            result:=ccallnode.createinternmethod(p,'CLASSNAME',nil);
            exit;
          end;
        if p.resultdef.typ in [objectdef,recorddef] then
          begin
            sym:=search_struct_member(tabstractrecorddef(p.resultdef),'TOSTRING');
            if assigned(sym) and (sym.typ=procsym) then
              begin
                result:=ccallnode.create(nil,tprocsym(sym),sym.owner,p,[],nil);
                exit;
              end;
          end
        else
          if search_objectpascal_helper(p.resultdef,nil,'TOSTRING',sym,symt) and
             (sym.typ=procsym) then
            begin
              result:=ccallnode.create(nil,tprocsym(sym),symt,p,[],nil);
              exit;
            end;
        tn:=p.resultdef.typename;
        if tn<>'' then
          begin
            p.free;
            result:=cstringconstnode.createstr(tn);
            exit;
          end;
        Message1(parser_e_interp_fmt_bad_type,'anonymous type');
      end;


    // flatten `{expr}` into one or more fragments appended to interp_paras.
    // scalars pass through unchanged (WriteStr handles them at the outer
    // interp block). arrays are unrolled into `'[', e0, ', ', e1, ..., ']'`.
    // class / record / object go through type dispatch which yields a string.
    procedure handle_interp_elem(p:tnode;var interp_paras:tnode;var interp_count:longint);

        procedure add_frag(f:tnode);
        begin
          interp_paras:=ccallparanode.create(f,interp_paras);
          inc(interp_count);
        end;

      var
        arrdef : tarraydef;
        ac,nextac : tarrayconstructornode;
        cnt,i,lo : sizeint;
        elem : tnode;
        first : boolean;
      begin
        if p.nodetype=arrayconstructorn then
          begin
            add_frag(cstringconstnode.createstr('['));
            ac:=tarrayconstructornode(p);
            first:=true;
            while assigned(ac) do
              begin
                elem:=ac.left;
                if not assigned(elem) then break;
                ac.left:=nil;
                if not first then
                  add_frag(cstringconstnode.createstr(', '));
                handle_interp_elem(elem,interp_paras,interp_count);
                first:=false;
                nextac:=tarrayconstructornode(ac.right);
                ac:=nextac;
              end;
            add_frag(cstringconstnode.createstr(']'));
            p.free;
            exit;
          end;
        if not assigned(p.resultdef) then
          do_typecheckpass(p);
        if not assigned(p.resultdef) then
          begin
            add_frag(p);
            exit;
          end;
        if is_ordinal(p.resultdef) or is_real(p.resultdef) or is_stringlike(p.resultdef) then
          begin
            add_frag(p);
            exit;
          end;
        if (p.resultdef.typ=arraydef) and
           not is_conststring_array(p.resultdef) and
           (is_normal_array(p.resultdef) or is_array_constructor(p.resultdef) or
            is_open_array(p.resultdef)) then
          begin
            add_frag(cstringconstnode.createstr('['));
            arrdef:=tarraydef(p.resultdef);
            cnt:=arrdef.elecount;
            lo:=arrdef.lowrange;
            for i:=0 to cnt-1 do
              begin
                if i>0 then
                  add_frag(cstringconstnode.createstr(', '));
                elem:=cvecnode.create(
                  p.getcopy,
                  cordconstnode.create(lo+i,s32inttype,false));
                handle_interp_elem(elem,interp_paras,interp_count);
              end;
            add_frag(cstringconstnode.createstr(']'));
            p.free;
            exit;
          end;
        add_frag(build_interp_type_dispatch(p));
      end;


    { parses `sync begin..end` or the one-statement form `sync <stmt>` and
      lowers it to TThread.Synchronize(nil, <body as reference to procedure>):
      the main thread runs the body while the caller waits, so the by-reference
      captures stay valid. on the main thread the RTL runs it in place. }
    function parse_sync_block:tnode;
      var
        pd : tprocdef;
        ttpsym,thrsym : ttypesym;
        syncsym : tsym;
        thrdef : tobjectdef;
        p1 : tnode;
        again : boolean;
      begin
        pd:=read_async_block(false,current_scanner.token<>_BEGIN);
        if not assigned(pd) then
          exit(cerrornode.create);
        ttpsym:=search_named_unit_globaltype('CLASSES','TTHREADPROCEDURE',false);
        thrsym:=search_named_unit_globaltype('CLASSES','TTHREAD',false);
        if not assigned(ttpsym) or not assigned(thrsym) or
           not is_class(thrsym.typedef) then
          begin
            Message(parser_e_sync_requires_classes);
            exit(cerrornode.create);
          end;
        again:=false;
        p1:=nil;
        do_proc_call(pd.procsym,pd.owner,nil,true,again,p1,[],nil);
        if p1.nodetype=errorn then
          exit(p1);
        { convert the anonymous procedure to `reference to procedure` so the
          capturer holds the referenced locals by reference }
        p1:=ctypeconvnode.create(p1,ttpsym.typedef);
        thrdef:=tobjectdef(thrsym.typedef);
        syncsym:=tsym(thrdef.symtable.find('SYNCHRONIZE'));
        if not assigned(syncsym) or (syncsym.typ<>procsym) then
          internalerror(2026072001);
        result:=ccallnode.create(
          ccallparanode.create(p1,ccallparanode.create(cnilnode.create,nil)),
          tprocsym(syncsym),thrdef.symtable,
          cloadvmtaddrnode.create(ctypenode.create(thrdef)),[],nil);
      end;


    function factor(getaddr:boolean;flags:texprflags) : tnode;

         {---------------------------------------------
                         Factor_read_id
         ---------------------------------------------}

       procedure factor_read_id(out p1:tnode;out again:boolean);

         function findwithsymtable : boolean;
           var
             hp : psymtablestackitem;
           begin
             result:=true;
             hp:=symtablestack.stack;
             while assigned(hp) do
               begin
                 if hp^.symtable.symtabletype=withsymtable then
                   exit;
                 hp:=hp^.next;
               end;
             result:=false;
           end;

         { compile-time fold of `offsetof(TStruct.path.to.field)`. supports
           composition flatten in the path: each composition hop (anon embed,
           inline anon, expose) accumulates every carrier's own offset along
           the chain before descending into its record. caller has not
           consumed the OFFSETOF token yet. }
         function parse_offsetof_like_intrinsic(in_bits: boolean): tnode;
           { shared walker for offsetof() and bitoffsetof().

             offsetof returns the field offset in bytes; if any field along
             the path sits in a bitpacked record on a non-byte boundary the
             intrinsic raises parser_e_offsetof_subbyte_field. bitoffsetof
             always returns bits regardless of the record layout.

             field walking + bit accumulation lives in
             defutil.walk_field_path_bits so the preprocessor `$if`
             evaluator can reuse it. }
           var
             cursym : tsym;
             cursymtable : tsymtable;
             cur_def : tabstractrecorddef;
             bit_total : asizeint;
             last_field : tsym;
             haderr : boolean;
             fail_at : longint;
             path : array of TIDString;
             orgnames : array of string;
             last_field_name : string;
           begin
             consume(_ID); { eat OFFSETOF or BITOFFSETOF }
             consume(_LKLAMMER);
             haderr:=false;
             bit_total:=0;
             cur_def:=nil;
             last_field:=nil;
             last_field_name:='';
             if current_scanner.token<>_ID then
               begin
                 consume(_ID);
                 consume(_RKLAMMER);
                 exit(cerrornode.create);
               end;
             searchsym_type(current_scanner.pattern,cursym,cursymtable);
             if not assigned(cursym) or (cursym.typ<>typesym) or
                not (ttypesym(cursym).typedef.typ in [recorddef,objectdef]) then
               begin
                 Message1(sym_e_id_no_member,current_scanner.orgpattern);
                 haderr:=true;
               end
             else
               cur_def:=tabstractrecorddef(ttypesym(cursym).typedef);
             consume(_ID);
             { collect dot/comma-separated field names into a path array,
               then walk it via the shared helper. accept either
               Pascal-style `Type.field` or C-style `Type, field` separators }
             path:=nil;
             orgnames:=nil;
             while not haderr and (try_to_consume(_POINT) or try_to_consume(_COMMA)) do
               begin
                 if current_scanner.token<>_ID then
                   begin
                     consume(_ID);
                     haderr:=true;
                     break;
                   end;
                 Insert(current_scanner.pattern,path,Length(path));
                 Insert(current_scanner.orgpattern,orgnames,Length(orgnames));
                 consume(_ID);
               end;
             consume(_RKLAMMER);
             if not haderr and (Length(path)>0) then
               begin
                 if not walk_field_path_bits(cur_def,path,bit_total,last_field,fail_at) then
                   begin
                     Message1(sym_e_id_no_member,orgnames[fail_at]);
                     haderr:=true;
                   end
                 else if assigned(last_field) then
                   last_field_name:=orgnames[High(orgnames)];
               end;
             if haderr then
               result:=cerrornode.create
             else if in_bits then
               result:=cordconstnode.create(bit_total,sizeuinttype,true)
             else if (bit_total mod 8)<>0 then
               begin
                 Message1(parser_e_offsetof_subbyte_field,last_field_name);
                 result:=cerrornode.create;
               end
             else
               result:=cordconstnode.create(bit_total div 8,sizeuinttype,true);
           end;

         function parse_alignof_like_intrinsic(in_bits: boolean): tnode;
           { AlignOf and BitAlignOf intrinsics for composablerecords.

             AlignOf returns the type or field alignment in bytes,
             BitAlignOf returns it in bits. For a type argument the value
             is the type's natural alignment. For a field reference the
             value honours per-field `align N` / `bitalign N` overrides,
             falling back to the field type's alignment when no override
             is present. The field-path walk delegates to the shared
             defutil.walk_field_path_bits helper. }
           var
             cursym : tsym;
             cursymtable : tsymtable;
             cur_def : tabstractrecorddef;
             type_align : asizeint;
             found_field : tsym;
             haderr : boolean;
             bit_total_unused : asizeint;
             fail_at : longint;
             path : array of TIDString;
             orgnames : array of string;
           begin
             consume(_ID); { eat ALIGNOF or BITALIGNOF }
             consume(_LKLAMMER);
             haderr:=false;
             cur_def:=nil;
             type_align:=0;
             found_field:=nil;
             if current_scanner.token<>_ID then
               begin
                 consume(_ID);
                 consume(_RKLAMMER);
                 exit(cerrornode.create);
               end;
             searchsym(current_scanner.pattern,cursym,cursymtable);
             if not assigned(cursym) then
               begin
                 Message1(sym_e_id_no_member,current_scanner.orgpattern);
                 haderr:=true;
               end
             else if cursym.typ=typesym then
               begin
                 type_align:=ttypesym(cursym).typedef.alignment;
                 if ttypesym(cursym).typedef.typ in [recorddef,objectdef] then
                   cur_def:=tabstractrecorddef(ttypesym(cursym).typedef);
               end
             else if cursym.typ in [staticvarsym,localvarsym,paravarsym,fieldvarsym,absolutevarsym] then
               begin
                 { accept a variable / parameter / field as the operand;
                   its type's alignment stands in for the typename case }
                 type_align:=tabstractvarsym(cursym).vardef.alignment;
                 if tabstractvarsym(cursym).vardef.typ in [recorddef,objectdef] then
                   cur_def:=tabstractrecorddef(tabstractvarsym(cursym).vardef);
               end
             else
               begin
                 Message1(sym_e_id_no_member,current_scanner.orgpattern);
                 haderr:=true;
               end;
             consume(_ID);
             { collect optional `.field` / `,field` chain }
             path:=nil;
             orgnames:=nil;
             while not haderr and (try_to_consume(_POINT) or try_to_consume(_COMMA)) do
               begin
                 if current_scanner.token<>_ID then
                   begin
                     consume(_ID);
                     haderr:=true;
                     break;
                   end;
                 Insert(current_scanner.pattern,path,Length(path));
                 Insert(current_scanner.orgpattern,orgnames,Length(orgnames));
                 consume(_ID);
               end;
             consume(_RKLAMMER);
             if not haderr and (Length(path)>0) then
               begin
                 if cur_def=nil then
                   begin
                     Message1(sym_e_id_no_member,orgnames[0]);
                     haderr:=true;
                   end
                 else if not walk_field_path_bits(cur_def,path,bit_total_unused,found_field,fail_at) then
                   begin
                     Message1(sym_e_id_no_member,orgnames[fail_at]);
                     haderr:=true;
                   end;
               end;
             if haderr then
               exit(cerrornode.create);
             if assigned(found_field) then
               begin
                 if in_bits then
                   begin
                     if tfieldvarsym(found_field).custom_bitalign>0 then
                       result:=cordconstnode.create(tfieldvarsym(found_field).custom_bitalign,sizeuinttype,true)
                     else if tfieldvarsym(found_field).custom_align>0 then
                       result:=cordconstnode.create(tfieldvarsym(found_field).custom_align*8,sizeuinttype,true)
                     else
                       result:=cordconstnode.create(tfieldvarsym(found_field).vardef.alignment*8,sizeuinttype,true);
                   end
                 else
                   begin
                     if tfieldvarsym(found_field).custom_align>0 then
                       result:=cordconstnode.create(tfieldvarsym(found_field).custom_align,sizeuinttype,true)
                     else
                       result:=cordconstnode.create(tfieldvarsym(found_field).vardef.alignment,sizeuinttype,true);
                   end;
               end
             else
               begin
                 if in_bits then
                   result:=cordconstnode.create(type_align*8,sizeuinttype,true)
                 else
                   result:=cordconstnode.create(type_align,sizeuinttype,true);
               end;
           end;

         var
           srsym: tsym;
           srsymtable: TSymtable;
           labsym: tlabelsym;
           hdef: tdef;
           pd: tprocdef;
           orgstoredpattern,
           storedpattern: string;
           t : ttoken;
           consumeid,
           wasgenericdummy,
           allowspecialize,
           isspecialize,
           unit_found : boolean;
           dummypos,
           tokenpos: tfileposinfo;
           spezcontext : tspecializationcontext;
           cufflags : tconsume_unitsym_flags;
         begin
           { allow post fix operators }
           again:=true;

           { preinitalize tokenpos }
           tokenpos:=current_filepos;
           p1:=nil;
           spezcontext:=nil;

           { avoid warning }
           fillchar(dummypos,sizeof(dummypos),0);

           allowspecialize:=not (m_implicit_generics in current_settings.modeswitches) and
                            not (ef_had_specialize in flags) and
                            (block_type in inline_specialization_block_types);
           if allowspecialize and (current_scanner.token=_ID) and (current_scanner.idtoken=_SPECIALIZE) then
             begin
               consume(_ID);
               isspecialize:=true;
             end
           else
             isspecialize:=ef_had_specialize in flags;

           { composablerecords: offsetof(TStruct.path.to.field) returns byte
             offset; bitoffsetof returns bit offset (always defined, even for
             sub-byte bitpacked fields). pattern-detected here so we don't
             depend on a sysconst symbol (which would require an RTL rebuild). }
           if (current_scanner.token=_ID) and
              (m_composable_records in current_settings.modeswitches) and
              (current_scanner.pattern='OFFSETOF') then
             begin
               p1:=parse_offsetof_like_intrinsic(false);
               again:=false;
               exit;
             end;
           if (current_scanner.token=_ID) and
              (m_composable_records in current_settings.modeswitches) and
              (current_scanner.pattern='BITOFFSETOF') then
             begin
               p1:=parse_offsetof_like_intrinsic(true);
               again:=false;
               exit;
             end;
           if (current_scanner.token=_ID) and
              (m_composable_records in current_settings.modeswitches) and
              (current_scanner.pattern='ALIGNOF') then
             begin
               p1:=parse_alignof_like_intrinsic(false);
               again:=false;
               exit;
             end;
           if (current_scanner.token=_ID) and
              (m_composable_records in current_settings.modeswitches) and
              (current_scanner.pattern='BITALIGNOF') then
             begin
               p1:=parse_alignof_like_intrinsic(true);
               again:=false;
               exit;
             end;

           { `await <future>` is a prefix operator joining a worker thread. it
             binds at factor level, so `await x + 1` is `(await x) + 1`. only
             intercept when no `await` symbol is in scope, so a user-declared
             `await` keeps resolving normally. }
           if (current_scanner.token=_ID) and
              (m_asyncawait in current_settings.modeswitches) and
              (current_scanner.pattern='AWAIT') then
             begin
               searchsym(current_scanner.pattern,srsym,srsymtable);
               if not assigned(srsym) then
                 begin
                   consume(_ID);
                   p1:=cawaitnode.create(factor(false,[]));
                   again:=false;
                   exit;
                 end;
             end;

           { `async <call>` spawns the call on a worker thread (snapshotting its
             arguments); `async begin..end` runs the block, capturing referenced
             locals by reference through the anonymous-function machinery. a
             statement keyword after `async` starts the one-statement block
             form (`async while ... do ...`), same capture rules as the block.
             all yield a future. same soft-keyword guard as `await`. }
           if (current_scanner.token=_ID) and
              (m_asyncawait in current_settings.modeswitches) and
              (current_scanner.pattern='ASYNC') then
             begin
               searchsym(current_scanner.pattern,srsym,srsymtable);
               if not assigned(srsym) then
                 begin
                   consume(_ID);
                   if current_scanner.token in [_BEGIN,_IF,_CASE,_MATCH,_TRY,
                        _WHILE,_FOR,_REPEAT,_WITH,_GOTO,_RAISE] then
                     begin
                       pd:=read_async_block(true,current_scanner.token<>_BEGIN);
                       do_proc_call(pd.procsym,pd.owner,nil,
                         not (current_scanner.token in [_POINT,_CARET,_LECKKLAMMER]),
                         again,p1,[],nil);
                       { convert the anonymous procedure to a function reference
                         so the capturer holds the referenced locals by reference }
                       if (p1.nodetype<>errorn) and assigned(pd) then
                         p1:=ctypeconvnode.create(p1,async_block_funcref(pd));
                       p1:=casyncnode.create(p1,true);
                     end
                   else
                     { parse a full expression, not a factor: a generic
                       specialization (`async Foo<Bar>(x)`) is disambiguated at
                       the operator level. anything that is not a call is
                       rejected during typecheck anyway }
                     p1:=casyncnode.create(comp_expr([]),false);
                   again:=false;
                   exit;
                 end;
             end;

           { the two-argument SwapValues(a,b) is a bitwise swap builtin that needs no
             unit beyond System. only intercept when no SwapValues symbol is in scope,
             so a user-declared SwapValues keeps resolving normally. }
           if (current_scanner.token=_ID) and
              (m_unleashed in current_settings.modeswitches) and
              (current_scanner.pattern='SWAPVALUES') then
             begin
               searchsym(current_scanner.pattern,srsym,srsymtable);
               if not assigned(srsym) then
                 begin
                   p1:=inline_swapvalues;
                   again:=false;
                   exit;
                 end;
             end;

           { pre/post inc/dec builtins returning a value. only intercept when
             no symbol of that name is in scope, so a user-declared PreInc etc
             keeps resolving normally }
           if (current_scanner.token=_ID) and
              (m_prepost_incdec in current_settings.modeswitches) and
              ((current_scanner.pattern='PREINC') or
               (current_scanner.pattern='POSTINC') or
               (current_scanner.pattern='PREDEC') or
               (current_scanner.pattern='POSTDEC')) then
             begin
               searchsym(current_scanner.pattern,srsym,srsymtable);
               if not assigned(srsym) then
                 begin
                   if current_scanner.pattern='PREINC' then
                     p1:=inline_prepost_incdec(in_preinc_x)
                   else if current_scanner.pattern='POSTINC' then
                     p1:=inline_prepost_incdec(in_postinc_x)
                   else if current_scanner.pattern='PREDEC' then
                     p1:=inline_prepost_incdec(in_predec_x)
                   else
                     p1:=inline_prepost_incdec(in_postdec_x);
                   again:=false;
                   exit;
                 end;
             end;

           { first check for identifier }
           if current_scanner.token<>_ID then
             begin
               srsym:=generrorsym;
               srsymtable:=nil;
               consume(_ID);
               unit_found:=false;
             end
           else
             begin
               storedpattern:=current_scanner.pattern;
               orgstoredpattern:=current_scanner.orgpattern;
               { store the position of the token before consuming it }
               tokenpos:=current_filepos;
               consumeid:=true;
               srsym:=nil;
               if ef_check_attr_suffix in flags then
                 begin
                   if not (ef_type_only in flags) then
                     internalerror(2019063001);
                   consume(_ID);
                   consumeid:=false;
                   if current_scanner.token<>_POINT then
                     searchsym_type(storedpattern+custom_attribute_suffix,srsym,srsymtable);
                 end;
               if not assigned(srsym) then
                 begin
                   if ef_type_only in flags then
                     searchsym_type(storedpattern,srsym,srsymtable)
                   else
                     searchsym(storedpattern,srsym,srsymtable);
                 end;
               { handle unit specification like System.Writeln }
               if not isspecialize then
                 begin
                   cufflags:=[];
                   if consumeid then
                     include(cufflags,cuf_consume_id);
                   if allowspecialize then
                     include(cufflags,cuf_allow_specialize);
                   if ef_check_attr_suffix in flags then
                     include(cufflags,cuf_check_attr_suffix);
                   unit_found:=try_consume_unitsym(srsym,srsymtable,t,cufflags,isspecialize,current_scanner.pattern);
                   if unit_found then
                     consumeid:=true;
                 end
               else
                 begin
                   unit_found:=false;
                   t:=_ID;
                 end;
               if consumeid then
                 begin
                   storedpattern:=current_scanner.pattern;
                   orgstoredpattern:=current_scanner.orgpattern;
                   { store the position of the token before consuming it }
                   tokenpos:=current_filepos;
                   consume(t);
                 end;
               { named parameter support }
               found_arg_name:=false;

               if not(unit_found) and
                   not isspecialize and
                  named_args_allowed and
                  (current_scanner.token=_ASSIGNMENT) then
                  begin
                    found_arg_name:=true;
                    p1:=cstringconstnode.createstr(orgstoredpattern);
                    consume(_ASSIGNMENT);
                    exit;
                  end;

               if isspecialize then
                 begin
                   if not assigned(srsym) then
                     begin
                       identifier_not_found(orgstoredpattern,tokenpos);
                       srsym:=generrorsym;
                       srsymtable:=nil;
                     end
                   else
                     begin
                       if not unit_found then
                         srsymtable:=nil;
                       {$push}
                       {$warn 5036 off}
                       hdef:=generate_specialization_phase1(spezcontext,nil,unit_found,nil,orgstoredpattern,srsymtable,dummypos);
                       {$pop}
                       if hdef=generrordef then
                         begin
                           spezcontext.free;
                           spezcontext:=nil;
                           srsym:=generrorsym;
                           srsymtable:=nil;
                         end
                       else
                         begin
                           if hdef.typ in [objectdef,recorddef,procvardef,arraydef] then
                             begin
                               hdef:=generate_specialization_phase2(spezcontext,tstoreddef(hdef),false,'');
                               spezcontext.free;
                               spezcontext:=nil;
                               if hdef<>generrordef then
                                 begin
                                   srsym:=hdef.typesym;
                                   srsymtable:=srsym.owner;
                                 end
                               else
                                 begin
                                   srsym:=generrorsym;
                                   srsymtable:=nil;
                                 end;
                             end
                           else
                             if hdef.typ=procdef then
                               begin
                                 if not(block_type in inline_specialization_block_types) then
                                   message(parser_e_illegal_expression);
                                 srsym:=tprocdef(hdef).procsym;
                                 if assigned(spezcontext.symtable) then
                                   srsymtable:=spezcontext.symtable
                                 else
                                   srsymtable:=srsym.owner;
                               end
                             else
                               internalerror(2015061204);
                         end;
                     end;
                 end;

               wasgenericdummy:=false;
               if assigned(srsym) and
                   (sp_generic_dummy in srsym.symoptions) and
                   (srsym.typ in [procsym,typesym]) and
                   (
                     (
                       (m_implicit_generics in current_settings.modeswitches) and
                       not (current_scanner.token in [_LT, _LSHARPBRACKET]) and
                       (
                         (
                           (srsym.typ=typesym) and
                           (ttypesym(srsym).typedef.typ=undefineddef)
                         ) or (
                           (srsym.typ=procsym) and
                           (tprocsym(srsym).procdeflist.count=0)
                         )
                       )
                     )
                     or
                     (
                       not (m_implicit_generics in current_settings.modeswitches) and
                       not isspecialize and
                       (
                         not parse_generic or
                         not (
                           assigned(current_structdef) and
                           assigned(get_generic_in_hierarchy_by_name(srsym,current_structdef))
                         )
                       )
                     )
                   ) then
                 begin
                   srsym:=resolve_generic_dummysym(srsym.name);
                   if assigned(srsym) then
                     srsymtable:=srsym.owner
                   else
                     begin
                       srsymtable:=nil;
                       wasgenericdummy:=true;
                     end;
                 end;

               { check hints, but only if it isn't a potential generic symbol;
                 that is checked in sub_expr if it isn't a generic }
               if assigned(srsym) and
                   not (
                     (srsym.typ=typesym) and
                     (
                       (ttypesym(srsym).typedef.typ in [recorddef,objectdef,arraydef,procvardef,undefineddef]) or
                       (
                         (ttypesym(srsym).typedef.typ=errordef) and
                         (sp_generic_dummy in srsym.symoptions)
                       )
                     ) and
                     not (sp_generic_para in srsym.symoptions) and
                     (current_scanner.token in [_LT, _LSHARPBRACKET])
                   ) then
                 check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg,tokenpos);

               { if nothing found give error and return errorsym }
               if not assigned(srsym) or
                   { is this a generic dummy symbol? }
                   ((srsym.typ=typesym) and
                   assigned(ttypesym(srsym).typedef) and
                   (ttypesym(srsym).typedef.typ=undefineddef) and
                   not (sp_generic_para in srsym.symoptions) and
                   not (current_scanner.token in [_LT, _LSHARPBRACKET]) and
                   not (
                     { in non-Delphi modes the generic class' name without a
                       "specialization" or "<T>" may be used to identify the
                       current class }
                     (sp_generic_dummy in srsym.symoptions) and
                     assigned(current_structdef) and
                     (df_generic in current_structdef.defoptions) and
                     not (m_implicit_generics in current_settings.modeswitches) and
                     assigned(get_generic_in_hierarchy_by_name(srsym,current_structdef))
                   )) and
                   { it could be a rename of a generic para }
                   { Note: if this generates false positives we'll need to
                           include a "basesym" to tsym to track the original
                           symbol }
                   not (sp_explicitrename in srsym.symoptions) then
                 begin
                   if not assigned(srsym) and
                      (ef_allow_lazy_label in flags) and
                      (
                        ((current_scanner.token=_COLON) and
                         get_or_create_labelsym(orgstoredpattern,labsym,srsymtable)) or
                        ((current_scanner.token=_LECKKLAMMER) and
                         get_or_create_arraylabelsym(orgstoredpattern,labsym,srsymtable))
                      ) then
                     srsym:=labsym;
                   { if a generic is parsed and when we are inside an with block,
                     a symbol might not be defined }
                   if not assigned(srsym) and
                      assigned(current_procinfo) and (df_generic in current_procinfo.procdef.defoptions) and
                      findwithsymtable then
                     begin
                       { create dummy symbol, it will be freed later on }
                       srsym:=tstoredsym.create(undefinedsym,'$undefinedsym');
                       srsymtable:=nil;
                     end
                   else if not assigned(srsym) then
                     begin
                       if wasgenericdummy then
                         messagepos(tokenpos,parser_e_no_generics_as_types)
                       else
                         identifier_not_found(orgstoredpattern,tokenpos);
                       srsym:=generrorsym;
                       srsymtable:=nil;
                     end;
                 end;
             end;

           { Access to funcret or need to call the function? }
           if (srsym.typ in [absolutevarsym,localvarsym,paravarsym]) and
              (vo_is_funcret in tabstractvarsym(srsym).varoptions) and
              { result(x) is not allowed }
              not(vo_is_result in tabstractvarsym(srsym).varoptions) and
              (
               (current_scanner.token=_LKLAMMER) or
               (
                (([m_tp7,m_delphi,m_mac,m_iso,m_extpas] * current_settings.modeswitches) <> []) and
                (afterassignment or in_args)
               )
              ) then
            begin
              hdef:=tdef(srsym.owner.defowner);
              if assigned(hdef) and
                 (hdef.typ=procdef) then
                srsym:=tprocdef(hdef).procsym
              else
                begin
                  Message(parser_e_illegal_expression);
                  srsym:=generrorsym;
                end;
              srsymtable:=srsym.owner;
            end;

            begin
              p1:=factor_handle_sym(srsym,srsymtable,again,getaddr,unit_found,flags,spezcontext);

              if assigned(spezcontext) then
                internalerror(2015061207);

              if assigned(p1) and (p1.nodetype<>errorn) then
                p1.fileinfo:=tokenpos;
            end;
         end;

         {---------------------------------------------
                         Factor_Read_Set
         ---------------------------------------------}

         { Peeks whether the tokens right after _LKLAMMER start a named
           tuple literal (ID ':'). Uses scanner token recording; skipped
           if an outer recording is already active. }
         function is_named_tuple_literal_ahead:boolean;
           var
             peekbuf : tdynamicarray;
           begin
             result:=false;
             if current_scanner.is_recording_tokens then
               exit;
             if current_scanner.token<>_ID then
               exit;
             peekbuf:=tdynamicarray.create(32);
             current_scanner.startrecordtokens(peekbuf);
             consume(_ID);
             current_scanner.stoprecordtokens;
             result:=current_scanner.token=_COLON;
             current_scanner.startreplaytokens(peekbuf,false);
           end;


         { Parses a named tuple literal body after _LKLAMMER was consumed
           and the first token is an identifier starting a 'name:' pair.
           Builds a temp tuple record with user-chosen field names and
           the parsed expression types. Consumes _RKLAMMER. }
         function named_tuple_lit_as_tempref:tnode;
           var
             names : array of TIDString;
             exprs : array of tnode;
             count : longint;
             i : longint;
             recdef : trecorddef;
             elemdef : tdef;
             blk : tblocknode;
             laststmt : tstatementnode;
             tempnode : ttempcreatenode;
             fieldsym : tsym;
           begin
             count:=0;
             setlength(names,4);
             setlength(exprs,4);
             repeat
               if count>=length(names) then
                 begin
                   setlength(names,length(names)*2);
                   setlength(exprs,length(exprs)*2);
                 end;
               names[count]:=current_scanner.orgpattern;
               consume(_ID);
               consume(_COLON);
               exprs[count]:=comp_expr([ef_accept_equal]);
               inc(count);
             until not try_to_consume(_COMMA);
             consume(_RKLAMMER);

             { promote common literal types }
             for i:=0 to count-1 do
               begin
                 typecheckpass(exprs[i]);
                 elemdef:=exprs[i].resultdef;
                 if is_integer(elemdef) and
                    (torddef(elemdef).ordtype in [s8bit,u8bit,s16bit,u16bit]) then
                   elemdef:=s32inttype
                 else if is_conststring_array(elemdef) or is_char(elemdef) then
                   begin
                     if m_default_unicodestring in current_settings.modeswitches then
                       elemdef:=cunicodestringtype
                     else if m_default_ansistring in current_settings.modeswitches then
                       elemdef:=getansistringdef
                     else
                       elemdef:=cshortstringtype;
                   end;
                 if elemdef<>exprs[i].resultdef then
                   begin
                     exprs[i]:=ctypeconvnode.create_internal(exprs[i],elemdef);
                     typecheckpass(exprs[i]);
                   end;
               end;

             recdef:=make_tuple_recdef;
             for i:=0 to count-1 do
               add_tuple_field(recdef,names[i],exprs[i].resultdef);
             trecordsymtable(recdef.symtable).addalignmentpadding;

             blk:=internalstatements(laststmt);
             tempnode:=ctempcreatenode.create(recdef,recdef.size,tt_persistent,false);
             addstatement(laststmt,tempnode);
             for i:=0 to count-1 do
               begin
                 fieldsym:=tsym(trecordsymtable(recdef.symtable).find(upper(names[i])));
                 addstatement(laststmt,
                   cassignmentnode.create(
                     csubscriptnode.create(fieldsym,ctemprefnode.create(tempnode)),
                     exprs[i]));
               end;
             addstatement(laststmt,ctempdeletenode.create_normal_temp(tempnode));
             addstatement(laststmt,ctemprefnode.create(tempnode));
             result:=blk;
           end;


         { Given a first expression parsed right after _LKLAMMER and the
           comma still pending, parses remaining comma-separated expressions
           up to _RKLAMMER and returns a block that evaluates to a temp
           tuple record holding (first_expr, rest...). Used by both array
           constructor elements and plain (e1, e2, ...) factors. }
         function tuple_lit_as_tempref(first_expr:tnode):tnode;
         var
           exprs : array of tnode;
           exprcount : longint;
           i : longint;
           recdef : trecorddef;
           blk : tblocknode;
           laststmt : tstatementnode;
           tempnode : ttempcreatenode;
           fieldsym : tsym;
           elemdef : tdef;
         begin
           setlength(exprs,4);
           exprs[0]:=first_expr;
           exprcount:=1;
           while try_to_consume(_COMMA) do
             begin
               if exprcount>=length(exprs) then
                 setlength(exprs,length(exprs)*2);
               exprs[exprcount]:=comp_expr([ef_accept_equal]);
               inc(exprcount);
             end;
           consume(_RKLAMMER);

           { promote common literal types so [(1,'a'),(2,'b')] matches
             declared types like array-of-(Integer, String) }
           for i:=0 to exprcount-1 do
             begin
               typecheckpass(exprs[i]);
               elemdef:=exprs[i].resultdef;
               if is_integer(elemdef) and
                  (torddef(elemdef).ordtype in [s8bit,u8bit,s16bit,u16bit]) then
                 elemdef:=s32inttype
               else if is_conststring_array(elemdef) or is_char(elemdef) then
                 begin
                   if m_default_unicodestring in current_settings.modeswitches then
                     elemdef:=cunicodestringtype
                   else if m_default_ansistring in current_settings.modeswitches then
                     elemdef:=getansistringdef
                   else
                     elemdef:=cshortstringtype;
                 end;
               if elemdef<>exprs[i].resultdef then
                 begin
                   exprs[i]:=ctypeconvnode.create_internal(exprs[i],elemdef);
                   typecheckpass(exprs[i]);
                 end;
             end;

           recdef:=make_tuple_recdef;
           for i:=0 to exprcount-1 do
             add_tuple_field(recdef,'_'+tostr(i+1),exprs[i].resultdef);
           trecordsymtable(recdef.symtable).addalignmentpadding;

           blk:=internalstatements(laststmt);
           tempnode:=ctempcreatenode.create(recdef,recdef.size,tt_persistent,false);
           addstatement(laststmt,tempnode);
           for i:=0 to exprcount-1 do
             begin
               fieldsym:=tsym(trecordsymtable(recdef.symtable).find('_'+tostr(i+1)));
               addstatement(laststmt,
                 cassignmentnode.create(
                   csubscriptnode.create(fieldsym,ctemprefnode.create(tempnode)),
                   exprs[i]));
             end;
           addstatement(laststmt,ctempdeletenode.create_normal_temp(tempnode));
           addstatement(laststmt,ctemprefnode.create(tempnode));
           result:=blk;
         end;

         { Read a set between [] }
         function factor_read_set:tnode;
         var
           p1,p2 : tnode;
           lastp,
           buildp : tarrayconstructornode;
         begin
           buildp:=nil;
           lastp:=nil;
         { be sure that a least one arrayconstructn is used, also for an
           empty [] }
           if current_scanner.token=_RECKKLAMMER then
             buildp:=carrayconstructornode.create(nil,buildp)
           else
            repeat
              { tuple literal as array element is recognised by factor's own
                _LKLAMMER path, which leaves the parser in the right state to
                continue the surrounding expression (e.g. `(1)/100`) }
              p1:=comp_expr([ef_accept_equal]);
              if try_to_consume(_POINTPOINT) then
                begin
                  p2:=comp_expr([ef_accept_equal]);
                  p1:=carrayconstructorrangenode.create(p1,p2);
                end;
               { insert at the end of the tree, to get the correct order }
             if not assigned(buildp) then
               begin
                 buildp:=carrayconstructornode.create(p1,nil);
                 lastp:=buildp;
               end
             else
               begin
                 lastp.right:=carrayconstructornode.create(p1,nil);
                 lastp:=tarrayconstructornode(lastp.right);
               end;
           { there could be more elements }
           until not try_to_consume(_COMMA);
           if block_type in [bt_body,bt_except] then
             Include(buildp.arrayconstructornodeflags, acnf_allow_array_constructor);
           factor_read_set:=buildp;
         end;

         function can_load_self_node: boolean;
         begin
           result:=false;
           if (block_type in [bt_const,bt_type,bt_const_type,bt_var_type]) or
              not assigned(current_structdef) or
              not assigned(current_procinfo) then
             exit;
           result:=not current_procinfo.get_normal_proc.procdef.no_self_node;
         end;


      {---------------------------------------------
                      Factor (Main)
      ---------------------------------------------}

      var
         l          : longint;
         ic         : int64;
         qc         : qword;
         ic128      : tconstexprint;
         ic128err   : boolean;
         p1         : tnode;
         code       : integer;
         srsym      : tsym;
         srsymtable : TSymtable;
         pd         : tprocdef;
         hclassdef  : tobjectdef;
         d          : bestreal;
         hs,hsorg   : string;
         hdef       : tdef;
         filepos    : tfileposinfo;
         callflags  : tcallnodeflags;
         idstr      : tidstring;
         spezcontext : tspecializationcontext;
         isspecialize,
         mightbegeneric,
         useself,
         dopostfix,
         again,
         updatefpos,
         nodechanged  : boolean;
         oldprocvardef : tprocvardef;
         oldfuncrefdef : tobjectdef;
         interp_paras : tnode;
         interp_count : longint;
         interp_has_expr : boolean;
         interp_stmt : tstatementnode;
         interp_temp : ttempcreatenode;
         interp_last : tnode;
         interp_inl : tinlinenode;
         interp_mask : ansistring;
         interp_w,interp_f : longint;
         interp_hasf : boolean;
      begin
        { can't keep a copy of p1 and compare pointers afterwards, because
          p1 may be freed and reallocated in the same place!  }
        dopostfix:=true;
        updatefpos:=false;
        p1:=nil;
        filepos:=current_tokenpos;
        again:=false;
        pd:=nil;
        isspecialize:=false;
        if current_scanner.token=_ID then
         begin
           again:=true;
           { Handle references to self }
           if (current_scanner.idtoken=_SELF) and can_load_self_node then
             begin
               p1:=load_self_node;
               consume(_ID);
               again:=true;
             end
           else
             factor_read_id(p1,again);

           if assigned(p1) then
            begin
              { factor_read_id will set the filepos to after the id,
                and in case of _SELF the filepos will already be the
                same as filepos (so setting it again doesn't hurt).  }
              p1.fileinfo:=filepos;
              filepos:=current_tokenpos;
            end;
           { handle post fix operators }
           if (p1.nodetype=specializen) then
             { post fix operators are handled after specialization }
             dopostfix:=false
           else
             if (m_implicit_generics in current_settings.modeswitches) and
                 (block_type in inline_specialization_block_types) and
                 (current_scanner.token in [_LT,_LSHARPBRACKET]) then
               begin
                 idstr:='';
                 case p1.nodetype of
                   typen:
                     idstr:=ttypenode(p1).typesym.name;
                   loadvmtaddrn:
                     if tloadvmtaddrnode(p1).left.nodetype=typen then
                       idstr:=ttypenode(tloadvmtaddrnode(p1).left).typesym.name;
                   loadn:
                     idstr:=tloadnode(p1).symtableentry.name;
                   calln:
                     idstr:=tcallnode(p1).symtableprocentry.name;
                   else
                     ;
                 end;
                 { if this is the case then the postfix handling is done in
                   sub_expr if necessary }
                 dopostfix:=not could_be_generic(idstr);
               end;
           { TP7 ugliness: @proc^ is parsed as (@proc)^, but @notproc^ is parsed
             as @(notproc^) }
           if (m_tp_procvar in current_settings.modeswitches) and (current_scanner.token=_CARET) and
              getaddr and (p1.nodetype=loadn) and (tloadnode(p1).symtableentry.typ=procsym) then
             dopostfix:=false;
           { maybe an additional parameter instead of misusing hadspezialize? }
           if dopostfix and not (ef_had_specialize in flags) then
             updatefpos:=postfixoperators(p1,again,getaddr);
         end
        else
         begin
           updatefpos:=true;
           case current_scanner.token of
             _RETURN :
                begin
                  consume(_RETURN);
                  p1:=nil;
                  if not(current_scanner.token in [_SEMICOLON,_ELSE,_END]) then
                    begin
                      p1:=comp_expr([ef_accept_equal]);
                      if not assigned(current_procinfo) or
                         (current_procinfo.procdef.proctypeoption in [potype_constructor,potype_destructor]) or
                         is_void(current_procinfo.procdef.returndef) then
                        begin
                          Message(parser_e_void_function);
                          { recovery }
                          p1.free;
                          p1:=nil;
                        end;
                    end;
                  p1 := cexitnode.create(p1);
                end;
             _INHERITED :
               begin
                 again:=true;
                 consume(_INHERITED);
                 if assigned(current_procinfo) and
                    assigned(current_structdef) and
                    ((current_structdef.typ=objectdef) or
                     ((target_info.system in systems_jvm) and
                      (current_structdef.typ=recorddef)))then
                  begin
                    { for record helpers in mode Delphi "inherited" is not
                      allowed }
                    if is_objectpascal_helper(current_structdef) and
                        (m_delphi in current_settings.modeswitches) and
                        (tobjectdef(current_structdef).helpertype=ht_record) then
                      Message(parser_e_inherited_not_in_record);
                    if (current_structdef.typ=objectdef) then
                      begin
                        hclassdef:=tobjectdef(current_structdef).childof;
                        { Objective-C categories *replace* methods in the class
                          they extend, or add methods to it. So calling an
                          inherited method always calls the method inherited from
                          the parent of the extended class }
                        if is_objccategory(current_structdef) then
                          hclassdef:=hclassdef.childof;
                      end
                    else if target_info.system in systems_jvm then
                      hclassdef:=java_fpcbaserecordtype
                    else
                      internalerror(2012012401);
                    spezcontext:=nil;
                    { if inherited; only then we need the method with
                      the same name }
                    if current_scanner.token <> _ID then
                     begin
                       hs:=current_procinfo.procdef.procsym.name;
                       hsorg:=current_procinfo.procdef.procsym.realname;
                       anon_inherited:=true;
                       { For message methods we need to search using the message
                         number or string }
                       pd:=tprocdef(tprocsym(current_procinfo.procdef.procsym).ProcdefList[0]);
                       srdef:=nil;
                       if (po_msgint in pd.procoptions) then
                         searchsym_in_class_by_msgint(hclassdef,pd.messageinf.i,srdef,srsym,srsymtable)
                       else
                        if (po_msgstr in pd.procoptions) then
                          searchsym_in_class_by_msgstr(hclassdef,pd.messageinf.str^,srsym,srsymtable)
                       else
                       { helpers have their own ways of dealing with inherited }
                       if is_objectpascal_helper(current_structdef) then
                         searchsym_in_helper(tobjectdef(current_structdef),tobjectdef(current_structdef),hs,srsym,srsymtable,[ssf_has_inherited])
                       else
                         searchsym_in_class(hclassdef,current_structdef,hs,srsym,srsymtable,[ssf_search_helper]);
                     end
                    else
                     begin
                       if not (m_implicit_generics in current_settings.modeswitches) and
                           (block_type in inline_specialization_block_types) and
                           (current_scanner.token=_ID) and
                           (current_scanner.idtoken=_SPECIALIZE) then
                         begin
                           consume(_ID);
                           if current_scanner.token<>_ID then
                             message(parser_e_methode_id_expected);
                           isspecialize:=true;
                         end
                       else
                         isspecialize:=false;
                       hs:=current_scanner.pattern;
                       hsorg:=current_scanner.orgpattern;
                       consume(_ID);
                       anon_inherited:=false;
                       { helpers have their own ways of dealing with inherited }
                       if is_objectpascal_helper(current_structdef) then
                         searchsym_in_helper(tobjectdef(current_structdef),tobjectdef(current_structdef),hs,srsym,srsymtable,[ssf_has_inherited])
                       else
                         searchsym_in_class(hclassdef,current_structdef,hs,srsym,srsymtable,[ssf_search_helper]);
                       if isspecialize and assigned(srsym) then
                         begin
                           if not handle_specialize_inline_specialization(srsym,false,srsymtable,spezcontext) then
                             srsym:=nil;
                         end;
                     end;
                    if assigned(srsym) then
                     begin
                       mightbegeneric:=(m_implicit_generics in current_settings.modeswitches) and
                                         (current_scanner.token in [_LT,_LSHARPBRACKET]) and
                                         (sp_generic_dummy in srsym.symoptions);
                       { load the procdef from the inherited class and
                         not from self }
                       case srsym.typ of
                         typesym,
                         procsym:
                           begin
                             { typesym is only a valid choice if we're dealing
                               with a potential generic }
                             if (srsym.typ=typesym) and not mightbegeneric then
                               begin
                                 Message(parser_e_methode_id_expected);
                                 p1:=cerrornode.create;
                               end
                             else
                               begin
                                 useself:=false;
                                 if is_objectpascal_helper(current_structdef) then
                                   begin
                                     { for a helper load the procdef either from the
                                       extended type, from the parent helper or from
                                       the extended type of the parent helper
                                       depending on the def the found symbol belongs
                                       to }
                                     if (srsym.Owner.defowner.typ=objectdef) and
                                         is_objectpascal_helper(tobjectdef(srsym.Owner.defowner)) then
                                       if def_is_related(current_structdef,tdef(srsym.Owner.defowner)) and
                                           assigned(tobjectdef(current_structdef).childof) then
                                         hdef:=tobjectdef(current_structdef).childof
                                       else
                                         begin
                                           hdef:=tobjectdef(srsym.Owner.defowner).extendeddef;
                                           useself:=true;
                                         end
                                     else
                                       begin
                                         hdef:=tdef(srsym.Owner.defowner);
                                         useself:=true;
                                       end;
                                   end
                                 else
                                   hdef:=hclassdef;
                                 if (po_classmethod in current_procinfo.procdef.procoptions) or
                                    (po_staticmethod in current_procinfo.procdef.procoptions) then
                                   hdef:=cclassrefdef.create(hdef);
                                 if useself then
                                   begin
                                     p1:=ctypeconvnode.create_internal(load_self_node,hdef);
                                   end
                                 else
                                   begin
                                     p1:=ctypenode.create(hdef);
                                     { we need to allow helpers here }
                                     ttypenode(p1).helperallowed:=true;
                                   end;
                               end;
                           end;
                         propertysym:
                           ;
                         else
                           begin
                             Message(parser_e_methode_id_expected);
                             p1:=cerrornode.create;
                           end;
                       end;
                       if mightbegeneric then
                         begin
                           p1:=cspecializenode.create_inherited(p1,getaddr,srsym,hclassdef);
                         end
                       else
                         begin
                           if not isspecialize then
                             check_hints(srsym,srsym.symoptions,srsym.deprecatedmsg);
                           callflags:=[cnf_inherited];
                           include(current_procinfo.flags,pi_has_inherited);
                           if anon_inherited then
                             include(callflags,cnf_anon_inherited);
                           do_member_read(hclassdef,getaddr,srsym,p1,again,callflags,spezcontext);
                         end;
                       if p1.nodetype=errorn then
                       begin
                         spezcontext.free;
                         spezcontext := nil;
                       end;
                     end
                    else
                     begin
                       if anon_inherited then
                        begin
                          { For message methods we need to call DefaultHandler }
                          if (po_msgint in pd.procoptions) or
                             (po_msgstr in pd.procoptions) then
                            begin
                              searchsym_in_class(hclassdef,hclassdef,'DEFAULTHANDLER',srsym,srsymtable,[ssf_search_helper]);
                              if not assigned(srsym) or
                                 (srsym.typ<>procsym) then
                                internalerror(200303171);
                              p1:=nil;
                              do_proc_call(srsym,srsym.owner,hclassdef,false,again,p1,[],nil);
                            end
                          else
                            begin
                              { we need to ignore the inherited; }
                              p1:=cnothingnode.create;
                            end;
                        end
                       else
                        begin
                          Message1(sym_e_id_no_member,hsorg);
                          p1:=cerrornode.create;
                        end;
                       again:=false;
                     end;
                    { turn auto inheriting off }
                    anon_inherited:=false;
                  end
                 else
                   begin
                     { in case of records we use a more clear error message }
                     if assigned(current_structdef) and
                         (current_structdef.typ=recorddef) then
                       Message(parser_e_inherited_not_in_record)
                     else
                       Message(parser_e_generic_methods_only_in_methods);
                     again:=false;
                     p1:=cerrornode.create;
                   end;
                 if p1.nodetype<>specializen then
                   postfixoperators(p1,again,getaddr);
               end;

             _INTCONST :
               begin
                 {Try first wether the value fits in an int64.}
                 val(current_scanner.pattern,ic,code);
                 if code=0 then
                   begin
                      consume(_INTCONST);
                      int_to_type(ic,hdef);
                      p1:=cordconstnode.create(ic,hdef,true);
                   end
                 else
                   begin
                     { try qword next }
                     val(current_scanner.pattern,qc,code);
                     if code=0 then
                       begin
                          consume(_INTCONST);
                          int_to_type(qc,hdef);
                          p1:=cordconstnode.create(qc,hdef,true);
                       end;
                   end;
{$if not defined(cpuhighleveltarget) or defined(wasm32)}
                 if (code<>0) and (m_int128 in current_settings.modeswitches) then
                   begin
                     { try 128 bit }
                     ic128:=str_to_tconstexprint(current_scanner.pattern,ic128err);
                     if not ic128err then
                       begin
                          code:=0;
                          consume(_INTCONST);
                          int_to_type(ic128,hdef);
                          p1:=cordconstnode.create(ic128,hdef,true);
                       end;
                   end;
{$endif not defined(cpuhighleveltarget) or defined(wasm32)}
                 if code<>0 then
                   begin
                     { finally float }
                     val(current_scanner.pattern,d,code);
                     if code<>0 then
                       begin
                          Message(parser_e_invalid_integer);
                          consume(_INTCONST);
                          l:=1;
                          p1:=cordconstnode.create(l,sinttype,true);
                       end
                     else
                       begin
                          consume(_INTCONST);
                          p1:=crealconstnode.create(d,pbestrealtype^);
                       end;
                   end
                 else
                   { the necessary range checking has already been done by val }
                   tordconstnode(p1).rangecheck:=false;
                 if current_scanner.token=_POINT then
                   begin
                     again:=true;
                     postfixoperators(p1,again,getaddr);
                   end;
               end;

             _REALNUMBER :
               begin
                 p1:=real_const_node_from_pattern(current_scanner.pattern);
                 consume(_REALNUMBER);
                 if current_scanner.token=_POINT then
                   begin
                     again:=true;
                     postfixoperators(p1,again,getaddr);
                   end;
               end;

             _STRING :
               begin
                 if cs_compilesystem in current_settings.moduleswitches then
                   Message(parser_e_nostringaliasinsystem);
                 string_dec(hdef,true);
                 { STRING can be also a type cast }
                 if try_to_consume(_LKLAMMER) then
                  begin
                    p1:=comp_expr([ef_accept_equal]);
                    consume(_RKLAMMER);
                    p1:=ctypeconvnode.create_explicit(p1,hdef);
                    { handle postfix operators here e.g. string(a)[10] }
                    again:=true;
                    postfixoperators(p1,again,getaddr);
                  end
                 else
                   begin
                     p1:=ctypenode.create(hdef);
                     if current_scanner.token=_POINT then
                       begin
                         again:=true;
                         { handle type helpers here }
                         postfixoperators(p1,again,getaddr);
                       end;
                   end;
               end;

             _FILE :
               begin
                 hdef:=cfiletype;
                 consume(_FILE);
                 { FILE can be also a type cast }
                 if try_to_consume(_LKLAMMER) then
                  begin
                    p1:=comp_expr([ef_accept_equal]);
                    consume(_RKLAMMER);
                    p1:=ctypeconvnode.create_explicit(p1,hdef);
                    { handle postfix operators here e.g. string(a)[10] }
                    again:=true;
                    postfixoperators(p1,again,getaddr);
                  end
                 else
                  begin
                    p1:=ctypenode.create(hdef);
                  end;
               end;

             _INTERP_START :
               begin
                 consume(_INTERP_START);
                 interp_paras:=nil;
                 interp_count:=0;
                 interp_has_expr:=false;
                 while current_scanner.token<>_INTERP_END do
                   begin
                     if current_scanner.token=_INTERP_FRAG then
                       begin
                         p1:=cstringconstnode.createpchar(pchar(current_scanner.cstringpattern),
                           length(current_scanner.cstringpattern),nil);
                         consume(_INTERP_FRAG);
                       end
                     else
                       begin
                         interp_has_expr:=true;
                         if current_scanner.token=_INTERP_EXPR_END then
                           begin
                             { empty interpolation braces - report error, skip }
                             Message(parser_e_illegal_expression);
                             consume(_INTERP_EXPR_END);
                             continue;
                           end;
                         p1:=comp_expr([ef_accept_equal]);
                         // format mask: `{expr:mask}` - everything after the
                         // first `:` up to the closing `}` is the raw mask
                         if current_scanner.token=_COLON then
                           begin
                             interp_mask:=current_scanner.read_interp_mask;
                             if interp_mask_is_width(interp_mask,interp_w,interp_f,interp_hasf) then
                               begin
                                 { plain numeric mask - lower to the same colon
                                   paras write(x:8:2) uses, so `x:6` pads the
                                   value instead of going through Format }
                                 interp_paras:=ccallparanode.create(p1,interp_paras);
                                 inc(interp_count);
                                 interp_paras:=ccallparanode.create(genintconstnode(interp_w),interp_paras);
                                 include(tcallparanode(interp_paras).callparaflags,cpf_is_colon_para);
                                 if interp_hasf then
                                   begin
                                     interp_paras:=ccallparanode.create(genintconstnode(interp_f),interp_paras);
                                     include(tcallparanode(interp_paras).callparaflags,cpf_is_colon_para);
                                   end;
                               end
                             else
                               begin
                                 p1:=handle_interp_format(p1,interp_mask);
                                 interp_paras:=ccallparanode.create(p1,interp_paras);
                                 inc(interp_count);
                               end;
                           end
                         else
                           handle_interp_elem(p1,interp_paras,interp_count);
                         consume(_INTERP_EXPR_END);
                         continue;
                       end;
                     interp_paras:=ccallparanode.create(p1,interp_paras);
                     inc(interp_count);
                   end;
                 consume(_INTERP_END);
                 if interp_count=0 then
                   p1:=cstringconstnode.createpchar(pchar(''),0,nil)
                 else if not interp_has_expr then
                   begin
                     { all literals - use Concat or return single string }
                     if interp_count=1 then
                       begin
                         p1:=tcallparanode(interp_paras).left;
                         tcallparanode(interp_paras).left:=nil;
                         interp_paras.free;
                       end
                     else
                       p1:=cinlinenode.create(in_concat_x,false,interp_paras);
                   end
                 else
                   begin
                     { has expressions - generate WriteStr(temp, fragments...) }
                     interp_temp:=ctempcreatenode.create(cansistringtype,
                       cansistringtype.size,tt_persistent,true);
                     { append temp destination at end of chain (reverseparameters
                       in handle_read_write will move it to front) }
                     interp_last:=interp_paras;
                     while assigned(tcallparanode(interp_last).right) do
                       interp_last:=tcallparanode(interp_last).right;
                     tcallparanode(interp_last).right:=ccallparanode.create(
                       ctemprefnode.create(interp_temp),nil);
                     p1:=internalstatements(interp_stmt);
                     addstatement(interp_stmt,interp_temp);
                     interp_inl:=cinlinenode.create(
                       in_writestr_x,false,interp_paras);
                     include(interp_inl.inlinenodeflags,inf_from_interpolation);
                     addstatement(interp_stmt,interp_inl);
                     addstatement(interp_stmt,ctempdeletenode.create_normal_temp(
                       interp_temp));
                     addstatement(interp_stmt,ctemprefnode.create(interp_temp));
                   end;
                 if current_scanner.token in postfixoperator_tokens then
                   begin
                     again:=true;
                     postfixoperators(p1,again,getaddr);
                   end;
               end;

             _CSTRING :
               begin
                 p1:=cstringconstnode.createpchar(pchar(current_scanner.cstringpattern),length(current_scanner.cstringpattern),nil);
                 consume(_CSTRING);
                 if current_scanner.token in postfixoperator_tokens then
                   begin
                     again:=true;
                     postfixoperators(p1,again,getaddr);
                   end;
               end;

             _CCHAR :
               begin
                 p1:=cordconstnode.create(ord(current_scanner.pattern[1]),cansichartype,true);
                 consume(_CCHAR);
                 if current_scanner.token=_POINT then
                   begin
                     again:=true;
                     postfixoperators(p1,again,getaddr);
                   end;
               end;

             _CWSTRING:
               begin
                 if getlengthwidestring(current_scanner.patternw)=1 then
                   p1:=cordconstnode.create(ord(getcharwidestring(current_scanner.patternw,0)),cwidechartype,true)
                 else
                   p1:=cstringconstnode.createunistr(current_scanner.patternw);
                 consume(_CWSTRING);
                 if current_scanner.token in postfixoperator_tokens then
                   begin
                     again:=true;
                     postfixoperators(p1,again,getaddr);
                   end;
               end;

             _CWCHAR:
               begin
                 p1:=cordconstnode.create(ord(getcharwidestring(current_scanner.patternw,0)),cwidechartype,true);
                 consume(_CWCHAR);
                 if current_scanner.token=_POINT then
                   begin
                     again:=true;
                     postfixoperators(p1,again,getaddr);
                   end;
               end;

             _KLAMMERAFFE :
               begin
                 consume(_KLAMMERAFFE);
                 got_addrn:=true;
                 { support both @<x> and @(<x>) }
                 if try_to_consume(_LKLAMMER) then
                  begin
                    p1:=factor(true,[]);
                    { inside parentheses a full expression is allowed, see also tests\webtbs\tb27517.pp }
                    if current_scanner.token<>_RKLAMMER then
                      p1:=sub_expr(opcompare,[ef_accept_equal],p1);
                    consume(_RKLAMMER);
                  end
                 else
                  p1:=factor(true,[]);
                 if (current_scanner.token in postfixoperator_tokens) and
                   { TP7 ugliness: @proc^ is parsed as (@proc)^, but @notproc^
                     is parsed as @(notproc^) }
                    not
                    (
                     (m_tp_procvar in current_settings.modeswitches) and
                     (current_scanner.token=_CARET) and (p1.nodetype=loadn) and (tloadnode(p1).symtableentry.typ=procsym)
                    )
                   then
                  begin
                    again:=true;
                    postfixoperators(p1,again,getaddr);
                  end;
                 got_addrn:=false;
                 p1:=caddrnode.create(p1);
                 p1.fileinfo:=filepos;
                 if cs_typed_addresses in current_settings.localswitches then
                   include(taddrnode(p1).addrnodeflags,anf_typedaddr);
                 { Store the procvar that we are expecting, the
                   addrn will use the information to find the correct
                   procdef or it will return an error }
                 if assigned(getprocvardef) and
                    (taddrnode(p1).left.nodetype = loadn) then
                   taddrnode(p1).getprocvardef:=getprocvardef;
                 if (current_scanner.token in postfixoperator_tokens) then
                  begin
                    again:=true;
                    postfixoperators(p1,again,getaddr);
                  end;
               end;

             _LKLAMMER :
               begin
                 consume(_LKLAMMER);
                 { named tuple literal ( name: expr, name: expr, ... )? }
                 if (m_tuples in current_settings.modeswitches) and
                    is_named_tuple_literal_ahead then
                   begin
                     p1:=named_tuple_lit_as_tempref;
                   end
                 else
                   begin
                     p1:=comp_expr([ef_accept_equal]);
                     if (m_tuples in current_settings.modeswitches) and
                        (current_scanner.token=_COMMA) then
                       begin
                         { positional tuple literal: (e1, e2, ...) }
                         p1:=tuple_lit_as_tempref(p1);
                       end
                     else
                       consume(_RKLAMMER);
                   end;
                 { it's not a good solution
                   but (a+b)^ makes some problems  }
                 if current_scanner.token in postfixoperator_tokens then
                  begin
                    again:=true;
                    postfixoperators(p1,again,getaddr);
                  end;
               end;

             _LECKKLAMMER :
               begin
                 consume(_LECKKLAMMER);
                 p1:=factor_read_set;
                 consume(_RECKKLAMMER);
               end;

             _PLUS :
               begin
                 consume(_PLUS);
                 p1:=factor(false,[]);
                 p1:=cunaryplusnode.create(p1);
               end;

             _MINUS :
               begin
                 consume(_MINUS);
                 if (current_scanner.token = _INTCONST) and not(m_isolike_unary_minus in current_settings.modeswitches) then
                    begin
                      { ugly hack, but necessary to be able to parse }
                      { -9223372036854775808 as int64 (JM)           }
                      current_scanner.pattern := '-'+current_scanner.pattern;
                      p1:=sub_expr(oppower,[],nil);
                      {  -1 ** 4 should be - (1 ** 4) and not
                         (-1) ** 4
                         This was the reason of tw0869.pp test failure PM }
                      if p1.nodetype=starstarn then
                        begin
                          if tbinarynode(p1).left.nodetype=ordconstn then
                            begin
                              tordconstnode(tbinarynode(p1).left).value:=-tordconstnode(tbinarynode(p1).left).value;
                              p1:=cunaryminusnode.create(p1);
                            end
                          else if tbinarynode(p1).left.nodetype=realconstn then
                            begin
                              trealconstnode(tbinarynode(p1).left).value_real:=-trealconstnode(tbinarynode(p1).left).value_real;
                              trealconstnode(tbinarynode(p1).left).value_currency:=-trealconstnode(tbinarynode(p1).left).value_currency;
                              p1:=cunaryminusnode.create(p1);
                            end
                          else
                            internalerror(20021029);
                        end;
                    end
                 else
                   begin
                     if m_isolike_unary_minus in current_settings.modeswitches then
                       p1:=sub_expr(opmultiply,[],nil)
                     else
                       p1:=sub_expr(oppower,[],nil);

                     p1:=cunaryminusnode.create(p1);
                   end;
               end;

             _OP_NOT :
               begin
                 consume(_OP_NOT);
                 p1:=factor(false,[]);
                 p1:=cnotnode.create(p1);
               end;

             _NIL :
               begin
                 consume(_NIL);
                 p1:=cnilnode.create;
                 { It's really ugly code nil^, but delphi allows it }
                 if current_scanner.token in [_CARET,_POINT] then
                  begin
                    again:=true;
                    postfixoperators(p1,again,getaddr);
                  end;
               end;
             _OBJCPROTOCOL:
               begin
                 { The @protocol keyword is used in two ways in Objective-C:
                     1) to declare protocols (~ Object Pascal interfaces)
                     2) to obtain the metaclass (~ Object Pascal) "class of")
                        of a declared protocol
                   This code is for handling the second case. Because of 1),
                   we cannot simply use a system unit symbol.
                 }
                 consume(_OBJCPROTOCOL);
                 consume(_LKLAMMER);
                 p1:=factor(false,[]);
                 consume(_RKLAMMER);
                 p1:=cinlinenode.create(in_objc_protocol_x,false,p1);
               end;

             _PROCEDURE,
             _FUNCTION:
               begin
                 if (block_type=bt_body) and
                     (m_anonymous_functions in current_settings.modeswitches) then
                   begin
                     filepos:=current_filepos;
                     oldprocvardef:=getprocvardef;
                     oldfuncrefdef:=getfuncrefdef;
                     getprocvardef:=nil;
                     getfuncrefdef:=nil;
                     pd:=read_proc([rpf_anonymous],nil);
                     getprocvardef:=oldprocvardef;
                     getfuncrefdef:=oldfuncrefdef;
                     { assume that we try to get the address except if certain
                       tokens follow that indicate a call }
                     do_proc_call(pd.procsym,pd.owner,nil,not (current_scanner.token in [_POINT,_CARET,_LECKKLAMMER]),
                                  again,p1,[],nil);
                     { don't allow @<anon func>, but keep the parsing for recovery }
                     if (p1.nodetype<>errorn) and getaddr then
                       begin
                         p1.free;
                         p1:=cerrornode.create;
                         MessagePos(filepos,parser_e_illegal_expression);
                       end;
                   end
                 else
                   begin
                     Message(parser_e_illegal_expression);
                     p1:=cerrornode.create;
                     { recover }
                     consume(current_scanner.token);
                   end;
               end;

             _TYPE :
               { unleashed: Type(expr) intrinsic in expression position. covers
                 typecasts `Type(x)(value)` as well as use as a type argument to
                 High/Low/SizeOf/Default. the type keyword has no other valid
                 meaning here, so we commit to the intrinsic once we see it. }
               if m_unleashed in current_settings.modeswitches then
                 begin
                   consume(_TYPE);
                   if current_scanner.token=_LKLAMMER then
                     begin
                       hdef:=parse_type_intrinsic_body;
                       p1:=handle_factor_typenode(hdef,getaddr,again,nil,ef_type_only in flags);
                     end
                   else
                     begin
                       Message(parser_e_illegal_expression);
                       p1:=cerrornode.create;
                     end;
                 end
               else
                 begin
                   Message(parser_e_illegal_expression);
                   p1:=cerrornode.create;
                   { recover }
                   consume(current_scanner.token);
                 end

             else if not statement_expr(p1) then
               begin
                 Message(parser_e_illegal_expression);
                 p1:=cerrornode.create;
                 { recover }
                 consume(current_scanner.token);
               end;
           end;
        end;

        { generate error node if no node is created }
        if not assigned(p1) then
         begin
{$ifdef EXTDEBUG}
           Comment(V_Warning,'factor: p1=nil');
{$endif}
           p1:=cerrornode.create;
           updatefpos:=true;
         end;

        { get the resultdef for the node if nothing stops us }
        if (not assigned(p1.resultdef)) and dopostfix then
          begin
            do_typecheckpass_changed(p1,nodechanged);
            updatefpos:=updatefpos or nodechanged;
          end;

        if assigned(p1) and
           updatefpos then
          p1.fileinfo:=filepos;
        factor:=p1;
      end;
  {$maxfpuregisters default}

    procedure post_comp_expr_gendef(var def: tdef);
      var
        p1 : tnode;
        again : boolean;
      begin
        if not assigned(def) then
          internalerror(2011053001);
        again:=false;
        { handle potential typecasts, etc }
        p1:=handle_factor_typenode(def,false,again,nil,false);
        { parse postfix operators }
        postfixoperators(p1,again,false);
        if assigned(p1) and (p1.nodetype=typen) then
          def:=ttypenode(p1).typedef
        else
          def:=generrordef;
      end;


    function parse_type_intrinsic_body: tdef;
      var
        p1 : tnode;
      begin
        result:=generrordef;
        consume(_LKLAMMER);
        p1:=comp_expr([ef_accept_equal]);
        if assigned(p1) then
          begin
            if not assigned(p1.resultdef) then
              typecheckpass(p1);
            if assigned(p1.resultdef) and (p1.resultdef.typ<>errordef) then
              result:=p1.resultdef;
            p1.free;
          end;
        consume(_RKLAMMER);
      end;

{****************************************************************************
                             Sub_Expr
****************************************************************************}
    function sub_expr(pred_level:Toperator_precedence;flags:texprflags;factornode:tnode):tnode;
    {Reads a subexpression while the operators are of the current precedence
     level, or any higher level. Replaces the old term, simple_expr and
     simpl2_expr.}

      function istypenode(n:tnode):boolean;inline;
      { Checks whether the given node is a type node or a VMT node containing a
        typenode. This is used in the code for inline specializations in the
        _LT branch below }
        begin
          result:=assigned(n) and
                    (
                      (n.nodetype=typen) or
                      (
                        (n.nodetype=loadvmtaddrn) and
                        (tloadvmtaddrnode(n).left.nodetype=typen)
                      )
                    );
        end;

      function gettypedef(n:tnode):tdef;inline;
      { This returns the typedef that belongs to the given typenode or
        loadvmtaddrnode. n must not be Nil! }
        begin
          if n.nodetype=typen then
            result:=ttypenode(n).typedef
          else
            result:=ttypenode(tloadvmtaddrnode(n).left).typedef;
        end;

      function gettypedef(sym:tsym):tdef;inline;
        begin
          result:=nil;
          case sym.typ of
            typesym:
              result:=ttypesym(sym).typedef;
            procsym:
              if not (sp_generic_dummy in sym.symoptions) or (tprocsym(sym).procdeflist.count>0) then
                result:=tdef(tprocsym(sym).procdeflist[0]);
            else
              internalerror(2015092701);
          end;
        end;

      function getgenericsym(n:tnode;out srsym:tsym):boolean;
        var
          srsymtable : tsymtable;
        begin
          srsym:=nil;
          case n.nodetype of
            typen:
              srsym:=ttypenode(n).typedef.typesym;
            loadvmtaddrn:
              srsym:=ttypenode(tloadvmtaddrnode(n).left).typedef.typesym;
            loadn:
              if not searchsym_with_symoption(tloadnode(n).symtableentry.Name,srsym,srsymtable,sp_generic_dummy) then
                srsym:=nil;
            calln:
              srsym:=tcallnode(n).symtableprocentry;
            specializen:
              srsym:=tspecializenode(n).sym;
            { TODO : handle const nodes }
            else
              ;
          end;
          result:=assigned(srsym);
        end;

      function generate_inline_specialization(gendef:tdef;n:tnode;filepos:tfileposinfo;parseddef:tdef;gensym:tsym;p2:tnode):tnode;
        var
          again,
          getaddr,
          unitspecific : boolean;
          pload : tnode;
          spezcontext : tspecializationcontext;
          structdef,
          inheriteddef : tabstractrecorddef;
          callflags : tcallnodeflags;
        begin
          if not assigned(gensym) then
            internalerror(2025103101);

          if n.nodetype=specializen then
            begin
              getaddr:=tspecializenode(n).getaddr;
              pload:=tspecializenode(n).left;
              inheriteddef:=tabstractrecorddef(tspecializenode(n).inheriteddef);
              unitspecific:=tspecializenode(n).unit_specific;
              tspecializenode(n).left:=nil;
            end
          else
            begin
              getaddr:=false;
              pload:=nil;
              inheriteddef:=nil;
              unitspecific:=false;
            end;

          if assigned(parseddef) and assigned(gensym) and assigned(p2) then
            gendef:=generate_specialization_phase1(spezcontext,gendef,unitspecific,parseddef,gensym.realname,gensym.owner,p2.fileinfo)
          else
            gendef:=generate_specialization_phase1(spezcontext,gendef,unitspecific,gensym.realname,gensym.owner);
          case gendef.typ of
            errordef:
              begin
                spezcontext.free;
                spezcontext:=nil;
                gensym:=generrorsym;
              end;
            objectdef,
            recorddef,
            procvardef,
            arraydef:
              begin
                gendef:=generate_specialization_phase2(spezcontext,tstoreddef(gendef),false,'');
                spezcontext.free;
                spezcontext:=nil;
                if gendef.typ=errordef then
                  gensym:=generrorsym
                else
                  gensym:=gendef.typesym;
              end;
            procdef:
              begin
                if not (block_type in [bt_body,bt_except]) then
                  begin
                    message(parser_e_illegal_expression);
                    gensym:=generrorsym;
                  end
                else
                  begin
                    gensym:=tprocdef(gendef).procsym;
                  end;
              end;
            else
              internalerror(2015092702);
          end;

          { in case of a class or a record the specialized generic
            is always a classrefdef }
          again:=false;

          if assigned(pload) then
            begin
              result:=pload;
              typecheckpass(result);
              structdef:=inheriteddef;
              if not assigned(structdef) then
                case result.resultdef.typ of
                  objectdef,
                  recorddef:
                    begin
                      structdef:=tabstractrecorddef(result.resultdef);
                    end;
                  classrefdef:
                    begin
                      structdef:=tabstractrecorddef(tclassrefdef(result.resultdef).pointeddef);
                    end;
                  else
                    internalerror(2015092703);
                end;
              if not (structdef.typ in [recorddef,objectdef]) then
                internalerror(2018092101);
              if assigned(inheriteddef) then
                begin
                  callflags:=[cnf_inherited];
                  include(current_procinfo.flags,pi_has_inherited);
                end
              else
                callflags:=[];
              do_member_read(structdef,getaddr,gensym,result,again,callflags,spezcontext);
              spezcontext:=nil;
            end
          else
            begin
              if gensym.typ=procsym then
                begin
                  result:=nil;
                  { check if it's a method/class method }
                  if is_member_read(gensym,gensym.owner,result,parseddef) then
                    begin
                      { if we are accessing a owner procsym from the nested }
                      { class we need to call it as a class member }
                      if (gensym.owner.symtabletype in [ObjectSymtable,recordsymtable]) and
                          assigned(current_structdef) and (current_structdef<>parseddef) and is_owned_by(current_structdef,parseddef) then
                        result:=cloadvmtaddrnode.create(ctypenode.create(parseddef));
                      { not srsymtable.symtabletype since that can be }
                      { withsymtable as well                          }
                      if (gensym.owner.symtabletype in [ObjectSymtable,recordsymtable]) then
                        begin
                          do_member_read(tabstractrecorddef(parseddef),getaddr,gensym,result,again,[],spezcontext);
                          spezcontext:=nil;
                        end
                      else
                        { no procsyms in records (yet) }
                        internalerror(2015092704);
                    end
                  else
                    begin
                      { regular procedure/function call }
                      do_proc_call(gensym,gensym.owner,nil,
                                   (getaddr and not(current_scanner.token in [_CARET,_POINT,_LECKKLAMMER])),
                                   again,result,[],spezcontext);
                      spezcontext:=nil;
                    end;
                  end
                else
                  { handle potential typecasts, etc }
                  result:=handle_factor_typenode(gendef,false,again,nil,false);
            end;

          { parse postfix operators }
          if postfixoperators(result,again,false) then
            if assigned(result) then
              result.fileinfo:=filepos
            else
              result:=cerrornode.create;

          spezcontext.free;
          spezcontext := nil;
        end;

      function maybe_handle_specialization(var p1,p2:tnode;filepos:tfileposinfo):boolean;
        var
          gensym : tsym;
          parseddef,
          gendef : tdef;
          ptmp : tnode;
        begin
          result:=false;
          { we need to decide whether we have an inline specialization
            (type nodes to the left and right of "<", mode Delphi and
            ">" or "," following) or a normal "<" comparison }
          { TODO : p1 could be a non type if e.g. a variable with the
                   same name is defined in the same unit where the
                   generic is defined (though "same unit" is not
                   necessarily needed) }
          if getgenericsym(p1,gensym) and
             { Attention: when nested specializations are supported
                          p2 could be a loadn if a "<" follows }
             istypenode(p2) and
              (m_implicit_generics in current_settings.modeswitches) and
              { TODO : add _LT, _LSHARPBRACKET for nested specializations }
              (current_scanner.token in [_GT,_RSHARPBRACKET,_COMMA]) then
            begin
              { this is an inline specialization }

              { retrieve the defs of two nodes }
              if p1.nodetype=specializen then
                gendef:=gettypedef(tspecializenode(p1).sym)
              else
                gendef:=nil;
              parseddef:=gettypedef(p2);

              { check the hints for parseddef }
              check_hints(parseddef.typesym,parseddef.typesym.symoptions,parseddef.typesym.deprecatedmsg,p1.fileinfo);

              ptmp:=generate_inline_specialization(gendef,p1,filepos,parseddef,gensym,p2);

              { we don't need these nodes anymore }
              p1.free;
              p2.free;
              p2 := nil;

              p1:=ptmp;

              result:=true;
            end;
        end;

      label
        SubExprStart;
      var
        p1,p2,ptmp : tnode;
        oldt    : Ttoken;
        filepos : tfileposinfo;
        gendef,parseddef : tdef;
        gensym : tsym;
        genlist : tfpobjectlist;
        dummyagain : boolean;
        dummyspezctxt : tspecializationcontext;
        is_not_op : boolean;
      begin
        SubExprStart:
        if pred_level=highest_precedence then
          begin
            if factornode=nil then
              p1:=factor(false,flags)
            else
              p1:=factornode;
          end
        else
          p1:=sub_expr(succ(pred_level),flags+[ef_accept_equal],factornode);
        repeat
          if (current_scanner.token in [NOTOKEN..last_operator]) and
             ((current_scanner.token in operator_levels[pred_level]) or
              ((m_unleashed in current_settings.modeswitches) and
               (pred_level=opcompare) and
               (current_scanner.token=_OP_NOT))) and
             ((current_scanner.token<>_EQ) or (ef_accept_equal in flags)) then
           begin
             oldt:=current_scanner.token;
             filepos:=current_tokenpos;
             consume(current_scanner.token);
             { delphi-style `is not T` and `not in S` (mode unleashed) }
             is_not_op:=false;
             if m_unleashed in current_settings.modeswitches then
               begin
                 if (oldt=_OP_IS) and (current_scanner.token=_OP_NOT) then
                   begin
                     consume(_OP_NOT);
                     is_not_op:=true;
                   end
                 else if oldt=_OP_NOT then
                   consume(_OP_IN);
               end;
             { an anonymous type as the first argument of an inline
               specialization, e.g. `TBox<(a: integer; b: string)>.Create`;
               the expression parser cannot read it }
             if (oldt=_LT) and getgenericsym(p1,gensym) and anon_type_arg_ahead then
               p2:=parse_anon_type_arg
             else
             if pred_level=highest_precedence then
               p2:=factor(false,[])
             else
               p2:=sub_expr(succ(pred_level),flags+[ef_accept_equal],nil);
             { a generic specialization on the right of a binary operator is
               parsed lazily into a bare specializen node, because "<" has a
               lower precedence than e.g. "+" so factor returns before the
               "<types>" is consumed. resolve it here before the operator node
               is built, otherwise the specializen survives to code generation
               and triggers an internal error. comparison operators and as/is
               keep their own handling of the "<" ambiguity }
             if (m_implicit_generics in current_settings.modeswitches) and
                (current_scanner.token in [_LT,_LSHARPBRACKET]) and
                assigned(p2) and (p2.nodetype=specializen) and
                not (oldt in [_LT,_GT,_LTE,_GTE,_EQ,_NE,_OP_AS,_OP_IS]) then
               begin
                 consume(current_scanner.token);
                 ptmp:=factor(false,[]);
                 maybe_handle_specialization(p2,ptmp,p2.fileinfo);
               end;
             case oldt of
               _PLUS :
                 p1:=caddnode.create(addn,p1,p2);
               _MINUS :
                 p1:=caddnode.create(subn,p1,p2);
               _STAR :
                 p1:=caddnode.create(muln,p1,p2);
               _SLASH :
                 p1:=caddnode.create(slashn,p1,p2);
               _EQ:
                 p1:=caddnode.create(equaln,p1,p2);
               _GT :
                 p1:=caddnode.create(gtn,p1,p2);
               _LT :
                 begin
                   if maybe_handle_specialization(p1,p2,filepos) then
                     begin
                       { p1 now holds the resolved specialization; we are in
                         reality directly behind the call to "factor", so
                         restart so the rest of the expression (operators that
                         follow the specialization) is parsed against it }
                       factornode:=p1;
                       goto SubExprStart;
                     end
                   else
                     begin
                       { this is a normal "<" comparison }

                       { potential generic types that are followed by a "<": }

                       if p1.nodetype=specializen then
                         begin
                           genlist:=tfpobjectlist(current_module.genericdummysyms.find(tspecializenode(p1).sym.name));
                           if assigned(genlist) and (genlist.count>0) then
                             begin
                               gensym:=tgenericdummyentry(genlist.last).resolvedsym;
                               check_hints(gensym,gensym.symoptions,gensym.deprecatedmsg,p1.fileinfo);

                               dummyagain:=false;
                               dummyspezctxt:=nil;

                               ptmp:=factor_handle_sym(gensym,
                                                       gensym.owner,
                                                       dummyagain,
                                                       tspecializenode(p1).getaddr,
                                                       false,
                                                       flags,
                                                       dummyspezctxt);

                               if dummyagain then
                                 internalerror(2022012201);

                               p1.free;
                               p1:=ptmp;
                             end
                           else
                             begin
                               identifier_not_found(tspecializenode(p1).sym.realname);
                               p1.free;
                               p1:=cerrornode.create;
                             end;
                         end;

                       { a) might not have their resultdef set }
                       if not assigned(p1.resultdef) then
                         do_typecheckpass(p1);

                       { b) are not checked whether they are an undefined def,
                            but not a generic parameter }
                       if (p1.nodetype=typen) and
                           (ttypenode(p1).typedef.typ=undefineddef) and
                           assigned(ttypenode(p1).typedef.typesym) and
                           not (sp_generic_para in ttypenode(p1).typedef.typesym.symoptions) then
                         begin
                           identifier_not_found(ttypenode(p1).typedef.typesym.RealName);
                           p1.Free;
                           p1:=cerrornode.create;
                         end;

                       { c) don't have their hints checked }
                       if istypenode(p1) then
                         begin
                           gendef:=gettypedef(p1);
                           if gendef.typ in [objectdef,recorddef,arraydef,procvardef] then
                             check_hints(gendef.typesym,gendef.typesym.symoptions,gendef.typesym.deprecatedmsg);
                         end;

                       { Note: the second part of the expression will be needed
                               for nested specializations }
                       if istypenode(p2) {and
                           not (current_scanner.token in [_LT, _LSHARPBRACKET])} then
                         begin
                           gendef:=gettypedef(p2);
                           if gendef.typ in [objectdef,recorddef,arraydef,procvardef] then
                             check_hints(gendef.typesym,gendef.typesym.symoptions,gendef.typesym.deprecatedmsg);
                         end;

                       { create the comparison node for "<" }
                       p1:=caddnode.create(ltn,p1,p2)
                     end;
                 end;
               _GTE :
                 p1:=caddnode.create(gten,p1,p2);
               _LTE :
                 p1:=caddnode.create(lten,p1,p2);
               _SYMDIF :
                 p1:=caddnode.create(symdifn,p1,p2);
               _STARSTAR :
                 p1:=caddnode.create(starstarn,p1,p2);
               _OP_AS,
               _OP_IS :
                 begin
                   if (m_implicit_generics in current_settings.modeswitches) and
                       (current_scanner.token in [_LT, _LSHARPBRACKET]) and
                       getgenericsym(p2,gensym) then
                     begin
                       { for now we're handling this as a generic declaration;
                         there could be cases though (because of operator
                         overloading) where this is the wrong decision... }
                       if gensym.typ=typesym then
                         gendef:=ttypesym(gensym).typedef
                       else
                         if gensym.typ=procsym then
                           gendef:=tdef(tprocsym(gensym).procdeflist[0])
                         else
                           internalerror(2015072401);

                       ptmp:=generate_inline_specialization(gendef,p2,filepos,nil,gensym,nil);

                       { we don't need the old p2 anymore }
                       p2.Free;

                       p2:=ptmp;

                       { here we don't need to call back down to "factor", thus
                         no "goto" }
                     end;

                   { now generate the "is" or "as" node }
                   case oldt of
                     _OP_AS:
                       p1:=casnode.create(p1,p2);
                     _OP_IS:
                       begin
                         p1:=cisnode.create(p1,p2);
                         if is_not_op then
                           p1:=cnotnode.create(p1);
                       end;
                     else
                       internalerror(2019050528);
                   end;
                 end;
               _OP_IN :
                 p1:=cinnode.create(p1,p2);
               _OP_OR,
               _PIPE {macpas only} :
                 begin
                   p1:=caddnode.create(orn,p1,p2);
                   if (oldt = _PIPE) then
                     include(taddnode(p1).addnodeflags,anf_short_bool);
                 end;
               _OP_AND,
               _AMPERSAND {macpas only} :
                 begin
                   p1:=caddnode.create(andn,p1,p2);
                   if (oldt = _AMPERSAND) then
                     include(taddnode(p1).addnodeflags,anf_short_bool);
                 end;
               _OP_DIV :
                 p1:=cmoddivnode.create(divn,p1,p2);
               _OP_NOT :
                 p1:=cnotnode.create(cinnode.create(p1,p2));
               _OP_MOD :
                 begin
                   p1:=cmoddivnode.create(modn,p1,p2);
                   if m_isolike_mod in current_settings.modeswitches then
                     include(tmoddivnode(p1).moddivnodeflags,mdnf_isomod);
                 end;
               _OP_SHL :
                 p1:=cshlshrnode.create(shln,p1,p2);
               _OP_SHR :
                 p1:=cshlshrnode.create(shrn,p1,p2);
               _OP_XOR :
                 p1:=caddnode.create(xorn,p1,p2);
               _ASSIGNMENT :
                 p1:=cassignmentnode.create(p1,p2);
               _NE :
                 p1:=caddnode.create(unequaln,p1,p2);
               else
                 internalerror(2019050529);
             end;
             p1.fileinfo:=filepos;
           end
          else
           break;
        until false;
        if (p1.nodetype=specializen) and
            (current_scanner.token=_LSHARPBRACKET) and
            (m_implicit_generics in current_settings.modeswitches) then
          begin
            filepos:=current_tokenpos;
            consume(current_scanner.token);
            p2:=factor(false,[]);
            if maybe_handle_specialization(p1,p2,filepos) then
              begin
                { with p1 now set we are in reality directly behind the
                  call to "factor" thus we need to call down to that
                  again }
                { This is disabled until specializations on the right
                  hand side work as well, because
                  "not working expressions" is better than "half working
                  expressions" }
                {factornode:=p1;
                goto SubExprStart;}
              end else
                message(parser_e_illegal_expression);
          end;
        sub_expr:=p1;
      end;


    function comp_expr(flags:texprflags):tnode;
      var
         oldafterassignment : boolean;
         p1 : tnode;
      begin
         oldafterassignment:=afterassignment;
         afterassignment:=true;
         p1:=sub_expr(opcompare,flags,nil);
         { get the resultdef for this expression }
         if not assigned(p1.resultdef) then
          do_typecheckpass(p1);
         afterassignment:=oldafterassignment;
         comp_expr:=p1;
      end;


    { Builds a block of per-field assignments for a tuple literal
      ( e1, e2, ... ) or ( name: e1, name: e2, ... ) assigned to lhs.
      Consumes ( ... ). lhs must have resultdef set to a df_tuple record. }
    function tuple_lit_assignment(lhs:tnode):tnode;
      var
        recdef     : trecorddef;
        fieldsyms  : array of tfieldvarsym;
        fieldcount : longint;
        exprcount  : longint;
        i          : longint;
        e          : tnode;
        blk        : tblocknode;
        laststmt   : tstatementnode;
        sym        : tsym;
        is_named   : boolean;
        peekbuf    : tdynamicarray;
        fname      : TIDString;
        field      : tfieldvarsym;
      begin
        recdef:=trecorddef(lhs.resultdef);
        fieldcount:=0;
        setlength(fieldsyms,recdef.symtable.symlist.count);
        for i:=0 to recdef.symtable.symlist.count-1 do
          begin
            sym:=tsym(recdef.symtable.symlist[i]);
            if sym.typ=fieldvarsym then
              begin
                fieldsyms[fieldcount]:=tfieldvarsym(sym);
                inc(fieldcount);
              end;
          end;
        setlength(fieldsyms,fieldcount);

        consume(_LKLAMMER);

        { disambiguate positional vs named: peek at _ID _COLON prefix.
          Skip peek when already recording (generic decl body) to avoid
          nested-record internalerror; assume positional in that case. }
        is_named:=false;
        if (current_scanner.token=_ID) and not current_scanner.is_recording_tokens then
          begin
            peekbuf:=tdynamicarray.create(32);
            current_scanner.startrecordtokens(peekbuf);
            consume(_ID);
            current_scanner.stoprecordtokens;
            is_named:=current_scanner.token=_COLON;
            current_scanner.startreplaytokens(peekbuf,false);
          end;

        blk:=internalstatements(laststmt);
        exprcount:=0;
        if is_named then
          repeat
            fname:=current_scanner.pattern;
            consume(_ID);
            consume(_COLON);
            e:=comp_expr([ef_accept_equal]);
            field:=nil;
            for i:=0 to fieldcount-1 do
              if upper(fieldsyms[i].name)=fname then
                begin
                  field:=fieldsyms[i];
                  break;
                end;
            if assigned(field) then
              addstatement(laststmt,
                cassignmentnode.create(
                  csubscriptnode.create(field,lhs.getcopy),
                  e))
            else
              begin
                Message1(sym_e_illegal_field,fname);
                e.free;
              end;
            inc(exprcount);
          until not try_to_consume(_COMMA)
        else
          repeat
            e:=comp_expr([ef_accept_equal]);
            if exprcount<fieldcount then
              addstatement(laststmt,
                cassignmentnode.create(
                  csubscriptnode.create(fieldsyms[exprcount],lhs.getcopy),
                  e))
            else
              e.free;
            inc(exprcount);
          until not try_to_consume(_COMMA);
        consume(_RKLAMMER);

        lhs.free;

        if exprcount<>fieldcount then
          Message(parser_e_illegal_expression);

        result:=blk;
      end;


    { Used by Exit(...) when the current function returns a tuple. Assumes
      _LKLAMMER was already consumed. Tries to interpret the body as a
      tuple literal that should be assigned to Result; if the body is a
      single expression, returns false with single_expr set so the caller
      can fall through to the normal single-value Exit path. In both
      cases _RKLAMMER is consumed. }
    function exit_tuple_body(out block:tnode;out single_expr:tnode):boolean;
      var
        recdef     : trecorddef;
        fieldsyms  : array of tfieldvarsym;
        fieldcount : longint;
        exprcount  : longint;
        i          : longint;
        e          : tnode;
        blk        : tblocknode;
        laststmt   : tstatementnode;
        sym        : tsym;
        is_named   : boolean;
        peekbuf    : tdynamicarray;
        fname      : TIDString;
        field      : tfieldvarsym;
        first_expr : tnode;

      function resultref:tnode;
        begin
          result:=cloadnode.create(current_procinfo.procdef.funcretsym,
            current_procinfo.procdef.funcretsym.owner);
        end;

      begin
        result:=false;
        block:=nil;
        single_expr:=nil;
        recdef:=trecorddef(current_procinfo.procdef.returndef);

        fieldcount:=0;
        setlength(fieldsyms,recdef.symtable.symlist.count);
        for i:=0 to recdef.symtable.symlist.count-1 do
          begin
            sym:=tsym(recdef.symtable.symlist[i]);
            if sym.typ=fieldvarsym then
              begin
                fieldsyms[fieldcount]:=tfieldvarsym(sym);
                inc(fieldcount);
              end;
          end;
        setlength(fieldsyms,fieldcount);

        { named tuple literal? peek _ID _COLON, but only if not inside an
          outer recording (generic decl body) to avoid nested-record ICE }
        is_named:=false;
        if (current_scanner.token=_ID) and not current_scanner.is_recording_tokens then
          begin
            peekbuf:=tdynamicarray.create(32);
            current_scanner.startrecordtokens(peekbuf);
            consume(_ID);
            current_scanner.stoprecordtokens;
            is_named:=current_scanner.token=_COLON;
            current_scanner.startreplaytokens(peekbuf,false);
          end;

        if is_named then
          begin
            blk:=internalstatements(laststmt);
            exprcount:=0;
            repeat
              fname:=current_scanner.pattern;
              consume(_ID);
              consume(_COLON);
              e:=comp_expr([ef_accept_equal]);
              field:=nil;
              for i:=0 to fieldcount-1 do
                if upper(fieldsyms[i].name)=fname then
                  begin
                    field:=fieldsyms[i];
                    break;
                  end;
              if assigned(field) then
                addstatement(laststmt,
                  cassignmentnode.create(
                    csubscriptnode.create(field,resultref),
                    e))
              else
                begin
                  Message1(sym_e_illegal_field,fname);
                  e.free;
                end;
              inc(exprcount);
            until not try_to_consume(_COMMA);
            consume(_RKLAMMER);
            if exprcount<>fieldcount then
              Message(parser_e_illegal_expression);
            block:=blk;
            result:=true;
            exit;
          end;

        { not named: parse first expression, decide by next token }
        first_expr:=comp_expr([ef_accept_equal]);
        if current_scanner.token<>_COMMA then
          begin
            consume(_RKLAMMER);
            single_expr:=first_expr;
            exit;
          end;

        { positional tuple literal: first_expr -> field 0, continue }
        blk:=internalstatements(laststmt);
        if fieldcount>0 then
          addstatement(laststmt,
            cassignmentnode.create(
              csubscriptnode.create(fieldsyms[0],resultref),
              first_expr))
        else
          first_expr.free;
        exprcount:=1;
        consume(_COMMA);
        repeat
          e:=comp_expr([ef_accept_equal]);
          if exprcount<fieldcount then
            addstatement(laststmt,
              cassignmentnode.create(
                csubscriptnode.create(fieldsyms[exprcount],resultref),
                e))
          else
            e.free;
          inc(exprcount);
        until not try_to_consume(_COMMA);
        consume(_RKLAMMER);
        if exprcount<>fieldcount then
          Message(parser_e_illegal_expression);
        block:=blk;
        result:=true;
      end;


    { build classic-var autofree desugar:
        x := autofree T.Create
      becomes a transparent helper block:
        x := T.Create;
        defer if x<>nil then begin x.Free; x:=nil end;  }
    function build_classic_autofree(lhs, rhs: tnode): tnode;
      var
        vsdef        : tdef;
        free_sym     : tsym;
        free_call    : tnode;
        free_block   : tblocknode;
        free_stat    : tstatementnode;
        free_guarded : tnode;
        chain_block  : tblocknode;
        chain_stat   : tstatementnode;
        defer_node   : tdefernode;
      begin
        // require a simple variable load on the LHS
        if lhs.nodetype <> loadn then
          begin
            Message(parser_e_autofree_lhs_must_be_local);
            exit(cassignmentnode.create(lhs, rhs));
          end;
        vsdef := lhs.resultdef;
        if not (assigned(vsdef) and is_class(vsdef) and
                def_is_related(tobjectdef(vsdef), class_tobject)) then
          begin
            Message(parser_e_autofree_requires_class);
            exit(cassignmentnode.create(lhs, rhs));
          end;
        free_sym := search_struct_member(tobjectdef(vsdef), 'FREE');
        if not assigned(free_sym) or (free_sym.typ <> procsym) then
          begin
            Message(parser_e_autofree_requires_class);
            exit(cassignmentnode.create(lhs, rhs));
          end;
        free_call := ccallnode.create(nil, tprocsym(free_sym), free_sym.owner,
                                      lhs.getcopy, [], nil);
        free_block := internalstatements(free_stat);
        addstatement(free_stat, free_call);
        addstatement(free_stat, cassignmentnode.create(lhs.getcopy, cnilnode.create));
        free_guarded := cifnode.create(
          caddnode.create(unequaln, lhs.getcopy, cnilnode.create),
          free_block, nil);
        chain_block := internalstatements(chain_stat);
        Include(chain_block.blocknodeflags, bnf_defer_transparent);
        addstatement(chain_stat, cassignmentnode.create(lhs, rhs));
        // mark the defer as bound to the variable's scope -- inner-block
        // rewrites (try-body, nested begin..end, with-body) must skip it;
        // only the routine's main begin..end captures it
        defer_node := cdefernode.create(free_guarded);
        defer_node.var_scope := true;
        addstatement(chain_stat, defer_node);
        result := chain_block;
      end;


    function expr(dotypecheck : boolean; flags : texprflags = []) : tnode;

      var
         p1,p2 : tnode;
         filepos : tfileposinfo;
         oldafterassignment,
         updatefpos          : boolean;
         oldflags : tnodeflags;
         autofree_active : boolean;
      begin
         oldafterassignment:=afterassignment;
         p1:=sub_expr(opcompare,flags + [ef_accept_equal],nil);
         { get the resultdef for this expression }
         if not assigned(p1.resultdef) and
            dotypecheck then
          do_typecheckpass(p1);
         filepos:=current_tokenpos;
         if current_scanner.token in [_ASSIGNMENT,_PLUSASN,_MINUSASN,_ANDASN,_ORASN,_STARASN,_SLASHASN,_MODASN,_DIVASN,_XORASN,_SHLASN,_SHRASN] then
           afterassignment:=true;
         updatefpos:=true;
         case current_scanner.token of
           _POINTPOINT :
             begin
                consume(_POINTPOINT);
                p2:=sub_expr(opcompare,[ef_accept_equal],nil);
                p1:=crangenode.create(p1,p2);
             end;
           _ASSIGNMENT :
             begin
                consume(_ASSIGNMENT);
                { classic-var autofree -- `x := autofree T.Create` }
                autofree_active := (m_autofree in current_settings.modeswitches) and
                                   (current_scanner.token = _AUTOFREE);
                if autofree_active then
                  consume(_AUTOFREE);
                { tuple literal RHS? rewrite as per-field assignments }
                if (m_tuples in current_settings.modeswitches) and
                   (current_scanner.token=_LKLAMMER) and
                   (not assigned(p1.resultdef)) then
                  do_typecheckpass(p1);
                if (m_tuples in current_settings.modeswitches) and
                   (current_scanner.token=_LKLAMMER) and
                   assigned(p1.resultdef) and
                   (p1.resultdef.typ=recorddef) and
                   (df_tuple in p1.resultdef.defoptions) then
                  p1:=tuple_lit_assignment(p1)
                else
                  begin
                    if assigned(p1.resultdef) then
                      if (p1.resultdef.typ=procvardef) then
                        getprocvardef:=tprocvardef(p1.resultdef)
                      else if is_invokable(p1.resultdef) then
                        getfuncrefdef:=tobjectdef(p1.resultdef);
                    p2:=sub_expr(opcompare,[ef_accept_equal],nil);
                    if assigned(getprocvardef) then
                      handle_procvar(getprocvardef,p2)
                    else if assigned(getfuncrefdef) then
                      handle_funcref(getfuncrefdef,p2);
                    getprocvardef:=nil;
                    getfuncrefdef:=nil;
                    if autofree_active then
                      begin
                        do_typecheckpass(p2);
                        p1:=build_classic_autofree(p1,p2);
                      end
                    else
                      p1:=cassignmentnode.create(p1,p2);
                  end;
             end;
           _PLUSASN :
             begin
               if not(cs_support_c_operators in current_settings.moduleswitches) then
                 Message(parser_e_coperators_off);
               consume(_PLUSASN);
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(addn,p1,p2);
            end;
          _MINUSASN :
            begin
               if not(cs_support_c_operators in current_settings.moduleswitches) then
                 Message(parser_e_coperators_off);
               consume(_MINUSASN);
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(subn,p1,p2);
            end;
          _STARASN :
            begin
               if not(cs_support_c_operators in current_settings.moduleswitches) then
                 Message(parser_e_coperators_off);
               consume(_STARASN  );
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(muln,p1,p2);
            end;
          _ANDASN :
            begin
               consume(_ANDASN);
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(andn,p1,p2);
            end;
          _ORASN :
            begin
               consume(_ORASN);
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(orn,p1,p2);
            end;
          _SLASHASN :
            begin
               if not(cs_support_c_operators in current_settings.moduleswitches) then
                 Message(parser_e_coperators_off);
               consume(_SLASHASN  );
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(slashn,p1,p2);
            end;
          _MODASN :
            begin
               consume(_MODASN);
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(modn,p1,p2);
            end;
          _DIVASN :
            begin
               consume(_DIVASN);
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(divn,p1,p2);
            end;
          _XORASN :
            begin
               consume(_XORASN);
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(xorn,p1,p2);
            end;
         _SHLASN :
            begin
               consume(_SHLASN);
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(shln,p1,p2);
            end;
         _SHRASN :
            begin
               consume(_SHRASN);
               p2:=sub_expr(opcompare,[ef_accept_equal],nil);
               p1:=gen_c_style_operator(shrn,p1,p2);
            end;
          else
            updatefpos:=false;
         end;
         oldflags:=p1.flags;
         { get the resultdef for this expression }
         if not assigned(p1.resultdef) and
            dotypecheck then
          do_typecheckpass(p1);
         { transfer generic parameter flag }
         if nf_generic_para in oldflags then
           include(p1.flags,nf_generic_para);
         afterassignment:=oldafterassignment;
         if updatefpos then
           p1.fileinfo:=filepos;
         expr:=p1;
      end;

    function get_intconst:TConstExprInt;
    {Reads an expression, tries to evaluate it and check if it is an integer
     constant. Then the constant is returned.}
    var
      p:tnode;
    begin
      result:=0;
      p:=comp_expr([ef_accept_equal]);
      if not codegenerror then
       begin
         if (p.nodetype<>ordconstn) or
            not(is_integer(p.resultdef)) then
          Message(parser_e_illegal_expression)
         else
          result:=tordconstnode(p).value;
       end;
      p.free;
      p := nil;
    end;


    function get_stringconst:string;
    {Reads an expression, tries to evaluate it and checks if it is a string
     constant. Then the constant is returned.}
    var
      p:tnode;
      snode : tstringconstnode absolute p;
      s : string;
      pw : tcompilerwidestring;
      pc : pansichar;
      len : Integer;

    begin
      get_stringconst:='';
      p:=comp_expr([ef_accept_equal]);
      if p.nodetype<>stringconstn then
        begin
          if (p.nodetype=ordconstn) and is_char(p.resultdef) then
            get_stringconst:=char(tordconstnode(p).value.svalue)
          else
            Message(parser_e_illegal_expression);
        end
      else if (tstringconstnode(p).cst_type in [cst_unicodestring,cst_widestring]) then
         begin
           pw:=snode.valuews;
           len:=getlengthwidestring(pw);
           pc:=getmem(Len+1);
           pc[len]:=#0;
           unicode2ascii(pw,pc,current_settings.sourcecodepage);
           get_stringconst:=strpas(pc);
           freemem(pc);
         end
      else
        get_stringconst:=snode.asrawbytestring;
      p.free;
      p := nil;
    end;

end.
