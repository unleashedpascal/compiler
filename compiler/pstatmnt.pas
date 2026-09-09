{
    Copyright (c) 1998-2002 by Florian Klaempfl

    Does the parsing of the statements

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
unit pstatmnt;

{$i fpcdefs.inc}

interface

    uses
      tokens,node,symsym;


    function statement_block(starttoken : ttoken) : tnode;
    function statement_expr(var p1 : tnode) : boolean;

    { builds an expression selecting the address of an indexed label
      member at run time; nil for an index without a member }
    function generate_arraylabel_addr(sentinel: tlabelsym; indexexpr: tnode): tnode;

    { parses exactly one statement - the headerless `sync <stmt>` body }
    function single_statement : tnode;

    { reads an assembler block }
    function assembler_block : tnode;


implementation

    uses
       { common }
       cutils,cclasses,
       { global }
       globtype,globals,verbose,constexp,
       systems,compinnr,
       { aasm }
       cpubase,aasmtai,aasmdata,aasmbase,
       { module - current_module.localsymtable for threadstatic registration }
       fmodule,
       { symtable }
       symconst,symbase,symtype,symdef,symtable,defutil,defcmp,
       paramgr,
       { pass 1 }
       pass_1,htypechk,
       nutils,ngenutil,nbas,nadd,ncal,nmem,nset,ncnv,ncon,nld,nflw,ninl,nmat,
       { parser }
       scanner,
       pbase,ptype,pexpr,ptconst,pdecl,pparautl,procdefutil,
       { codegen }
       procinfo,cgbase,ncgutil,
       { assembler reader }
       rabase,
       { scanner }
       switches;


    function statement : tnode;forward;
    function defer_statement : tnode;forward;
    function lock_statement(is_try: boolean) : tnode;forward;
    procedure rewrite_defers_in_block(var first: tnode; is_routine_body: boolean = false);forward;

    { Promote a "constructor" array type (the result of `[a, b, c]` parsed as
      a branch value) to a proper dynamic-array def with the same element
      type. Without this, the synthesized temp variable for an `if`/`case`/
      `match` expression has the constructor flag set on its def, and the
      assignment of the constructor value into the temp does not actually
      allocate a managed dynarray - the function returns nil. }
    function constructor_to_dynarray(def: tdef): tdef;
      var
        arr: tarraydef;
      begin
        result:=def;
        if not assigned(def) or (def.typ<>arraydef) then
          exit;
        if not (ado_IsConstructor in tarraydef(def).arrayoptions) then
          exit;
        if (tarraydef(def).arrayoptions * [ado_IsArrayOfConst,ado_IsVariant])<>[] then
          exit;
        if not assigned(tarraydef(def).elementdef) or (tarraydef(def).elementdef=voidtype) then
          exit;
        arr:=carraydef.create(0,-1,ptruinttype);
        arr.arrayoptions:=arr.arrayoptions+[ado_IsDynamicArray];
        arr.elementdef:=tarraydef(def).elementdef;
        result:=arr;
      end;

    { symtable an inline declaration inserts into: the innermost stack
      entry that can hold variables. `with` fieldset and `on E` exception
      symtables are lookup-only views pushed over it, so a declaration
      in a statement list nested under them (e.g. `with r do try`) skips
      them and lands in the enclosing scope }
    function inline_decl_symtable: TSymtable;
      var
        stackitem: psymtablestackitem;
      begin
        stackitem:=symtablestack.stack;
        while assigned(stackitem) and
              (stackitem^.symtable.symtabletype in [withsymtable,exceptsymtable]) do
          stackitem:=stackitem^.next;
        if assigned(stackitem) then
          result:=stackitem^.symtable
        else
          result:=symtablestack.top;
      end;

    { block scopes at main-program level (program body, unit init) hold
      static vars like every other main-program variable, so a closure can
      capture them directly - a parent-frame access from a nested routine
      into the main frame cannot be expressed (IE 2020050302). Block scopes
      inside routines hold ordinary locals }
    function inline_var_sym_is_local: boolean;
      var
        st: TSymtable;
      begin
        st:=inline_decl_symtable;
        result:=(st.symtabletype=localsymtable) or
                ((st.symtabletype=blocksymtable) and
                 (st.symtablelevel>=normal_function_level));
      end;

    { create the sym for an inline var declaration. sibling main-body block
      scopes may reuse a name, so block statics get the declaration position
      mangled in to keep their asm labels unique. the full mangled name is
      anchored at the routine's static symtable because make_mangledname
      cannot walk a block chain that leads through a with-symtable }
    function create_inline_var_sym(const n: string; def: tdef): tabstractnormalvarsym;
      begin
        if inline_var_sym_is_local then
          result:=clocalvarsym.create(n,vs_value,def,[])
        else
          begin
            result:=cstaticvarsym.create(n,vs_value,def,[]);
            if inline_decl_symtable.symtabletype=blocksymtable then
              tstaticvarsym(result).set_mangledname(
                make_mangledname('U',current_procinfo.procdef.localst,
                  n+'$blk'+tostr(current_tokenpos.line)+'_'+tostr(current_tokenpos.column)));
          end;
      end;

    function branch_type(olddef, branchdef: tdef): tdef; inline;
      begin
        olddef:=constructor_to_dynarray(olddef);
        branchdef:=constructor_to_dynarray(branchdef);
        { Handle promotion of string and char types for expression results.
          String constants are typed as chararray (array of char with
          ado_IsConstString), so chararray must be promoted like strings. }
        if not assigned(olddef) or
            (is_anychar(olddef) and is_string(branchdef)) then
          result:=branchdef
        else if (is_anychar(olddef) and is_chararray(branchdef)) or
                (is_chararray(olddef) and is_anychar(branchdef)) then
          result:=cansistringtype
        else if is_widestring(branchdef) or
                ((is_ansistring(olddef) or is_shortstring(olddef) or is_chararray(olddef)) and is_widechar(branchdef)) then
          result:=cwidestringtype
        else if is_char(olddef) and is_widechar(branchdef) then
          result:=cwidechartype
        else if is_shortstring(olddef) and is_shortstring(branchdef) and
                (tstringdef(branchdef).len>tstringdef(olddef).len) then
          result:=branchdef
        else if is_shortstring(olddef) and (is_ansistring(branchdef) or is_unicodestring(branchdef)) then
          result:=branchdef
        else if (is_chararray(olddef) or is_chararray(branchdef)) and
                ((is_chararray(olddef) or is_shortstring(olddef)) and
                 (is_chararray(branchdef) or is_shortstring(branchdef))) then
          { Promote to shortstring when mixing chararray (const string) types,
            so the temp variable is large enough for any branch value }
          result:=cshortstringtype
        else if is_chararray(olddef) and (is_ansistring(branchdef) or is_unicodestring(branchdef)) then
          result:=branchdef
        { numeric branches: widen to a common type instead of silently
          truncating the other branch to the first one's type }
        else if is_integer(olddef) and is_integer(branchdef) then
          result:=get_common_intdef(torddef(olddef),torddef(branchdef),true)
        else if (olddef.typ=floatdef) and (branchdef.typ=floatdef) then
          begin
            if branchdef.size>olddef.size then
              result:=branchdef
            else
              result:=olddef;
          end
        else if is_integer(olddef) and (branchdef.typ=floatdef) then
          result:=branchdef
        else if (olddef.typ=floatdef) and is_integer(branchdef) then
          result:=olddef
        else
          result:=olddef;
      end;

    { parses the single-statement body of a control-flow construct; an
      inline declaration there is rejected - the symbol would go out of
      scope as soon as the statement ends, so it could never be read }
    function control_body_statement : tnode;
      begin
        if ((current_scanner.token in [_VAR,_CONST]) and
            (m_inline_var in current_settings.modeswitches)) or
           ((current_scanner.token=_ID) and
            (((current_scanner.idtoken=_STATIC) and
              (m_inline_static in current_settings.modeswitches)) or
             ((current_scanner.idtoken=_THREADSTATIC) and
              (m_thread_static in current_settings.modeswitches)))) then
          begin
            Message(parser_e_inline_decl_control_body);
            consume_all_until(_SEMICOLON);
            result:=cerrornode.create;
            exit;
          end;
        result:=statement;
      end;


    function if_statement(is_expr:boolean=false) : tnode;
      function statementorexpr : tnode; inline;
        begin
          if is_expr then
            result:=expr(true)
          else
            result:=control_body_statement;
        end;

      var
         ex,if_a,else_a : tnode;
         statements : tstatementnode;
         resultvar : ttempcreatenode;
         resultdef : tdef;
      begin
         consume(_IF);
         ex:=comp_expr([ef_accept_equal]);
         consume(_THEN);
         if not(current_scanner.token in endtokens) then
           if_a:=statementorexpr
         else
           if_a:=nil;

         else_a:=nil;
         if try_to_consume(_ELSE) then
            else_a:=statementorexpr
         else if is_expr then
           consume(_ELSE);
         if (not is_expr) then
           begin
             result:=cifnode.create(ex,if_a,else_a);
             exit;
           end;
         result:=internalstatements(statements);
         resultdef:=branch_type(if_a.resultdef,else_a.resultdef);
         resultvar:=ctempcreatenode.create(resultdef,resultdef.size,tt_persistent,true);
         addstatement(statements,resultvar);
         addstatement(statements,cifnode.create(ex,
           cassignmentnode.create(ctemprefnode.create(resultvar),if_a),
           cassignmentnode.create(ctemprefnode.create(resultvar),else_a)
         ));
         addstatement(statements,ctempdeletenode.create_normal_temp(resultvar));
         addstatement(statements,ctemprefnode.create(resultvar));
      end;

    { creates a block (list) of statements, til the next END token }
    function statements_til_end : tnode;

      var
         first,last : tstatementnode;

      begin
         first:=nil;
         last:=nil;
         while current_scanner.token<>_END do
           begin
              if first=nil then
                begin
                   last:=cstatementnode.create(statement,nil);
                   first:=last;
                end
              else
                begin
                   last.right:=cstatementnode.create(statement,nil);
                   last:=tstatementnode(last.right);
                end;
              if not try_to_consume(_SEMICOLON) then
                break;
              consume_emptystats;
           end;
         consume(_END);
         statements_til_end:=cblocknode.create(first);
         if assigned(first) then
           statements_til_end.fileinfo:=first.fileinfo;
      end;


    function case_statement(is_expr:boolean=false) : tnode;
      var
        resultdef : tdef;

      function statementorexpr : tnode;inline;
        begin
          if is_expr then
            begin
               result:=expr(true);
               resultdef:=branch_type(resultdef,result.resultdef);
            end
          else
            result:=control_body_statement;
        end;

        function requires_else(casenode : tcasenode) : boolean; inline;
          var
            lv,hv : TConstExprInt;
          begin
            if is_boolean(casenode.left.resultdef) then
              begin
                lv:=0;
                hv:=1;
              end
            else if is_string(casenode.left.resultdef) then
              { strings have no enumerable range, full coverage is impossible }
              exit(true)
            else
              getrange(casenode.left.resultdef,lv,hv);
            Result:=casenode.labelcoverage<hv-lv;
          end;

      var
         casedef : tdef;
         caseexpr,p : tnode;
         blockid : longint;
         hl1,hl2 : TConstExprInt;
         sl1,sl2 : tstringconstnode;
         casedeferror, caseofstring : boolean;
         casenode : tcasenode;
         i : longint;
         statements : tstatementnode;
         resultvar : ttempcreatenode;
      begin
         resultdef:=nil;
         consume(_CASE);
         caseexpr:=comp_expr([ef_accept_equal]);
         { determines result type }
         do_typecheckpass(caseexpr);
         { variants must be accepted, but first they must be converted to integer }
         if caseexpr.resultdef.typ=variantdef then
           begin
             caseexpr:=ctypeconvnode.create_internal(caseexpr,sinttype);
             do_typecheckpass(caseexpr);
           end;
         set_varstate(caseexpr,vs_read,[vsf_must_be_valid]);
         casedeferror:=false;
         casedef:=caseexpr.resultdef;
         { case of string must be rejected in delphi-, }
         { tp7/bp7-, mac-compatibility modes.          }
         caseofstring :=
           ([m_delphi, m_mac, m_tp7] * current_settings.modeswitches = []) and
           is_string(casedef);

         if (not assigned(casedef)) or
            ( not(is_ordinal(casedef)) and (not caseofstring) ) then
          begin
            CGMessage(type_e_ordinal_or_string_expr_expected);
            { create a correct tree }
            caseexpr.free;
            caseexpr:=cordconstnode.create(0,u32inttype,false);
            { set error flag so no rangechecks are done }
            casedeferror:=true;
          end;
         { Create casenode }
         casenode:=ccasenode.create(caseexpr);
         consume(_OF);
         { Parse all case blocks }
         blockid:=0;
         repeat
           { maybe an instruction has more case labels }
           repeat
             p:=expr(true);
             if is_widechar(casedef) then
               begin
                  if (p.nodetype=rangen) then
                    begin
                       trangenode(p).left:=ctypeconvnode.create(trangenode(p).left,cwidechartype);
                       trangenode(p).right:=ctypeconvnode.create(trangenode(p).right,cwidechartype);
                       do_typecheckpass(trangenode(p).left);
                       do_typecheckpass(trangenode(p).right);
                    end
                  else
                    begin
                       p:=ctypeconvnode.create(p,cwidechartype);
                       do_typecheckpass(p);
                    end;
               end
             else
               begin
                 if is_char(casedef) and is_widechar(p.resultdef) then
                   begin
                      if (p.nodetype=ordconstn) then
                        begin
                           p:=ctypeconvnode.create(p,cansichartype);
                           do_typecheckpass(p);
                        end
                      else if (p.nodetype=rangen) then
                        begin
                           trangenode(p).left:=ctypeconvnode.create(trangenode(p).left,cansichartype);
                           trangenode(p).right:=ctypeconvnode.create(trangenode(p).right,cansichartype);
                           do_typecheckpass(trangenode(p).left);
                           do_typecheckpass(trangenode(p).right);
                        end;
                   end;
               end;
             hl1:=0;
             hl2:=0;
             sl1:=nil;
             sl2:=nil;
             if (p.nodetype=rangen) then
               begin
                 { type check for string case statements }
                 if caseofstring and
                   is_conststring_or_constcharnode(trangenode(p).left) and
                   is_conststring_or_constcharnode(trangenode(p).right) then
                 begin
                   { we need stringconstnodes, even if expression contains single chars }
                   sl1 := get_string_value(trangenode(p).left, tstringdef(casedef));
                   sl2 := get_string_value(trangenode(p).right, tstringdef(casedef));
                   if sl1.fullcompare(sl2) > 0 then
                     CGMessage(parser_e_case_lower_less_than_upper_bound);
                 end
                 { type checking for ordinal case statements }
                 else if (not caseofstring) and
                   is_subequal(casedef, trangenode(p).left.resultdef) and
                   is_subequal(casedef, trangenode(p).right.resultdef) then
                   begin
                     hl1:=get_ordinal_value(trangenode(p).left);
                     hl2:=get_ordinal_value(trangenode(p).right);
                     if hl1>hl2 then
                       CGMessage(parser_e_case_lower_less_than_upper_bound);
                     if not casedeferror then
                       begin
                         adaptrange(casedef,hl1,false,false,cs_check_range in current_settings.localswitches);
                         adaptrange(casedef,hl2,false,false,cs_check_range in current_settings.localswitches);
                       end;
                   end
                 else
                   CGMessage(parser_e_case_mismatch);

                 if caseofstring then
                   casenode.addlabel(blockid,sl1,sl2)
                 else
                   casenode.addlabel(blockid,hl1,hl2);
               end
             else
               begin
                 { type check for string case statements }
                 if (caseofstring and (not is_conststring_or_constcharnode(p))) or
                 { type checking for ordinal case statements }
                   ((not caseofstring) and (not is_subequal(casedef, p.resultdef))) then
                   CGMessage(parser_e_case_mismatch);

                 if caseofstring then
                   begin
                     sl1:=get_string_value(p, tstringdef(casedef));
                     casenode.addlabel(blockid,sl1,sl1);
                   end
                 else
                   begin
                     hl1:=get_ordinal_value(p);
                     if not casedeferror then
                       adaptrange(casedef,hl1,false,false,cs_check_range in current_settings.localswitches);
                     casenode.addlabel(blockid,hl1,hl1);
                   end;
               end;
             p.free;
             p := nil;
             sl1.free;
             sl1 := nil;
             sl2.free;
             sl2 := nil;

             if current_scanner.token=_COMMA then
               consume(_COMMA)
             else
               break;
           until false;
           consume(_COLON);

           { add instruction block }
           casenode.addblock(blockid,statementorexpr);

           { next block }
           inc(blockid);

           if not(current_scanner.token in [_ELSE,_OTHERWISE,_END]) then
             consume(_SEMICOLON);
         until (current_scanner.token in [_ELSE,_OTHERWISE,_END]);

         if (current_scanner.token in [_ELSE,_OTHERWISE]) then
           begin
              if not try_to_consume(_ELSE) then
                consume(_OTHERWISE);
              if is_expr then
                casenode.addelseblock(statementorexpr)
              else
                casenode.addelseblock(statements_til_end);
           end
         else
           begin
             if is_expr and requires_else(casenode) then
               Comment(V_Error,'`case` expression needs `else` or `otherwise` to cover unmatched values');
             consume(_END);
           end;

         if not is_expr then
           begin
             result:=casenode;
             exit;
           end;
         result:=internalstatements(statements);
         resultvar:=ctempcreatenode.create(resultdef,resultdef.size,tt_persistent,true);
         addstatement(statements,resultvar);
         for i:=0 to casenode.blocks.Count-1 do
           pcaseblock(casenode.blocks[i])^.statement:=cassignmentnode.create(
             ctemprefnode.create(resultvar), pcaseblock(casenode.blocks[i])^.statement
           );
         if assigned(casenode.elseblock) then
           casenode.elseblock:=cassignmentnode.create(ctemprefnode.create(resultvar), casenode.elseblock);
         addstatement(statements,casenode);
         addstatement(statements,ctempdeletenode.create_normal_temp(resultvar));
         addstatement(statements,ctemprefnode.create(resultvar));
      end;


    function match_statement(is_expr:boolean=false) : tnode;
      { Match statement: first-match (if-elseif) or fallthrough (match all).
        Subject-based: match EXPR of pat: stmt; end;
        Condition-based: match cond: stmt; end; }

      function is_wildcard_underscore : boolean; inline;
        begin
          result:=(current_scanner.token=_ID) and (current_scanner.pattern='_');
        end;

      procedure append_else(var ifchain:tnode;elseblock:tnode);
        var
          tailnode : tnode;
        begin
          if ifchain=nil then
            ifchain:=elseblock
          else
            begin
              tailnode:=ifchain;
              while assigned(tifnode(tailnode).t1) do
                tailnode:=tifnode(tailnode).t1;
              tifnode(tailnode).t1:=elseblock;
            end;
        end;

      function parse_branch_cond(has_subject:boolean;subject:tnode;out is_catchall:boolean) : tnode;
        { Parse pattern(s) for a branch. Subject mode supports comma-separated
          patterns (OR'd) and tuple patterns with _ wildcards. A bare `_`
          alone or anywhere in the comma list flips `is_catchall` and the
          caller treats the whole branch as `else`. }

        { equality check, or range check if `..` follows. when an ordinal
          subject's range bound sits exactly at the type's natural minimum
          (or maximum), the corresponding `>=`/`<=` check is always true
          and only triggers `comparison might be always true` warnings;
          drop the redundant half }
        function build_match_cond(subj,lo:tnode):tnode;
          var
            hi : tnode;
            type_lo,type_hi : TConstExprInt;
            skip_lower,skip_upper : boolean;
          begin
            if try_to_consume(_POINTPOINT) then
              begin
                hi:=comp_expr([ef_accept_equal]);
                do_typecheckpass(hi);
                skip_lower:=false;
                skip_upper:=false;
                if is_ordinal(subj.resultdef) then
                  begin
                    getrange(subj.resultdef,type_lo,type_hi);
                    if (lo.nodetype=ordconstn) and (tordconstnode(lo).value=type_lo) then
                      skip_lower:=true;
                    if (hi.nodetype=ordconstn) and (tordconstnode(hi).value=type_hi) then
                      skip_upper:=true;
                  end;
                if skip_lower and skip_upper then
                  begin
                    lo.free;
                    hi.free;
                    result:=cordconstnode.create(1,pasbool1type,false);
                  end
                else if skip_lower then
                  begin
                    lo.free;
                    result:=caddnode.create(lten,subj.getcopy,hi);
                  end
                else if skip_upper then
                  begin
                    hi.free;
                    result:=caddnode.create(gten,subj.getcopy,lo);
                  end
                else
                  result:=caddnode.create(andn,
                    caddnode.create(gten,subj.getcopy,lo),
                    caddnode.create(lten,subj.getcopy,hi));
              end
            else
              result:=caddnode.create(equaln,subj.getcopy,lo);
          end;

        var
          pat,cond : tnode;
          fields : array of tnode;
          fieldcount,i,symidx : integer;
          sym : tsym;
          recdef : trecorddef;
        begin
          is_catchall:=false;
          { tuple pattern with potential _ wildcards }
          if has_subject and (current_scanner.token=_LKLAMMER) and
             assigned(subject.resultdef) and (subject.resultdef.typ=recorddef) and
             (df_tuple in subject.resultdef.defoptions) then
            begin
              consume(_LKLAMMER);
              fieldcount:=0;
              setlength(fields,8);
              repeat
                if fieldcount>=length(fields) then
                  setlength(fields,fieldcount*2);
                if (current_scanner.token=_ID) and (current_scanner.pattern='_') then
                  begin
                    fields[fieldcount]:=nil;
                    consume(_ID);
                  end
                else
                  begin
                    fields[fieldcount]:=comp_expr([ef_accept_equal]);
                    do_typecheckpass(fields[fieldcount]);
                  end;
                inc(fieldcount);
              until not try_to_consume(_COMMA);
              { single expression in parens = parenthesized expr, not tuple }
              if fieldcount=1 then
                begin
                  consume(_RKLAMMER);
                  if fields[0]=nil then
                    result:=cordconstnode.create(1,pasbool1type,false)
                  else
                    result:=caddnode.create(equaln,subject.getcopy,fields[0]);
                  exit;
                end;
              consume(_RKLAMMER);
              { build per-field AND chain, skipping wildcards }
              recdef:=trecorddef(subject.resultdef);
              cond:=nil;
              i:=0;
              for symidx:=0 to recdef.symtable.symlist.count-1 do
                begin
                  sym:=tsym(recdef.symtable.symlist[symidx]);
                  if sym.typ<>fieldvarsym then
                    continue;
                  if i>=fieldcount then
                    break;
                  if fields[i]<>nil then
                    begin
                      pat:=caddnode.create(equaln,
                        csubscriptnode.create(tfieldvarsym(sym),subject.getcopy),
                        fields[i]);
                      if cond=nil then
                        cond:=pat
                      else
                        cond:=caddnode.create(andn,cond,pat);
                    end;
                  inc(i);
                end;
              if cond=nil then
                cond:=cordconstnode.create(1,pasbool1type,false);
              result:=cond;
            end
          else
            begin
              { bare _ at branch start: standalone catch-all, but must be
                the LAST pattern in the branch - reject `_,...` }
              if is_wildcard_underscore then
                begin
                  is_catchall:=true;
                  consume(_ID);
                  if current_scanner.token=_COMMA then
                    Comment(V_Error,'`_` must be the last pattern in a `match` branch');
                  result:=nil;
                  exit;
                end;
              { normal pattern with optional comma-separated OR; `_` is only
                allowed as the FINAL element of the comma list }
              pat:=comp_expr([ef_accept_equal]);
              do_typecheckpass(pat);
              if has_subject then
                begin
                  result:=build_match_cond(subject,pat);
                  while try_to_consume(_COMMA) do
                    begin
                      if is_wildcard_underscore then
                        begin
                          is_catchall:=true;
                          consume(_ID);
                          if current_scanner.token=_COMMA then
                            Comment(V_Error,'`_` must be the last pattern in a `match` branch');
                          result.free;
                          result:=nil;
                          exit;
                        end;
                      pat:=comp_expr([ef_accept_equal]);
                      do_typecheckpass(pat);
                      result:=caddnode.create(orn,result,
                        build_match_cond(subject,pat));
                    end;
                end
              else
                result:=pat;
            end;
        end;

      var
        subject,cond,stmt,ifchain,firstcond,walknode,stmtblock,flagblock : tnode;
        fallthrough,has_subject,has_catchall,branch_catchall : boolean;
        stmts,exprstatements,flagstmts : tstatementnode;
        resultdef : tdef;
        resultvar,matchedvar : ttempcreatenode;
      begin
        consume(_MATCH);
        { check for 'all' (context-sensitive) }
        fallthrough:=(current_scanner.token=_ID) and (current_scanner.pattern='ALL');
        if fallthrough then
          consume(_ID);
        { empty `match end` / `match all end` as statement: no-op, parity with
          empty `begin..end` and empty `case X of end`. only allowed as
          statement, expression context still needs a value }
        if (not is_expr) and (current_scanner.token=_END) then
          begin
            consume(_END);
            result:=cnothingnode.create;
            exit;
          end;
        { determine mode: subject-based (match X of) vs condition-based }
        has_subject:=false;
        subject:=nil;
        firstcond:=nil;
        if not is_wildcard_underscore then
          begin
            firstcond:=comp_expr([ef_accept_equal]);
            do_typecheckpass(firstcond);
            if current_scanner.token=_OF then
              begin
                has_subject:=true;
                subject:=firstcond;
                set_varstate(subject,vs_read,[vsf_must_be_valid]);
                consume(_OF);
                firstcond:=nil;
              end;
          end;
        if fallthrough then
          begin
            { fallthrough: independent if-statements in repeat..until true }
            stmtblock:=internalstatements(stmts);
            has_catchall:=false;
            repeat
              if firstcond<>nil then
                begin
                  cond:=firstcond;
                  firstcond:=nil;
                  branch_catchall:=false;
                end
              else
                cond:=parse_branch_cond(has_subject,subject,branch_catchall);
              consume(_COLON);
              if branch_catchall then
                begin
                  has_catchall:=true;
                  addstatement(stmts,control_body_statement);
                  if not(current_scanner.token in [_END]) then
                    consume(_SEMICOLON);
                  break;
                end;
              addstatement(stmts,cifnode.create(cond,control_body_statement,nil));
              if not(current_scanner.token in [_ELSE,_OTHERWISE,_END]) then
                consume(_SEMICOLON);
            until current_scanner.token in [_ELSE,_OTHERWISE,_END];
            if try_to_consume(_ELSE) or try_to_consume(_OTHERWISE) then
              begin
                stmt:=statements_til_end;
                if has_catchall then
                  begin
                    { `_` counts as a match, so the fallback can never run }
                    Comment(V_Warning,'`_:` always matches, `else`/`otherwise` branch never executes');
                    stmt.free;
                  end
                else
                  begin
                    { fallback runs only when no branch matched: a flag temp
                      is set by every branch body and checked after the
                      dispatch ifs. cleared with an explicit statement -
                      create_value's lazy init would run inside the first
                      branch body instead of unconditionally }
                    matchedvar:=ctempcreatenode.create(pasbool1type,1,tt_persistent,true);
                    walknode:=tblocknode(stmtblock).left;
                    while assigned(walknode) do
                      begin
                        { skip the dummy nothing-statement at the chain head }
                        if tstatementnode(walknode).statement.nodetype=ifn then
                          begin
                            flagblock:=internalstatements(flagstmts);
                            addstatement(flagstmts,cassignmentnode.create(
                              ctemprefnode.create(matchedvar),
                              cordconstnode.create(1,pasbool1type,false)));
                            addstatement(flagstmts,tifnode(tstatementnode(walknode).statement).right);
                            tifnode(tstatementnode(walknode).statement).right:=flagblock;
                          end;
                        walknode:=tstatementnode(walknode).next;
                      end;
                    tblocknode(stmtblock).left:=cstatementnode.create(matchedvar,
                      cstatementnode.create(
                        cassignmentnode.create(ctemprefnode.create(matchedvar),
                          cordconstnode.create(0,pasbool1type,false)),
                        tblocknode(stmtblock).left));
                    addstatement(stmts,cifnode.create(
                      cnotnode.create(ctemprefnode.create(matchedvar)),stmt,nil));
                    addstatement(stmts,ctempdeletenode.create(matchedvar));
                  end;
              end
            else
              consume(_END);
            if has_subject then
              subject.free;
            result:=cwhilerepeatnode.create(
              cordconstnode.create(1,pasbool1type,false),
              stmtblock,false,true);
          end
        else
          begin
            { first-match: if-elseif chain }
            resultdef:=nil;
            has_catchall:=false;
            ifchain:=nil;
            repeat
              if firstcond<>nil then
                begin
                  cond:=firstcond;
                  firstcond:=nil;
                  branch_catchall:=false;
                end
              else
                cond:=parse_branch_cond(has_subject,subject,branch_catchall);
              consume(_COLON);
              if is_expr then
                begin
                  stmt:=expr(true);
                  resultdef:=branch_type(resultdef,stmt.resultdef);
                end
              else
                stmt:=control_body_statement;
              if branch_catchall then
                begin
                  has_catchall:=true;
                  append_else(ifchain,stmt);
                  if not(current_scanner.token in [_END]) then
                    consume(_SEMICOLON);
                  break;
                end;
              stmt:=cifnode.create(cond,stmt,nil);
              append_else(ifchain,stmt);
              if not(current_scanner.token in [_ELSE,_OTHERWISE,_END]) then
                consume(_SEMICOLON);
            until current_scanner.token in [_ELSE,_OTHERWISE,_END];
            if has_catchall and (current_scanner.token in [_ELSE,_OTHERWISE]) then
              begin
                Comment(V_Error,'`_:` already covers unmatched values, drop trailing `else`/`otherwise`');
                consume(current_scanner.token);
                if is_expr then
                  expr(true).free
                else
                  statements_til_end.free;
              end
            else if try_to_consume(_ELSE) or try_to_consume(_OTHERWISE) then
              begin
                { in expr mode `else`/`otherwise <expr>` terminates the match -
                  no `end` keyword expected, mirroring case-style else }
                has_catchall:=true;
                if is_expr then
                  begin
                    stmt:=expr(true);
                    resultdef:=branch_type(resultdef,stmt.resultdef);
                  end
                else
                  stmt:=statements_til_end;
                append_else(ifchain,stmt);
              end
            else
              begin
                if is_expr and not has_catchall then
                  Comment(V_Error,'`match` expression needs `_:`, `else` or `otherwise` to cover unmatched values');
                consume(_END);
              end;
            if has_subject then
              subject.free;
            if not is_expr then
              result:=ifchain
            else
              begin
                { expression mode: wrap branches in temp var assignments }
                result:=internalstatements(exprstatements);
                resultvar:=ctempcreatenode.create(resultdef,resultdef.size,tt_persistent,true);
                addstatement(exprstatements,resultvar);
                { walk if-chain, wrap each branch value in assignment }
                walknode:=ifchain;
                while walknode.nodetype=ifn do
                  begin
                    tifnode(walknode).right:=cassignmentnode.create(
                      ctemprefnode.create(resultvar),tifnode(walknode).right);
                    if assigned(tifnode(walknode).t1) and (tifnode(walknode).t1.nodetype=ifn) then
                      walknode:=tifnode(walknode).t1
                    else
                      begin
                        if assigned(tifnode(walknode).t1) then
                          tifnode(walknode).t1:=cassignmentnode.create(
                            ctemprefnode.create(resultvar),tifnode(walknode).t1);
                        break;
                      end;
                  end;
                if ifchain.nodetype<>ifn then
                  { single catch-all value }
                  ifchain:=cassignmentnode.create(ctemprefnode.create(resultvar),ifchain);
                addstatement(exprstatements,ifchain);
                addstatement(exprstatements,ctempdeletenode.create_normal_temp(resultvar));
                addstatement(exprstatements,ctemprefnode.create(resultvar));
              end;
          end;
      end;


    function repeat_statement : tnode;

      var
         first,last,p_e : tnode;

      begin
         consume(_REPEAT);

         first:=nil;
         last:=nil;
         while current_scanner.token<>_UNTIL do
           begin
              if first=nil then
                begin
                   last:=cstatementnode.create(statement,nil);
                   first:=last;
                end
              else
                begin
                   tstatementnode(last).right:=cstatementnode.create(statement,nil);
                   last:=tstatementnode(last).right;
                end;
              if not try_to_consume(_SEMICOLON) then
                break;
              consume_emptystats;
           end;
         consume(_UNTIL);

         first:=cblocknode.create(first);
         p_e:=comp_expr([ef_accept_equal]);
         result:=cwhilerepeatnode.create(p_e,first,false,true);
      end;


    function while_statement : tnode;

      var
         p_e,p_a : tnode;

      begin
         consume(_WHILE);
         p_e:=comp_expr([ef_accept_equal]);
         consume(_DO);
         p_a:=control_body_statement;
         result:=cwhilerepeatnode.create(p_e,p_a,true,false);
      end;

    { a helper function which is used both by "with" and "for-in loop" nodes }
    function skip_nodes_before_load(p: tnode): tnode;
      begin
        { ignore nodes that don't add instructions in the tree }
        while assigned(p) and
           { equal type conversions }
           (
            (p.nodetype=typeconvn) and
            (ttypeconvnode(p).convtype=tc_equal)
           ) or
           { constant array index }
           (
            (p.nodetype=vecn) and
            (tvecnode(p).right.nodetype=ordconstn)
           ) do
          p:=tunarynode(p).left;
        result:=p;
      end;

    { parallel-for body checks: break targeting the loop, exit, and goto
      leaving the body have no meaning once the body runs on worker threads.
      continue is fine - it ends the current iteration. }

    function parfor_collect_labels(var n: tnode; arg: pointer): foreachnoderesult;
      begin
        if n.nodetype=labeln then
          tfplist(arg).add(tlabelnode(n).labsym);
        result:=fen_true;
      end;

    function parfor_check_exit_goto(var n: tnode; arg: pointer): foreachnoderesult;
      begin
        result:=fen_true;
        if n.nodetype=exitn then
          MessagePos(n.fileinfo,parser_e_parallel_for_no_exit)
        else if (n.nodetype=goton) and
                (tfplist(arg).indexof(tgotonode(n).labelsym)<0) then
          MessagePos(n.fileinfo,parser_e_parallel_for_no_goto);
      end;

    { a `break` bound to the parallel loop cancels it cooperatively: it raises
      the shared flag (so no worker claims another iteration) and leaves this
      worker's dispatch loop; iterations already running elsewhere finish }
    function parfor_rewrite_break(var n: tnode; arg: pointer): foreachnoderesult;
      var
        cancelsym: tabstractnormalvarsym;
        stat: tstatementnode;
        fi: tfileposinfo;
      begin
        case n.nodetype of
          // a break inside a nested loop targets that loop, not the parallel one
          forn,whilerepeatn:
            result:=fen_norecurse_true;
          breakn:
            begin
              cancelsym:=tabstractnormalvarsym(arg);
              fi:=n.fileinfo;
              n.free;
              n:=internalstatements(stat);
              n.fileinfo:=fi;
              addstatement(stat,cassignmentnode.create(cloadnode.create(cancelsym,cancelsym.owner),
                cordconstnode.create(1,s32inttype,false)));
              addstatement(stat,cbreaknode.create);
              // do not descend into the replacement - its break is the rewrite
              result:=fen_norecurse_true;
            end;
          else
            result:=fen_true;
        end;
      end;

    procedure parfor_validate_body(body: tnode; cancelsym: tabstractnormalvarsym);
      var
        lbls: tfplist;
      begin
        if not assigned(body) then
          exit;
        lbls:=tfplist.create;
        foreachnodestatic(body,@parfor_collect_labels,lbls);
        foreachnodestatic(body,@parfor_check_exit_goto,lbls);
        { postprocess visits a loop node before its children, so returning
          fen_norecurse on an inner loop skips the breaks that belong to it }
        foreachnodestatic(pm_postprocess,body,@parfor_rewrite_break,cancelsym);
        lbls.free;
      end;

    { create a value variable in pd's localst - a static var for the main/unit
      symtable, an ordinary local otherwise - used for the parallel-for state }
    function parfor_make_local(pd: tprocdef; const n: string; d: tdef): tabstractnormalvarsym;
      begin
        if pd.localst.symtabletype=staticsymtable then
          result:=cstaticvarsym.create(n,vs_value,d,[])
        else
          result:=clocalvarsym.create(n,vs_value,d,[]);
        result.register_sym;
        pd.localst.insertsym(result);
        if result.typ=staticvarsym then
          cnodeutils.insertbssdata(tstaticvarsym(result));
      end;

    { load a read-only worker-local for an internal write; the flag lets the
      assignment pass the const check that blocks user code }
    function parfor_load_ignoreconst(sym: tabstractnormalvarsym): tnode;
      begin
        result:=cloadnode.create(sym,sym.owner);
        include(tloadnode(result).loadnodeflags,loadnf_isinternal_ignoreconst);
      end;

    { Inline-var type inference reads the typechecked init expression, whose
      integer arithmetic was already promoted to the native int size. On
      64-bit targets that turns arithmetic on 32-bit operands into a 64-bit
      result, so `var s := a + b` with a, b: LongWord would infer QWord on
      x86_64 but LongWord on i386, silently changing wrap-around semantics
      between targets. Undo the promotion for inference: when every operand
      of a +,-,*,div,mod tree originally fit in 32 bits, return the 32-bit
      type a 32-bit-native target would have produced. Unsigned subtraction
      is widened to 64 bit even on 32-bit natives, so its demotion applies
      on every target. In the other direction, a qword operand combined
      with a nonnegative integer constant is typechecked as int64 (folded
      constants lose an unsigned def when the value fits int64), so such
      trees go back to qword for inference. }
    function unleashed_infer_natural_intdef(n: tnode; def: tdef): tdef;
      type
        tintkind = (ik_wide,ik_sig,ik_u32,ik_pos);
        tuqkind = (uq_none,uq_u64,uq_const);

      { classify a plain operand by the range its value spans: ik_sig =
        signed 32 bit or smaller, ik_u32 = unsigned needing full 32 bits,
        ik_pos = unsigned fitting in a signed 32 bit, ik_wide = the rest }
      function leafkind(def: tdef): tintkind;
        begin
          result:=ik_wide;
          if not is_integer(def) then
            exit;
          case torddef(def).ordtype of
            s8bit,s16bit,s32bit:
              result:=ik_sig;
            u8bit,u16bit:
              result:=ik_pos;
            u32bit:
              result:=ik_u32;
            else
              ;
          end;
        end;

      function kindof(n: tnode): tintkind;
        var
          lk,rk : tintkind;
        begin
          result:=ik_wide;
          if not assigned(n.resultdef) then
            exit;
          case n.nodetype of
            addn,muln,divn,modn:
              begin
                lk:=kindof(tbinarynode(n).left);
                rk:=kindof(tbinarynode(n).right);
                if (lk=ik_wide) or (rk=ik_wide) then
                  exit;
                { full unsigned mixed with signed widens to 64 bit even on
                  32-bit natives }
                if ((lk=ik_u32) and (rk=ik_sig)) or ((lk=ik_sig) and (rk=ik_u32)) then
                  exit;
                if (lk=ik_u32) or (rk=ik_u32) then
                  result:=ik_u32
                else if (lk=ik_sig) or (rk=ik_sig) then
                  result:=ik_sig
                else
                  result:=ik_u32;
              end;
            subn:
              begin
                { subtraction mixing full unsigned with signed widens to
                  64 bit, pure unsigned stays a 32-bit wrap-around }
                lk:=kindof(tbinarynode(n).left);
                rk:=kindof(tbinarynode(n).right);
                if (lk=ik_wide) or (rk=ik_wide) then
                  exit;
                if ((lk=ik_u32) and (rk=ik_sig)) or ((lk=ik_sig) and (rk=ik_u32)) then
                  exit;
                if (lk=ik_u32) or (rk=ik_u32) then
                  result:=ik_u32
                else
                  result:=ik_sig;
              end;
            unaryminusn:
              if kindof(tunarynode(n).left)<>ik_wide then
                result:=ik_sig;
            ordconstn:
              if is_integer(n.resultdef) and not(nf_explicit in n.flags) then
                begin
                  if (tordconstnode(n).value>=0) and (tordconstnode(n).value<=high(longint)) then
                    result:=ik_pos
                  else if (tordconstnode(n).value<0) and (tordconstnode(n).value>=low(longint)) then
                    result:=ik_sig
                  else if (tordconstnode(n).value>high(longint)) and (tordconstnode(n).value<=high(cardinal)) then
                    result:=ik_u32;
                end
              else
                result:=leafkind(n.resultdef);
            typeconvn:
              { look through the compiler-inserted widening to native int }
              if not(nf_explicit in n.flags) and is_integer(n.resultdef) and (torddef(n.resultdef).ordtype in [s64bit,u64bit]) and assigned(ttypeconvnode(n).left.resultdef) and is_integer(ttypeconvnode(n).left.resultdef) then
                result:=kindof(ttypeconvnode(n).left)
              else
                result:=leafkind(n.resultdef);
            else
              result:=leafkind(n.resultdef);
          end;
        end;

      { classify operands of a 64-bit tree: uq_u64 = unsigned 64-bit
        operand, uq_const = nonnegative integer constant, uq_none = rest }
      function uqkind(n: tnode): tuqkind;
        var
          lk,rk : tuqkind;
        begin
          result:=uq_none;
          if not assigned(n.resultdef) or not is_integer(n.resultdef) then
            exit;
          case n.nodetype of
            addn,subn,muln:
              begin
                lk:=uqkind(tbinarynode(n).left);
                rk:=uqkind(tbinarynode(n).right);
                if (lk=uq_none) or (rk=uq_none) then
                  exit;
                if (lk=uq_u64) or (rk=uq_u64) then
                  result:=uq_u64
                else
                  result:=uq_const;
              end;
            ordconstn:
              if tordconstnode(n).value>=0 then
                result:=uq_const;
            typeconvn:
              { look through the compiler-inserted widening to int64 }
              if not(nf_explicit in n.flags) and (torddef(n.resultdef).ordtype=s64bit) and assigned(ttypeconvnode(n).left.resultdef) and is_integer(ttypeconvnode(n).left.resultdef) then
                result:=uqkind(ttypeconvnode(n).left)
              else if torddef(n.resultdef).ordtype=u64bit then
                result:=uq_u64;
            else
              if torddef(n.resultdef).ordtype=u64bit then
                result:=uq_u64;
          end;
        end;

      begin
        result:=def;
        if not is_integer(def) or
           not(torddef(def).ordtype in [s64bit,u64bit]) or
           not(n.nodetype in [addn,subn,muln,divn,modn,unaryminusn]) then
          exit;
        case kindof(n) of
          ik_sig:
            result:=s32inttype;
          ik_u32,ik_pos:
            result:=u32inttype;
          else
            { the signed result of a qword operand mixed with nonnegative
              constants relabels as qword; the add, sub and mul bit
              patterns are sign-agnostic, so only the inferred type
              changes, not the value }
            if (torddef(def).ordtype=s64bit) and (n.nodetype in [addn,subn,muln]) and (uqkind(n)=uq_u64) then
              result:=u64inttype;
        end;
      end;

    function for_statement : tnode;

        procedure check_range(hp:tnode; fordef: tdef);
          begin
            if (hp.nodetype=ordconstn) and
               (fordef.typ<>errordef) and
               { the node was derived from a generic parameter so ignore range check }
               not(nf_generic_para in hp.flags) then
              adaptrange(fordef,tordconstnode(hp).value,false,false,true);
          end;

        function for_loop_create(hloopvar: tnode): tnode;
          var
             hp,
             hblock,
             hto,hfrom,hstep : tnode;
             backward : boolean;
             loopvarsym : tabstractvarsym;
          begin
             { Check loop variable }
             loopvarsym:=nil;
             hstep:=nil;

             { variable must be an ordinal, int64 is not allowed for 32bit targets
               (for loops lower to while loops, whose 64-bit arithmetic works on
               32-bit targets - keep the historic error outside unleashed) }
             if (
                 not(is_ordinal(hloopvar.resultdef))
    {$if not defined(cpu64bitaddr) and not defined(cpu64bitalu)}
                 or (is_64bitint(hloopvar.resultdef) and
                     not(m_unleashed in current_settings.modeswitches))
    {$endif not cpu64bitaddr and not cpu64bitalu}
               ) and
               (hloopvar.resultdef.typ<>undefineddef)
               then
               begin
                 MessagePos(hloopvar.fileinfo,type_e_ordinal_expr_expected);
                 hloopvar.resultdef:=generrordef;
               end;

             hp:=hloopvar;
             while assigned(hp) and
                   (
                    { record/object fields and array elements are allowed }
                    { in tp7 mode only                                    }
                    (
                     (m_tp7 in current_settings.modeswitches) and
                     (
                      ((hp.nodetype=subscriptn) and
                       ((tsubscriptnode(hp).left.resultdef.typ=recorddef) or
                        is_object(tsubscriptnode(hp).left.resultdef))
                      ) or
                      { constant array index }
                      (
                       (hp.nodetype=vecn) and
                       is_constintnode(tvecnode(hp).right)
                      )
                     )
                    ) or
                    { equal typeconversions }
                    (
                     (hp.nodetype=typeconvn) and
                     (ttypeconvnode(hp).convtype=tc_equal)
                    )
                   ) do
               begin
                 { Use the recordfield for loopvarsym }
                 if not assigned(loopvarsym) and
                    (hp.nodetype=subscriptn) then
                   loopvarsym:=tsubscriptnode(hp).vs;
                 hp:=tunarynode(hp).left;
               end;

             if assigned(hp) and
                (hp.nodetype=loadn) then
               begin
                 case tloadnode(hp).symtableentry.typ of
                   staticvarsym,
                   localvarsym,
                   paravarsym :
                     begin
                       { we need a simple loadn:
                           1. The load must be in a global symtable or
                               in the same level as the para of the current proc.
                           2. value variables (no const,out or var)
                           3. No threadvar, readonly or typedconst
                       }
                       if (
                           (tloadnode(hp).symtable.symtablelevel=main_program_level) or
                           (tloadnode(hp).symtable.symtablelevel=current_procinfo.procdef.parast.symtablelevel)
                          ) and
                          (tabstractvarsym(tloadnode(hp).symtableentry).varspez=vs_value) and
                          ([vo_is_thread_var,vo_is_typed_const] * tabstractvarsym(tloadnode(hp).symtableentry).varoptions=[]) then
                         begin
                           { Assigning for-loop variable is only allowed in tp7 and macpas }
                           if ([m_tp7,m_mac] * current_settings.modeswitches = []) then
                             begin
                               if not assigned(loopvarsym) then
                                 loopvarsym:=tabstractvarsym(tloadnode(hp).symtableentry);
                               include(loopvarsym.varoptions,vo_is_loop_counter);
                             end;
                         end
                       else
                         begin
                           { Typed const is allowed in tp7 }
                           if not(m_tp7 in current_settings.modeswitches) or
                              not(vo_is_typed_const in tabstractvarsym(tloadnode(hp).symtableentry).varoptions) then
                             MessagePos(hp.fileinfo,type_e_illegal_count_var);
                         end;
                     end;
                   else
                     MessagePos(hp.fileinfo,type_e_illegal_count_var);
                 end;
               end
             else
               MessagePos(hloopvar.fileinfo,type_e_illegal_count_var);

             hfrom:=comp_expr([ef_accept_equal]);

             if try_to_consume(_DOWNTO) then
               backward:=true
             else
               begin
                 consume(_TO);
                 backward:=false;
               end;

             hto:=comp_expr([ef_accept_equal]);
             { context-sensitive `step`: only after the to/downto expression
               and before `do`. Anywhere else `step` stays an ordinary
               identifier - `comp_expr` would have consumed it as part of hto }
             if (m_for_step in current_settings.modeswitches) and (current_scanner.token=_ID) and (current_scanner.pattern='STEP') then
               begin
                 consume(_ID);
                 hstep:=comp_expr([ef_accept_equal]);
                 typecheckpass(hstep);
                 if not is_ordinal(hstep.resultdef) then
                   begin
                     Message(parser_e_for_step_not_ordinal);
                     hstep.free;
                     hstep:=nil;
                   end
                 else if (hstep.nodetype=ordconstn) and (tordconstnode(hstep).value<=0) then
                   Message(parser_e_for_step_must_be_positive);
               end;
             consume(_DO);

             { Check if the constants fit in the range }
             check_range(hfrom,hloopvar.resultdef);
             check_range(hto,hloopvar.resultdef);

             { first set the varstate for from and to, so
               uses of loopvar in those expressions will also
               trigger a warning when it is not used yet. This
               needs to be done before the instruction block is
               parsed to have a valid hloopvar }
             typecheckpass(hfrom);
             set_varstate(hfrom,vs_read,[vsf_must_be_valid]);
             typecheckpass(hto);
             set_varstate(hto,vs_read,[vsf_must_be_valid]);
             typecheckpass(hloopvar);
             { in two steps, because vs_readwritten may turn on vsf_must_be_valid }
             { for some subnodes                                                  }
             set_varstate(hloopvar,vs_written,[]);
             set_varstate(hloopvar,vs_read,[vsf_must_be_valid]);

             { ... now the instruction block }
             hblock:=control_body_statement;

             { variable is not used for loop counter anymore }
             if assigned(loopvarsym) then
               exclude(loopvarsym.varoptions,vo_is_loop_counter);

             result:=cfornode.create(hloopvar,hfrom,hto,hblock,backward);
             tfornode(result).loopstep:=hstep;

             { only in tp and mac pascal mode, we care about the value of the loop counter on loop exit

               I am not sure though, if this is the right rule, at least in delphi the loop counter is undefined
               on loop exit, we assume the same in all FPC modes.

               Mode unleashed keeps the counter across the exit too, so this
               flag (which lets the optimizer overshoot the final value) must
               not be set. }
             if (([m_objfpc,m_fpc,m_delphi]*current_settings.modeswitches)<>[]) and
                not(m_unleashed in current_settings.modeswitches) then
               Include(tfornode(Result).loopflags,lnf_dont_mind_loopvar_on_exit);
          end;


          function for_in_loop_create(hloopvar: tnode): tnode;
            var
              expr,hloopbody,hp: tnode;
              loopvarsym: tabstractvarsym;
            begin
              hp:=skip_nodes_before_load(hloopvar);
              if assigned(hp)and(hp.nodetype=loadn) then
                begin
                  loopvarsym:=tabstractvarsym(tloadnode(hp).symtableentry);
                  include(loopvarsym.varoptions,vo_is_loop_counter);
                end
              else
                loopvarsym:=nil;

              expr:=comp_expr([ef_accept_equal]);
              do_typecheckpass(expr);
              if assigned(expr.resultdef) and is_flexible_array(expr.resultdef) then
                begin
                  MessagePos(expr.fileinfo,parser_e_fam_no_for_in);
                  expr.free;
                  hloopvar.free;
                  if assigned(loopvarsym) then
                    exclude(loopvarsym.varoptions,vo_is_loop_counter);
                  result:=cerrornode.create;
                  exit;
                end;

              if (m_for_step in current_settings.modeswitches) and (current_scanner.token=_ID) and (current_scanner.pattern='STEP') then
                Message(parser_e_step_not_allowed_in_for_in);
              consume(_DO);

              set_varstate(hloopvar,vs_written,[]);
              set_varstate(hloopvar,vs_read,[vsf_must_be_valid]);

              hloopbody:=control_body_statement;
              if assigned(loopvarsym) then
                exclude(loopvarsym.varoptions,vo_is_loop_counter);
              result:=create_for_in_loop(hloopvar,hloopbody,expr);

              expr.free;
              expr := nil;
            end;


          { Determine the element type of a for-in collection expression.
            Returns nil if the type cannot be determined. }
          function get_for_in_element_type(expr: tnode): tdef;
            var
              pd: tprocdef;
              helperdef: tobjectdef;
              current: tpropertysym;
              hp: tarrayconstructornode;
            begin
              result := nil;
              if not assigned(expr.resultdef) then
                exit;

              if expr.nodetype = typen then
                begin
                  { for var x in TEnumType }
                  if expr.resultdef.typ = enumdef then
                    result := expr.resultdef
                  else if expr.resultdef.typ = setdef then
                    result := tsetdef(expr.resultdef).elementdef;
                  exit;
                end;

              case expr.resultdef.typ of
                arraydef:
                  begin
                    result := tarraydef(expr.resultdef).elementdef;
                    { string literals carry a conststring array def sized
                      to the first element which would truncate longer
                      elements, widen to AnsiString like var x := [...] }
                    if is_conststring_array(result) then
                      result := getansistringdef;
                    { untyped [a, b, c] literal: the constructor's elementdef
                      comes from the first element only - widen over all
                      elements so [4, 1994, 3888] infers a type holding
                      every value instead of truncating to the first one's }
                    if (expr.nodetype = arrayconstructorn) and is_integer(result) then
                      begin
                        hp := tarrayconstructornode(expr);
                        while assigned(hp) do
                          begin
                            if assigned(hp.left) and
                               (hp.left.nodetype <> arrayconstructorrangen) and
                               assigned(hp.left.resultdef) and
                               is_integer(hp.left.resultdef) then
                              result := get_common_intdef(torddef(result), torddef(hp.left.resultdef), true);
                            hp := tarrayconstructornode(hp.right);
                          end;
                        { promote sub-32-bit results like var x := expr does }
                        if torddef(result).ordtype in [s8bit,u8bit,s16bit,u16bit] then
                          result := s32inttype;
                      end;
                  end;
                stringdef:
                  begin
                    if is_wide_or_unicode_string(expr.resultdef) or
                       is_widechararray(expr.resultdef) then
                      result := cwidechartype
                    else
                      result := cansichartype;
                  end;
                setdef:
                  result := tsetdef(expr.resultdef).elementdef;
                else
                  begin
                    { Try enumerator operator }
                    pd := search_enumerator_operator(expr.resultdef, generrordef);
                    { Try class/object enumerator method }
                    if (pd = nil) and (expr.resultdef.typ in [objectdef, recorddef]) then
                      begin
                        if search_last_objectpascal_helper(tabstractrecorddef(expr.resultdef), nil, helperdef) then
                          repeat
                            pd := helperdef.search_enumerator_get;
                            helperdef := helperdef.childof;
                          until (pd <> nil) or (helperdef = nil);
                        if pd = nil then
                          pd := tabstractrecorddef(expr.resultdef).search_enumerator_get;
                      end;
                    if pd <> nil then
                      begin
                        current := tpropertysym(tabstractrecorddef(pd.returndef).search_enumerator_current);
                        if assigned(current) then
                          result := current.propdef;
                      end;
                  end;
              end;
            end;


          { For-in with inline var and type inference:
            the 'in' has already been consumed. Parses collection, infers
            element type, sets it on the variable, then creates the loop. }
          function for_in_loop_create_inline(loopvs: tabstractnormalvarsym; hloopvar: tnode): tnode;
            var
              expr, hloopbody: tnode;
              elemdef: tdef;
            begin
              include(loopvs.varoptions, vo_is_loop_counter);

              expr := comp_expr([ef_accept_equal]);
              do_typecheckpass(expr);

              if assigned(expr.resultdef) and is_flexible_array(expr.resultdef) then
                begin
                  MessagePos(expr.fileinfo, parser_e_fam_no_for_in);
                  expr.free;
                  hloopvar.free;
                  exclude(loopvs.varoptions, vo_is_loop_counter);
                  result := cerrornode.create;
                  exit;
                end;

              { Infer element type from collection }
              elemdef := get_for_in_element_type(expr);
              if assigned(elemdef) and (elemdef <> generrordef) then
                begin
                  loopvs.vardef := elemdef;
                  if loopvs.typ = staticvarsym then
                    cnodeutils.insertbssdata(tstaticvarsym(loopvs));
                  { Re-typecheck the loopvar with the inferred type }
                  do_typecheckpass(hloopvar);
                end
              else
                begin
                  MessagePos1(expr.fileinfo, sym_e_no_enumerator, expr.resultdef.typename);
                  expr.free;
                  hloopvar.free;
                  result := cerrornode.create;
                  exit;
                end;

              if (m_for_step in current_settings.modeswitches) and (current_scanner.token=_ID) and (current_scanner.pattern='STEP') then
                Message(parser_e_step_not_allowed_in_for_in);
              consume(_DO);

              set_varstate(hloopvar, vs_written, []);
              set_varstate(hloopvar, vs_read, [vsf_must_be_valid]);

              hloopbody := control_body_statement;
              exclude(loopvs.varoptions, vo_is_loop_counter);
              result := create_for_in_loop(hloopvar, hloopbody, expr);

              expr.free;
            end;


          { Like for_loop_create but for inline var with type inference:
            the ':=' has already been consumed, so we parse 'from' here,
            infer the type, set it on the variable, then parse the rest. }
          function for_loop_create_inferred(loopvs: tabstractnormalvarsym; hloopvar: tnode): tnode;
            var
               hblock,
               hto,hfrom,hstep : tnode;
               backward : boolean;
            begin
               hstep:=nil;
               hfrom:=comp_expr([ef_accept_equal]);
               typecheckpass(hfrom);

               { Infer the loop variable type from the 'from' expression. }
               if assigned(hfrom.resultdef) and (hfrom.resultdef <> generrordef) then
                 begin
                   { Promote sub-32-bit integers to LongInt, same as
                     inline_var_statement does for var i := expr. }
                   if not(nf_explicit in hfrom.flags) and is_integer(hfrom.resultdef) and
                      (torddef(hfrom.resultdef).ordtype in [s8bit,u8bit,s16bit,u16bit]) then
                     loopvs.vardef := s32inttype
                   else
                     loopvs.vardef := unleashed_infer_natural_intdef(hfrom, hfrom.resultdef);
                   if loopvs.typ = staticvarsym then
                     cnodeutils.insertbssdata(tstaticvarsym(loopvs));
                 end
               else
                 begin
                   Message(parser_e_syntax_error);
                   hfrom.free;
                   hloopvar.free;
                   result := cerrornode.create;
                   exit;
                 end;

               { Now typecheck the loopvar with the inferred type. }
               typecheckpass(hloopvar);

               { variable must be an ordinal }
               if (
                   not(is_ordinal(hloopvar.resultdef))
    {$if not defined(cpu64bitaddr) and not defined(cpu64bitalu)}
                   or (is_64bitint(hloopvar.resultdef) and
                       not(m_unleashed in current_settings.modeswitches))
    {$endif not cpu64bitaddr and not cpu64bitalu}
                 ) and
                 (hloopvar.resultdef.typ<>undefineddef)
                 then
                 begin
                   MessagePos(hloopvar.fileinfo,type_e_ordinal_expr_expected);
                   hloopvar.resultdef:=generrordef;
                 end;

               include(loopvs.varoptions,vo_is_loop_counter);

               if try_to_consume(_DOWNTO) then
                 backward:=true
               else
                 begin
                   consume(_TO);
                   backward:=false;
                 end;

               hto:=comp_expr([ef_accept_equal]);
               if (m_for_step in current_settings.modeswitches) and (current_scanner.token=_ID) and (current_scanner.pattern='STEP') then
                 begin
                   consume(_ID);
                   hstep:=comp_expr([ef_accept_equal]);
                   typecheckpass(hstep);
                   if not is_ordinal(hstep.resultdef) then
                     begin
                       Message(parser_e_for_step_not_ordinal);
                       hstep.free;
                       hstep:=nil;
                     end
                   else if (hstep.nodetype=ordconstn) and (tordconstnode(hstep).value<=0) then
                     Message(parser_e_for_step_must_be_positive);
                 end;
               consume(_DO);

               check_range(hfrom,hloopvar.resultdef);
               check_range(hto,hloopvar.resultdef);

               set_varstate(hfrom,vs_read,[vsf_must_be_valid]);
               typecheckpass(hto);
               set_varstate(hto,vs_read,[vsf_must_be_valid]);
               set_varstate(hloopvar,vs_written,[]);
               set_varstate(hloopvar,vs_read,[vsf_must_be_valid]);

               hblock:=control_body_statement;

               exclude(loopvs.varoptions,vo_is_loop_counter);

               result:=cfornode.create(hloopvar,hfrom,hto,hblock,backward);
               tfornode(result).loopstep:=hstep;
               if (([m_objfpc,m_fpc,m_delphi]*current_settings.modeswitches)<>[]) and
                  not(m_unleashed in current_settings.modeswitches) then
                 Include(tfornode(Result).loopflags,lnf_dont_mind_loopvar_on_exit);
            end;


          { for var (x, y, ...) in collection do body - destructure each
            tuple element into fresh locals and prepend field assignments
            to the body. Entered after 'for var' was consumed; the current
            token is '('. }
          function for_in_destructure_loop : tnode;
            var
              tnames : array of string;
              tcount : longint;
              itempvs : tabstractnormalvarsym;
              uservs : tabstractnormalvarsym;
              hdef : tdef;
              elemdef : tdef;
              collexpr, hbody, wrappedbody : tnode;
              recdef : trecorddef;
              fieldsyms : array of tfieldvarsym;
              fieldcount : longint;
              sym : tsym;
              st_unused : tsymtable;
              i : longint;
              wrapblk : tblocknode;
              wraplast : tstatementnode;
              uniq : string;
              orig_hloopvar : tnode;
              forblockst : tblocksymtable;
            begin
              result := nil;
              consume(_LKLAMMER);
              tcount := 0;
              setlength(tnames, 4);
              repeat
                if current_scanner.token <> _ID then
                  begin
                    Message(parser_e_syntax_error);
                    exit(cerrornode.create);
                  end;
                if tcount >= length(tnames) then
                  setlength(tnames, length(tnames)*2);
                tnames[tcount] := current_scanner.orgpattern;
                inc(tcount);
                consume(_ID);
              until not try_to_consume(_COMMA);
              consume(_RKLAMMER);
              consume(_IN);

              collexpr := comp_expr([ef_accept_equal]);
              do_typecheckpass(collexpr);
              elemdef := get_for_in_element_type(collexpr);
              if not assigned(elemdef) or (elemdef = generrordef) or
                 (elemdef.typ <> recorddef) then
                begin
                  Message(parser_e_illegal_expression);
                  collexpr.free;
                  exit(cerrornode.create);
                end;
              recdef := trecorddef(elemdef);

              { collect field syms }
              fieldcount := 0;
              setlength(fieldsyms, recdef.symtable.symlist.count);
              for i := 0 to recdef.symtable.symlist.count-1 do
                begin
                  sym := tsym(recdef.symtable.symlist[i]);
                  if sym.typ = fieldvarsym then
                    begin
                      fieldsyms[fieldcount] := tfieldvarsym(sym);
                      inc(fieldcount);
                    end;
                end;
              setlength(fieldsyms, fieldcount);
              if tcount <> fieldcount then
                begin
                  Message(parser_e_illegal_expression);
                  collexpr.free;
                  exit(cerrornode.create);
                end;

              if (m_for_step in current_settings.modeswitches) and (current_scanner.token=_ID) and (current_scanner.pattern='STEP') then
                Message(parser_e_step_not_allowed_in_for_in);
              consume(_DO);

              { block scope for destructured variables }
              forblockst:=nil;
              if assigned(current_procinfo) then
                begin
                  forblockst:=tblocksymtable.create(symtablestack.top);
                  symtablestack.push(forblockst);
                end;

              { hidden loop variable holds each collection element }
              str(current_tokenpos.line, uniq);
              itempvs := create_inline_var_sym('$forTup'+uniq, elemdef);
              itempvs.register_sym;
              symtablestack.top.insertsym(itempvs);
              if itempvs.typ = staticvarsym then
                cnodeutils.insertbssdata(tstaticvarsym(itempvs));
              include(itempvs.varoptions, vo_is_loop_counter);
              hdef := elemdef;

              { user variables (skip _ wildcards) }
              for i := 0 to tcount-1 do
                begin
                  if tnames[i]='_' then
                    continue;
                  uservs := create_inline_var_sym(tnames[i], fieldsyms[i].vardef);
                  uservs.register_sym;
                  symtablestack.top.insertsym(uservs);
                  if uservs.typ = staticvarsym then
                    cnodeutils.insertbssdata(tstaticvarsym(uservs));
                  uservs.varstate := vs_initialised;
                end;

              orig_hloopvar := cloadnode.create(itempvs, itempvs.owner);
              typecheckpass(orig_hloopvar);
              set_varstate(orig_hloopvar, vs_written, []);
              set_varstate(orig_hloopvar, vs_read, [vsf_must_be_valid]);

              hbody := control_body_statement;
              exclude(itempvs.varoptions, vo_is_loop_counter);

              // wrap body: prepend field assignments, then original body
              wrapblk := internalstatements(wraplast);
              for i := 0 to tcount-1 do
                begin
                  if (tnames[i]='_') or
                     not searchsym(upper(tnames[i]), sym, st_unused) then
                    continue;
                  addstatement(wraplast,
                    cassignmentnode.create(
                      cloadnode.create(sym, sym.owner),
                      csubscriptnode.create(fieldsyms[i],
                        cloadnode.create(itempvs, itempvs.owner))));
                end;
              if assigned(hbody) then
                addstatement(wraplast, hbody);
              wrappedbody := wrapblk;

              result := create_for_in_loop(orig_hloopvar, wrappedbody, collexpr);
              collexpr.free;

              { pop block scope and wrap in blocknode }
              if assigned(forblockst) then
                begin
                  symtablestack.pop(forblockst);
                  if not assigned(current_procinfo.procdef.blocklocalsymtables) then
                    current_procinfo.procdef.blocklocalsymtables:=tfpobjectlist.create(true);
                  current_procinfo.procdef.blocklocalsymtables.add(forblockst);
                  wrappedbody:=cblocknode.create(cstatementnode.create(result,nil));
                  wrappedbody.fileinfo:=result.fileinfo;
                  tblocknode(wrappedbody).blocksymtable:=forblockst;
                  result:=wrappedbody;
                end;
            end;


          { Parse `for parallel [(N)] var i [: T] := lo to|downto hi [step s] do
            body`. `parallel` has already been consumed; the current token is
            `(` or `var`. for-in, a missing inline var, and break/exit/goto in
            the body are rejected. }
          function parallel_for_statement : tnode;
            var
              threadcount,hfrom,hto,hstep,hchunk,hbody,iloadnode,
              iexpr,workerloop,innerloop,parblock,wpval : tnode;
              backward : boolean;
              oldbt : tblock_type;
              loopdef,dispdef : tdef;
              incname : string;
              iname : string;
              workerpd,thunkpd : tprocdef;
              workerps,thunkps : tprocsym;
              workerpi : tprocinfo;
              thunkpvs : tparavarsym;
              wst : tsymtable;
              oldsymstack : tsymtablestack;
              isym,idxsym,basesym,lastsym,widsym,wcntsym,parlo,parstep,parcount,parcounter,parwp,
              parnthreads,parkvar,partids,parexc,parexctaken,parcancel,parchunk,parslot : tabstractnormalvarsym;
              tidtype,tidarrtype : tdef;
              excstat : tstatementnode;
              workerbody : tnode;
              old_procinfo : tprocinfo;
              dispstat,innerstat,setupstat,parstat : tstatementnode;
            begin
              result:=nil;
              threadcount:=nil;
              hstep:=nil;
              hchunk:=nil;
              loopdef:=nil;

              { optional (N) thread count - applied by the dispatch below }
              if try_to_consume(_LKLAMMER) then
                begin
                  threadcount:=comp_expr([ef_accept_equal]);
                  consume(_RKLAMMER);
                end;

              { an inline loop variable is mandatory - a shared outer counter
                would be meaningless across threads }
              if current_scanner.token<>_VAR then
                begin
                  Message(parser_e_parallel_for_requires_var);
                  threadcount.free;
                  result:=cerrornode.create;
                  exit;
                end;
              consume(_VAR);

              if current_scanner.token<>_ID then
                begin
                  consume(_ID);
                  threadcount.free;
                  result:=cerrornode.create;
                  exit;
                end;
              iname:=current_scanner.orgpattern;
              consume(_ID);

              { explicit loop variable type, or inferred from the start value }
              if try_to_consume(_COLON) then
                begin
                  oldbt:=block_type;
                  block_type:=bt_var_type;
                  read_anon_type(loopdef,false,nil);
                  block_type:=oldbt;
                end;

              { for-in is inherently sequential and not allowed. `in` lexes to
                the operator token, so test idtoken like consume does }
              if current_scanner.idtoken=_IN then
                begin
                  Message(parser_e_parallel_for_no_for_in);
                  consume(_IN);
                  hfrom:=comp_expr([ef_accept_equal]);
                  hfrom.free;
                  if try_to_consume(_DO) then
                    begin
                      hbody:=control_body_statement;
                      hbody.free;
                    end;
                  threadcount.free;
                  result:=cerrornode.create;
                  exit;
                end;

              consume(_ASSIGNMENT);
              hfrom:=comp_expr([ef_accept_equal]);
              typecheckpass(hfrom);

              if not assigned(loopdef) then
                begin
                  if assigned(hfrom.resultdef) and (hfrom.resultdef<>generrordef) then
                    begin
                      if not(nf_explicit in hfrom.flags) and is_integer(hfrom.resultdef) and
                         (torddef(hfrom.resultdef).ordtype in [s8bit,u8bit,s16bit,u16bit]) then
                        loopdef:=s32inttype
                      else
                        loopdef:=unleashed_infer_natural_intdef(hfrom,hfrom.resultdef);
                    end
                  else
                    loopdef:=generrordef;
                end;

              if (not is_ordinal(loopdef)) and (loopdef.typ<>undefineddef) then
                begin
                  MessagePos(hfrom.fileinfo,type_e_ordinal_expr_expected);
                  loopdef:=generrordef;
                end;

              { the hidden dispatch state follows the loop variable width: a
                64-bit variable gets a 64-bit counter so huge ranges do not
                wrap, everything smaller stays on the 32-bit interlocked ops }
{$ifdef cpu64bitalu}
              if loopdef.size>4 then
                begin
                  dispdef:=s64inttype;
                  incname:='INTERLOCKEDEXCHANGEADD64';
                end
              else
{$else}
              if loopdef.size>4 then
                Message(parser_e_parallel_for_no_int64_dispatch);
{$endif}
                begin
                  dispdef:=s32inttype;
                  incname:='INTERLOCKEDEXCHANGEADD';
                end;

              if try_to_consume(_DOWNTO) then
                backward:=true
              else
                begin
                  consume(_TO);
                  backward:=false;
                end;
              hto:=comp_expr([ef_accept_equal]);
              typecheckpass(hto);

              if (m_for_step in current_settings.modeswitches) and (current_scanner.token=_ID) and (current_scanner.pattern='STEP') then
                begin
                  consume(_ID);
                  hstep:=comp_expr([ef_accept_equal]);
                  typecheckpass(hstep);
                  if not is_ordinal(hstep.resultdef) then
                    begin
                      Message(parser_e_for_step_not_ordinal);
                      hstep.free;
                      hstep:=nil;
                    end
                  else if (hstep.nodetype=ordconstn) and (tordconstnode(hstep).value<=0) then
                    Message(parser_e_for_step_must_be_positive);
                end;
              { optional `chunk N` - iterations claimed per counter grab; the
                same soft-keyword spot as `step` }
              if (current_scanner.token=_ID) and (current_scanner.pattern='CHUNK') then
                begin
                  consume(_ID);
                  hchunk:=comp_expr([ef_accept_equal]);
                  typecheckpass(hchunk);
                  if not is_ordinal(hchunk.resultdef) then
                    begin
                      Message(parser_e_parallel_chunk_not_ordinal);
                      hchunk.free;
                      hchunk:=nil;
                    end
                  else if (hchunk.nodetype=ordconstn) and (tordconstnode(hchunk).value<=0) then
                    Message(parser_e_parallel_chunk_must_be_positive);
                end;
              consume(_DO);

              check_range(hfrom,loopdef);
              check_range(hto,loopdef);
              set_varstate(hfrom,vs_read,[vsf_must_be_valid]);
              set_varstate(hto,vs_read,[vsf_must_be_valid]);

              { hoist the body into a nested worker. The loop variable and the
                dispatch index are private to each worker thread. }
              old_procinfo:=current_procinfo;
              { Build the worker like create_for_outlining: a classic nested
                proc. The constructor sets the Delphi nested cc under
                m_nested_procvars; dropping it keeps the worker procvar a
                code+frame pair, which is what the thunk reinterprets a pointer
                to wp as. With the Delphi cc the procvar would be address-only
                (frame passed as a hidden param) and the caller frame would be
                lost crossing into the worker thread. }
              wst:=old_procinfo.procdef.localst;
              oldsymstack:=symtablestack;
              symtablestack:=nil;
              workerpd:=cprocdef.create(max(normal_function_level,wst.symtablelevel)+1,true);
              workerpd.returndef:=voidtype;
              symtablestack:=oldsymstack;
              wst.insertdef(workerpd);
              workerpd.struct:=old_procinfo.procdef.struct;
              exclude(workerpd.procoptions,po_delphi_nested_cc);
              workerpd.proctypeoption:=potype_procedure;
              workerpd.proccalloption:=pocall_default;
              include(workerpd.procoptions,po_hascallingconvention);
              handle_calling_convention(workerpd,hcc_default_actions_impl);
              workerps:=cprocsym.create('$parfor$'+workerpd.unique_id_str);
              wst.insertsym(workerps);
              workerpd.procsym:=workerps;
              proc_add_definition(workerpd);
              workerpd.forwarddef:=false;
              workerpd.aliasnames.insert(workerpd.mangledname);
              workerpi:=cprocinfo.create(old_procinfo);
              workerpi.force_nested;
              workerpi.procdef:=workerpd;
              workerpi.entrypos:=hfrom.fileinfo;
              workerpi.entryswitches:=current_settings.localswitches;
              workerpi.exitpos:=current_tokenpos;
              workerpi.exitswitches:=current_settings.localswitches;

              { shared state, kept on the caller frame and read by the workers
                through their implicit $parentfp (or directly, when the caller is
                the main/unit body). The worker id keeps the names unique when a
                routine has several parallel loops. }
              parlo:=parfor_make_local(old_procinfo.procdef,'$parlo'+workerpd.unique_id_str,dispdef);
              parstep:=parfor_make_local(old_procinfo.procdef,'$parstep'+workerpd.unique_id_str,dispdef);
              parcount:=parfor_make_local(old_procinfo.procdef,'$parcnt'+workerpd.unique_id_str,dispdef);
              parcounter:=parfor_make_local(old_procinfo.procdef,'$parctr'+workerpd.unique_id_str,dispdef);
              { the first worker to fault stores its exception here (claimed via
                an atomic flag); the caller re-raises it after the barrier }
              parexc:=parfor_make_local(old_procinfo.procdef,'$parexc'+workerpd.unique_id_str,class_tobject);
              parexctaken:=parfor_make_local(old_procinfo.procdef,'$parexct'+workerpd.unique_id_str,s32inttype);
              { the cancel flag is written by whichever worker breaks and read
                by all the others - volatile keeps every check a memory read }
              parcancel:=parfor_make_local(old_procinfo.procdef,'$parcncl'+workerpd.unique_id_str,s32inttype);
              include(parcancel.varoptions,vo_volatile);
              parchunk:=parfor_make_local(old_procinfo.procdef,'$parchk'+workerpd.unique_id_str,dispdef);
              parslot:=parfor_make_local(old_procinfo.procdef,'$parslot'+workerpd.unique_id_str,s32inttype);
              parnthreads:=parfor_make_local(old_procinfo.procdef,'$parnth'+workerpd.unique_id_str,s32inttype);

              { parse the body in the worker context }
              current_procinfo:=workerpi;
              current_module.procinfo:=workerpi;
              oldbt:=block_type;
              block_type:=bt_body;
              symtablestack.push(workerpd.parast);
              symtablestack.push(workerpd.localst);

              isym:=parfor_make_local(workerpd,iname,loopdef);
              idxsym:=parfor_make_local(workerpd,'$idx',dispdef);
              basesym:=parfor_make_local(workerpd,'$base',dispdef);
              lastsym:=parfor_make_local(workerpd,'$last',dispdef);
              { visible in the body: which worker this is (0..WorkerCount-1,
                claimed from an atomic slot at worker entry) and the pool size }
              widsym:=parfor_make_local(workerpd,'WorkerIndex',s32inttype);
              wcntsym:=parfor_make_local(workerpd,'WorkerCount',s32inttype);
              widsym.varstate:=vs_initialised;
              wcntsym.varstate:=vs_initialised;
              { read-only in the body; only the worker entry writes them }
              widsym.varspez:=vs_const;
              wcntsym.varspez:=vs_const;
              { the dispatch assigns the loop variable before every body run }
              isym.varstate:=vs_initialised;
              include(isym.varoptions,vo_is_loop_counter);
              iloadnode:=cloadnode.create(isym,isym.owner);
              typecheckpass(iloadnode);

              hbody:=control_body_statement;
              exclude(isym.varoptions,vo_is_loop_counter);
              parfor_validate_body(hbody,parcancel);

              { worker dispatch loop - each counter grab claims a chunk of
                iterations, walked without further atomics:
                  repeat
                    if cancelled <> 0 then break;
                    base := InterlockedExchangeAdd(counter, chunk);
                    if base >= count then break;
                    last := base + chunk;
                    if last > count then last := count;
                    for idx := base to last-1 do begin
                      if cancelled <> 0 then break;
                      i := lo +/- idx*step;
                      <body>
                    end;
                  until false
                the chunk walk is a real for-loop so a `continue` in the body
                advances the index like in any for }
              { the ordinal math runs on the dispatch type; the result converts
                back to the declared variable type (which may be an enum/char) }
              if backward then
                iexpr:=caddnode.create(subn,cloadnode.create(parlo,parlo.owner),
                         caddnode.create(muln,cloadnode.create(idxsym,idxsym.owner),cloadnode.create(parstep,parstep.owner)))
              else
                iexpr:=caddnode.create(addn,cloadnode.create(parlo,parlo.owner),
                         caddnode.create(muln,cloadnode.create(idxsym,idxsym.owner),cloadnode.create(parstep,parstep.owner)));
              iexpr:=ctypeconvnode.create_internal(iexpr,loopdef);
              innerloop:=internalstatements(innerstat);
              addstatement(innerstat,cifnode.create(
                caddnode.create(unequaln,cloadnode.create(parcancel,parcancel.owner),cordconstnode.create(0,s32inttype,false)),
                cbreaknode.create,nil));
              addstatement(innerstat,cassignmentnode.create(cloadnode.create(isym,isym.owner),iexpr));
              if assigned(hbody) then
                addstatement(innerstat,hbody);
              innerloop:=cfornode.create(cloadnode.create(idxsym,idxsym.owner),
                cloadnode.create(basesym,basesym.owner),
                caddnode.create(subn,cloadnode.create(lastsym,lastsym.owner),cordconstnode.create(1,s32inttype,false)),
                innerloop,false);
              workerloop:=internalstatements(dispstat);
              addstatement(dispstat,cifnode.create(
                caddnode.create(unequaln,cloadnode.create(parcancel,parcancel.owner),cordconstnode.create(0,s32inttype,false)),
                cbreaknode.create,nil));
              addstatement(dispstat,cassignmentnode.create(cloadnode.create(basesym,basesym.owner),
                ccallnode.createintern(incname,
                  ccallparanode.create(cloadnode.create(parchunk,parchunk.owner),
                    ccallparanode.create(cloadnode.create(parcounter,parcounter.owner),nil)))));
              addstatement(dispstat,cifnode.create(
                caddnode.create(gten,cloadnode.create(basesym,basesym.owner),cloadnode.create(parcount,parcount.owner)),
                cbreaknode.create,nil));
              addstatement(dispstat,cassignmentnode.create(cloadnode.create(lastsym,lastsym.owner),
                caddnode.create(addn,cloadnode.create(basesym,basesym.owner),cloadnode.create(parchunk,parchunk.owner))));
              addstatement(dispstat,cifnode.create(
                caddnode.create(gtn,cloadnode.create(lastsym,lastsym.owner),cloadnode.create(parcount,parcount.owner)),
                cassignmentnode.create(cloadnode.create(lastsym,lastsym.owner),cloadnode.create(parcount,parcount.owner)),nil));
              addstatement(dispstat,innerloop);
              workerloop:=cwhilerepeatnode.create(cordconstnode.create(0,pasbool1type,false),workerloop,false,true);
              { worker entry: claim a worker slot, publish the pool size }
              iexpr:=workerloop;
              workerloop:=internalstatements(setupstat);
              addstatement(setupstat,cassignmentnode.create(parfor_load_ignoreconst(widsym),
                caddnode.create(subn,
                  ccallnode.createintern('INTERLOCKEDINCREMENT',
                    ccallparanode.create(cloadnode.create(parslot,parslot.owner),nil)),
                  cordconstnode.create(1,s32inttype,false))));
              addstatement(setupstat,cassignmentnode.create(parfor_load_ignoreconst(wcntsym),
                cloadnode.create(parnthreads,parnthreads.owner)));
              addstatement(setupstat,iexpr);
              { wrap the dispatch in try/except: the first worker to fault claims
                the exception with an atomic flag and hands it to the caller, the
                rest drop theirs.
                  try <loop>
                  except
                    if InterlockedCompareExchange(exctaken, 1, 0) = 0 then
                      exc := AcquireExceptionObject
                  end }
              workerbody:=internalstatements(excstat);
              addstatement(excstat,cifnode.create(
                caddnode.create(equaln,
                  ccallnode.createintern('INTERLOCKEDCOMPAREEXCHANGE',
                    ccallparanode.create(cordconstnode.create(0,s32inttype,false),
                      ccallparanode.create(cordconstnode.create(1,s32inttype,false),
                        ccallparanode.create(cloadnode.create(parexctaken,parexctaken.owner),nil)))),
                  cordconstnode.create(0,s32inttype,false)),
                cassignmentnode.create(cloadnode.create(parexc,parexc.owner),
                  ctypeconvnode.create_internal(ccallnode.createintern('ACQUIREEXCEPTIONOBJECT',nil),class_tobject)),
                nil));
              workerbody:=ctryexceptnode.create(workerloop,nil,workerbody);
              do_typecheckpass(workerbody);
              workerpi.set_code(workerbody);

              symtablestack.pop(workerpd.localst);
              symtablestack.pop(workerpd.parast);
              block_type:=oldbt;
              current_procinfo:=old_procinfo;
              current_module.procinfo:=old_procinfo;

              { Per-module generic thread-entry thunk, declared forward here and
                implemented + generated at module finish (where current_procinfo
                is nil). Building its body and procinfo mid-parse crashes, but a
                bare forward declaration is fine. }
              if not assigned(current_module.parfor_thunk_pd) then
                begin
                  { thread creation on unix-like targets needs the cthreads
                    driver; remind once per module }
                  if target_info.system in systems_linux+systems_bsd+systems_darwin+
                                           systems_solaris+systems_aix+systems_android then
                    Message(parser_h_parallel_for_needs_cthreads);
                  oldsymstack:=symtablestack;
                  symtablestack:=nil;
                  thunkpd:=cprocdef.create(normal_function_level,true);
                  thunkpd.returndef:=ptrsinttype;
                  symtablestack:=oldsymstack;
                  current_module.localsymtable.insertdef(thunkpd);
                  include(thunkpd.procoptions,po_global);
                  exclude(thunkpd.procoptions,po_delphi_nested_cc);
                  thunkpd.proctypeoption:=potype_function;
                  thunkpd.proccalloption:=pocall_default;
                  include(thunkpd.procoptions,po_hascallingconvention);
                  thunkpvs:=cparavarsym.create('p',10,vs_value,voidpointertype,[]);
                  thunkpd.parast.insertsym(thunkpvs);
                  handle_calling_convention(thunkpd,hcc_default_actions_impl);
                  thunkps:=cprocsym.create('$parthreadentry'+thunkpd.unique_id_str);
                  current_module.localsymtable.insertsym(thunkps);
                  { only ever address-taken, so the unused-symbol pass must skip it }
                  include(thunkps.symoptions,sp_internal);
                  thunkpd.procsym:=thunkps;
                  proc_add_definition(thunkpd);
                  thunkpd.forwarddef:=true;
                  current_module.parfor_thunk_pd:=thunkpd;
                end
              else
                thunkpd:=tprocdef(current_module.parfor_thunk_pd);
              thunkps:=tprocsym(thunkpd.procsym);

              { wp holds @worker as a code+frame pair. Force the pc_normal procaddr
                the thunk reinterprets it as (the default proc-to-procvar picks an
                address-only code pointer). It still stores a nil frame, because a
                procdef is address-only and the conversion only captures a frame
                for anonymous functions; the caller block below patches in the real
                caller frame so the worker threads can reach the caller locals. }
              if not assigned(current_module.parfor_nested_pvd) then
                current_module.parfor_nested_pvd:=cprocvardef.getreusableprocaddr(workerpd,pc_normal);
              wpval:=ctypeconvnode.create_proc_to_procvar(cloadnode.create_procvar(workerps,workerpd,workerps.owner));
              ttypeconvnode(wpval).totypedef:=tdef(current_module.parfor_nested_pvd);
              typecheckpass(wpval);
              parwp:=parfor_make_local(old_procinfo.procdef,'$parwp'+workerpd.unique_id_str,tdef(current_module.parfor_nested_pvd));
              tidtype:=search_named_unit_globaltype('SYSTEM','TTHREADID',true).typedef;
              { fixed handle array - the pool is capped at 256; the atomic counter
                still drains every iteration when there are more than that }
              tidarrtype:=carraydef.create(0,255,s32inttype);
              tarraydef(tidarrtype).elementdef:=tidtype;
              partids:=parfor_make_local(old_procinfo.procdef,'$partids'+workerpd.unique_id_str,tidarrtype);
              { only written element-wise in the spawn loop, which dfa cannot
                prove covers the reads - keep it out of the uninitialized checks }
              include(partids.varoptions,vo_is_internal);
              parkvar:=parfor_make_local(old_procinfo.procdef,'$park'+workerpd.unique_id_str,s32inttype);

              { caller side: set up the shared state, size the pool, spawn the
                helpers, run the worker on the calling thread too, then join:
                  lo := from; step := s; count := (to-from) div step + 1; counter := 0 }
              parblock:=internalstatements(parstat);
              addstatement(parstat,cassignmentnode.create(cloadnode.create(parlo,parlo.owner),
                ctypeconvnode.create_internal(hfrom,dispdef)));
              if assigned(hstep) then
                addstatement(parstat,cassignmentnode.create(cloadnode.create(parstep,parstep.owner),
                  ctypeconvnode.create_internal(hstep,dispdef)))
              else
                addstatement(parstat,cassignmentnode.create(cloadnode.create(parstep,parstep.owner),cordconstnode.create(1,s32inttype,false)));
              hto:=ctypeconvnode.create_internal(hto,dispdef);
              if backward then
                addstatement(parstat,cassignmentnode.create(cloadnode.create(parcount,parcount.owner),
                  caddnode.create(addn,cmoddivnode.create(divn,
                    caddnode.create(subn,cloadnode.create(parlo,parlo.owner),hto),
                    cloadnode.create(parstep,parstep.owner)),cordconstnode.create(1,s32inttype,false))))
              else
                addstatement(parstat,cassignmentnode.create(cloadnode.create(parcount,parcount.owner),
                  caddnode.create(addn,cmoddivnode.create(divn,
                    caddnode.create(subn,hto,cloadnode.create(parlo,parlo.owner)),
                    cloadnode.create(parstep,parstep.owner)),cordconstnode.create(1,s32inttype,false))));
              addstatement(parstat,cassignmentnode.create(cloadnode.create(parcounter,parcounter.owner),cordconstnode.create(0,s32inttype,false)));
              addstatement(parstat,cassignmentnode.create(cloadnode.create(parexctaken,parexctaken.owner),cordconstnode.create(0,s32inttype,false)));
              addstatement(parstat,cassignmentnode.create(cloadnode.create(parexc,parexc.owner),cnilnode.create));
              addstatement(parstat,cassignmentnode.create(cloadnode.create(parcancel,parcancel.owner),cordconstnode.create(0,s32inttype,false)));
              addstatement(parstat,cassignmentnode.create(cloadnode.create(parslot,parslot.owner),cordconstnode.create(0,s32inttype,false)));
              { wp := @worker, then store the real caller frame into its parentfp
                field (the conversion above left it nil): cast @wp to the nested
                proc pointer record and assign the parent frame. }
              addstatement(parstat,cassignmentnode.create(cloadnode.create(parwp,parwp.owner),wpval));
              addstatement(parstat,cassignmentnode.create(
                csubscriptnode.create(tfieldvarsym(search_struct_member(trecorddef(nestedprocpointertype),'parentfp')),
                  cderefnode.create(ctypeconvnode.create_internal(
                    caddrnode.create_internal(cloadnode.create(parwp,parwp.owner)),
                    cpointerdef.getreusable(nestedprocpointertype)))),
                ctypeconvnode.create_internal(
                  cloadparentfpnode.create(old_procinfo.procdef,lpf_forpara),
                  parentfpvoidpointertype)));
              { nthreads := N (if given) else CPUCount, clamped to [1, min(count,256)] }
              if assigned(threadcount) then
                addstatement(parstat,cassignmentnode.create(cloadnode.create(parnthreads,parnthreads.owner),threadcount))
              else
                addstatement(parstat,cassignmentnode.create(cloadnode.create(parnthreads,parnthreads.owner),
                  ccallnode.createintern('GETCPUCOUNT',nil)));
              addstatement(parstat,cifnode.create(
                caddnode.create(gtn,cloadnode.create(parnthreads,parnthreads.owner),cloadnode.create(parcount,parcount.owner)),
                cassignmentnode.create(cloadnode.create(parnthreads,parnthreads.owner),cloadnode.create(parcount,parcount.owner)),nil));
              addstatement(parstat,cifnode.create(
                caddnode.create(gtn,cloadnode.create(parnthreads,parnthreads.owner),cordconstnode.create(256,s32inttype,false)),
                cassignmentnode.create(cloadnode.create(parnthreads,parnthreads.owner),cordconstnode.create(256,s32inttype,false)),nil));
              addstatement(parstat,cifnode.create(
                caddnode.create(ltn,cloadnode.create(parnthreads,parnthreads.owner),cordconstnode.create(1,s32inttype,false)),
                cassignmentnode.create(cloadnode.create(parnthreads,parnthreads.owner),cordconstnode.create(1,s32inttype,false)),nil));
              { a parallel loop whose caller is itself a worker, and that did not
                ask for a pool size, runs its body on the calling thread alone.
                each loop spawns its own pool, so a default-sized inner loop would
                give CPUCount*CPUCount threads and oversubscribe the cores. an
                explicit (N) is taken as an opt-in to nested parallelism and kept. }
              if assigned(old_procinfo.procdef.procsym) and
                 (copy(old_procinfo.procdef.procsym.name,1,7)='parfor$') and
                 not assigned(threadcount) then
                addstatement(parstat,cassignmentnode.create(cloadnode.create(parnthreads,parnthreads.owner),cordconstnode.create(1,s32inttype,false)));
              { chunk := N (if given) else count div (nthreads*4), floored at 1.
                The auto default keeps about four grabs per worker: enough
                spare chunks that a slow one gets rebalanced, few enough that
                the counter is hit rarely }
              if assigned(hchunk) then
                addstatement(parstat,cassignmentnode.create(cloadnode.create(parchunk,parchunk.owner),
                  ctypeconvnode.create_internal(hchunk,dispdef)))
              else
                addstatement(parstat,cassignmentnode.create(cloadnode.create(parchunk,parchunk.owner),
                  cmoddivnode.create(divn,cloadnode.create(parcount,parcount.owner),
                    caddnode.create(muln,cloadnode.create(parnthreads,parnthreads.owner),cordconstnode.create(4,s32inttype,false)))));
              addstatement(parstat,cifnode.create(
                caddnode.create(ltn,cloadnode.create(parchunk,parchunk.owner),cordconstnode.create(1,s32inttype,false)),
                cassignmentnode.create(cloadnode.create(parchunk,parchunk.owner),cordconstnode.create(1,s32inttype,false)),nil));
              { for k := 0 to nthreads-2 do tids[k] := BeginThread(@thunk, @wp) }
              addstatement(parstat,cfornode.create(cloadnode.create(parkvar,parkvar.owner),
                cordconstnode.create(0,s32inttype,false),
                caddnode.create(subn,cloadnode.create(parnthreads,parnthreads.owner),cordconstnode.create(2,s32inttype,false)),
                cassignmentnode.create(
                  cvecnode.create(cloadnode.create(partids,partids.owner),cloadnode.create(parkvar,parkvar.owner)),
                  ccallnode.createintern('BEGINTHREAD',
                    ccallparanode.create(
                      ctypeconvnode.create_internal(caddrnode.create_internal(cloadnode.create(parwp,parwp.owner)),voidpointertype),
                      ccallparanode.create(
                        ctypeconvnode.create_proc_to_procvar(cloadnode.create_procvar(thunkps,thunkpd,thunkps.owner)),
                        nil)))),false));
              { the caller runs the worker too }
              addstatement(parstat,ccallnode.create(nil,workerps,workerps.owner,nil,[],nil));
              { barrier: for k := 0 to nthreads-2 do
                           if tids[k] <> 0 then WaitForThreadTerminate(tids[k], -1)
                A zero handle is a spawn that failed - there is no thread to
                join and the atomic counter drains its share through the
                workers that did start (worst case the caller alone). }
              addstatement(parstat,cfornode.create(cloadnode.create(parkvar,parkvar.owner),
                cordconstnode.create(0,s32inttype,false),
                caddnode.create(subn,cloadnode.create(parnthreads,parnthreads.owner),cordconstnode.create(2,s32inttype,false)),
                cifnode.create(
                  caddnode.create(unequaln,
                    ctypeconvnode.create_internal(
                      cvecnode.create(cloadnode.create(partids,partids.owner),cloadnode.create(parkvar,parkvar.owner)),
                      ptruinttype),
                    cordconstnode.create(0,ptruinttype,false)),
                  { WaitForThreadTerminate(tids[k], -1): the last call argument is
                    the outermost paranode. -1 is the timeout (an infinite wait):
                    the Windows backend hands it straight to WaitForSingleObject,
                    where 0 returns at once and leaves the workers running past the
                    barrier. }
                  ccallnode.createintern('WAITFORTHREADTERMINATE',
                    ccallparanode.create(
                      cordconstnode.create(-1,s32inttype,false),
                      ccallparanode.create(
                        cvecnode.create(cloadnode.create(partids,partids.owner),cloadnode.create(parkvar,parkvar.owner)),nil))),
                  nil),false));
              { re-raise the first captured worker exception, now on the caller }
              addstatement(parstat,cifnode.create(
                caddnode.create(unequaln,cloadnode.create(parexc,parexc.owner),cnilnode.create),
                craisenode.create(cloadnode.create(parexc,parexc.owner),nil,nil),nil));
              result:=parblock;
              do_typecheckpass(result);
            end;


      var
         hloopvar: tnode;
         vs : tabstractnormalvarsym;
         hdef : tdef;
         old_block_type : tblock_type;
         forblockst : tblocksymtable;
         parname,parupname : string;
         parsym : tsym;
         parsymtable : tsymtable;
      begin
         { parse loop header }
         consume(_FOR);

         { `for parallel [(N)] var ...` runs the body on worker threads.
           `parallel` is a soft keyword: it only starts a parallel loop when
           the next token is `var` or `(`. After an ordinary variable named
           parallel comes `:=` or `in`, and the loop is parsed as usual. }
         if (m_parallelfor in current_settings.modeswitches) and
            (current_scanner.token=_ID) and (current_scanner.pattern='PARALLEL') then
           begin
             parname:=current_scanner.orgpattern;
             parupname:=current_scanner.pattern;
             consume(_ID);
             { only `:=` or `in` next means parallel is an ordinary loop
               variable; anything else starts a parallel loop (a malformed
               header is diagnosed inside parallel_for_statement). `in` lexes
               to the operator token, so test idtoken for it }
             if (current_scanner.token<>_ASSIGNMENT) and (current_scanner.idtoken<>_IN) then
               begin
                 result:=parallel_for_statement;
                 exit;
               end;
             { ordinary variable named parallel - rebuild the loop variable }
             if searchsym(parupname,parsym,parsymtable) then
               begin
                 addsymref(parsym);
                 hloopvar:=cloadnode.create(parsym,parsymtable);
               end
             else
               begin
                 Message1(sym_e_id_not_found,parname);
                 hloopvar:=cerrornode.create;
               end;
             typecheckpass(hloopvar);
             valid_for_loopvar(hloopvar,true);
             if try_to_consume(_ASSIGNMENT) then
               result:=for_loop_create(hloopvar)
             else
               begin
                 consume(_IN);
                 result:=for_in_loop_create(hloopvar)
               end;
             exit;
           end;

         { Check for inline variable declaration: for var I ... }
         if (current_scanner.token = _VAR) and (m_inline_var in current_settings.modeswitches) then
           begin
             consume(_VAR);

             if not (inline_decl_symtable.symtabletype in [localsymtable,staticsymtable,blocksymtable]) then
               begin
                 Message(parser_e_syntax_error);
                 result := cerrornode.create;
                 exit;
               end;

             { tuple destructuring: for var (x, y, ...) in expr do body }
             if (m_tuples in current_settings.modeswitches) and
                (current_scanner.token = _LKLAMMER) then
               begin
                 result := for_in_destructure_loop;
                 exit;
               end;

             if current_scanner.token <> _ID then
               begin
                 consume(_ID);
                 result := cerrornode.create;
                 exit;
               end;

             { Push a block-scope symtable to limit the loop variable's
               visibility to the for-statement (Delphi-style scoping). }
             forblockst:=nil;
             if assigned(current_procinfo) then
               begin
                 forblockst:=tblocksymtable.create(symtablestack.top);
                 symtablestack.push(forblockst);
               end;

             { Create the loop variable – type may be set explicitly or inferred. }
             vs := create_inline_var_sym(current_scanner.orgpattern, generrordef);
             vs.register_sym;
             symtablestack.top.insertsym(vs);
             consume(_ID);

             if try_to_consume(_COLON) then
               begin
                 { Explicit type:  for var I: Integer := ... / for var Item: T in ... }
                 old_block_type := block_type;
                 block_type := bt_var_type;
                 read_anon_type(hdef, false, nil);
                 block_type := old_block_type;
                 vs.vardef := hdef;
                 if vs.typ = staticvarsym then
                   cnodeutils.insertbssdata(tstaticvarsym(vs));
                 hloopvar := cloadnode.create(vs, vs.owner);
                 typecheckpass(hloopvar);
                 valid_for_loopvar(hloopvar, true);

                 if try_to_consume(_ASSIGNMENT) then
                   result := for_loop_create(hloopvar)
                 else if try_to_consume(_IN) then
                   result := for_in_loop_create(hloopvar)
                 else
                   begin
                     consume(_ASSIGNMENT);
                     result := cerrornode.create;
                   end;
               end
             else if current_scanner.token = _ASSIGNMENT then
               begin
                 { Type inference from 'from' expression:  for var I := expr to/downto expr }
                 consume(_ASSIGNMENT);
                 { We need to infer the type from the 'from' expression, so we
                   parse it here, typecheck, set the var type, then call
                   for_loop_create which will parse the rest (to/downto, body). }
                 { But for_loop_create expects to parse 'from' itself via comp_expr.
                   So instead we handle the full for-loop inline here. }
                 hloopvar := cloadnode.create(vs, vs.owner);
                 result := for_loop_create_inferred(vs, hloopvar);
               end
             else if try_to_consume(_IN) then
               begin
                 { Type inference from for-in:  for var Item in Collection }
                 hloopvar := cloadnode.create(vs, vs.owner);
                 result := for_in_loop_create_inline(vs, hloopvar);
               end
             else
               begin
                 consume(_ASSIGNMENT);
                 result := cerrornode.create;
               end;

             { Pop the for-loop block scope; wrap the for-statement in a
               block node that owns the symtable so codegen emits begin/end
               labels around the loop and DWARF scopes the loop variable
               properly. }
             if assigned(forblockst) then
               begin
                 symtablestack.pop(forblockst);
                 if not assigned(current_procinfo.procdef.blocklocalsymtables) then
                   current_procinfo.procdef.blocklocalsymtables:=tfpobjectlist.create(true);
                 current_procinfo.procdef.blocklocalsymtables.add(forblockst);
                 hloopvar:=cblocknode.create(cstatementnode.create(result,nil));
                 hloopvar.fileinfo:=result.fileinfo;
                 tblocknode(hloopvar).blocksymtable:=forblockst;
                 result:=hloopvar;
               end;
           end
         else
           begin
             { Standard for loop without inline var }
             hloopvar:=factor(false,[]);
             valid_for_loopvar(hloopvar,true);

             if try_to_consume(_ASSIGNMENT) then
               result:=for_loop_create(hloopvar)
             else if try_to_consume(_IN) then
               result:=for_in_loop_create(hloopvar)
             else
               begin
                 consume(_ASSIGNMENT); // fail
                 result:=cerrornode.create;
               end;
           end;
      end;


    type
      twithshadowcand = class
        fname : TSymStr;
        frealname : TSymStr;
        fpos : tfileposinfo;
        fismethod : boolean;
        constructor Create(const an,arn:TSymStr;const afp:tfileposinfo;aismethod:boolean);
      end;

    constructor twithshadowcand.Create(const an,arn:TSymStr;const afp:tfileposinfo;aismethod:boolean);
      begin
        fname:=an;
        frealname:=arn;
        fpos:=afp;
        fismethod:=aismethod;
      end;

    { collect names of field/method symbols actually referenced inside a with-body,
      used to suppress shadow warnings for unused entries }
    function with_shadow_collect_used(var n: tnode; arg: pointer): foreachnoderesult;
      var
        used : TFPHashList;
        sym  : tsym;
      begin
        used:=TFPHashList(arg);
        result:=fen_true;
        case n.nodetype of
          subscriptn:
            begin
              sym:=tsubscriptnode(n).vs;
              if assigned(sym) and (used.Find(sym.name)=nil) then
                used.Add(sym.name,sym);
            end;
          loadn:
            begin
              sym:=tloadnode(n).symtableentry;
              if assigned(sym) and (sym.typ=fieldvarsym) and
                 (used.Find(sym.name)=nil) then
                used.Add(sym.name,sym);
            end;
          calln:
            begin
              sym:=tcallnode(n).symtableprocentry;
              if assigned(sym) and (used.Find(sym.name)=nil) then
                used.Add(sym.name,sym);
            end;
          else
            ;
        end;
      end;


    { build the body for a scoped-with autofree cleanup:
        if vs<>nil then begin vs.Free; vs:=nil end
      Returned node is intended to be wrapped in a cdefernode. }
    function build_lifetime_freeandnil(vs: tabstractnormalvarsym;
                                       const fp: tfileposinfo): tnode;
      var
        free_sym       : tsym;
        free_call      : tnode;
        free_inner     : tblocknode;
        free_inner_st  : tstatementnode;
      begin
        free_sym := search_struct_member(tobjectdef(vs.vardef), 'FREE');
        if not assigned(free_sym) or (free_sym.typ <> procsym) then
          begin
            Message(parser_e_autofree_requires_class);
            result := cnothingnode.create;
            exit;
          end;
        free_call := ccallnode.create(nil, tprocsym(free_sym), free_sym.owner,
                                      cloadnode.create(vs, vs.owner), [], nil);
        free_inner := internalstatements(free_inner_st);
        addstatement(free_inner_st, free_call);
        addstatement(free_inner_st, cassignmentnode.create(
          cloadnode.create(vs, vs.owner), cnilnode.create));
        result := cifnode.create(
          caddnode.create(unequaln, cloadnode.create(vs, vs.owner), cnilnode.create),
          free_inner, nil);
        result.fileinfo := fp;
      end;


    function _with_statement(seensyms : TFPList;seenfields : TFPHashList;shadowcands : TFPObjectList) : tnode;

      var
         p   : tnode;
         i,j : longint;
         st  : TSymtable;
         newblock : tblocknode;
         newstatement : tstatementnode;
         calltempnode,
         tempnode : ttempcreatenode;
         valuenode,
         hp,
         refnode  : tnode;
         hdef : tdef;
         helperdef : tobjectdef;
         hasimplicitderef : boolean;
         withsymtablelist : TFPObjectList;
         dupsym,fsym : tsym;
         localfields : TFPHashList;
         entrypos : tfileposinfo;
         { scoped-with state }
         lifetime_var : tabstractnormalvarsym;
         lifetime_autofree : boolean;
         lifetime_init : tnode;
         lifetime_handled : boolean;
         lifetime_name : TIDString;
         lifetime_filepos : tfileposinfo;
         lifetime_tcsym : tstaticvarsym;
         lifetime_name_suffix : string[16];
         withblockst : tblocksymtable;

         procedure pushobjchild(withdef,obj:tobjectdef);
         var
           parenthelperdef : tobjectdef;
         begin
           if not assigned(obj) then
             exit;
           pushobjchild(withdef,obj.childof);
           { we need to look for helpers that were defined for the parent
             class as well }
           search_last_objectpascal_helper(obj,current_structdef,parenthelperdef);
           { push the symtables of the helper's parents in reverse order }
           if assigned(parenthelperdef) then
             pushobjchild(withdef,parenthelperdef.childof);
           { keep the original tobjectdef as owner, because that is used for
             visibility of the symtable }
           st:=twithsymtable.create(withdef,obj.symtable.SymList,refnode.getcopy);
           symtablestack.push(st);
           withsymtablelist.add(st);
           { push the symtable of the helper }
           if assigned(parenthelperdef) then
             begin
               st:=twithsymtable.create(withdef,parenthelperdef.symtable.SymList,refnode.getcopy);
               symtablestack.push(st);
               withsymtablelist.add(st);
             end;
         end;


      begin
         calltempnode:=nil;
         { scoped-with -- recognise inline-var and autofree
           in the with-clause before falling back to the classic with-target
           expression. }
         lifetime_handled := false;
         lifetime_var := nil;
         lifetime_autofree := false;
         lifetime_init := nil;
         lifetime_tcsym := nil;
         withblockst := nil;
         hdef := nil;
         if (m_autofree in current_settings.modeswitches) and
            (current_scanner.token in [_VAR,_AUTOFREE]) then
           begin
             lifetime_filepos := current_filepos;
             { scope the inline var (and any hidden tcsym) to the with-body
               via a dedicated block symtable, so the same name can appear
               in a later sibling `with var NAME` in the same routine.
               Anchor blockparentst at the routine's localst directly so
               `make_mangledname` can peel cleanly: walking via stack-top
               can lead through nested begin..end blocksymtables whose own
               parent is a withsymtable (no defined ancestor for mangling),
               which trips IE 200204175. }
             if assigned(current_procinfo) and
                assigned(current_procinfo.procdef.localst) then
               begin
                 withblockst := tblocksymtable.create(current_procinfo.procdef.localst);
                 symtablestack.push(withblockst);
               end;
             if current_scanner.token = _VAR then
               begin
                 { Form C:  with var NAME := [autofree] EXPR do BODY
                   Form D:  with var NAME : TYPE do BODY     (no init) }
                 consume(_VAR);
                 if current_scanner.token <> _ID then
                   begin
                     consume(_ID);   { trigger expected-identifier error }
                     if assigned(withblockst) then
                       begin
                         symtablestack.pop(withblockst);
                         withblockst.free;
                       end;
                     result := cerrornode.create;
                     exit;
                   end;
                 lifetime_name := current_scanner.orgpattern;
                 consume(_ID);
                 if current_scanner.token = _COLON then
                   begin
                     { Form D: typed declaration with optional initializer }
                     block_type := bt_var_type;
                     consume(_COLON);
                     read_anon_type(hdef, false, nil);
                     block_type := bt_var;
                     lifetime_init := nil;
                     if try_to_consume(_ASSIGNMENT) then
                       begin
                         if current_scanner.token = _AUTOFREE then
                           begin
                             consume(_AUTOFREE);
                             lifetime_autofree := true;
                             lifetime_init := comp_expr([ef_accept_equal]);
                             do_typecheckpass(lifetime_init);
                           end
                         { Aggregate literal init for record/array: reuse
                           typed-constant parser via a hidden static sym,
                           then copy it into the with-var. The plain
                           expression parser cannot handle (a, b, c) form. }
                         else if (current_scanner.token = _LKLAMMER) and
                                 ((hdef.typ = arraydef) or (hdef.typ = recorddef)) then
                           begin
                             { suffix with line number so multiple sibling
                               `with var NAME : TYPE := (...)` in the same
                               routine don't share an asm label }
                             system.str(lifetime_filepos.line, lifetime_name_suffix);
                             lifetime_tcsym := cstaticvarsym.create(
                               '$with_tc_' + lifetime_name + '_' + lifetime_name_suffix,
                               vs_const, hdef, []);
                             include(lifetime_tcsym.symoptions, sp_internal);
                             symtablestack.top.insertsym(lifetime_tcsym);
                             read_typed_const(current_asmdata.asmlists[al_typedconsts],
                                              lifetime_tcsym, false, false);
                             lifetime_init := cloadnode.create(lifetime_tcsym, lifetime_tcsym.owner);
                             do_typecheckpass(lifetime_init);
                           end
                         else
                           begin
                             lifetime_init := comp_expr([ef_accept_equal]);
                             do_typecheckpass(lifetime_init);
                           end;
                       end;
                   end
                 else
                   begin
                     consume(_ASSIGNMENT);
                     if current_scanner.token = _AUTOFREE then
                       begin
                         consume(_AUTOFREE);
                         lifetime_autofree := true;
                       end;
                     lifetime_init := comp_expr([ef_accept_equal]);
                     do_typecheckpass(lifetime_init);
                   end;
               end
             else { _AUTOFREE }
               begin
                 { Form A:  with autofree EXPR do BODY  -- hidden helper var }
                 consume(_AUTOFREE);
                 lifetime_autofree := true;
                 { unique-ish suffix in case multiple form-A entries appear in the same scope }
                 system.str(int64(ptruint(symtablestack.top)) and $ffff,lifetime_name);
                 lifetime_name := '$with_' + lifetime_name;
                 lifetime_init := comp_expr([ef_accept_equal]);
                 do_typecheckpass(lifetime_init);
               end;
             { Form D already set hdef from the type annotation; only
               infer hdef from init.resultdef when there was no explicit
               type (Forms A and C). }
             if assigned(lifetime_init) and not assigned(hdef) then
               hdef := lifetime_init.resultdef;
             if not assigned(hdef) or (hdef = generrordef) then
               begin
                 if assigned(lifetime_init) then lifetime_init.free;
                 if assigned(withblockst) then
                   begin
                     symtablestack.pop(withblockst);
                     withblockst.free;
                   end;
                 result := cerrornode.create;
                 exit;
               end;
             if lifetime_autofree and
                not (is_class(hdef) and def_is_related(tobjectdef(hdef), class_tobject)) then
               begin
                 Message(parser_e_autofree_requires_class);
                 if assigned(lifetime_init) then lifetime_init.free;
                 if assigned(withblockst) then
                   begin
                     symtablestack.pop(withblockst);
                     withblockst.free;
                   end;
                 result := cerrornode.create;
                 exit;
               end;
             { create the holder variable scoped to the with-body. With
               `withblockst` pushed, symtablestack.top is the block symtable
               that gets popped at the end of `with`, so a sibling `with var
               NAME` can reuse the same name. }
             lifetime_var := create_inline_var_sym(lifetime_name, hdef);
             lifetime_var.register_sym;
             symtablestack.top.insertsym(lifetime_var);
             { Form C/A get an init expression so the var is effectively
               initialized; Form D leaves it at vs_declared so first read
               without write still triggers the usual uninitialized warning. }
             if assigned(lifetime_init) then
               tabstractnormalvarsym(lifetime_var).varstate := vs_initialised;
             if lifetime_var.typ = staticvarsym then
               cnodeutils.insertbssdata(tstaticvarsym(lifetime_var));
             { p := load(lifetime_var) -- this is what `with` binds to }
             p := cloadnode.create(lifetime_var, lifetime_var.owner);
             do_typecheckpass(p);
             lifetime_handled := true;
           end
         else
           begin
             p:=comp_expr([ef_accept_equal]);
             do_typecheckpass(p);
             { form B -- with NAME := [autofree] EXPR do
               (existing variable). Detected by `:=` after a plain load. }
             if (m_autofree in current_settings.modeswitches) and
                (current_scanner.token = _ASSIGNMENT) and
                (p.nodetype = loadn) and
                assigned(tloadnode(p).symtableentry) and
                (tloadnode(p).symtableentry.typ in [localvarsym,staticvarsym,paravarsym]) then
               begin
                 lifetime_filepos := current_filepos;
                 consume(_ASSIGNMENT);
                 if current_scanner.token = _AUTOFREE then
                   begin
                     consume(_AUTOFREE);
                     lifetime_autofree := true;
                   end;
                 lifetime_init := comp_expr([ef_accept_equal]);
                 do_typecheckpass(lifetime_init);
                 hdef := lifetime_init.resultdef;
                 if not assigned(hdef) or (hdef = generrordef) then
                   begin
                     lifetime_init.free;
                     p.free;
                     result := cerrornode.create;
                     exit;
                   end;
                 if lifetime_autofree and
                    not (is_class(hdef) and def_is_related(tobjectdef(hdef), class_tobject)) then
                   Message(parser_e_autofree_requires_class);
                 lifetime_var := tabstractnormalvarsym(tloadnode(p).symtableentry);
                 lifetime_handled := true;
                 { p stays as the load to the existing var }
               end;
           end;
         entrypos:=p.fileinfo;

         { unleashed: `with EnumType do` exposes the type's enum members
           without qualification (useful with $SCOPEDENUMS). Only a type
           reference makes sense here - there is no instance to bind, so
           the regular refnode machinery is skipped entirely. }
         if (m_unleashed in current_settings.modeswitches) and
            (p.nodetype=typen) and (p.resultdef.typ=enumdef) then
           begin
             st:=tenumdef(p.resultdef).symtable;
             symtablestack.push(st);
             if try_to_consume(_COMMA) then
               result:=_with_statement(seensyms,seenfields,shadowcands)
             else
               begin
                 consume(_DO);
                 if current_scanner.token<>_SEMICOLON then
                   result:=control_body_statement
                 else
                   result:=cnothingnode.create;
               end;
             symtablestack.pop(st);
             p.free;
             exit;
           end;

         { detect duplicate symbols in the WITH list (only for plain
           symbol references - p^, foo(), a[i] are intentionally skipped) }
         if (m_unleashed in current_settings.modeswitches) and
            (p.nodetype=loadn) and assigned(tloadnode(p).symtableentry) then
           begin
             dupsym:=tloadnode(p).symtableentry;
             if seensyms.IndexOf(dupsym)>=0 then
               Message1(parser_e_with_duplicate_symbol,dupsym.realname)
             else
               seensyms.Add(dupsym);
           end;

         if (p.nodetype=vecn) and
            (vnf_memseg in tvecnode(p).vecnodeflags) then
           CGMessage(parser_e_no_with_for_variable_in_other_segments);

         { "with procvar" can never mean anything, so always try
           to call it in case it returns a record/object/... }
         maybe_call_procvar(p,false);

         if (p.resultdef.typ in [objectdef,recorddef,classrefdef]) or
           ((p.resultdef.typ=undefineddef) and (df_generic in current_procinfo.procdef.defoptions)) then
          begin
            newblock:=nil;
            valuenode:=nil;
            tempnode:=nil;

            { scoped-with -- always wrap in a block so we
              can prepend `lifetime_var := init_expr;` before the with-body.
              Form D (typed declaration, no init) skips the assignment. }
            if lifetime_handled then
              begin
                newblock := internalstatements(newstatement);
                if assigned(lifetime_init) then
                  addstatement(newstatement, cassignmentnode.create(
                    cloadnode.create(lifetime_var, lifetime_var.owner),
                    lifetime_init));
              end;

            hp:=skip_nodes_before_load(p);
            if (hp.nodetype=loadn) and
               (
                (tloadnode(hp).symtable=current_procinfo.procdef.localst) or
                (tloadnode(hp).symtable=current_procinfo.procdef.parast) or
                (tloadnode(hp).symtable.symtabletype in [staticsymtable,globalsymtable,blocksymtable])
               ) and
               { MacPas objects are mapped to classes, and the MacPas compilers
                 interpret with-statements with MacPas objects the same way
                 as records (the object referenced by the with-statement
                 must remain constant)
               }
               not(is_class(hp.resultdef) and
                   (m_mac in current_settings.modeswitches)) then
              begin
                { simple load, we can reference direct }
                refnode:=p;
              end
            else
              begin
                { complex load, load in temp first }
                newblock:=internalstatements(newstatement);
                { when we can't take the address of p, load it in a temp }
                { since we may need its address later on                 }
                if not valid_for_addr(p,false) then
                  begin
                    calltempnode:=ctempcreatenode.create(p.resultdef,p.resultdef.size,tt_persistent,true);
                    addstatement(newstatement,calltempnode);
                    addstatement(newstatement,cassignmentnode.create(
                        ctemprefnode.create(calltempnode),
                        p));
                    p:=ctemprefnode.create(calltempnode);
                    typecheckpass(p);
                  end;
                { several object types have implicit dereferencing }
                { is_implicit_pointer_object_type() returns true for records
                  on the JVM target because they are implemented as classes
                  there, but we definitely have to take their address here
                  since otherwise a deep copy is made and changes are made to
                  this copy rather than to the original one }
                hasimplicitderef:=
                  (is_implicit_pointer_object_type(p.resultdef) or
                   (p.resultdef.typ=classrefdef)) and
                  not((target_info.system in systems_jvm) and
                      ((p.resultdef.typ=recorddef) or
                       is_object(p.resultdef)));
                if hasimplicitderef then
                  hdef:=p.resultdef
                else
                  hdef:=cpointerdef.create(p.resultdef);
                { load address of the value in a temp }
                tempnode:=ctempcreatenode.create_withnode(hdef,sizeof(pint),tt_persistent,true,p);
                typecheckpass(tnode(tempnode));
                valuenode:=p;
                refnode:=ctemprefnode.create(tempnode);
                fillchar(refnode.fileinfo,sizeof(tfileposinfo),0);
                { add address call for valuenode and deref for refnode if this
                  is not done implicitly }
                if not hasimplicitderef then
                  begin
                    valuenode:=caddrnode.create_internal_nomark(valuenode);
                    include(taddrnode(valuenode).addrnodeflags,anf_typedaddr);
                    refnode:=cderefnode.create(refnode);
                    fillchar(refnode.fileinfo,sizeof(tfileposinfo),0);
                  end;
                addstatement(newstatement,tempnode);
                addstatement(newstatement,cassignmentnode.create(
                    ctemprefnode.create(tempnode),
                    valuenode));
                typecheckpass(refnode);
              end;
            { Note: the symtable of the helper is pushed after the following
                    "case", the symtables of the helper's parents are passed in
                    the "case" branches }
            withsymtablelist:=TFPObjectList.create(true);
            case p.resultdef.typ of
              objectdef :
                begin
                   { do we have a helper for this type? }
                   search_last_objectpascal_helper(tabstractrecorddef(p.resultdef),current_structdef,helperdef);
                   { push symtables of all parents in reverse order }
                   pushobjchild(tobjectdef(p.resultdef),tobjectdef(p.resultdef).childof);
                   { push symtables of all parents of the helper in reverse order }
                   if assigned(helperdef) then
                     pushobjchild(helperdef,helperdef.childof);
                   { push object symtable }
                   st:=twithsymtable.Create(tobjectdef(p.resultdef),tobjectdef(p.resultdef).symtable.SymList,refnode);
                   symtablestack.push(st);
                   withsymtablelist.add(st);
                 end;
              classrefdef :
                begin
                   { do we have a helper for this type? }
                   search_last_objectpascal_helper(tobjectdef(tclassrefdef(p.resultdef).pointeddef),current_structdef,helperdef);
                   { push symtables of all parents in reverse order }
                   pushobjchild(tobjectdef(tclassrefdef(p.resultdef).pointeddef),tobjectdef(tclassrefdef(p.resultdef).pointeddef).childof);
                   { push symtables of all parents of the helper in reverse order }
                   if assigned(helperdef) then
                     pushobjchild(helperdef,helperdef.childof);
                   { push object symtable }
                   st:=twithsymtable.Create(tobjectdef(tclassrefdef(p.resultdef).pointeddef),tobjectdef(tclassrefdef(p.resultdef).pointeddef).symtable.SymList,refnode);
                   symtablestack.push(st);
                   withsymtablelist.add(st);
                end;
              recorddef :
                begin
                   { do we have a helper for this type? }
                   search_last_objectpascal_helper(tabstractrecorddef(p.resultdef),current_structdef,helperdef);
                   { push symtables of all parents of the helper in reverse order }
                   if assigned(helperdef) then
                     pushobjchild(helperdef,helperdef.childof);
                   { push record symtable }
                   st:=twithsymtable.create(trecorddef(p.resultdef),trecorddef(p.resultdef).symtable.SymList,refnode);
                   symtablestack.push(st);
                   withsymtablelist.add(st);
                end;
              undefineddef :
                begin
                   if not(df_generic in current_procinfo.procdef.defoptions) then
                     internalerror(2012122802);
                   helperdef:=nil;
                   { push record symtable }
                   st:=twithsymtable.create(p.resultdef,nil,refnode);
                   symtablestack.push(st);
                   withsymtablelist.add(st);
                end;
              else
                internalerror(200601271);
            end;

            { push helper symtable }
            if assigned(helperdef) then
              begin
                st:=twithsymtable.Create(helperdef,helperdef.symtable.SymList,refnode.getcopy);
                symtablestack.push(st);
                withsymtablelist.add(st);
              end;

            { warn when a field/method from this entry shadows the same name
              from an earlier entry in the same WITH list (inheritance inside
              one entry is collapsed via a local dedup set; constructors and
              destructors are skipped -- typically not called from with-body) }
            if m_unleashed in current_settings.modeswitches then
              begin
                localfields:=TFPHashList.Create;
                try
                  for i:=0 to withsymtablelist.count-1 do
                    begin
                      st:=TSymtable(withsymtablelist[i]);
                      if not assigned(st) then
                        continue;
                      for j:=0 to st.SymList.Count-1 do
                        begin
                          fsym:=tsym(st.SymList[j]);
                          if (localfields.Find(fsym.name)<>nil) then
                            continue;
                          if fsym.typ=fieldvarsym then
                            localfields.Add(fsym.name,fsym)
                          else if (fsym.typ=procsym) and
                                  (tprocsym(fsym).ProcdefList.Count>0) and
                                  not (tprocdef(tprocsym(fsym).ProcdefList[0]).proctypeoption
                                       in [potype_constructor,potype_destructor]) and
                                  { skip TObject methods (Free, NewInstance, ...): present
                                    in every class, do not represent meaningful shadowing }
                                  (assigned(fsym.owner) and (fsym.owner.defowner<>class_tobject)) then
                            localfields.Add(fsym.name,fsym);
                        end;
                    end;
                  for j:=0 to localfields.Count-1 do
                    begin
                      fsym:=tsym(localfields.Items[j]);
                      if seenfields.Find(fsym.name)<>nil then
                        shadowcands.Add(twithshadowcand.Create(fsym.name,fsym.realname,entrypos,fsym.typ=procsym))
                      else
                        seenfields.Add(fsym.name,fsym);
                    end;
                finally
                  localfields.Free;
                end;
              end;

            if try_to_consume(_COMMA) then
              p:=_with_statement(seensyms,seenfields,shadowcands)
            else
              begin
                consume(_DO);
                if current_scanner.token<>_SEMICOLON then
                  p:=control_body_statement
                else
                  p:=cnothingnode.create;
              end;

            { remove symtables in reverse order from the stack }
            for i:=withsymtablelist.count-1 downto 0 do
              symtablestack.pop(TSymtable(withsymtablelist[i]));
            withsymtablelist.free;
            withsymtablelist := nil;

            { pop the with-var block symtable (if any) and hand it to the
              procdef so its locals get stack space allocated; the wrapping
              newblock keeps a reference for debug-info scoping }
            if assigned(withblockst) then
              begin
                symtablestack.pop(withblockst);
                if not assigned(current_procinfo.procdef.blocklocalsymtables) then
                  current_procinfo.procdef.blocklocalsymtables := tfpobjectlist.create(true);
                current_procinfo.procdef.blocklocalsymtables.add(withblockst);
                if assigned(newblock) then
                  tblocknode(newblock).blocksymtable := withblockst;
              end;

            { scoped-with -- rewrite any defers the body
              registered (e.g. `with X do defer Foo;` or stray defers in
              a begin..end body that wasn't already a defer-scope) so they
              fire at with-scope exit, not in the enclosing routine.
              We need a blocknode to feed rewrite_defers_in_block its
              statement chain; wrap a single statement first. }
            if lifetime_handled and (m_autofree in current_settings.modeswitches) then
              begin
                if p.nodetype <> blockn then
                  p := cblocknode.create(cstatementnode.create(p, nil));
                hp := tblocknode(p).left;
                rewrite_defers_in_block(hp);
                tblocknode(p).left := hp;
              end;

            { scoped-with autofree -- wrap the body in
              try..finally with the auto-cleanup, so the holder's Free
              fires regardless of how the body exits. }
            if lifetime_handled and lifetime_autofree and
               (m_autofree in current_settings.modeswitches) then
              begin
                p := ctryfinallynode.create(
                       p,
                       build_lifetime_freeandnil(lifetime_var, lifetime_filepos));
                p.fileinfo := lifetime_filepos;
                typecheckpass(p);
              end;

            { Finalize complex withnode with destroy of temp }
            if assigned(newblock) then
             begin
               addstatement(newstatement,p);
               if assigned(tempnode) then
                 addstatement(newstatement,ctempdeletenode.create(tempnode));
               if assigned(calltempnode) then
                 addstatement(newstatement,ctempdeletenode.create(calltempnode));
               p:=newblock;
             end;
            result:=p;
          end
         else
          begin
            Message1(parser_e_false_with_expr,p.resultdef.GetTypeName);
            p.free;
            p := nil;
            { try to recover from error }
            if try_to_consume(_COMMA) then
             begin
               hp:=_with_statement(seensyms,seenfields,shadowcands);
               if (hp=nil) then; { remove warning about unused }
             end
            else
             begin
               consume(_DO);
               { ignore all }
               if current_scanner.token<>_SEMICOLON then
                statement;
             end;
            result:=cerrornode.create;
          end;
      end;


    function with_statement : tnode;
      var
         seensyms : TFPList;
         seenfields,usedfields : TFPHashList;
         shadowcands : TFPObjectList;
         i : longint;
         cand : twithshadowcand;
      begin
         consume(_WITH);
         seensyms:=TFPList.Create;
         seenfields:=TFPHashList.Create;
         shadowcands:=TFPObjectList.Create(true);
         try
           result:=_with_statement(seensyms,seenfields,shadowcands);
           { only warn about shadowed fields that are actually referenced
             inside the with-body (avoids noise for unused fields) }
           if shadowcands.Count>0 then
             begin
               usedfields:=TFPHashList.Create;
               try
                 foreachnodestatic(result,@with_shadow_collect_used,usedfields);
                 for i:=0 to shadowcands.Count-1 do
                   begin
                     cand:=twithshadowcand(shadowcands[i]);
                     if usedfields.Find(cand.fname)<>nil then
                       if cand.fismethod then
                         MessagePos1(cand.fpos,parser_w_with_shadowed_method,cand.frealname)
                       else
                         MessagePos1(cand.fpos,parser_w_with_shadowed_field,cand.frealname);
                   end;
               finally
                 usedfields.Free;
               end;
             end;
         finally
           seensyms.Free;
           seenfields.Free;
           shadowcands.Free;
         end;
      end;


    function raise_statement : tnode;
      var
         p,pobj,paddr,pframe : tnode;
      begin
         pobj:=nil;
         paddr:=nil;
         pframe:=nil;
         consume(_RAISE);
         if not(current_scanner.token in endtokens) then
           begin
              { object }
              pobj:=comp_expr([ef_accept_equal]);
              if try_to_consume(_AT) then
                begin
                   paddr:=comp_expr([ef_accept_equal]);
                   if try_to_consume(_COMMA) then
                     pframe:=comp_expr([ef_accept_equal]);
                end;
           end
         else
           begin
              if (block_type<>bt_except) then
                Message(parser_e_no_reraise_possible);
           end;
         if (po_noreturn in current_procinfo.procdef.procoptions) and (exceptblockcounter=0) then
           Message(parser_e_raise_with_noreturn_not_allowed);
         p:=craisenode.create(pobj,paddr,pframe);
         raise_statement:=p;
      end;


    function try_statement(is_expr:boolean=false) : tnode;
      var
        resultdef : tdef;

      function readexpr : tnode;inline;
        begin
          result:=expr(true);
          resultdef:=branch_type(resultdef,result.resultdef);
        end;

      procedure update_onnode_assignment(temp: ttempcreatenode; onnode: tonnode);
        begin
          if not assigned(onnode) then
            exit;
          onnode.right:=cassignmentnode.create(ctemprefnode.create(temp),onnode.right);
          update_onnode_assignment(temp,tonnode(onnode.left));
        end;

      procedure check_type_valid(var def: tdef);
        begin
           if not (is_class(def) or is_javaclass(def) or
              { skip showing error message the second time }
              (def.typ=errordef)) then
             begin
               Message1(type_e_class_type_expected,def.typename);
               def:=generrordef;
             end;
        end;

      var
         p_try_block,p_finally_block,first,last,
         p_default,p_specific,hp : tnode;
         ot : tDef;
         sym : tlocalvarsym;
         old_block_type : tblock_type;
         excepTSymtable : TSymtable;
         objname,objrealname : TIDString;
         srsym : tsym;
         srsymtable : TSymtable;
         t:ttoken;
         unit_found:boolean;
         oldcurrent_exceptblock: integer;
         filepostry : tfileposinfo;
         trynode : ttryexceptnode;
         statements : tstatementnode;
         resultvar : ttempcreatenode;
      begin
         p_default:=nil;
         p_specific:=nil;
         excepTSymtable:=nil;
         last:=nil;
         resultdef:=nil;
         result:=nil;

         { read statements to try }
         consume(_TRY);
         filepostry:=current_filepos;
         first:=nil;
         inc(exceptblockcounter);
         oldcurrent_exceptblock := current_exceptblock;
         current_exceptblock := exceptblockcounter;
         old_block_type := block_type;
         block_type := bt_body;

         if is_expr then
           p_try_block:=readexpr
         else
           begin
             while (current_scanner.token<>_FINALLY) and (current_scanner.token<>_EXCEPT) do
               begin
                  if first=nil then
                    begin
                       last:=cstatementnode.create(statement,nil);
                       first:=last;
                    end
                  else
                    begin
                       tstatementnode(last).right:=cstatementnode.create(statement,nil);
                       last:=tstatementnode(last).right;
                    end;
                  if not try_to_consume(_SEMICOLON) then
                    break;
                  consume_emptystats;
               end;
             { try-body is its own defer scope; rewrite
               nested `defer` statements before they leak into the
               enclosing routine's scope. }
             if assigned(first) then
               rewrite_defers_in_block(first);
             p_try_block:=cblocknode.create(first);
           end;

         if current_scanner.token=_FINALLY then
           begin
              if is_expr then
                begin
                  { try-finally expressions are not allowed }
                  consume(_EXCEPT);
                  result:=cerrornode.create;
                  exit;
                end;
              consume(_FINALLY);
              inc(exceptblockcounter);
              current_exceptblock := exceptblockcounter;
              p_finally_block:=statements_til_end;
              result:=ctryfinallynode.create(p_try_block,p_finally_block);
              result.fileinfo:=filepostry;
           end
         else
           begin
              consume(_EXCEPT);
              block_type:=bt_except;
              inc(exceptblockcounter);
              current_exceptblock := exceptblockcounter;
              ot:=generrordef;
              p_specific:=nil;
              if (current_scanner.idtoken=_ON) then
                { catch specific exceptions }
                begin
                   repeat
                     consume(_ON);
                     if current_scanner.token=_ID then
                       begin
                          objname:=current_scanner.pattern;
                          objrealname:=current_scanner.orgpattern;
                          { can't use consume_sym here, because we need already
                            to check for the colon }
                          searchsym(objname,srsym,srsymtable);
                          consume(_ID);
                          { is a explicit name for the exception given ? }
                          if try_to_consume(_COLON) then
                            begin
                              single_type(ot,[]);
                              check_type_valid(ot);
                              sym:=clocalvarsym.create(objrealname,vs_value,ot,[]);
                            end
                          else
                            begin
                               { check if type is valid, must be done here because
                                 with "e: Exception" the e is not necessary }

                               { support unit.identifier }
                               unit_found:=try_consume_unitsym_no_specialize(srsym,srsymtable,t,[],objname);
                               if srsym=nil then
                                 begin
                                   identifier_not_found(objrealname);
                                   srsym:=generrorsym;
                                 end;
                               if unit_found then
                                 consume(t);
                               { check if type is valid, must be done here because
                                 with "e: Exception" the e is not necessary }
                               if (srsym.typ=typesym) then
                                 begin
                                   ot:=ttypesym(srsym).typedef;
                                   parse_nested_types(ot,false,false,nil);
                                   check_type_valid(ot);
                                 end
                               else
                                 begin
                                   Message(type_e_type_id_expected);
                                   ot:=generrordef;
                                 end;

                                 { create dummy symbol so we don't need a special
                                 case in ncgflw, and so that we always know the
                                 type }
                               sym:=clocalvarsym.create('$exceptsym',vs_value,ot,[]);
                            end;
                          excepTSymtable:=tstt_excepTSymtable.create;
                          excepTSymtable.defowner:=current_procinfo.procdef;
                          excepTSymtable.insertsym(sym);
                          symtablestack.push(excepTSymtable);
                       end
                     else
                       consume(_ID);
                     consume(_DO);
                     if is_expr then
                       hp:=connode.create(nil,readexpr)
                     else
                       hp:=connode.create(nil,control_body_statement);
                     if ot.typ=errordef then
                       begin
                          hp.free;
                          hp:=cerrornode.create;
                       end;
                     if p_specific=nil then
                       begin
                          last:=hp;
                          p_specific:=last;
                       end
                     else
                       begin
                          tonnode(last).left:=hp;
                          last:=tonnode(last).left;
                       end;
                     { set the informations }
                     { only if the creation of the onnode was successful, it's possible}
                     { that last and hp are errornodes (JM)                            }
                     if last.nodetype = onn then
                       begin
                         tonnode(last).excepttype:=tobjectdef(ot);
                         tonnode(last).excepTSymtable:=excepTSymtable;
                       end;
                     { remove exception symtable }
                     if assigned(excepTSymtable) then
                       begin
                         symtablestack.pop(excepTSymtable);
                         if last.nodetype <> onn then
                           begin
                             excepTSymtable.free;
                             excepTSymtable := nil;
                           end;
                       end;
                     if not try_to_consume(_SEMICOLON) then
                        break;
                     consume_emptystats;
                   until (current_scanner.token in [_END,_ELSE]);
                   if try_to_consume(_ELSE) then
                     begin
                       { catch the other exceptions }
                       if is_expr then
                         p_default:=readexpr
                       else
                         p_default:=statements_til_end;
                     end
                   else if is_expr then
                     consume(_ELSE)
                   else
                     consume(_END);
                end
              else
                begin
                   { catch all exceptions }
                   if is_expr then
                     p_default:=readexpr
                   else
                     p_default:=statements_til_end;
                end;

              result:=ctryexceptnode.create(p_try_block,p_specific,p_default);
           end;
         block_type:=old_block_type;
         current_exceptblock := oldcurrent_exceptblock;

         if not is_expr then
           exit;
         trynode:=ttryexceptnode(result);
         result:=internalstatements(statements);
         resultvar:=ctempcreatenode.create(resultdef,resultdef.size,tt_persistent,true);
         addstatement(statements,resultvar);

         trynode.left:=cassignmentnode.create(ctemprefnode.create(resultvar),trynode.left);
         update_onnode_assignment(resultvar,tonnode(trynode.right));
         if assigned(trynode.t1) then
           trynode.t1:=cassignmentnode.create(ctemprefnode.create(resultvar),trynode.t1);

         addstatement(statements,trynode);
         addstatement(statements,ctempdeletenode.create_normal_temp(resultvar));
         addstatement(statements,ctemprefnode.create(resultvar));
      end;


    function _asm_statement : tnode;
      var
        asmstat : tasmnode;
        reg     : tregister;
        asmreader : tbaseasmreader;
        entrypos : tfileposinfo;
        hl : TAsmList;
      begin
         Inside_asm_statement:=true;
         asmstat:=nil;
         hl:=nil;

         { apply all switch changes as the assembler readers doesn't do so }
         flushpendingswitchesstate;

         if assigned(asmmodeinfos[current_settings.asmmode]) then
           begin
             asmreader:=asmmodeinfos[current_settings.asmmode]^.casmreader.create;
             entrypos:=current_filepos;
             hl:=asmreader.assemble as TAsmList;
             if (not hl.empty) then
               begin
                 { mark boundaries of assembler block, this is necessary for optimizer }
                 hl.insert(tai_marker.create(mark_asmblockstart));
                 hl.concat(tai_marker.create(mark_asmblockend));
               end;
             asmstat:=casmnode.create(hl);
             asmstat.fileinfo:=entrypos;
             asmreader.free;
             asmreader := nil;
           end
         else
           Message(parser_f_assembler_reader_not_supported);

         { Mark procedure that it has assembler blocks }
         include(current_procinfo.flags,pi_has_assembler_block);
{$if defined(cpu8bitalu) or defined(cpu16bitalu)}
         { We assume the function result is always used in the TP mode }
         if (m_tp7 in current_settings.modeswitches) and
            not (po_assembler in current_procinfo.procdef.procoptions) and
            assigned(current_procinfo.procdef.funcretsym) then
           current_procinfo.procdef.funcretsym.IncRefCount;
{$endif}
         { Read first the _ASM statement }
         consume(_ASM);

         { Force an empty register list for pure assembler routines,
           so that pass2 won't allocate volatile registers for them. }
         if (po_assembler in current_procinfo.procdef.procoptions) then
           Include(asmstat.asmnodeflags,asmnf_has_registerlist);

         { END is read, got a list of changed registers? }
         if try_to_consume(_LECKKLAMMER) then
           begin
             if current_scanner.token<>_RECKKLAMMER then
              begin
                if po_assembler in current_procinfo.procdef.procoptions then
                  Message(parser_w_register_list_ignored);
                repeat
                  { it's possible to specify the modified registers }
                  if current_scanner.token=_CSTRING then
                    reg:=std_regnum_search(lower(current_scanner.cstringpattern))
                  else if current_scanner.token=_CCHAR then
                    reg:=std_regnum_search(lower(current_scanner.pattern))
                  else
                    reg:=NR_NO;
                  { is_extra_reg is not exported on all architectures from cpubase }
{$if defined(RISCV)}
                  if (reg=NR_NO) and (current_scanner.token=_CSTRING) then
                    reg:=is_extra_reg(upper(current_scanner.cstringpattern));
{$endif defined(RISCV)}
                  if reg<>NR_NO then
                    begin
                      if not(po_assembler in current_procinfo.procdef.procoptions) and assigned(hl) then
                        begin
                          hl.Insert(tai_regalloc.alloc(reg,nil));
                          hl.Insert(tai_regalloc.markused(reg));
                          hl.Concat(tai_regalloc.dealloc(reg,nil));
                        end;
                    end
                  else
                    Message(asmr_e_invalid_register);
                  if current_scanner.token=_CCHAR then
                    consume(_CCHAR)
                  else
                    consume(_CSTRING);
                  if not try_to_consume(_COMMA) then
                    break;
                until false;
                Include(asmstat.asmnodeflags,asmnf_has_registerlist);
              end;
             consume(_RECKKLAMMER);
           end;

         Inside_asm_statement:=false;
         _asm_statement:=asmstat;
      end;


    { Old Turbo Pascal INLINE(data/data/...) }
    function tp_inline_statement : tnode;
      var
        actype : taiconst_type;

      function eval_intconst: asizeint;
        var
          cv : Tconstexprint;
          def: tdef;
        begin
          cv:=get_intconst;
          case actype of
            aitconst_8bit:
              def:=s8inttype;
            aitconst_16bit:
              def:=s16inttype;
            else
              def:=sizesinttype;
          end;
          if cv.uvalue>get_max_value(def).uvalue then
            def:=get_unsigned_inttype(def);
          adaptrange(def,cv,rc_implicit);
          result:=cv.svalue;
        end;

      var
        cur_line : longint;
        w : asizeint;
        hl : TAsmList;
        asmstat : tasmnode;
        sym : tsym;
        symtable : TSymtable;
        s : tsymstr;
        ac : tai_const;
        nesting : integer;
        tokenbuf : tdynamicarray;
      begin
        consume(_INLINE);
        consume(_LKLAMMER);
        hl:=TAsmList.create;
        asmstat:=casmnode.create(hl);
        asmstat.fileinfo:=current_filepos;
        tokenbuf:=tdynamicarray.Create(16);
        cur_line:=0;
        { Parse data blocks }
        repeat
          { Record one data block for further replaying.
            This is needed  since / is used as a data block delimiter and cause troubles
            with constant evaluation which is allowed inside a data block. }
          tokenbuf.reset;
          current_scanner.startrecordtokens(tokenbuf);
          nesting:=0;
          while current_scanner.token<>_SLASH do
            begin
              case current_scanner.token of
                _LKLAMMER:
                  inc(nesting);
                _RKLAMMER:
                  begin
                    dec(nesting);
                    if nesting<0 then
                      break;
                  end;
                _SEMICOLON:
                  consume(_RKLAMMER); { error }
                else
                  ; {no action}
              end;
              consume(current_scanner.token);
            end;
          current_scanner.stoprecordtokens;
          { Set the current token to ; to make the constant evaluator happy }
          current_scanner.token:=_SEMICOLON;
          { Parse recorded tokens }
          current_scanner.startreplaytokens(tokenbuf,false);

          if cur_line<>current_filepos.line then
            begin
              hl.concat(tai_force_line.Create);
              cur_line:=current_filepos.line;
            end;

          { Data size override }
          if try_to_consume(_GT) then
            actype:=aitconst_16bit
          else
            if try_to_consume(_LT) then
              actype:=aitconst_8bit
            else
              actype:=aitconst_128bit; { default size }
          sym:=nil;
          if current_scanner.token=_ID then
            begin
              if searchsym(current_scanner.pattern,sym,symtable) then
                begin
                  if sym.typ in [staticvarsym,localvarsym,paravarsym] then
                    begin
                      { Address of the static symbol or base offset for local symbols }
                      consume(_ID);
                      if (sym.typ=staticvarsym) and not (actype in [aitconst_128bit,aitconst_ptr]) then
                        Message1(type_e_integer_expr_expected,sym.name);
                      { Additional offset }
                      if current_scanner.token in [_PLUS,_MINUS] then
                        w:=eval_intconst
                      else
                        w:=0;
                      if sym.typ=staticvarsym then
                        s:=sym.mangledname
                      else
                        s:=sym.name;
                      ac:=tai_const.Createname(s,w);
                      if actype=aitconst_128bit then
                        ac.consttype:=aitconst_ptr
                      else
                        ac.consttype:=actype;
                      { For a local symbol it is needed to generate a constant with the symbols's stack offset.
                        The stack offset is unavailable rigth now and will be resolved later in tcgasmnode.pass_generate_code.
                        Set sym.bind:=AB_NONE to indicate that this is a local symbol. }
                      if sym.typ<>staticvarsym then
                        ac.sym.bind:=AB_NONE;
                      hl.concat(ac);
                    end
                  else
                    if sym.typ=constsym then
                      sym:=nil
                    else
                      begin
                        consume(_ID);
                        Message(asmr_e_wrong_sym_type);
                      end;
                end;
            end;

          if sym=nil then
            begin
              { Integer constant expression }
              w:=eval_intconst;
              case actype of
                aitconst_8bit:
                  hl.concat(tai_const.Create_8bit(w));
                aitconst_16bit:
                  hl.concat(tai_const.Create_16bit(w));
                else
                  if w<$100 then
                    hl.concat(tai_const.Create_8bit(w))
                  else
                    hl.concat(tai_const.Create_sizeint(w));
              end;
            end;

          if not try_to_consume(_SEMICOLON) then
            consume(_RKLAMMER); {error}
        until nesting<0;
        tokenbuf.free;
        tokenbuf := nil;
        { mark boundaries of assembler block, this is necessary for optimizer }
        hl.insert(tai_marker.create(mark_asmblockstart));
        hl.concat(tai_marker.create(mark_asmblockend));
        { Mark procedure that it has assembler blocks }
        include(current_procinfo.flags,pi_has_assembler_block);
        { Assume the function result is always used }
        if assigned(current_procinfo.procdef.funcretsym) then
          current_procinfo.procdef.funcretsym.IncRefCount;
        result:=asmstat;
      end;


    { Parse an inline variable declaration of the form:
        var name : Type
        var name : Type := expr
        var name := expr   (type inference)
        var name1, name2 : Type
      Enabled by modeswitch InlineVars (m_inline_var), on by default in
      $mode unleashed.  Adds the declared variable(s) to the current local
      symbol table (procedure-wide scope, same as ordinary local variables) and
      returns an assignment node when an initialiser is present, or a nothing
      node otherwise. }

    { unleashed: pick a dynamic-array element type from the first element's
      category (nil maps to Pointer), force every element to that type (compile
      error on mismatch), and return a fresh `array of T` dynamic def. The
      arrayconstructor already went through pass_typecheck producing some
      legacy carrier; we replace its semantic shape here. Mixed-type literals
      (string+int+...) become a compile error - use `array of Variant`
      explicitly or pass to an `array of const` parameter for genuinely mixed
      cases. Empty `[]` and all-nil literals get a diagnostic hint and the
      reasonable defaults (AnsiString / Pointer). }
    function unleashed_infer_array_literal(arrconstr: tarrayconstructornode) : tdef;
      var
        hp : tarrayconstructornode;
        first_nonnil : tnode;
        elemdef : tdef;
        dyndef : tarraydef;
      begin
        first_nonnil := nil;
        if assigned(arrconstr.left) then
          begin
            hp := arrconstr;
            while assigned(hp) do
              begin
                if (not assigned(first_nonnil)) and (hp.left.nodetype <> niln) then
                  first_nonnil := hp.left;
                hp := tarrayconstructornode(hp.right);
              end;
          end;

        elemdef := nil;
        if not assigned(arrconstr.left) then
          begin
            { empty `[]` }
            Comment(V_Hint, 'empty array literal, defaulting element type to AnsiString');
            elemdef := getansistringdef;
          end
        else if not assigned(first_nonnil) then
          begin
            { every element is nil - hint that the type was guessed }
            Comment(V_Hint, 'array literal with only nil elements, defaulting element type to Pointer');
            elemdef := voidpointertype;
          end
        else if arrconstr.left.nodetype = niln then
          { first element is nil but the literal carries a real one further on;
            still Pointer (nil semantically *is* a pointer) but no hint - the
            non-nil tail tells us the user's intent is pointer-like enough }
          elemdef := voidpointertype
        else if arrconstr.left.resultdef.typ = stringdef then
          { preserve the specific string kind the user wrote (UnicodeString,
            WideString, ShortString) - only fall back to AnsiString for the
            conststring literals where the source didn't say }
          case tstringdef(arrconstr.left.resultdef).stringtype of
            st_unicodestring: elemdef := cunicodestringtype;
            st_widestring:    elemdef := cwidestringtype;
            st_shortstring:   elemdef := cshortstringtype;
            else              elemdef := getansistringdef;
          end
        else if is_char(arrconstr.left.resultdef) or
                is_conststring_array(arrconstr.left.resultdef) then
          elemdef := getansistringdef
        else if is_boolean(arrconstr.left.resultdef) then
          elemdef := pasbool8type
        else if is_integer(arrconstr.left.resultdef) then
          elemdef := s32inttype
        else if is_enum(arrconstr.left.resultdef) then
          elemdef := arrconstr.left.resultdef
        else if arrconstr.left.resultdef.typ = floatdef then
          elemdef := s64floattype
        else if arrconstr.left.resultdef.typ = objectdef then
          elemdef := arrconstr.left.resultdef
        else if arrconstr.left.resultdef.typ = pointerdef then
          elemdef := arrconstr.left.resultdef
        else if arrconstr.left.resultdef.typ = variantdef then
          elemdef := cvarianttype
        else
          elemdef := arrconstr.left.resultdef;

        { force every element to elemdef - incompatible elements surface as
          compile errors here, before the cassignment runs }
        arrconstr.force_type(elemdef);

        { build the dynamic array def for the inferred var; cassignmentnode
          routes through typecheck_arrayconstructor_to_dynarray which calls
          setlength + per-element assign at runtime }
        dyndef := carraydef.create(0, -1, sizesinttype);
        include(dyndef.arrayoptions, ado_IsDynamicArray);
        dyndef.elementdef := elemdef;
        result := dyndef;
      end;

    function inline_var_statement : tnode;
      var
        vs             : tabstractnormalvarsym;
        hdef           : tdef;
        initexpr       : tnode;
        i              : longint;
        sc             : TFPObjectList;
        old_block_type : tblock_type;
        statements     : tstatementnode;
        tempnode        : ttempcreatenode;
        tcsym          : tstaticvarsym;
        { destructuring state }
        names : array of string;
        namecount : longint;
        blk : tblocknode;
        laststmt : tstatementnode;
        recdef : trecorddef;
        sym : tsym;
        fieldsyms : array of tfieldvarsym;
        fieldcount : longint;
        j : longint;
        destruct_var : tabstractnormalvarsym;
        { autofree state }
        autofree_active : boolean;
        free_sym        : tsym;
        free_call       : tnode;
        free_block      : tblocknode;
        free_stat       : tstatementnode;
        free_guarded    : tnode;
        chain_block     : tblocknode;
        chain_stat      : tstatementnode;
        declst          : TSymtable;
      begin
        result := nil;
        consume(_VAR);

        { Inline var is only meaningful inside a routine body (localsymtable,
          a block-scope symtable) or in the main program block (staticsymtable
          at main_program_level). }
        declst := inline_decl_symtable;
        if not (declst.symtabletype in [localsymtable,staticsymtable,blocksymtable]) then
          begin
            Message(parser_e_syntax_error);
            result := cerrornode.create;
            exit;
          end;

        { destructuring: var (name1, name2, ...) := tuple_expr }
        if current_scanner.token = _LKLAMMER then
          begin
            consume(_LKLAMMER);
            namecount := 0;
            setlength(names, 4);
            repeat
              if current_scanner.token <> _ID then
                begin
                  Message(parser_e_syntax_error);
                  result := cerrornode.create;
                  exit;
                end;
              if namecount >= length(names) then
                setlength(names, length(names)*2);
              names[namecount] := current_scanner.orgpattern;
              inc(namecount);
              consume(_ID);
            until not try_to_consume(_COMMA);
            consume(_RKLAMMER);
            consume(_ASSIGNMENT);
            initexpr := expr(true);
            do_typecheckpass(initexpr);
            if not assigned(initexpr.resultdef) or
               (initexpr.resultdef.typ <> recorddef) then
              begin
                Message(parser_e_illegal_expression);
                initexpr.free;
                result := cerrornode.create;
                exit;
              end;
            recdef := trecorddef(initexpr.resultdef);
            fieldcount := 0;
            setlength(fieldsyms, recdef.symtable.symlist.count);
            for j := 0 to recdef.symtable.symlist.count-1 do
              begin
                sym := tsym(recdef.symtable.symlist[j]);
                if sym.typ = fieldvarsym then
                  begin
                    fieldsyms[fieldcount] := tfieldvarsym(sym);
                    inc(fieldcount);
                  end;
              end;
            setlength(fieldsyms, fieldcount);
            if namecount <> fieldcount then
              begin
                Message(parser_e_illegal_expression);
                initexpr.free;
                result := cerrornode.create;
                exit;
              end;
            { temp := initexpr; var_i := temp.f_i }
            blk := internalstatements(laststmt);
            tempnode := ctempcreatenode.create(recdef, recdef.size, tt_persistent, false);
            addstatement(laststmt, tempnode);
            addstatement(laststmt,
              cassignmentnode.create(ctemprefnode.create(tempnode), initexpr));
            for j := 0 to namecount-1 do
              begin
                if names[j]='_' then
                  continue;
                destruct_var := create_inline_var_sym(names[j], fieldsyms[j].vardef);
                destruct_var.register_sym;
                declst.insertsym(destruct_var);
                destruct_var.varstate := vs_initialised;
                if destruct_var.typ = staticvarsym then
                  cnodeutils.insertbssdata(tstaticvarsym(destruct_var));
                addstatement(laststmt,
                  cassignmentnode.create(
                    cloadnode.create(destruct_var, destruct_var.owner),
                    csubscriptnode.create(fieldsyms[j], ctemprefnode.create(tempnode))));
              end;
            addstatement(laststmt, ctempdeletenode.create_normal_temp(tempnode));
            result := blk;
            exit;
          end;

        if current_scanner.token <> _ID then
          begin
            consume(_ID);   { generate the expected-identifier error }
            result := cerrornode.create;
            exit;
          end;

        sc := TFPObjectList.create(false);
        old_block_type := block_type;
        try
          { --- collect one or more variable names -------------------------------- }
          repeat
            vs := create_inline_var_sym(current_scanner.orgpattern, generrordef);
            vs.register_sym;
            declst.insertsym(vs);
            sc.add(vs);
            consume(_ID);
          until not try_to_consume(_COMMA);

          { --- now parse the type or initialiser --------------------------------- }
          if current_scanner.token = _COLON then
            begin
              { Explicit type:  var x [, y, ...] : Type [:= expr] }
              { set block_type before consuming `:` so a following `^T...` is
                tokenised as pointer type, not as a control-character literal }
              block_type := bt_var_type;
              consume(_COLON);
              read_anon_type(hdef, false, nil);
              block_type := bt_var;
              // anonymous function reference type: convert it to its
              // interface representation like regular var sections do
              if (hdef.typ=procvardef) and (hdef.typesym=nil) and
                 (po_is_function_ref in tprocvardef(hdef).procoptions) then
                begin
                  if not (m_function_references in current_settings.modeswitches) and
                     not (po_is_block in tprocvardef(hdef).procoptions) then
                    Message(sym_e_error_in_type_def)
                  else
                    begin
                      adjust_funcref(hdef,nil,nil);
                      if current_scanner.replay_stack_depth=0 then
                        hdef.register_def;
                    end;
                end;
              for i := 0 to sc.count - 1 do
                begin
                  tabstractnormalvarsym(sc[i]).vardef := hdef;
                  if tsym(sc[i]).typ = staticvarsym then
                    cnodeutils.insertbssdata(tstaticvarsym(sc[i]));
                end;

              if try_to_consume(_ASSIGNMENT) then
                begin
                  { Only one variable may be initialised at a time. }
                  if (sc.count > 1) and
                     not(m_multi_var_init in current_settings.modeswitches) then
                    Message(parser_e_initialized_only_one_var);
                  block_type := old_block_type;
                  { Aggregate literal (array/record) init: reuse the typed
                    constant parser via a hidden static sym, then copy it
                    into the inline var at the declaration point. The plain
                    expression parser cannot handle (a, b, c) notation. }
                  if (sc.count = 1) and
                     (current_scanner.token = _LKLAMMER) and
                     ((hdef.typ = arraydef) or (hdef.typ = recorddef)) then
                    begin
                      tcsym := cstaticvarsym.create('$inlinetc_'+tsym(sc[0]).realname,
                                                    vs_const, hdef, []);
                      include(tcsym.symoptions, sp_internal);
                      declst.insertsym(tcsym);
                      read_typed_const(current_asmdata.asmlists[al_typedconsts],
                                       tcsym, false, false);
                      tabstractnormalvarsym(sc[0]).varstate := vs_initialised;
                      result := cassignmentnode.create(
                        cloadnode.create(tsym(sc[0]), tsym(sc[0]).owner),
                        cloadnode.create(tcsym, tcsym.owner));
                      exit;
                    end;
                  initexpr := expr(true);
                  if sc.count = 1 then
                    begin
                      tabstractnormalvarsym(sc[0]).varstate := vs_initialised;
                      result := cassignmentnode.create(
                        cloadnode.create(tsym(sc[0]), tsym(sc[0]).owner),
                        initexpr);
                    end
                  else
                    begin
                      { multi-var: temp := expr; a := temp; b := temp; }
                      do_typecheckpass(initexpr);
                      result := internalstatements(statements);
                      tempnode := ctempcreatenode.create(hdef, hdef.size, tt_persistent, true);
                      addstatement(statements, tempnode);
                      addstatement(statements, cassignmentnode.create(
                        ctemprefnode.create(tempnode), initexpr));
                      for i := 0 to sc.count - 1 do
                        begin
                          tabstractnormalvarsym(sc[i]).varstate := vs_initialised;
                          addstatement(statements, cassignmentnode.create(
                            cloadnode.create(tsym(sc[i]), tsym(sc[i]).owner),
                            ctemprefnode.create(tempnode)));
                        end;
                      addstatement(statements, ctempdeletenode.create(tempnode));
                    end;
                end
              else
                begin
                  { no initializer: re-initialize managed vars at the
                    declaration point, so a loop pass over the declaration
                    gets a fresh value instead of the previous iteration's }
                  result := nil;
                  for i := 0 to sc.count - 1 do
                    if is_managed_type(tabstractnormalvarsym(sc[i]).vardef) and
                       is_valid_for_default(tabstractnormalvarsym(sc[i]).vardef) then
                      begin
                        if not assigned(result) then
                          result := internalstatements(statements);
                        addstatement(statements, cassignmentnode.create(
                          cloadnode.create(tsym(sc[i]), tsym(sc[i]).owner),
                          cinlinenode.create(in_default_x, false,
                            ctypenode.create(tabstractnormalvarsym(sc[i]).vardef))));
                      end;
                  if not assigned(result) then
                    result := cnothingnode.create;
                end;
            end
          else if current_scanner.token = _ASSIGNMENT then
            begin
              { Type inference:  var x := expr or var x, y := expr }
              if (sc.count > 1) and
                 not(m_multi_var_init in current_settings.modeswitches) then
                Message(parser_e_initialized_only_one_var);
              consume(_ASSIGNMENT);
              { optional `autofree` modifier on the init
                expression. Sets up an automatic .Free at scope exit. }
              autofree_active := false;
              if current_scanner.token = _AUTOFREE then
                begin
                  consume(_AUTOFREE);
                  autofree_active := (sc.count = 1);
                  if not autofree_active then
                    Message(parser_e_initialized_only_one_var);
                end;
              vs := tabstractnormalvarsym(sc[0]);
              { Restore block_type before parsing the expression so that the
                scanner does not misinterpret keywords in the RHS. }
              block_type := old_block_type;
              initexpr := expr(true);
              do_typecheckpass(initexpr);
              hdef := initexpr.resultdef;
              { unleashed: array literal `[...]` -> infer element type from the
                first non-nil element's category, force every element to that
                type (compile error on mismatch), and wrap the constructor's
                static carrier into a proper `array of T` dynamic def for the
                inferred var. Diverges from the legacy fall-through behaviour
                that would silently produce a static array of the first
                element's exact byte width and truncate everything else. }
              if (m_unleashed in current_settings.modeswitches) and
                 assigned(initexpr) and
                 (initexpr.nodetype = arrayconstructorn) and
                 assigned(hdef) and (hdef.typ = arraydef) and
                 (ado_IsConstructor in tarraydef(hdef).arrayoptions) and
                 not (ado_IsDynamicArray in tarraydef(hdef).arrayoptions) then
                hdef := unleashed_infer_array_literal(tarrayconstructornode(initexpr));
              if not assigned(hdef) or (hdef = generrordef) then
                begin
                  { Type inference failed – keep error def on the sym so that
                    subsequent uses at least get a sensible error, not an ICE. }
                  initexpr.free;
                  result := cerrornode.create;
                end
              else
                begin
                  { String literal constants get type array[0..n] of char
                    (cst_conststring).  Promote to the default string type
                    so that comparisons and assignments behave as expected.
                    Single char literals are also promoted to string so
                    that var s := 'x' behaves consistently with var s := 'xx'. }
                  if is_conststring_array(hdef) or
                     (not(nf_explicit in initexpr.flags) and is_char(hdef)) then
                    begin
                      if m_default_unicodestring in current_settings.modeswitches then
                        hdef := cunicodestringtype
                      else if m_default_ansistring in current_settings.modeswitches then
                        hdef := getansistringdef
                      else
                        hdef := cshortstringtype;
                    end;
                  { For inline var declarations, promote sub-32-bit integer
                    types to LongInt so that e.g. var i := 10 yields a 4-byte
                    signed integer instead of a signed byte. Skip promotion
                    when the user wrote an explicit typecast (e.g. byte(10))
                    - detected via nf_explicit flag preserved through
                    constant folding by the typeconv node. }
                  if not(nf_explicit in initexpr.flags) and is_integer(hdef) and
                     (torddef(hdef).ordtype in [s8bit,u8bit,s16bit,u16bit]) then
                    hdef := s32inttype;
                  { undo native-int promotion of 32-bit arithmetic so the
                    inferred type matches 32-bit targets }
                  hdef := unleashed_infer_natural_intdef(initexpr, hdef);
                  for i := 0 to sc.count - 1 do
                    begin
                      tabstractnormalvarsym(sc[i]).vardef := hdef;
                      tabstractnormalvarsym(sc[i]).varstate := vs_initialised;
                      if tsym(sc[i]).typ = staticvarsym then
                        cnodeutils.insertbssdata(tstaticvarsym(sc[i]));
                    end;
                  if sc.count = 1 then
                    begin
                      if autofree_active then
                        begin
                          { autofree requires class type derived from TObject. }
                          if not (is_class(hdef) and def_is_related(tobjectdef(hdef), class_tobject)) then
                            begin
                              Message(parser_e_autofree_requires_class);
                              result := cassignmentnode.create(
                                cloadnode.create(vs, vs.owner),
                                initexpr);
                            end
                          else
                            begin
                              { build chain: x := initexpr; defer x.Free; }
                              free_sym := search_struct_member(tobjectdef(hdef), 'FREE');
                              if not assigned(free_sym) or (free_sym.typ <> procsym) then
                                begin
                                  Message(parser_e_autofree_requires_class);
                                  result := cassignmentnode.create(
                                    cloadnode.create(vs, vs.owner),
                                    initexpr);
                                end
                              else
                                begin
                                  { build defer body: if x<>nil then begin x.Free; x:=nil; end
                                    Guards against double-free if user manually calls x.Free
                                    earlier in the scope. }
                                  free_call := ccallnode.create(nil, tprocsym(free_sym), free_sym.owner,
                                                                cloadnode.create(vs, vs.owner), [], nil);
                                  free_block := internalstatements(free_stat);
                                  addstatement(free_stat, free_call);
                                  addstatement(free_stat, cassignmentnode.create(
                                    cloadnode.create(vs, vs.owner),
                                    cnilnode.create));
                                  free_guarded := cifnode.create(
                                    caddnode.create(unequaln,
                                      cloadnode.create(vs, vs.owner),
                                      cnilnode.create),
                                    free_block,
                                    nil);
                                  chain_block := internalstatements(chain_stat);
                                  Include(chain_block.blocknodeflags, bnf_defer_transparent);
                                  addstatement(chain_stat, cassignmentnode.create(
                                    cloadnode.create(vs, vs.owner),
                                    initexpr));
                                  addstatement(chain_stat, cdefernode.create(free_guarded));
                                  result := chain_block;
                                end;
                            end;
                        end
                      else
                        result := cassignmentnode.create(
                          cloadnode.create(vs, vs.owner),
                          initexpr);
                    end
                  else
                    begin
                      result := internalstatements(statements);
                      tempnode := ctempcreatenode.create(hdef, hdef.size, tt_persistent, true);
                      addstatement(statements, tempnode);
                      addstatement(statements, cassignmentnode.create(
                        ctemprefnode.create(tempnode), initexpr));
                      for i := 0 to sc.count - 1 do
                        addstatement(statements, cassignmentnode.create(
                          cloadnode.create(tsym(sc[i]), tsym(sc[i]).owner),
                          ctemprefnode.create(tempnode)));
                      addstatement(statements, ctempdeletenode.create(tempnode));
                    end;
                end;
            end
          else
            begin
              { Neither ':' nor ':=' – syntax error. }
              Message(parser_e_syntax_error);
              result := cerrornode.create;
            end;
        finally
          block_type := old_block_type;
          sc.free;
        end;
      end;


    { Parse an inline constant declaration of the form:
        const name = expr
        const name : Type = expr
      Scoped like inline vars: the symbol lands in the current block-scope
      symtable. The typed form creates the usual typed-constant storage. }
    function inline_const_statement : tnode;
      var
        orgname : TIDString;
        filepos : tfileposinfo;
        csym : tconstsym;
        vsym : tstaticvarsym;
        hdef : tdef;
        nt : tnodetype;
        old_block_type : tblock_type;
        varspez : tvarspez;
        asmtype : tasmlisttype;
        declst : TSymtable;
      begin
        result:=nil;
        consume(_CONST);
        declst:=inline_decl_symtable;
        if not (declst.symtabletype in [localsymtable,staticsymtable,blocksymtable]) then
          begin
            Message(parser_e_syntax_error);
            result:=cerrornode.create;
            exit;
          end;
        if current_scanner.token<>_ID then
          begin
            consume(_ID);
            result:=cerrornode.create;
            exit;
          end;
        orgname:=current_scanner.orgpattern;
        filepos:=current_tokenpos;
        consume(_ID);
        old_block_type:=block_type;
        block_type:=bt_const;
        if try_to_consume(_EQ) then
          begin
            csym:=readconstant(orgname,filepos,nt);
            if assigned(csym) then
              begin
                csym.register_sym;
                declst.insertsym(csym);
                result:=cnothingnode.create;
              end
            else
              result:=cerrornode.create;
          end
        else if current_scanner.token=_COLON then
          begin
            { typed constant - static storage scoped to the block }
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
            vsym:=cstaticvarsym.create(orgname,varspez,hdef,[]);
            declst.insertsym(vsym);
            vsym.register_sym;
            consume(_EQ);
            { parse_tail=false: the statement loop owns the semicolon }
            read_typed_const(current_asmdata.asmlists[asmtype],vsym,false,false);
            result:=cnothingnode.create;
          end
        else
          begin
            { neither '=' nor ':' - generate the expected-token error }
            consume(_EQ);
            result:=cerrornode.create;
          end;
        block_type:=old_block_type;
      end;


    { Parse an inline static declaration of the form:
        static name : Type
        static name : Type := expr
        static name := expr   (type inference)
      The static var lives in the data segment (program lifetime) but is
      scoped to the declaring block. With an initializer, a one-shot guard
      flag ensures the expression is evaluated only on the first reach;
      if it raises, the flag stays set and the variable keeps its zero
      bytes - no retry. Enabled by modeswitch InlineStatic. }
    function inline_static_statement(is_threadvar:boolean) : tnode;
      var
        name           : TIDString;
        hdef           : tdef;
        initexpr       : tnode;
        sym            : tstaticvarsym;
        guardsym       : tstaticvarsym;
        init_block     : tblocknode;
        init_stat      : tstatementnode;
        old_block_type : tblock_type;
        old_writable   : boolean;
        already_recording : boolean;
        tokenbuf       : tdynamicarray;
        storetokenpos,
        filepos        : tfileposinfo;
        kw_label       : ansistring;
        guard_prefix   : ansistring;
        declst         : TSymtable;
      begin
        if is_threadvar then
          begin
            kw_label := 'threadstatic';
            guard_prefix := '$threadstatic_guard_';
          end
        else
          begin
            kw_label := 'static';
            guard_prefix := '$static_guard_';
          end;
        result := nil;
        consume(_ID);
        if (not assigned(current_procinfo)) or
           (current_procinfo.procdef.localst.symtablelevel<normal_function_level) then
          begin
            Comment(V_Error,kw_label+' is only allowed in function/procedure bodies');
            consume_all_until(_SEMICOLON);
            result := cerrornode.create;
            exit;
          end;
        if current_scanner.token<>_ID then
          begin
            consume(_ID);
            result := cerrornode.create;
            exit;
          end;
        name := current_scanner.orgpattern;
        filepos := current_tokenpos;
        consume(_ID);
        hdef := nil;
        initexpr := nil;
        tokenbuf := nil;
        already_recording := false;
        old_block_type := block_type;
        try
          if current_scanner.token=_COLON then
            begin
              block_type := bt_var_type;
              consume(_COLON);
              read_anon_type(hdef,false,nil);
              block_type := bt_var;
              if try_to_consume(_ASSIGNMENT) then
                begin
                  block_type := old_block_type;
                  { record tokens around expr() so a compile-time-constant
                    initializer can be replayed straight into the typed
                    constant builder; runtime expressions throw the buffer
                    away and fall through to the guarded init }
                  already_recording := current_scanner.is_recording_tokens;
                  tokenbuf := tdynamicarray.create(256);
                  if not already_recording then
                    current_scanner.startrecordtokens(tokenbuf);
                  initexpr := expr(true);
                  if not already_recording then
                    current_scanner.stoprecordtokens;
                  do_typecheckpass(initexpr);
                end;
            end
          else if current_scanner.token=_ASSIGNMENT then
            begin
              consume(_ASSIGNMENT);
              block_type := old_block_type;
              already_recording := current_scanner.is_recording_tokens;
              tokenbuf := tdynamicarray.create(256);
              if not already_recording then
                current_scanner.startrecordtokens(tokenbuf);
              initexpr := expr(true);
              if not already_recording then
                current_scanner.stoprecordtokens;
              do_typecheckpass(initexpr);
              if (not assigned(initexpr.resultdef)) or (initexpr.resultdef=generrordef) then
                begin
                  Comment(V_Error,'cannot infer type for inline '+kw_label+' declaration');
                  initexpr.free;
                  tokenbuf.free;
                  result := cerrornode.create;
                  exit;
                end;
              hdef := initexpr.resultdef;
              { same inference rules as inline var: char promotes to default
                string type, sub-32-bit integers promote to LongInt }
              if is_conststring_array(hdef) or
                 (not(nf_explicit in initexpr.flags) and is_char(hdef)) then
                begin
                  if m_default_unicodestring in current_settings.modeswitches then
                    hdef := cunicodestringtype
                  else if m_default_ansistring in current_settings.modeswitches then
                    hdef := getansistringdef
                  else
                    hdef := cshortstringtype;
                end;
              if not(nf_explicit in initexpr.flags) and is_integer(hdef) and
                 (torddef(hdef).ordtype in [s8bit,u8bit,s16bit,u16bit]) then
                hdef := s32inttype;
              hdef := unleashed_infer_natural_intdef(initexpr, hdef);
            end
          else
            begin
              Message(parser_e_syntax_error);
              result := cerrornode.create;
              exit;
            end;
          storetokenpos := current_tokenpos;
          current_tokenpos := filepos;
          declst := inline_decl_symtable;
          sym := cstaticvarsym.create(name,vs_value,hdef,[]);
          sym.visibility := declst.currentvisibility;
          sym.varstate := vs_initialised;
          declst.insertsym(sym);
          if is_threadvar then
            begin
              { sym lives in the function's localst for proper scoping;
                register it on the module-level list so InsertThreadvars
                walks it into FPC_THREADVARTABLES alongside top-level
                threadvars - without that step the BSS slot stays at a
                zero TLS handle and FPC_THREADVAR_RELOCATE returns garbage }
              include(sym.varoptions,vo_is_thread_var);
              if not assigned(current_module.extra_threadvar_syms) then
                current_module.extra_threadvar_syms := tfplist.create;
              current_module.extra_threadvar_syms.add(sym);
            end;
          sym.register_sym;
          current_tokenpos := storetokenpos;
          { the typed-constant data-segment fast path applies only to
            regular static - threadstatic must run the assignment for
            each thread because FPC's TLS layout has no per-thread
            template support, so we always take the guarded init path
            (guard itself is also a threadvar, giving one guard per
            thread) }
          if (not is_threadvar) and assigned(initexpr) and is_constnode(initexpr) then
            begin
              { compile-time constant initializer: drop the parsed tree and
                replay the recorded tokens through read_typed_const, which
                materializes the value in the data segment. No guard, no
                BSS slot, no runtime branch on every call. Force writeable
                typed constants in this scope so the variable stays
                assignable; restore the flag on exit. }
              initexpr.free;
              old_writable := cs_typed_const_writable in current_settings.localswitches;
              include(current_settings.localswitches,cs_typed_const_writable);
              try
                tokenbuf.seek(0);
                current_scanner.startreplaytokens(tokenbuf,false);
                read_typed_const(current_asmdata.asmlists[al_typedconsts],sym,false,false);
              finally
                if not old_writable then
                  exclude(current_settings.localswitches,cs_typed_const_writable);
              end;
              result := cnothingnode.create;
            end
          else
            begin
              { mark the static var as typed-const so DFA treats the BSS-zero
                bytes as a valid initial value and does not warn about reads
                before the guard fires }
              include(sym.varoptions,vo_is_typed_const);
              cnodeutils.insertbssdata(sym);
              if assigned(initexpr) and is_zerobytes_const(initexpr) then
                begin
                  { the initializer folds to all-zero bytes, which the BSS
                    zero-init already provides (per thread for threadstatic),
                    so neither a guard nor an assignment is needed }
                  initexpr.free;
                  result := cnothingnode.create;
                end
              else if assigned(initexpr) then
                begin
                  { hidden Boolean guard, lives next to the static var in BSS;
                    the generated code sets it true before evaluating the init
                    expr, so a raised exception leaves the variable on its zero
                    bytes and subsequent calls skip the init block. Marked
                    vo_is_internal so DFA skips it entirely. For threadstatic
                    the guard is also a threadvar so each thread runs init
                    independently on its first reach. }
                  guardsym := cstaticvarsym.create(guard_prefix+name,vs_value,pasbool8type,[]);
                  include(guardsym.symoptions,sp_internal);
                  include(guardsym.varoptions,vo_is_internal);
                  include(guardsym.varoptions,vo_is_typed_const);
                  declst.insertsym(guardsym);
                  if is_threadvar then
                    begin
                      include(guardsym.varoptions,vo_is_thread_var);
                      current_module.extra_threadvar_syms.add(guardsym);
                    end;
                  guardsym.register_sym;
                  guardsym.varstate := vs_initialised;
                  cnodeutils.insertbssdata(guardsym);
                  init_block := internalstatements(init_stat);
                  addstatement(init_stat,cassignmentnode.create(
                    cloadnode.create(guardsym,guardsym.owner),
                    cordconstnode.create(1,pasbool8type,false)));
                  addstatement(init_stat,cassignmentnode.create(
                    cloadnode.create(sym,sym.owner),
                    initexpr));
                  result := cifnode.create(
                    cnotnode.create(cloadnode.create(guardsym,guardsym.owner)),
                    init_block,
                    nil);
                end
              else
                result := cnothingnode.create;
            end;
          if assigned(tokenbuf) then
            tokenbuf.free;
        finally
          block_type := old_block_type;
        end;
      end;


    { Generate a case statement for goto label[variable_expr].
      The sentinel labelsym holds the range lo..hi; we build:
        case expr of
          lo: goto LB$lo;
          lo+1: goto LB$lo+1;
          ...
          hi: goto LB$hi;
        end;
      This leverages FPC's existing case node which generates efficient
      jump tables on x86. }
    function generate_arraylabel_goto(sentinel: tlabelsym; indexexpr: tnode): tnode;
      var
        caseexpr   : tnode;
        casenode   : tcasenode;
        i          : longint;
        looplo,
        loophi     : longint;
        blockid    : longint;
        labsym     : tsym;
        labsymtable: TSymtable;
        s          : TIDString;
        g          : tgotonode;
        idxlo,
        idxhi      : TConstExprInt;
        h          : int64;

      function const_to_longint_clamped(const v: TConstExprInt): longint;
        begin
          h:=int64(v);
          if h<low(longint) then
            result:=low(longint)
          else if h>high(longint) then
            result:=high(longint)
          else
            result:=longint(h);
        end;
      begin
        if length(sentinel.arraylabel_strings)>0 then
          begin
            { String array labels don't support variable index }
            Message(type_e_ordinal_expr_expected);
            indexexpr.free;
            result:=cerrornode.create;
            exit;
          end;
        { Ensure index expression is fully typechecked and marked as read }
        caseexpr:=indexexpr;
        if not assigned(caseexpr.resultdef) then
          do_typecheckpass(caseexpr);
        set_varstate(caseexpr,vs_read,[vsf_must_be_valid]);
        if not is_ordinal(caseexpr.resultdef) then
          begin
            Message(type_e_ordinal_expr_expected);
            caseexpr.free;
            result:=cerrornode.create;
            exit;
          end;
        { Build case node }
        casenode:=ccasenode.create(caseexpr);
        include(casenode.flags,nf_internal);
        // the dispatch index is dense and unpredictable, one indirect jump
        // beats a compare chain even for a handful of labels
        casenode.prefer_jumptable:=true;
        looplo:=sentinel.arraylabel_lo;
        loophi:=sentinel.arraylabel_hi;
        { Restrict generated jump targets to values representable by the
          index expression type, so that unreachable labels are not treated
          as used. }
        getrange(caseexpr.resultdef,idxlo,idxhi);
        i:=const_to_longint_clamped(idxlo);
        if i>looplo then
          looplo:=i;
        i:=const_to_longint_clamped(idxhi);
        if i<loophi then
          loophi:=i;
        blockid:=0;
        for i:=looplo to loophi do
          begin
            s:=sentinel.name+'$'+tostr(i);
            if searchsym(s,labsym,labsymtable) and (labsym.typ=labelsym) then
              begin
                casenode.addlabel(blockid,i,i);
                g:=cgotonode.create(tlabelsym(labsym));
                g.allow_undefined_target:=true;
                casenode.addblock(blockid,g);
                inc(blockid);
              end;
          end;
        { the dispatch is baked from the range known here; freeze the family
          so later additions outside it are rejected instead of being
          silently unreachable }
        sentinel.arraylabel_dispatched:=true;
        result:=casenode;
      end;

    { Runtime address counterpart of generate_arraylabel_goto: builds
        case expr of
          lo: tmp := @LB$lo;
          ...
          hi: tmp := @LB$hi;
        else tmp := nil;
      and yields tmp as the expression value. The caller in factor wraps
      the result of @<factor> in an addrnode, so the block is returned
      behind a derefnode which that addrnode cancels out. }
    function generate_arraylabel_addr(sentinel: tlabelsym; indexexpr: tnode): tnode;
      var
        block      : tnode;
        statements : tstatementnode;
        resultvar  : ttempcreatenode;
        casenode   : tcasenode;
        i          : longint;
        looplo,
        loophi     : longint;
        blockid    : longint;
        labsym     : tsym;
        labsymtable: TSymtable;
        s          : TIDString;
        idxlo,
        idxhi      : TConstExprInt;
        h          : int64;

      function const_to_longint_clamped(const v: TConstExprInt): longint;
        begin
          h:=int64(v);
          if h<low(longint) then
            result:=low(longint)
          else if h>high(longint) then
            result:=high(longint)
          else
            result:=longint(h);
        end;
      begin
        if length(sentinel.arraylabel_strings)>0 then
          begin
            { String array labels don't support variable index }
            Message(type_e_ordinal_expr_expected);
            indexexpr.free;
            result:=cerrornode.create;
            exit;
          end;
        if not assigned(indexexpr.resultdef) then
          do_typecheckpass(indexexpr);
        set_varstate(indexexpr,vs_read,[vsf_must_be_valid]);
        if not is_ordinal(indexexpr.resultdef) then
          begin
            Message(type_e_ordinal_expr_expected);
            indexexpr.free;
            result:=cerrornode.create;
            exit;
          end;
        { a runtime index needs a declared range to select from }
        if sentinel.arraylabel_lo>sentinel.arraylabel_hi then
          begin
            Message(sym_e_label_not_found);
            indexexpr.free;
            result:=cerrornode.create;
            exit;
          end;
        block:=internalstatements(statements);
        resultvar:=ctempcreatenode.create(charpointertype,charpointertype.size,tt_persistent,true);
        addstatement(statements,resultvar);
        casenode:=ccasenode.create(indexexpr);
        include(casenode.flags,nf_internal);
        looplo:=sentinel.arraylabel_lo;
        loophi:=sentinel.arraylabel_hi;
        { restrict to values representable by the index expression type }
        getrange(indexexpr.resultdef,idxlo,idxhi);
        i:=const_to_longint_clamped(idxlo);
        if i>looplo then
          looplo:=i;
        i:=const_to_longint_clamped(idxhi);
        if i<loophi then
          loophi:=i;
        blockid:=0;
        for i:=looplo to loophi do
          begin
            s:=sentinel.name+'$'+tostr(i);
            if searchsym(s,labsym,labsymtable) and (labsym.typ=labelsym) then
              begin
                casenode.addlabel(blockid,i,i);
                { the member address is materialized, so the member must be
                  defined somewhere: count it as used to get a hard error
                  for a missing definition }
                tlabelsym(labsym).used:=true;
                casenode.addblock(blockid,
                  cassignmentnode.create(ctemprefnode.create(resultvar),
                    ctypeconvnode.create_internal(
                      caddrnode.create(cloadnode.create(labsym,labsymtable)),
                      charpointertype)));
                inc(blockid);
              end;
          end;
        { an index with no member yields nil }
        casenode.elseblock:=cassignmentnode.create(ctemprefnode.create(resultvar),
          ctypeconvnode.create_internal(cnilnode.create,charpointertype));
        addstatement(statements,casenode);
        addstatement(statements,ctempdeletenode.create_normal_temp(resultvar));
        addstatement(statements,ctemprefnode.create(resultvar));
        result:=cderefnode.create(block);
      end;

    function generate_pointer_goto(pointerexpr: tnode): tnode;
      var
        statements : tstatementnode;
        tempnode   : ttempcreatenode;
        i          : longint;
        sym        : tsym;
        labsym     : tlabelsym;
        cmp        : tnode;
        gotostmt   : tnode;
      begin
        if not assigned(pointerexpr.resultdef) then
          do_typecheckpass(pointerexpr);
        if not assigned(pointerexpr.resultdef) then
          begin
            pointerexpr.free;
            result:=cerrornode.create;
            exit;
          end;
        set_varstate(pointerexpr,vs_read,[vsf_must_be_valid]);
        if not is_pointer(pointerexpr.resultdef) then
          begin
            Message1(type_e_pointer_type_expected,pointerexpr.resultdef.typename);
            pointerexpr.free;
            result:=cerrornode.create;
            exit;
          end;
        inserttypeconv(pointerexpr,voidcodepointertype);
        do_typecheckpass(pointerexpr);

        result:=internalstatements(statements);
        tempnode:=ctempcreatenode.create_value(
          voidcodepointertype,
          voidcodepointertype.size,
          tt_persistent,
          true,
          pointerexpr
        );
        addstatement(statements,tempnode);

        for i:=0 to current_procinfo.procdef.localst.SymList.Count-1 do
          begin
            sym:=tsym(current_procinfo.procdef.localst.SymList[i]);
            if not assigned(sym) or
               (sym.typ<>labelsym) then
              continue;

            labsym:=tlabelsym(sym);
            if labsym.arraylabel then
              continue;

            cmp:=caddnode.create(equaln,
              ctemprefnode.create(tempnode),
              caddrnode.create(cloadnode.create(labsym,labsym.owner))
            );
            gotostmt:=cgotonode.create(labsym);
            tgotonode(gotostmt).labelsym:=labsym;
            labsym.used:=true;
            addstatement(statements,cifnode.create(cmp,gotostmt,nil));
          end;

        addstatement(statements,ctempdeletenode.create_normal_temp(tempnode));
      end;

    { Multi-variable assignment: a, b, c := expr
      first_target is the already-parsed first LHS node. }
    function multi_var_assign(first_target: tnode): tnode;
      var
        targets    : TFPObjectList;
        initexpr   : tnode;
        statements : tstatementnode;
        tempnode    : ttempcreatenode;
        i          : longint;
      begin
        targets:=TFPObjectList.create(false);
        try
          targets.add(first_target);
          { use comp_expr so that := is NOT consumed as part of the target }
          while try_to_consume(_COMMA) do
            targets.add(comp_expr([ef_accept_equal]));
          consume(_ASSIGNMENT);
          initexpr:=expr(true);
          do_typecheckpass(initexpr);
          result:=internalstatements(statements);
          tempnode:=ctempcreatenode.create(initexpr.resultdef,initexpr.resultdef.size,tt_persistent,true);
          addstatement(statements,tempnode);
          addstatement(statements,cassignmentnode.create(ctemprefnode.create(tempnode),initexpr));
          for i:=0 to targets.count-1 do
            addstatement(statements,cassignmentnode.create(tnode(targets[i]),ctemprefnode.create(tempnode)));
          addstatement(statements,ctempdeletenode.create(tempnode));
        finally
          targets.free;
        end;
      end;

    { Detects ( target, target, ... ) := tuple_expr destructuring assignment
      at the start of a statement. Uses scanner token recording to peek.
      Returns a block of per-field assignments if the pattern matches,
      otherwise nil with scanner state restored via replay. }
    function try_tuple_destructure_assign : tnode;
      var
        buf : tdynamicarray;
        targets : array of tnode;
        targetcount : longint;
        depth,
        commas : longint;
        match : boolean;
        initexpr : tnode;
        recdef : trecorddef;
        sym : tsym;
        fieldsyms : array of tfieldvarsym;
        fieldcount : longint;
        i : longint;
        tempnode : ttempcreatenode;
        blk : tblocknode;
        laststmt : tstatementnode;
      begin
        result:=nil;
        if current_scanner.is_recording_tokens then
          exit;
        buf:=tdynamicarray.create(64);
        current_scanner.startrecordtokens(buf);
        consume(_LKLAMMER);
        { scan to the matching ) without parsing: targets may be any
          assignable expression (a[i], r.f, p^), so only bracket depth and
          top-level commas matter here }
        depth:=0;
        commas:=0;
        match:=false;
        repeat
          case current_scanner.token of
            _LKLAMMER,_LECKKLAMMER:
              inc(depth);
            _RKLAMMER,_RECKKLAMMER:
              begin
                if depth=0 then
                  begin
                    match:=current_scanner.token=_RKLAMMER;
                    break;
                  end;
                dec(depth);
              end;
            _COMMA:
              if depth=0 then
                inc(commas);
            _ASSIGNMENT,_SEMICOLON,_END,_EOF:
              break;
          end;
          consume(current_scanner.token);
        until false;
        if match then
          begin
            consume(_RKLAMMER);
            match:=(commas>0) and (current_scanner.token=_ASSIGNMENT);
          end;
        current_scanner.stoprecordtokens;
        current_scanner.startreplaytokens(buf,false);
        if not match then
          exit;

        consume(_LKLAMMER);
        setlength(targets,commas+1);
        targetcount:=0;
        repeat
          if (current_scanner.token=_ID) and (current_scanner.orgpattern='_') then
            begin
              consume(_ID);
              targets[targetcount]:=nil;
            end
          else
            targets[targetcount]:=comp_expr([ef_accept_equal]);
          inc(targetcount);
        until not try_to_consume(_COMMA);
        consume(_RKLAMMER);
        consume(_ASSIGNMENT);

        initexpr:=expr(true);
        do_typecheckpass(initexpr);
        if not assigned(initexpr.resultdef) or
           (initexpr.resultdef.typ<>recorddef) then
          begin
            Message(parser_e_illegal_expression);
            for i:=0 to targetcount-1 do
              targets[i].free;
            initexpr.free;
            result:=cerrornode.create;
            exit;
          end;
        recdef:=trecorddef(initexpr.resultdef);
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
        if targetcount<>fieldcount then
          begin
            Message(parser_e_illegal_expression);
            for i:=0 to targetcount-1 do
              targets[i].free;
            initexpr.free;
            result:=cerrornode.create;
            exit;
          end;
        blk:=internalstatements(laststmt);
        tempnode:=ctempcreatenode.create(recdef,recdef.size,tt_persistent,false);
        addstatement(laststmt,tempnode);
        addstatement(laststmt,
          cassignmentnode.create(ctemprefnode.create(tempnode),initexpr));
        for i:=0 to targetcount-1 do
          begin
            if not assigned(targets[i]) then
              continue;
            if (targets[i].nodetype=loadn) and
               (tloadnode(targets[i]).symtableentry.typ in [localvarsym,staticvarsym,paravarsym]) then
              tabstractnormalvarsym(tloadnode(targets[i]).symtableentry).varstate:=vs_initialised;
            addstatement(laststmt,
              cassignmentnode.create(
                targets[i],
                csubscriptnode.create(fieldsyms[i],ctemprefnode.create(tempnode))));
          end;
        addstatement(laststmt,ctempdeletenode.create_normal_temp(tempnode));
        result:=blk;
      end;

    { peeks whether the token after a leading `sync` identifier can start a
      statement, which makes `sync` the marshalling keyword; before `:=`,
      `(`, `;`, `.` etc. it stays an ordinary identifier, so a user symbol
      named sync keeps resolving. uses scanner token recording like the
      named-tuple peek; when an outer recording is active (generic body),
      falls back to "no user symbol named sync in scope" }
    function sync_keyword_ahead:boolean;
      var
        peekbuf : tdynamicarray;
        srsym : tsym;
        srsymtable : TSymtable;
      begin
        if current_scanner.is_recording_tokens then
          exit(not searchsym('SYNC',srsym,srsymtable));
        peekbuf:=tdynamicarray.create(32);
        current_scanner.startrecordtokens(peekbuf);
        consume(_ID);
        current_scanner.stoprecordtokens;
        result:=current_scanner.token in [_ID,_BEGIN,_IF,_CASE,_FOR,_WHILE,
          _REPEAT,_WITH,_TRY,_RAISE,_GOTO,_INHERITED];
        current_scanner.startreplaytokens(peekbuf,false);
      end;


    function statement : tnode;
      var
         p,
         astatement,
         code       : tnode;
         filepos    : tfileposinfo;
         srsym      : tsym;
         srsymtable : TSymtable;
         labsym     : tlabelsym;
         s          : TIDString;
         labsuffix  : TIDString;
         labisstring: boolean;
         labidx     : longint;
         labcode    : word;
      begin
         filepos:=current_tokenpos;
         code:=nil;
         case current_scanner.token of
            _GOTO :
              begin
                 if not(cs_support_goto in current_settings.moduleswitches) then
                   Message(sym_e_goto_and_label_not_supported);
                 consume(_GOTO);
                 if (current_scanner.token=_INTCONST) or
                    ((current_scanner.token=_ID) and
                     searchsym(current_scanner.pattern,srsym,srsymtable) and
                     (srsym.typ=labelsym)) then
                   begin
                      if current_scanner.token=_ID then
                        consume_sym(srsym,srsymtable)
                      else
                       begin
                         if current_scanner.token<>_INTCONST then
                           internalerror(201008021);

                         { strip leading 0's in iso mode }
                         if (([m_iso,m_extpas]*current_settings.modeswitches)<>[]) then
                           while (length(current_scanner.pattern)>1) and (current_scanner.pattern[1]='0') do
                             delete(current_scanner.pattern,1,1);

                         searchsym(current_scanner.pattern,srsym,srsymtable);
                         if srsym=nil then
                           begin
                             if get_or_create_labelsym(current_scanner.pattern,labsym,srsymtable) then
                               srsym:=labsym
                             else
                               begin
                                 identifier_not_found(current_scanner.pattern);
                                 srsym:=generrorsym;
                                 srsymtable:=nil;
                               end;
                           end;
                         consume(current_scanner.token);
                       end;

                      if srsym.typ<>labelsym then
                        begin
                           Message(sym_e_id_is_no_label_id);
                           code:=cerrornode.create;
                        end
                      else
                        begin
                          { Array label: goto name[index] }
                          if tlabelsym(srsym).arraylabel then
                            begin
                              if current_scanner.token<>_LECKKLAMMER then
                                begin
                                  Message1(sym_e_label_index_expected,srsym.realname);
                                  code:=cerrornode.create;
                                end
                              else
                                begin
                                  consume(_LECKKLAMMER);
                                  if current_scanner.token=_CSTRING then
                                    begin
                                      { Constant string index - direct goto }
                                      s:=srsym.name+'$'+upper(current_scanner.cstringpattern);
                                      consume(_CSTRING);
                                      consume(_RECKKLAMMER);
                                      searchsym(s,srsym,srsymtable);
                                      if (srsym=nil) or (srsym.typ<>labelsym) then
                                        begin
                                          identifier_not_found(s);
                                          srsym:=generrorsym;
                                          srsymtable:=nil;
                                          code:=cerrornode.create;
                                        end;
                                    end
                                  else
                                    begin
                                      { Parse index expression }
                                      p:=expr(true);
                                      consume(_RECKKLAMMER);
                                      do_typecheckpass(p);
                                      if is_constintnode(p) then
                                        begin
                                          { Constant integer index - direct goto, zero overhead }
                                          labidx:=tordconstnode(p).value.svalue;
                                          s:=srsym.name+'$'+tostr(labidx);
                                          p.free;
                                          searchsym(s,srsym,srsymtable);
                                          if (srsym=nil) or (srsym.typ<>labelsym) then
                                            begin
                                              identifier_not_found(s);
                                              srsym:=generrorsym;
                                              srsymtable:=nil;
                                              code:=cerrornode.create;
                                            end;
                                        end
                                      else
                                        begin
                                          { Variable index - generate dispatch for jump.
                                            Requires explicit label declaration with range. }
                                          if tlabelsym(srsym).arraylabel_lo<=tlabelsym(srsym).arraylabel_hi then
                                            code:=generate_arraylabel_goto(tlabelsym(srsym),p)
                                          else
                                            begin
                                              p.free;
                                              Message(sym_e_label_not_found);
                                              code:=cerrornode.create;
                                            end;
                                        end;
                                    end;
                                end;
                            end;

                          if not assigned(code) then
                            begin
                              { goto outside the current scope? }
                              if srsym.owner<>current_procinfo.procdef.localst then
                                begin
                                  { allowed? }
                                  if not(m_non_local_goto in current_settings.modeswitches) then
                                    Message(parser_e_goto_outside_proc);
                                  include(current_procinfo.flags,pi_has_global_goto);
                                  if is_nested_pd(current_procinfo.procdef) then
                                    current_procinfo.set_needs_parentfp(srsym.owner.symtablelevel);
                                end;
                              code:=cgotonode.create(tlabelsym(srsym));
                              tgotonode(code).labelsym:=tlabelsym(srsym);
                              { set flag that this label is used }
                              tlabelsym(srsym).used:=true;
                            end;
                        end;
                   end
                 else if (current_scanner.token=_ID) and
                         not searchsym(current_scanner.pattern,srsym,srsymtable) then
                   begin
                     s:=current_scanner.orgpattern;
                     consume(_ID);
                     if current_scanner.token=_LECKKLAMMER then
                       begin
                         consume(_LECKKLAMMER);
                         labsuffix:='';
                         labisstring:=false;
                         if current_scanner.token=_CSTRING then
                           begin
                             labsuffix:=upper(current_scanner.cstringpattern);
                             labisstring:=true;
                             consume(_CSTRING);
                             consume(_RECKKLAMMER);
                           end
                         else
                           begin
                             p:=expr(true);
                             consume(_RECKKLAMMER);
                             do_typecheckpass(p);
                             if is_constintnode(p) then
                               begin
                                 labidx:=tordconstnode(p).value.svalue;
                                 labsuffix:=tostr(labidx);
                                 p.free;
                                 p:=nil;
                               end
                             else
                               begin
                                 if get_or_create_arraylabelsym(s,labsym,srsymtable) and
                                    (((labsym.arraylabel_lo<=labsym.arraylabel_hi) and not(labisstring)) or
                                     (length(labsym.arraylabel_strings)>0)) then
                                   code:=generate_arraylabel_goto(labsym,p)
                                 else
                                   begin
                                     p.free;
                                     Message(sym_e_label_not_found);
                                     code:=cerrornode.create;
                                   end;
                               end;
                           end;

                         if not assigned(code) then
                           begin
                             if get_or_create_indexed_labelsym(s,labsuffix,labisstring,labidx,labsym,srsymtable) then
                               begin
                                 code:=cgotonode.create(labsym);
                                 tgotonode(code).labelsym:=labsym;
                                 labsym.used:=true;
                               end
                             else
                               begin
                                 Message(sym_e_label_not_found);
                                 code:=cerrornode.create;
                               end;
                           end;
                       end;
                     if not assigned(code) then
                       begin
                         if get_or_create_labelsym(s,labsym,srsymtable) then
                           begin
                             srsym:=labsym;
                             code:=cgotonode.create(tlabelsym(srsym));
                             tgotonode(code).labelsym:=tlabelsym(srsym);
                             tlabelsym(srsym).used:=true;
                           end
                         else
                           code:=cerrornode.create;
                       end;
                   end
                 else
                   begin
                     code:=generate_pointer_goto(expr(true));
                   end;
              end;
           _BEGIN :
             begin
               code:=statement_block(_BEGIN);
               Include(TBlockNode(code).blocknodeflags, bnf_strippable);
             end;
           _IF :
             code:=if_statement;
           _CASE :
             code:=case_statement;
           _MATCH :
             code:=match_statement;
           _REPEAT :
             code:=repeat_statement;
           _WHILE :
             code:=while_statement;
           _FOR :
             code:=for_statement;
           _WITH :
             code:=with_statement;
           _TRY :
             code:=try_statement;
           _RAISE :
             code:=raise_statement;
           _DEFER :
             code:=defer_statement;
           _LOCK :
             code:=lock_statement(false);
           _TRYLOCK :
             code:=lock_statement(true);
           { semicolons,else until and end are ignored }
           _SEMICOLON,
           _ELSE,
           _UNTIL,
           _END:
             code:=cnothingnode.create;
           _FAIL :
             begin
                if (current_procinfo.procdef.proctypeoption<>potype_constructor) then
                  Message(parser_e_fail_only_in_constructor);
                consume(_FAIL);
                code:=cnodeutils.call_fail_node;
             end;
           _ASM :
             begin
               if parse_generic then
                 Message(parser_e_no_assembler_in_generic);
               code:=_asm_statement;
             end;
           _PLUS:
             begin
               Message(parser_e_syntax_error);
               consume(_PLUS);
             end;
           _INLINE:
             begin
               code:=tp_inline_statement;
             end;
           _VAR:
             begin
               if m_inline_var in current_settings.modeswitches then
                 code:=inline_var_statement
               else
                 begin
                   { In modes without inline vars, 'var' is not a valid
                     statement keyword – give a clear error and skip. }
                   Message(parser_e_syntax_error);
                   consume(_VAR);
                   code:=cerrornode.create;
                 end;
             end;
           _CONST:
             begin
               if m_inline_var in current_settings.modeswitches then
                 code:=inline_const_statement
               else
                 begin
                   Message(parser_e_syntax_error);
                   consume(_CONST);
                   code:=cerrornode.create;
                 end;
             end;
           _EOF :
             if current_scanner.had_multiline_string then
               Message2(scan_f_unterminated_multiline_string,
                        tostr(current_scanner.multiline_start_line),
                        tostr(current_scanner.multiline_start_column))
             else
               Message(scan_f_end_of_file);
         else
           begin
             { Inline static declaration: `static name := ...` inside a body }
             if (m_inline_static in current_settings.modeswitches) and
                (current_scanner.token=_ID) and
                (current_scanner.idtoken=_STATIC) then
               begin
                 code:=inline_static_statement(false);
                 if assigned(code) then
                   exit(code);
               end;
             { Inline thread-static: per-thread storage via TLS, with a
               per-thread guard so the init runs once per thread on first
               reach. `threadstatic name := ...` }
             if (m_thread_static in current_settings.modeswitches) and
                (current_scanner.token=_ID) and
                (current_scanner.idtoken=_THREADSTATIC) then
               begin
                 code:=inline_static_statement(true);
                 if assigned(code) then
                   exit(code);
               end;
             { (a, b) := tuple_expr destructuring to existing vars }
             if (m_tuples in current_settings.modeswitches) and
                (current_scanner.token=_LKLAMMER) then
               begin
                 code:=try_tuple_destructure_assign;
                 if assigned(code) then
                   exit(code);
               end;
             { `sync <stmt>` / `sync begin..end`: run the body on the main
               thread. soft keyword by shape: only a token that can start a
               statement makes it the keyword }
             if (m_asyncawait in current_settings.modeswitches) and
                (current_scanner.token=_ID) and
                (current_scanner.pattern='SYNC') and
                sync_keyword_ahead then
               begin
                 consume(_ID);
                 code:=parse_sync_block;
                 if assigned(code) then
                   begin
                     { typecheck now: the funcref conversion must build its
                       capturer before parse_body postprocesses capturers }
                     do_typecheckpass(code);
                     exit(code);
                   end;
               end;
             { don't typecheck yet, because that will also simplify, which may
               result in not detecting certain kinds of syntax errors --
               see mantis #15594. allow lazy-label creation here because we
               are at statement start, where `IDENT:` and `IDENT[i]:` legally
               declare a new label }
             p:=expr(false,[ef_allow_lazy_label]);
             { save the current_scanner.pattern here for latter usage, the label could be "000",
               even if we read an expression, the current_scanner.pattern is still valid if it's really
               a label (FK)
               if you want to mess here, take care of
               tests/webtbs/tw3546.pp
             }
             s:=current_scanner.pattern;

             { Multi-variable assignment: a, b, c := expr }
             if (current_scanner.token=_COMMA) and
                (m_multi_var_init in current_settings.modeswitches) then
               begin
                 p:=multi_var_assign(p);
                 code:=p;
               end
             else
             begin

             { When a colon follows a intconst then transform it into a label }
             if (p.nodetype=ordconstn) and
                try_to_consume(_COLON) then
              begin
                { in iso mode, 0003: is equal to 3: }
                if (([m_iso,m_extpas]*current_settings.modeswitches)<>[]) then
                  begin
                    s:=tostr(tordconstnode(p).value);
                    searchsym(s,srsym,srsymtable);
                  end
                else
                  searchsym(s,srsym,srsymtable);
                p.free;
                p := nil;

                if not assigned(srsym) then
                  get_or_create_labelsym(s,labsym,srsymtable)
                else
                  labsym:=nil;

                if assigned(srsym) and
                   (srsym.typ=labelsym) then
                  labsym:=tlabelsym(srsym)
                else if assigned(labsym) then
                  srsym:=labsym;

                if assigned(srsym) and
                   (srsym.typ=labelsym) then
                 begin
                   if tlabelsym(srsym).defined then
                     Message(sym_e_label_already_defined);
                   if symtablestack.top.symtablelevel<>srsymtable.symtablelevel then
                     begin
                       include(current_procinfo.flags,pi_has_interproclabel);
                       if (current_procinfo.procdef.proctypeoption in [potype_unitinit,potype_unitfinalize]) then
                         Message(sym_e_interprocgoto_into_init_final_code_not_allowed);
                     end;

                   tlabelsym(srsym).defined:=true;
                   p:=clabelnode.create(nil,tlabelsym(srsym));
                   tlabelsym(srsym).code:=p;
                 end
                else if assigned(srsym) then
                 begin
                   Message(sym_e_id_is_no_label_id);
                   p:=cnothingnode.create;
                 end
                else
                 begin
                   identifier_not_found(s);
                   p:=cnothingnode.create;
                 end;
              end;

             if p.nodetype=labeln then
               begin
                 if not(current_scanner.token in endtokens) then
                   begin
                     astatement:=statement();
                     typecheckpass(astatement);
                     p:=cblocknode.create(cstatementnode.create(p,cstatementnode.create(astatement,nil)));
                     Include(TBlockNode(p).blocknodeflags, bnf_strippable);
                   end;
               end
             else
               { change a load of a procvar to a call. this is also
                 supported in fpc mode }
               if p.nodetype in [vecn,derefn,typeconvn,subscriptn,loadn] then
                 maybe_call_procvar(p,false);

             { blockn support because a read/write is changed into a blocknode
               with a separate statement for each read/write operation (JM)
               the same is true for val() if the third parameter is not 32 bit

               goto nodes are created by the compiler for non local exit statements, so
               include them as well
             }
             if not(p.nodetype in [nothingn,errorn,calln,ifn,assignn,breakn,inlinen,
                                   continuen,labeln,blockn,exitn,goton,asyncn,awaitn]) or
                ((p.nodetype=inlinen) and
                 not tinlinenode(p).may_ignore_result) or
                ((p.nodetype=calln) and
                 (assigned(tcallnode(p).procdefinition)) and
                 (tcallnode(p).procdefinition.proctypeoption=potype_operator)) then
               Message(parser_e_illegal_expression);

             if not assigned(p.resultdef) then
               do_typecheckpass(p);

             { Specify that we don't use the value returned by the call.
               This is used for :
                - dispose of temp stack space
                - dispose on FPU stack
                - extended syntax checking }
             if (p.nodetype=calln) then
               begin
                 exclude(tcallnode(p).callnodeflags,cnf_return_value_used);

                 { in $x- state, the function result must not be ignored }
                 if not(cs_extsyntax in current_settings.moduleswitches) and
                    not(is_void(p.resultdef)) and
                    { can be nil in case there was an error in the expression }
                    assigned(tcallnode(p).procdefinition) and
                    { allow constructor calls to drop the result if they are
                      called as instance methods instead of class methods }
                    not(
                      (tcallnode(p).procdefinition.proctypeoption=potype_constructor) and
                      is_class_or_object(tprocdef(tcallnode(p).procdefinition).struct) and
                      assigned(tcallnode(p).methodpointer) and
                      (tnode(tcallnode(p).methodpointer).resultdef.typ=objectdef)
                    ) then
                   Message(parser_e_illegal_expression);
               end;

             code:=p;
           end; { else (not multi-var assign) }
           end;
         end;
         if assigned(code) then
           begin
             typecheckpass(code);
             code.fileinfo:=filepos;
           end;
         statement:=code;
      end;


    type
      pdeferinfo = ^tdeferinfo;
      tdeferinfo = record
        flagvar : tlocalvarsym;
        body    : tnode;
      end;

      pdefercollect = ^tdefercollect;
      tdefercollect = record
        items           : tfplist;
        counter         : longint;
        { capture classic-var autofree defers (bnf_defer_var_scope blocks)
          only when rewriting the routine's main begin..end -- otherwise
          they leak into try-body / nested-block / with-body scopes }
        is_routine_body : boolean;
      end;


    { Build a `proc(target)` system-procedure call node from a copy of the
      target lvalue (the routine expects a var/out TRTLCriticalSection). }
    function lock_build_cs_call(const procname: string; target: tnode): tnode;
      begin
        result:=ccallnode.createintern(procname,
          ccallparanode.create(target.getcopy, nil));
      end;


    { Find an existing hidden TRTLCriticalSection global with the given name
      in the module's local symtable, or create one and register it for
      Init/Done emission in the unit's init/finalize sections. The leading
      `$` in the realname stays out of the symtable's hash (it is stripped
      by insertsym for `$`-prefixed names) - so a stable per-name lookup
      key is the realname without the `$`. }
    function lock_find_or_create_hidden_cs(const csname: string): tstaticvarsym;
      var
        srsym: tsym;
        cs_typesym: ttypesym;
        lookup: string;
      begin
        if (csname<>'') and (csname[1]='$') then
          lookup:=copy(csname,2,length(csname))
        else
          lookup:=csname;
        srsym:=tsym(current_module.localsymtable.find(lookup));
        if assigned(srsym) and (srsym.typ=staticvarsym) then
          exit(tstaticvarsym(srsym));
        cs_typesym:=search_named_unit_globaltype('SYSTEM','TRTLCRITICALSECTION',true);
        result:=cstaticvarsym.create(csname, vs_value, cs_typesym.typedef, []);
        include(result.symoptions, sp_internal);
        { InitCriticalSection in the unit init sets it up before any body runs;
          mark it so per-routine DFA does not flag the Enter as reading an
          uninitialized var (fires for bare forms in the main program body,
          where the proc localst is the module static symtable) }
        result.varstate:=vs_initialised;
        result.register_sym;
        current_module.localsymtable.insertsym(result);
        cnodeutils.insertbssdata(result);
        current_module.lock_cs_syms.add(result);
      end;


    { Stable ordering key for a lock target: the dotted source path of the
      variable / field / deref chain it names. }
    function lock_target_name(n: tnode): ansistring;
      begin
        case n.nodetype of
          loadn:
            result:=tloadnode(n).symtableentry.realname;
          subscriptn:
            result:=lock_target_name(tsubscriptnode(n).left)+'.'+tsubscriptnode(n).vs.realname;
          derefn:
            result:=lock_target_name(tderefnode(n).left)+'^';
          else
            result:='';
        end;
      end;


    { Insertion-sort targets by their ordering key so any two `lock(...)`
      sites that mention the same set of variables lock them in the same
      order; that's enough to prevent the AB-vs-BA deadlock pattern. }
    procedure lock_sort_targets(var targets: array of tnode; var names: array of ansistring);
      var
        i, j: longint;
        tmpn: tnode;
        tmps: ansistring;
      begin
        for i:=1 to high(targets) do
          begin
            j:=i;
            while (j>0) and (CompareStr(names[j-1], names[j]) > 0) do
              begin
                tmpn:=targets[j-1];
                targets[j-1]:=targets[j];
                targets[j]:=tmpn;
                tmps:=names[j-1];
                names[j-1]:=names[j];
                names[j]:=tmps;
                dec(j);
              end;
          end;
      end;


    { TryEnterCriticalSection(target) <> 0 }
    function lock_build_tryenter(target: tnode): tnode;
      begin
        result:=caddnode.create(unequaln,
          ccallnode.createintern('TRYENTERCRITICALSECTION',
            ccallparanode.create(target.getcopy, nil)),
          cordconstnode.create(0, s32inttype, false));
      end;


    { one all-or-nothing acquisition attempt over the sorted lock list:
      take each CS with TryEnter in order; on the first failure release
      the ones already taken (reverse order) so a partial grab can never
      deadlock against another multi-lock site }
    function lock_build_tryall(const targets: array of tnode; acquired: tlocalvarsym; idx: longint): tnode;
      var
        rollback: tblocknode;
        rstat: tstatementnode;
        succ: tnode;
        j: longint;
      begin
        if idx=high(targets) then
          succ:=cassignmentnode.create(
            cloadnode.create(acquired, acquired.owner),
            cordconstnode.create(1, pasbool1type, false))
        else
          succ:=lock_build_tryall(targets, acquired, idx+1);
        if idx=0 then
          result:=cifnode.create(lock_build_tryenter(targets[idx]), succ, nil)
        else
          begin
            rollback:=internalstatements(rstat);
            for j:=idx-1 downto 0 do
              addstatement(rstat, lock_build_cs_call('LEAVECRITICALSECTION', targets[j]));
            result:=cifnode.create(lock_build_tryenter(targets[idx]), succ, rollback);
          end;
      end;


    { Lower `trylock(...) [wait N] do body else elsebody`. The wait budget
      (Int64 milliseconds) is evaluated once, before the first attempt.
      Acquisition: one immediate try, then a few yields that catch
      short-held locks, then - only with a positive budget - 16 ms sleep
      slices on a throwaway RTL event until acquired or the budget is
      gone. The slice floor matches the default Windows timer tick, so
      summing slept slices stays an honest elapsed-time estimate without
      reading any clock. The event is created on demand - the uncontended
      fast path allocates nothing. }
    function trylock_build(const targets: array of tnode; waitnode, body, elsebody: tnode; const filepos: tfileposinfo): tnode;
      const
        spin_yields = 3;
        slice_ms = 16;
      var
        suffix: ansistring;

      function newlocal(const prefix: string; def: tdef): tlocalvarsym;
        begin
          result:=tlocalvarsym.create('$lock_'+prefix+'_'+suffix, vs_value, def, []);
          include(result.symoptions, sp_internal);
          symtablestack.top.insertsym(result);
        end;

      var
        acquired_sym, remaining_sym, slice_sym, ev_sym: tlocalvarsym;
        ev_typesym: ttypesym;
        block, sleep_block, loop_block, spin_block, leave_block: tblocknode;
        stmts, sleep_stat, loop_stat, spin_stat, leave_stat: tstatementnode;
        acquired_branch: tnode;
        i: longint;
        sline, scol: string[12];
        has_wait_loop: boolean;
      begin
        str(filepos.line, sline);
        str(filepos.column, scol);
        suffix:=sline+'_'+scol;

        { absent `wait` and constant `wait 0` are the same thing: attempts
          only, no sleeping }
        has_wait_loop:=assigned(waitnode);
        if has_wait_loop then
          begin
            typecheckpass(waitnode);
            if (waitnode.nodetype=ordconstn) and (tordconstnode(waitnode).value < 0) then
              MessagePos(waitnode.fileinfo, parser_e_trylock_wait_negative);
            if (waitnode.nodetype=ordconstn) and (tordconstnode(waitnode).value <= 0) then
              begin
                waitnode.free;
                has_wait_loop:=false;
              end;
          end;

        block:=internalstatements(stmts);
        acquired_sym:=newlocal('acq', pasbool1type);
        addstatement(stmts, cassignmentnode.create(
          cloadnode.create(acquired_sym, acquired_sym.owner),
          cordconstnode.create(0, pasbool1type, false)));
        if has_wait_loop then
          begin
            remaining_sym:=newlocal('rem', s64inttype);
            addstatement(stmts, cassignmentnode.create(
              cloadnode.create(remaining_sym, remaining_sym.owner),
              waitnode));
          end;
        addstatement(stmts, lock_build_tryall(targets, acquired_sym, 0));
        for i:=1 to spin_yields do
          begin
            spin_block:=internalstatements(spin_stat);
            addstatement(spin_stat, ccallnode.createintern('THREADSWITCH', nil));
            addstatement(spin_stat, lock_build_tryall(targets, acquired_sym, 0));
            addstatement(stmts, cifnode.create(
              cnotnode.create(cloadnode.create(acquired_sym, acquired_sym.owner)),
              spin_block, nil));
          end;

        if has_wait_loop then
          begin
            slice_sym:=newlocal('slice', s32inttype);
            ev_typesym:=search_named_unit_globaltype('SYSTEM','PRTLEVENT',true);
            ev_sym:=newlocal('ev', ev_typesym.typedef);

            sleep_block:=internalstatements(sleep_stat);
            addstatement(sleep_stat, cassignmentnode.create(
              cloadnode.create(ev_sym, ev_sym.owner),
              ccallnode.createintern('RTLEVENTCREATE', nil)));
            loop_block:=internalstatements(loop_stat);
            { slice := min(slice_ms, remaining) }
            addstatement(loop_stat, cifnode.create(
              caddnode.create(gten,
                cloadnode.create(remaining_sym, remaining_sym.owner),
                cordconstnode.create(slice_ms, s32inttype, false)),
              cassignmentnode.create(
                cloadnode.create(slice_sym, slice_sym.owner),
                cordconstnode.create(slice_ms, s32inttype, false)),
              cassignmentnode.create(
                cloadnode.create(slice_sym, slice_sym.owner),
                cloadnode.create(remaining_sym, remaining_sym.owner))));
            { the event is never signalled - the timed wait is a portable sleep }
            addstatement(loop_stat, ccallnode.createintern('RTLEVENTWAITFOR',
              ccallparanode.create(cloadnode.create(slice_sym, slice_sym.owner),
                ccallparanode.create(cloadnode.create(ev_sym, ev_sym.owner), nil))));
            addstatement(loop_stat, cassignmentnode.create(
              cloadnode.create(remaining_sym, remaining_sym.owner),
              caddnode.create(subn,
                cloadnode.create(remaining_sym, remaining_sym.owner),
                cloadnode.create(slice_sym, slice_sym.owner))));
            addstatement(loop_stat, lock_build_tryall(targets, acquired_sym, 0));
            addstatement(sleep_stat, cwhilerepeatnode.create(
              caddnode.create(andn,
                cnotnode.create(cloadnode.create(acquired_sym, acquired_sym.owner)),
                caddnode.create(gtn,
                  cloadnode.create(remaining_sym, remaining_sym.owner),
                  cordconstnode.create(0, s32inttype, false))),
              loop_block, true, false));
            addstatement(sleep_stat, ccallnode.createintern('RTLEVENTDESTROY',
              ccallparanode.create(cloadnode.create(ev_sym, ev_sym.owner), nil)));

            addstatement(stmts, cifnode.create(
              caddnode.create(andn,
                cnotnode.create(cloadnode.create(acquired_sym, acquired_sym.owner)),
                caddnode.create(gtn,
                  cloadnode.create(remaining_sym, remaining_sym.owner),
                  cordconstnode.create(0, s32inttype, false))),
              sleep_block, nil));
          end;

        { acquired -> body guarded by Leave in finally; missed -> else.
          an empty body cannot raise, so skip the try-finally - it would
          otherwise emit an unused exception frame (objfpc-family hint) }
        leave_block:=internalstatements(leave_stat);
        for i:=high(targets) downto 0 do
          addstatement(leave_stat, lock_build_cs_call('LEAVECRITICALSECTION', targets[i]));
        if has_no_code(body) then
          begin
            body.free;
            acquired_branch:=leave_block;
          end
        else
          acquired_branch:=ctryfinallynode.create(body, leave_block);
        addstatement(stmts, cifnode.create(
          cloadnode.create(acquired_sym, acquired_sym.owner),
          acquired_branch,
          elsebody));

        block.fileinfo:=filepos;
        typecheckpass(tnode(block));
        result:=block;
      end;


    { `lock [(targets)] do <stmt>` - blocks until acquired, never fails.
      `trylock [(targets)] [wait <expr>] do <stmt> else <stmt>` - may miss
      (single attempt, or the wait budget runs out) and then runs the
      mandatory else branch without the lock held. }
    function lock_statement(is_try: boolean) : tnode;
      var
        cs_targets: array of tnode;
        cs_names: array of ansistring;
        addr_inits: array of tnode;
        body, arg, waitnode, elsebody, built: tnode;
        enter_stat, leave_stat, init_stat: tstatementnode;
        enter_block, leave_block, init_block: tblocknode;
        i: longint;
        filepos: tfileposinfo;
        arg_sym: tsym;
        hidden_cs: tstaticvarsym;
        addrtemp: tlocalvarsym;
        cs_typesym: ttypesym;
        is_explicit_cs, arg_error: boolean;
        sline, scol: string[12];
        csname: ansistring;

      procedure add_target(target: tnode; const name: ansistring);
        begin
          setlength(cs_targets, length(cs_targets)+1);
          cs_targets[high(cs_targets)]:=target;
          setlength(cs_names, length(cs_names)+1);
          cs_names[high(cs_names)]:=name;
        end;

      { the enter/leave builders only ever copy the targets, so the originals
        (and, on the error path, the unconsumed address initializers) are
        always freed here }
      procedure free_targets(free_inits: boolean);
        var
          j: longint;
        begin
          for j:=0 to high(cs_targets) do
            cs_targets[j].free;
          if free_inits then
            for j:=0 to high(addr_inits) do
              addr_inits[j].free;
        end;

      begin
        if is_try then
          consume(_TRYLOCK)
        else
          consume(_LOCK);
        filepos:=current_tokenpos;
        str(filepos.line, sline);
        str(filepos.column, scol);
        setlength(cs_targets, 0);
        setlength(cs_names, 0);
        setlength(addr_inits, 0);
        waitnode:=nil;
        arg_error:=false;
        cs_typesym:=search_named_unit_globaltype('SYSTEM','TRTLCRITICALSECTION',false);
        if try_to_consume(_LKLAMMER) then
          begin
            repeat
              arg:=comp_expr([ef_accept_equal]);
              if (not assigned(arg)) or (arg.nodetype=errorn) then
                begin
                  arg.free;
                  arg_error:=true;
                  continue;
                end;
              is_explicit_cs:=assigned(cs_typesym) and assigned(arg.resultdef) and
                              equal_defs(arg.resultdef, cs_typesym.typedef);
              if is_explicit_cs then
                begin
                  { any assignable location works: the lowering only needs a
                    stable lvalue to pass to Enter/Leave/TryEnter }
                  if not valid_for_var(arg, false) then
                    begin
                      MessagePos(arg.fileinfo, parser_e_lock_arg_not_variable);
                      arg.free;
                      arg_error:=true;
                    end
                  else if arg.nodetype=loadn then
                    add_target(arg, tloadnode(arg).symtableentry.realname)
                  else
                    begin
                      { instance field, deref, ... - snapshot the address once
                        into a hidden local so every Enter/Leave hits the same
                        section even if parts of the expression change while
                        the lock is held }
                      csname:=lock_target_name(arg);
                      addrtemp:=clocalvarsym.create(
                        '$lock_tgt'+tostr(length(cs_targets))+'_'+sline+'_'+scol,
                        vs_value, cpointerdef.getreusable(cs_typesym.typedef), []);
                      include(addrtemp.symoptions, sp_internal);
                      { the initializer is prepended after the acquisition
                        block is already typechecked, so DFA must not flag
                        the loads in it }
                      addrtemp.varstate:=vs_initialised;
                      symtablestack.top.insertsym(addrtemp);
                      setlength(addr_inits, length(addr_inits)+1);
                      addr_inits[high(addr_inits)]:=cassignmentnode.create(
                        cloadnode.create(addrtemp, addrtemp.owner),
                        ctypeconvnode.create_internal(caddrnode.create_internal(arg),
                          addrtemp.vardef));
                      add_target(cderefnode.create(
                        cloadnode.create(addrtemp, addrtemp.owner)), csname);
                    end;
                end
              else
                begin
                  arg_sym:=nil;
                  if arg.nodetype=loadn then
                    arg_sym:=tloadnode(arg).symtableentry;
                  { an auto target's hidden CS is keyed by symbol, not by
                    instance, so a field makes no sense here - only an
                    explicit TRTLCriticalSection field does }
                  if (arg.nodetype=subscriptn) or
                     (assigned(arg_sym) and (arg_sym.typ=fieldvarsym)) then
                    begin
                      MessagePos(arg.fileinfo, parser_e_lock_field_arg);
                      arg.free;
                      arg_error:=true;
                    end
                  else if not assigned(arg_sym) then
                    begin
                      MessagePos(arg.fileinfo, parser_e_lock_arg_not_variable);
                      arg.free;
                      arg_error:=true;
                    end
                  else if arg_sym.typ<>staticvarsym then
                    begin
                      MessagePos(arg.fileinfo, parser_e_lock_local_arg);
                      arg.free;
                      arg_error:=true;
                    end
                  else
                    begin
                      hidden_cs:=lock_find_or_create_hidden_cs(
                        '$lock_var_'+arg_sym.realname);
                      add_target(cloadnode.create(hidden_cs, hidden_cs.owner),
                        arg_sym.realname);
                      arg.free;
                    end;
                end;
            until not try_to_consume(_COMMA);
            consume(_RKLAMMER);
            if length(cs_targets)>1 then
              lock_sort_targets(cs_targets, cs_names);
          end;
        if (length(cs_targets)=0) and not arg_error then
          begin
            { per-callsite hidden CS named by source position - two bare
              statements never share a lock, even when they touch the same
              variable }
            csname:='$lock_cs_'+sline+'_'+scol;
            hidden_cs:=lock_find_or_create_hidden_cs(csname);
            add_target(cloadnode.create(hidden_cs, hidden_cs.owner), csname);
          end;
        { `wait <expr>` - only the trylock form can give up, so only it can
          bound the acquisition. Nothing else is legal between the target
          list and `do`, so a bare identifier `wait` here is always the
          clause. }
        if (current_scanner.token=_ID) and (current_scanner.pattern='WAIT') then
          begin
            if not is_try then
              Message(parser_e_lock_no_wait);
            consume(_ID);
            waitnode:=comp_expr([ef_accept_equal]);
            if (not assigned(waitnode)) or (waitnode.nodetype=errorn) or not is_try then
              begin
                waitnode.free;
                free_targets(true);
                exit(cerrornode.create);
              end;
          end;
        consume(_DO);
        body:=statement;
        if (not assigned(body)) or (body.nodetype=errorn) then
          begin
            body.free;
            waitnode.free;
            free_targets(true);
            exit(cerrornode.create);
          end;
        if is_try then
          begin
            { a missed acquisition skips the body - the else branch must
              spell out what happens instead }
            if not try_to_consume(_ELSE) then
              begin
                Message(parser_e_trylock_needs_else);
                body.free;
                waitnode.free;
                free_targets(true);
                exit(cerrornode.create);
              end;
            elsebody:=statement;
            if (not assigned(elsebody)) or (elsebody.nodetype=errorn) then
              begin
                elsebody.free;
                body.free;
                waitnode.free;
                free_targets(true);
                exit(cerrornode.create);
              end;
            { a bad target already got its own error; the statement is fully
              parsed, so bail without the misleading syntax cascade }
            if arg_error then
              begin
                elsebody.free;
                body.free;
                waitnode.free;
                free_targets(true);
                exit(cerrornode.create);
              end;
            built:=trylock_build(cs_targets, waitnode, body, elsebody, filepos);
            if length(addr_inits)>0 then
              begin
                init_block:=internalstatements(init_stat);
                for i:=0 to high(addr_inits) do
                  addstatement(init_stat, addr_inits[i]);
                addstatement(init_stat, built);
                init_block.fileinfo:=filepos;
                typecheckpass(tnode(init_block));
                built:=init_block;
              end;
            free_targets(false);
            exit(built);
          end;
        if arg_error then
          begin
            body.free;
            free_targets(true);
            exit(cerrornode.create);
          end;
        enter_block:=internalstatements(enter_stat);
        for i:=0 to high(addr_inits) do
          addstatement(enter_stat, addr_inits[i]);
        for i:=0 to high(cs_targets) do
          addstatement(enter_stat,
            lock_build_cs_call('ENTERCRITICALSECTION', cs_targets[i]));
        leave_block:=internalstatements(leave_stat);
        for i:=high(cs_targets) downto 0 do
          addstatement(leave_stat,
            lock_build_cs_call('LEAVECRITICALSECTION', cs_targets[i]));
        { an empty body cannot raise - acquire then release directly, skipping
          the try-finally that would emit an unused exception frame }
        if has_no_code(body) then
          begin
            body.free;
            addstatement(enter_stat, leave_block);
          end
        else
          addstatement(enter_stat, ctryfinallynode.create(body, leave_block));
        enter_block.fileinfo:=filepos;
        typecheckpass(tnode(enter_block));
        free_targets(false);
        result:=enter_block;
      end;


    function defer_statement : tnode;
      var
        body: tnode;
      begin
        consume(_DEFER);
        if current_scanner.token=_DEFER then
          begin
            Message(parser_e_defer_inside_defer);
            consume(_DEFER);
          end;
        body:=statement;
        if (body=nil) or (body.nodetype=errorn) then
          result:=cerrornode.create
        else
          result:=cdefernode.create(body);
      end;


    function defer_collect_callback(var n: tnode; arg: pointer): foreachnoderesult;
      var
        ctx     : pdefercollect;
        flagvar : tlocalvarsym;
        flagname: TIDString;
        linestr : string[12];
        info    : pdeferinfo;
        deferred: tnode;
        asgn    : tnode;
      begin
        result:=fen_false;
        ctx:=pdefercollect(arg);
        // inner blocks have their own defer scope - skip, unless flagged
        // as a parser-generated helper (e.g. autofree desugar)
        if (n.nodetype=blockn) and not (bnf_defer_transparent in tblocknode(n).blocknodeflags) then
          exit(fen_norecurse_false);
        if n.nodetype=defern then
          begin
            // classic-var autofree's defer is bound to the variable's scope,
            // not whatever block surrounds the assignment - leave it alone
            // for an outer rewrite to capture at the variable's owning scope
            if tdefernode(n).var_scope and not ctx^.is_routine_body then
              exit(fen_false);
            { include the source line in the flag name so two separate
              rewrites in the same routine (each with its own counter)
              cannot produce the same identifier and collide in the
              shared procdef.localst. The intra-ctx counter still
              disambiguates multiple defers on the same line. }
            inc(ctx^.counter);
            str(n.fileinfo.line,flagname);
            str(ctx^.counter,linestr);
            flagname:='$defer_flag_'+flagname+'_'+linestr;
            flagvar:=tlocalvarsym.create(flagname,vs_value,pasbool1type,[]);
            symtablestack.top.insertsym(flagvar);
            // detach deferred body before freeing the marker
            deferred:=tunarynode(n).left;
            tunarynode(n).left:=nil;
            new(info);
            info^.flagvar:=flagvar;
            info^.body:=deferred;
            ctx^.items.add(info);
            // replace marker with `flagvar := true`, typechecked
            asgn:=cassignmentnode.create(
                    cloadnode.create(flagvar,flagvar.owner),
                    cordconstnode.create(1,pasbool1type,false));
            asgn.fileinfo:=n.fileinfo;
            typecheckpass(asgn);
            n.free;
            n:=asgn;
            exit(fen_norecurse_false);
          end;
      end;


    procedure rewrite_defers_in_block(var first: tnode; is_routine_body: boolean = false);
      var
        ctx          : tdefercollect;
        i            : longint;
        info         : pdeferinfo;
        init_block   : tblocknode;
        init_stat    : tstatementnode;
        finally_block: tblocknode;
        finally_stat : tstatementnode;
        body_block   : tnode;
        saved_filepos: tfileposinfo;
      begin
        ctx.items:=tfplist.create;
        ctx.counter:=0;
        ctx.is_routine_body:=is_routine_body;
        try
          foreachnodestatic(pm_preprocess,first,@defer_collect_callback,@ctx);
          if ctx.items.count=0 then
            exit;
          saved_filepos:=first.fileinfo;
          // prepend initialization of every flag to the original body
          // (boolean locals would otherwise be uninitialized garbage)
          init_block:=internalstatements(init_stat);
          Include(init_block.blocknodeflags, bnf_defer_transparent);
          for i:=0 to ctx.items.count-1 do
            begin
              info:=pdeferinfo(ctx.items[i]);
              addstatement(init_stat,
                cassignmentnode.create(
                  cloadnode.create(info^.flagvar,info^.flagvar.owner),
                  cordconstnode.create(0,pasbool1type,false)));
            end;
          typecheckpass(tnode(init_block));
          // build finally body in LIFO order
          finally_block:=internalstatements(finally_stat);
          for i:=ctx.items.count-1 downto 0 do
            begin
              info:=pdeferinfo(ctx.items[i]);
              addstatement(finally_stat,
                cifnode.create(
                  cloadnode.create(info^.flagvar,info^.flagvar.owner),
                  info^.body,
                  nil));
            end;
          typecheckpass(tnode(finally_block));
          // wrap original chain in try..finally, prepended with flag inits
          body_block:=cblocknode.create(
                        cstatementnode.create(init_block,
                          cstatementnode.create(cblocknode.create(first), nil)));
          body_block.fileinfo:=saved_filepos;
          typecheckpass(body_block);
          first:=cstatementnode.create(
                   ctryfinallynode.create(body_block,finally_block),
                   nil);
          first.fileinfo:=saved_filepos;
          typecheckpass(first);
        finally
          for i:=0 to ctx.items.count-1 do
            dispose(pdeferinfo(ctx.items[i]));
          ctx.items.free;
        end;
      end;


    function single_statement : tnode;
      begin
        result:=statement();
      end;


    function statement_block(starttoken : ttoken) : tnode;

      var
         first,last : tnode;
         filepos : tfileposinfo;
         blockst : tblocksymtable;
         is_routine_body : boolean;

      begin
         first:=nil;
         last:=nil;
         filepos:=current_tokenpos;
         consume(starttoken);

         { capture whether this is the routine's main begin..end before
           consuming the flag - used by rewrite_defers_in_block to decide
           whether to capture classic-var autofree defers (which belong to
           the variable's scope, i.e. routine, not to inner blocks) }
         is_routine_body := assigned(current_procinfo) and (starttoken=_BEGIN) and
                            current_procinfo.parsing_main_block;
         if is_routine_body then
           current_procinfo.parsing_main_block:=false;

         { Push a block-scope symtable so that inline vars declared inside
           this begin..end are scoped to the block (Delphi-style).
           Only active when m_inline_var is set; avoids overhead in other modes. }
         blockst:=nil;
         if assigned(current_procinfo) and (m_inline_var in current_settings.modeswitches) and
            not is_routine_body then
           begin
             blockst:=tblocksymtable.create(symtablestack.top);
             symtablestack.push(blockst);
           end;

         while not((current_scanner.token=_END) or (current_scanner.token=_FINALIZATION)) do
           begin
              if first=nil then
                begin
                   last:=cstatementnode.create(statement,nil);
                   first:=last;
                end
              else
                begin
                   tstatementnode(last).right:=cstatementnode.create(statement,nil);
                   last:=tstatementnode(last).right;
                end;
              if ((current_scanner.token=_END) or (current_scanner.token=_FINALIZATION)) then
                break
              else
                begin
                   { if no semicolon, then error and go on }
                   if current_scanner.token<>_SEMICOLON then
                     begin
                        consume(_SEMICOLON);
                        consume_all_until(_SEMICOLON);
                     end;
                   consume(_SEMICOLON);
                end;
              consume_emptystats;
           end;

         { don't consume the finalization token, it is consumed when
           reading the finalization block, but allow it only after
           an initialization ! }
         if (starttoken<>_INITIALIZATION) or (current_scanner.token<>_FINALIZATION) then
           consume(_END);

         { rewrite defer markers into try..finally with bool flags.
           Must run while the block-scope symtable is still on the stack so that
           generated flag-vars land in the right scope. No-op if no defer in tree. }
         if assigned(first) then
           rewrite_defers_in_block(first, is_routine_body);

         { Pop the block-scope symtable and keep it on the procdef so nested
           debug scopes can still follow the original parent chain later on. }
         if assigned(blockst) then
           begin
             symtablestack.pop(blockst);
             if not assigned(current_procinfo.procdef.blocklocalsymtables) then
               current_procinfo.procdef.blocklocalsymtables:=tfpobjectlist.create(true);
             current_procinfo.procdef.blocklocalsymtables.add(blockst);
           end;

         last:=cblocknode.create(first);
         if assigned(blockst) then
           tblocknode(last).blocksymtable:=blockst;
         last.fileinfo:=filepos;
         statement_block:=last;
      end;


    function assembler_block : tnode;
      var
        p : tnode;
        {$if not(defined(sparcgen)) and not(defined(arm)) and not(defined(avr)) and not(defined(mips))}
        locals : longint;
        {$endif not(defined(sparcgen)) and not(defined(arm)) and not(defined(avr)) and not(defined(mips))}
        srsym : tsym;
      begin
         if parse_generic then
           message(parser_e_no_assembler_in_generic);

         { Rename the funcret so that recursive calls are possible }
         if not is_void(current_procinfo.procdef.returndef) then
           begin
             srsym:=TSym(current_procinfo.procdef.localst.Find(current_procinfo.procdef.procsym.name));
             if assigned(srsym) then
               srsym.realname:='$hiddenresult';
           end;

         { delphi uses register calling for assembler methods }
         if (m_delphi in current_settings.modeswitches) and
            (po_assembler in current_procinfo.procdef.procoptions) and
            not(po_hascallingconvention in current_procinfo.procdef.procoptions) then
           current_procinfo.procdef.proccalloption:=pocall_register;

         { force the asm statement }
         if current_scanner.token<>_ASM then
           consume(_ASM);
         include(current_procinfo.flags,pi_is_assembler);
         p:=_asm_statement;

{$if not(defined(sparcgen)) and not(defined(arm)) and not(defined(avr)) and not(defined(mips))}
         if (po_assembler in current_procinfo.procdef.procoptions) then
           begin
             { set the framepointer to esp for assembler functions when the
               following conditions are met:
               - if the are no local variables and parameters (except the allocated result)
               - no reference to the result variable (refcount<=1)
               - result is not stored as parameter
               - target processor has optional frame pointer save
                 (vm, i386, vm only currently)
             }
             locals:=tabstractlocalsymtable(current_procinfo.procdef.parast).count_locals;
             if (current_procinfo.procdef.localst.symtabletype=localsymtable) then
               inc(locals,tabstractlocalsymtable(current_procinfo.procdef.localst).count_locals);
             if (locals=0) and
                not (current_procinfo.procdef.owner.symtabletype in [ObjectSymtable,recordsymtable]) and
                (not assigned(current_procinfo.procdef.funcretsym) or
                 (tabstractvarsym(current_procinfo.procdef.funcretsym).refs<=1)) and
                not (df_generic in current_procinfo.procdef.defoptions) and
                not(paramanager.ret_in_param(current_procinfo.procdef.returndef,current_procinfo.procdef)) then
               begin
                 { Only need to set the framepointer, the locals will
                   be inserted with the correct reference in tcgasmnode.pass_generate_code }
                 current_procinfo.framepointer:=NR_STACK_POINTER_REG;
               end;
           end;
{$endif not(defined(sparcgen)) and not(defined(arm)) and not(defined(avr)) not(defined(mipsel))}

        { Flag the result as assigned when it is returned in a
          register.
        }
        if assigned(current_procinfo.procdef.funcretsym) and
            not (df_generic in current_procinfo.procdef.defoptions) and
           (not paramanager.ret_in_param(current_procinfo.procdef.returndef,current_procinfo.procdef)) then
          tabstractvarsym(current_procinfo.procdef.funcretsym).varstate:=vs_initialised;

        { because the END is already read we need to get the
          last_endtoken_filepos here (PFV) }
        last_endtoken_filepos:=current_tokenpos;

        assembler_block:=p;
      end;


    function statement_expr(var p1 : tnode) : boolean;
      begin
        if not (m_statement_expressions in current_settings.modeswitches) then
          exit(false);
        result:=true;
        case current_scanner.token of
        _IF: p1:=if_statement(true);
        _CASE: p1:=case_statement(true);
        _MATCH: p1:=match_statement(true);
        _TRY: p1:=try_statement(true);
        else
          result:=false;
        end;
      end;

end.
