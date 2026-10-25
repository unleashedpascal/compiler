{
    Replaces calls by inline code

    Copyright (c) 1998-2026 by Florian Klaempfl and others

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

unit optcall;

{$i fpcdefs.inc}

{ $define EXTDEBUG_INLINE}

  interface

    uses
      node;

    procedure do_optinline(var rootnode : tnode;out changed: boolean);

  implementation

    uses
      cclasses,
      verbose,globals,globtype,
      defutil,defcmp,
      symconst,symtype,symdef,symsym,
      parabase,paramgr,
      procinfo,
      nutils,
      fmodule,
      pass_1,
      nbas,ncal,nld,ncnv;

    type
      pinlinectx = ^tinlinectx;
      tinlinectx = record
        changed : boolean;
        { the root of the tree being processed, for whole-routine scans }
        root : ^tnode;
      end;

    { this procedure removes the user code flag because it prevents optimizations }
    function removeusercodeflag(var n : tnode; arg : pointer) : foreachnoderesult;
      begin
        result:=fen_false;
        if nf_usercode_entry in n.flags then
          begin
            exclude(n.flags,nf_usercode_entry);
            result:=fen_norecurse_true;
          end;
      end;


    function setinlinelevel(var n:tnode; arg:pointer):foreachnoderesult;
      begin
        if n.nodetype=calln then
          tcallnode(n).inlinelevel:=PtrUInt(arg);
        result:=fen_false;
      end;


    { redirect assembler operands to the per-expansion backing symbols and mark
      the block so its local labels get relabeled per call site }
    function rewriteinlinedasm(var n:tnode; arg:pointer):foreachnoderesult;
      begin
        result:=fen_false;
        if n.nodetype=asmn then
          begin
            asmlist_rewrite_local_syms(tasmnode(n).p_asm,TFPObjectList(arg));
            include(tasmnode(n).asmnodeflags,asmnf_inlined);
          end;
      end;


    { reference symbols that are imported from another unit }
    function importglobalsyms(var n:tnode; arg:pointer):foreachnoderesult;
      var
        sym : tsym;
      begin
        result:=fen_false;
        if n.nodetype=loadn then
          begin
            sym:=tloadnode(n).symtableentry;
            if sym.typ=staticvarsym then
              begin
                if FindUnitSymtable(tloadnode(n).symtable).moduleid<>current_module.moduleid then
                  current_module.addimportedsym(sym);
              end
            else if (sym.typ=constsym) and (tconstsym(sym).consttyp in [constwresourcestring,constresourcestring]) then
              begin
                if tloadnode(n).symtableentry.owner.moduleid<>current_module.moduleid then
                  current_module.addimportedsym(sym);
              end;
          end
        else if (n.nodetype=calln) then
          begin
            if (assigned(tcallnode(n).procdefinition)) and
               (tcallnode(n).procdefinition.typ=procdef) and
               (findunitsymtable(tcallnode(n).procdefinition.owner).moduleid<>current_module.moduleid) then
              current_module.addimportedsym(tprocdef(tcallnode(n).procdefinition).procsym);
          end;
      end;


    function redoalinaparams(var n: tnode; arg: pointer): foreachnoderesult;
      begin
        result:=fen_false;
        if n.nodetype=calln then
          begin
            { re-init varargs paraloc that may have been invalidated by inlining }
            if assigned(tcallnode(n).varargsparas) then
              paramanager.create_varargs_paraloc_info(tcallnode(n).procdefinition,callerside,tcallnode(n).varargsparas);
            tcallnode(n).order_parameters;
          end;
      end;


    { strips value-preserving conversions off a procvar expression }
    function strip_procvar_convs(n: tnode): tnode;
      begin
        while assigned(n) and
              (n.nodetype=typeconvn) and
              (ttypeconvnode(n).convtype in [tc_equal,tc_proc_2_procvar]) do
          n:=ttypeconvnode(n).left;
        result:=n;
      end;


    type
      plocalscan = ^tlocalscan;
      tlocalscan = record
        { the scanned location: a local variable or a temp }
        sym : tsym;
        temp : ptempinfo;
        reads,
        writes,
        assigns : longint;
        source : tnode;
        bad : boolean;
      end;

      { the chain of locations a resolution was chased through }
      pdevirtchain = ^tdevirtchain;
      tdevirtchain = record
        count : longint;
        syms : array[0..3] of tsym;
        temps : array[0..3] of ptempinfo;
      end;

    { true when n (already stripped) loads the scanned location }
    function is_scanned_location(n: tnode; scan: plocalscan): boolean;
      begin
        result:=
          (assigned(scan^.sym) and
           (n.nodetype=loadn) and
           (tloadnode(n).symtableentry=scan^.sym)) or
          (assigned(scan^.temp) and
           (n.nodetype=temprefn) and
           (ttemprefnode(n).tempinfo=scan^.temp));
      end;

    function scan_local_writes(var n: tnode; arg: pointer): foreachnoderesult;
      var
        scan : plocalscan;
        hp : tnode;
      begin
        result:=fen_false;
        scan:=plocalscan(arg);
        case n.nodetype of
          loadn,
          temprefn:
            if is_scanned_location(n,scan) then
              begin
                if n.flags*[nf_write,nf_modify]<>[] then
                  inc(scan^.writes)
                else
                  inc(scan^.reads);
              end;
          assignn:
            begin
              hp:=strip_procvar_convs(tassignmentnode(n).left);
              if is_scanned_location(hp,scan) then
                begin
                  inc(scan^.assigns);
                  scan^.source:=tassignmentnode(n).right;
                end;
            end;
          addrn:
            begin
              hp:=strip_procvar_convs(tunarynode(n).left);
              if is_scanned_location(hp,scan) then
                scan^.bad:=true;
            end;
          callparan:
            begin
              hp:=strip_procvar_convs(tcallparanode(n).left);
              if is_scanned_location(hp,scan) and
                 (not assigned(tcallparanode(n).parasym) or
                  (tcallparanode(n).parasym.varspez in [vs_var,vs_out,vs_constref])) then
                scan^.bad:=true;
            end;
          else
            ;
        end;
      end;


    { runs scan_local_writes for a location over the whole routine }
    procedure run_location_scan(ctx: pinlinectx; sym: tsym; temp: ptempinfo; out scan: tlocalscan);
      begin
        scan.sym:=sym;
        scan.temp:=temp;
        scan.reads:=0;
        scan.writes:=0;
        scan.assigns:=0;
        scan.source:=nil;
        scan.bad:=false;
        foreachnodestatic(pm_postprocess,ctx^.root^,@scan_local_writes,@scan);
      end;


    { returns the source of the location's single store, nil when there is
      not exactly one or the location escapes }
    function find_single_store(ctx: pinlinectx; sym: tsym; temp: ptempinfo): tnode;
      var
        scan : tlocalscan;
      begin
        result:=nil;
        run_location_scan(ctx,sym,temp,scan);
        if scan.bad or (scan.assigns<>1) or (scan.writes<>1) then
          exit;
        result:=scan.source;
      end;


    { replaces the scanned location's single store with a nothing node }
    function kill_single_store(var n: tnode; arg: pointer): foreachnoderesult;
      var
        scan : plocalscan;
        hp : tnode;
      begin
        result:=fen_false;
        scan:=plocalscan(arg);
        if n.nodetype<>assignn then
          exit;
        hp:=strip_procvar_convs(tassignmentnode(n).left);
        if not is_scanned_location(hp,scan) or
           might_have_sideeffects(tassignmentnode(n).right) then
          exit;
        hp:=cnothingnode.create;
        firstpass(hp);
        n.free;
        n:=hp;
        result:=fen_norecurse_true;
      end;


    { after a devirtualized call dropped its procvar expression, the stores
      feeding the locations it was resolved through may have become dead;
      remove those no longer read anywhere (nothing eliminates them later:
      dead store elimination is not part of any -O level) }
    procedure remove_dead_chain_stores(ctx: pinlinectx; const chain: tdevirtchain);
      var
        scan : tlocalscan;
        i : longint;
      begin
        for i:=0 to chain.count-1 do
          begin
            run_location_scan(ctx,chain.syms[i],chain.temps[i],scan);
            if scan.bad or (scan.assigns<>1) or (scan.writes<>1) or (scan.reads<>0) then
              break;
            if not foreachnodestatic(pm_postprocess,ctx^.root^,@kill_single_store,@scan) then
              break;
          end;
      end;


    { returns the routine a procvar expression provably always evaluates to:
      either the address of a routine taken directly, or a load of a local
      or temp whose only store in the whole routine is such an address;
      the locations chased through are recorded in chain }
    function resolve_procvar_target(n: tnode; ctx: pinlinectx; chain: pdevirtchain): tprocdef;
      var
        source : tnode;
        sym : tsym;
      begin
        result:=nil;
        n:=strip_procvar_convs(n);
        case n.nodetype of
          loadn:
            begin
              sym:=tloadnode(n).symtableentry;
              case sym.typ of
                procsym:
                  result:=tloadnode(n).procdef;
                localvarsym:
                  begin
                    if (chain^.count>high(chain^.syms)) or
                       tabstractvarsym(sym).addr_taken or
                       (vo_volatile in tabstractvarsym(sym).varoptions) or
                       current_procinfo.has_nestedprocs or
                       (pi_has_assembler_block in current_procinfo.flags) then
                      exit;
                    { a single store whose value always reaches the call: any
                      path calling through the variable without passing the
                      store reads an uninitialized procvar }
                    source:=find_single_store(ctx,sym,nil);
                    if assigned(source) then
                      begin
                        chain^.syms[chain^.count]:=sym;
                        chain^.temps[chain^.count]:=nil;
                        inc(chain^.count);
                        result:=resolve_procvar_target(source,ctx,chain);
                      end;
                  end;
                else
                  ;
              end;
            end;
          temprefn:
            begin
              if (chain^.count>high(chain^.temps)) or
                 (ti_addr_taken in ttemprefnode(n).tempflags) or
                 (pi_has_assembler_block in current_procinfo.flags) then
                exit;
              source:=find_single_store(ctx,nil,ttemprefnode(n).tempinfo);
              if assigned(source) then
                begin
                  chain^.syms[chain^.count]:=nil;
                  chain^.temps[chain^.count]:=ttemprefnode(n).tempinfo;
                  inc(chain^.count);
                  result:=resolve_procvar_target(source,ctx,chain);
                end;
            end;
          else
            ;
        end;
      end;


    { rewrites a call through a procvar whose target is a compile-time
      constant into a direct call to that routine }
    procedure try_devirtualize(callnode: tcallnode; ctx: pinlinectx);
      var
        pv : tprocvardef;
        pd : tprocdef;
        para : tcallparanode;
        chain : tdevirtchain;
        i : longint;
      begin
        if assigned(callnode.methodpointer) or
           assigned(callnode.varargsparas) then
          exit;
        pv:=tprocvardef(callnode.procdefinition);
        { only plain procedure pointers: a method pointer or nested procvar
          carries a context value along with the address }
        if not pv.is_addressonly then
          exit;
        chain.count:=0;
        pd:=resolve_procvar_target(callnode.right,ctx,@chain);
        if not assigned(pd) or
           (pd.typ<>procdef) or
           is_nested_pd(pd) or
           (po_anonymous in pd.procoptions) then
          exit;
        { must be call-identical, not merely assignment-compatible }
        if (pd.proccalloption<>pv.proccalloption) or
           (proc_to_procvar_equal(pd,pv,false)<>te_equal) or
           (pd.paras.count<>pv.paras.count) then
          exit;
        { the parameter binding must remap one-to-one }
        para:=tcallparanode(callnode.left);
        while assigned(para) do
          begin
            if not assigned(para.parasym) then
              exit;
            i:=pv.paras.IndexOf(para.parasym);
            if (i<0) or
               (tparavarsym(pd.paras[i]).varspez<>para.parasym.varspez) or
               ((vo_is_hidden_para in tparavarsym(pd.paras[i]).varoptions)<>
                (vo_is_hidden_para in para.parasym.varoptions)) or
               not equal_defs(tparavarsym(pd.paras[i]).vardef,para.parasym.vardef) then
              exit;
            para:=tcallparanode(para.right);
          end;
        para:=tcallparanode(callnode.left);
        while assigned(para) do
          begin
            para.parasym:=tparavarsym(pd.paras[pv.paras.IndexOf(para.parasym)]);
            para:=tcallparanode(para.right);
          end;
        { the resolved forms are pure loads, dropping them loses no effects }
        callnode.right.free;
        callnode.right:=nil;
        remove_dead_chain_stores(ctx,chain);
        callnode.procdefinition:=pd;
        callnode.symtableprocentry:=tprocsym(pd.procsym);
        callnode.symtableproc:=pd.procsym.owner;
        pd.init_paraloc_info(callerside);
        callnode.check_inlining;
        { the call was firstpassed as an indirect one, which never needs a
          function result temp; inlining does }
        callnode.maybe_create_funcret_node;
        CGMessagePos1(callnode.fileinfo,cg_h_devirtualized_call,pd.GetTypeName);
        ctx^.changed:=true;
      end;


    function doinline(var _n: tnode; arg: pointer): foreachnoderesult;
      var
        n,
        body : tnode;
        para : tcallparanode;
        inlineblock,
        inlinecleanupblock : tblocknode;
        callnode: tcallnode;
      begin
        result:=fen_false;
        if not(_n.nodetype=calln) then
          exit;
        callnode:=tcallnode(_n);
        { a call through a procvar whose target address is known becomes a
          direct call, which below may then be inlined; only call sites in
          unleashed units are rewritten, and `$inline off` keeps the call
          indirect so the procvar keeps its value for a debugger }
        if assigned(callnode.right) and
           (callnode.procdefinition.typ=procvardef) and
           (m_unleashed in current_settings.modeswitches) and
           (cs_do_inline in callnode.localswitches) then
          try_devirtualize(callnode,pinlinectx(arg));
        if not(po_inline in callnode.procdefinition.procoptions) then
          exit;

        { assembler bodies are spliced in codegen, not here }
        if cnf_asm_inline in callnode.callnodeflags then
          exit;

        if not(callnode.doinlining) then
          begin
            { a definition-side diagnostic already named the reason once;
              repeating it at every call site is just noise }
            if not(po_compilerproc in callnode.procdefinition.procoptions) and
               not(pio_inline_not_possible in tprocdef(callnode.procdefinition).implprocoptions) then
              Message1(cg_n_no_inline,tprocdef(callnode.procdefinition).customprocname([pno_proctypeoption, pno_paranames,pno_ownername, pno_noclassmarker, pno_prettynames]));
            exit;
          end;

        if not(assigned(tprocdef(callnode.procdefinition).inlininginfo) and
          assigned(tprocdef(callnode.procdefinition).inlininginfo^.code)) then
          internalerror(200412021);

        callnode.inlinelocals:=TFPObjectList.create(true);

        { inherit flags }
        current_procinfo.flags:=current_procinfo.flags+
          ((callnode.procdefinition as tprocdef).inlininginfo^.flags*inherited_inlining_flags);

        { Create new code block for inlining }
        inlineblock:=internalstatements(callnode.inlineinitstatement);
        { make sure that valid_for_assign() returns false for this block
          (otherwise assigning values to the block will result in assigning
           values to the inlined function's result) }
        include(inlineblock.flags,nf_no_lvalue);
        inlinecleanupblock:=internalstatements(callnode.inlinecleanupstatement);

        if assigned(callnode.callinitblock) then
          addstatement(callnode.inlineinitstatement,callnode.callinitblock.getcopy);

        { replace complex parameters with temps }
        callnode.createinlineparas;

        { create a copy of the body and replace parameter loads with the parameter values }
        body:=tprocdef(callnode.procdefinition).inlininginfo^.code.getcopy;
        foreachnodestatic(pm_postprocess,body,@ removeusercodeflag,nil);
        foreachnodestatic(pm_postprocess,body,@importglobalsyms,nil);
        foreachnodestatic(pm_postprocess,body,@setinlinelevel,pointer(callnode.inlinelevel+1));
        foreachnode(pm_preprocess,body,@callnode.replaceparaload,@callnode.fileinfo);
        if assigned(callnode.inlineasmsymmap) then
          foreachnodestatic(pm_postprocess,body,@rewriteinlinedasm,callnode.inlineasmsymmap);

        { Concat the body and finalization parts }
        addstatement(callnode.inlineinitstatement,body);
        addstatement(callnode.inlineinitstatement,inlinecleanupblock);
        inlinecleanupblock:=nil;

        if assigned(callnode.callcleanupblock) then
          addstatement(callnode.inlineinitstatement,callnode.callcleanupblock.getcopy);

        { the last statement of the new inline block must return the
          location and type of the function result.
          This is not needed when the result is not used, also the tempnode is then
          already destroyed  by a tempdelete in the callcleanupblock tree }
        if not is_void(callnode.resultdef) and
           (cnf_return_value_used in callnode.callnodeflags) then
          begin
            if assigned(callnode.funcretnode) then
              addstatement(callnode.inlineinitstatement,callnode.funcretnode.getcopy)
            else
              begin
                para:=tcallparanode(callnode.left);
                while assigned(para) do
                  begin
                    if (vo_is_hidden_para in para.parasym.varoptions) and
                       (vo_is_funcret in para.parasym.varoptions) then
                      begin
                        addstatement(callnode.inlineinitstatement,para.left.getcopy);
                        break;
                      end;
                    para:=tcallparanode(para.right);
                  end;
              end;
          end;

        typecheckpass(tnode(inlineblock));
        doinlinesimplify(tnode(inlineblock));
        firstpass(tnode(inlineblock));
        _n:=inlineblock;

        { if the function result is used then verify that the blocknode
          returns the same result type as the original callnode }
        if (cnf_return_value_used in callnode.callnodeflags) and
           not(equal_defs(_n.resultdef,callnode.resultdef)) then
          internalerror(200709171);

        { free the temps for the locals }
        callnode.inlinelocals.free;
        callnode.inlinelocals:=nil;
        callnode.inlineasmsyms.free;
        callnode.inlineasmsyms:=nil;
        callnode.inlineasmsymmap.free;
        callnode.inlineasmsymmap:=nil;
        callnode.inlineinitstatement:=nil;
        callnode.inlinecleanupstatement:=nil;

        n:=callnode.optimize_funcret_assignment(inlineblock);
        if assigned(n) then
          begin
            inlineblock.free;
            inlineblock:=nil;
            _n:=n;
            { the replacement can itself be a call node (the inlined body was
              a lone function call): the walk only descends into the children
              of a replaced node, so process it here or it escapes the pass }
            if _n.nodetype=calln then
              result:=doinline(_n,arg);
          end;

        { the inlined block takes the place of the call node, so it has to
          inherit its currency scaling state: without it, the enclosing
          taddnode sees an operand that is no longer marked as scaled and
          taddnode.do_currency_corrections applies the 10000 scalar a second
          time }
        if (cnf_return_value_used in callnode.callnodeflags) and
           (nf_is_currency in callnode.flags) then
          include(_n.flags,nf_is_currency);

        pinlinectx(arg)^.changed:=true;

{$ifdef EXTDEBUG_INLINE}
        writeln;
        writeln('**************************************************************************************************************');
        writeln('************************** Inlined ',tprocdef(callnode.procdefinition).mangledname,'**************************');
        writeln('**************************************************************************************************************');
{$endif EXTDEBUG_INLINE}
      end;


    procedure do_optinline(var rootnode: tnode;out changed: boolean);
      var
        ctx : tinlinectx;
      begin
        ctx.changed:=false;
        ctx.root:=@rootnode;
{$ifdef EXTDEBUG_INLINE}
        writeln('************************ Tree before inlining ******************************');
        printnode(rootnode);
        writeln('****************************************************************************');
{$endif EXTDEBUG_INLINE}
        foreachnodestatic(pm_postprocess, rootnode, @doinline, @ctx);
        changed:=ctx.changed;
        if changed then
          begin
            doinlinesimplify(rootnode);
            { after inlining, call nodes in the tree may have parameters
              whose subtrees now contain additional calls (e.g. fpc_shortstr_sint
              from an inlined str() call). The parent call nodes need their
              parameter analysis redone to recalculate parameter ordering and
              stack tainting info, otherwise parameters may be evaluated in the
              wrong order corrupting already pushed stack parameters }
            foreachnodestatic(pm_postprocess,rootnode,@redoalinaparams,nil);
{$ifdef EXTDEBUG_INLINE}
            writeln('************************ Tree after inlining ******************************');
            printnode(rootnode);
            writeln('****************************************************************************');
{$endif EXTDEBUG_INLINE}
          end;
      end;

end.

