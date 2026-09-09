{
    Copyright (c) 2018 by Jonas Maebe
    Copyright (c) 2011-2021 by Blaise.ru

    This unit provides helpers for creating procdefs

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
{$i fpcdefs.inc}
unit procdefutil;

interface

uses
  globtype,procinfo,
  symconst,symtype,symdef,
  node,nbas;

{ create a nested procdef that will be used to outline code from a procedure;
  astruct should usually be nil, except in special cases like the Windows SEH
  exception handling funclets }
function create_outline_procdef(const basesymname: string; astruct: tabstractrecorddef; potype: tproctypeoption; resultdef: tdef): tprocdef;

procedure convert_to_funcref_intf(const n:tidstring;var def:tdef);
function adjust_funcref(var def:tdef;sym,dummysym:tsym):boolean;

{ synthesized COM interface for `future of T` (elemdef) or bare `future`
  (elemdef=nil); interned per-module, exposes the `__Await` method that
  `await` lowers to and the worker-control methods (`Cancel`, `Cancelled`,
  `Done`, `ThreadID`) }
function get_future_intf_def(elemdef:tdef):tobjectdef;

{ the function-reference interface for a parameterless anonymous procedure
  (used to convert an `async begin..end` block into a captured funcref) }
function async_block_funcref(pd:tprocdef):tobjectdef;

{ the function-reference interface matching an anonymous routine's
  signature; the same one the capturer binds the routine to }
function anon_proc_funcref(pd:tprocdef):tobjectdef;

{ rewrites `async`/`await` nodes in a routine body into the future-impl factory
  call and the `__Await` method call; no-op for routines without them }
procedure lower_async(pi:tprocinfo);

{ functionality related to capturing local variables for anonymous functions }

function get_or_create_capturer(pd:tprocdef):tsym;
function capturer_add_anonymous_proc(owner:tprocinfo;pd:tprocdef;out capturer:tsym):tobjectdef;
function capturer_add_procvar_or_proc(owner:tprocinfo;n:tnode;out capturer:tsym;out capturen:tnode):tobjectdef;
procedure initialize_capturer(ctx:tprocinfo;var stmt:tstatementnode);
procedure postprocess_capturer(ctx:tprocinfo);
procedure convert_captured_syms(pd:tprocdef;tree:tnode);

implementation

  uses
    cutils,cclasses,verbose,globals,constexp,
    fmodule,
    pass_1,
    nobj,ncal,nmem,nld,nutils,ncnv,nflw,nadd,ncon,
    ngenutil,
    symbase,symsym,symtable,defutil,defcmp,
    htypechk,
    pparautl,psub;


  function get_future_intf_def(elemdef:tdef):tobjectdef;

    function add_intf_method(intf:tobjectdef;const mname:string;rettype:tdef):tprocdef;
      var
        oldstack : tsymtablestack;
      begin
        oldstack:=symtablestack;
        symtablestack:=nil;
        result:=cprocdef.create(normal_function_level,false);
        result.struct:=intf;
        if assigned(rettype) then
          begin
            result.proctypeoption:=potype_function;
            result.returndef:=rettype;
          end
        else
          begin
            result.proctypeoption:=potype_procedure;
            result.returndef:=voidtype;
          end;
        result.proccalloption:=pocall_default;
        include(result.procoptions,po_hascallingconvention);
        include(result.procoptions,po_virtualmethod);
        exclude(result.procoptions,po_staticmethod);
        exclude(result.procoptions,po_classmethod);
        exclude(result.procoptions,po_delphi_nested_cc);
        result.forwarddef:=false;
        result.procsym:=cprocsym.create(mname);
        result.visibility:=vis_public;
        intf.symtable.insertsym(result.procsym);
        intf.symtable.insertdef(result);
        handle_calling_convention(result,hcc_default_actions_intf_struct);
        proc_add_definition(result);
        result.calcparas;
        symtablestack:=oldstack;
      end;

    var
      name : tsymstr;
      sym : tsym;
      symowner : tsymtable;
    begin
      if assigned(elemdef) then
        name:='$FUTURE$'+tostr(elemdef.defid)
      else
        name:='$FUTURE$VOID';
      { intern in a table that lives for the whole module: a unit's
        globalsymtable while its interface is being parsed (visible to
        importers), the localsymtable afterwards - inserting into the
        globalsymtable once the interface is closed would add a def behind the
        already-built PPU registration and break the deref pass. lookup checks
        both, so an interface-interned future is found from the implementation.
        symtable stores `$`-prefixed names without the leading `$` (marks them
        inaccessible to users), so search under the stripped key }
      sym:=nil;
      if assigned(current_module.globalsymtable) then
        sym:=tsym(current_module.globalsymtable.find(copy(name,2,length(name))));
      if not assigned(sym) and assigned(current_module.localsymtable) then
        sym:=tsym(current_module.localsymtable.find(copy(name,2,length(name))));
      if assigned(sym) then
        begin
          if (sym.typ<>typesym) or not is_future_intf(ttypesym(sym).typedef) then
            internalerror(2026061301);
          result:=tobjectdef(ttypesym(sym).typedef);
          exit;
        end;
      if current_module.in_interface then
        symowner:=current_module.globalsymtable
      else
        symowner:=current_module.localsymtable;

      result:=cobjectdef.create(odt_interfacecom,name,interface_iunknown,false);
      include(result.objectoptions,oo_has_virtual);

      sym:=ctypesym.create(name,result);
      symowner.insertsym(sym);
      symowner.insertdef(result);
      addsymref(sym);

      add_intf_method(result,'__Await',elemdef);
      // worker-control surface: a cooperative cancel flag and non-blocking
      // state reads, implemented by every future-impl class
      add_intf_method(result,'Cancel',nil);
      add_intf_method(result,'Cancelled',pasbool8type);
      add_intf_method(result,'Done',pasbool8type);
      add_intf_method(result,'ThreadID',search_system_type('TTHREADID').typedef);

      build_vmt(result);
    end;


  function async_refs_local(var n:tnode;arg:pointer):foreachnoderesult;
    var
      found : pboolean absolute arg;
      sym : tsym;
    begin
      result:=fen_false;
      if not assigned(current_procinfo) then
        exit;
      if n.nodetype=loadn then
        begin
          sym:=tloadnode(n).symtableentry;
          if assigned(sym) and
             ((sym.owner=current_procinfo.procdef.localst) or
              (sym.owner=current_procinfo.procdef.parast)) then
            found^:=true;
        end
      else if n.nodetype=loadparentfpn then
        found^:=true;
    end;


  { the node an async call snapshots for an argument. an open array
    parameter takes a dynamic array through an address/deref pair and an
    array literal through a conversion to a constant open array; neither
    wrapper has a value of its own, so the array behind it is copied and
    the rebuilt call converts it again. detach unlinks it from the wrapper }
  function async_snapshot_arg(arg:tnode;detach:boolean):tnode;
    var
      wrapper : tnode;
    begin
      result:=arg;
      wrapper:=nil;
      if (arg.nodetype=derefn) and is_dynamic_array(arg.resultdef) and
         (tderefnode(arg).left.nodetype=typeconvn) then
        wrapper:=tderefnode(arg).left
      else if (arg.nodetype=typeconvn) and
         (ttypeconvnode(arg).left.nodetype=arrayconstructorn) then
        wrapper:=arg;
      if assigned(wrapper) then
        begin
          result:=ttypeconvnode(wrapper).left;
          if detach then
            ttypeconvnode(wrapper).left:=nil;
        end;
    end;


  function resolve_async_future(left:tnode;isblock:boolean):tdef;
    var
      refslocal : boolean;
      cpn : tcallparanode;
    begin
      if isblock then
        begin
          { `async begin..end` yields no value - a bare future }
          result:=get_future_intf_def(nil);
          exit;
        end;
      { the call form runs a routine call (calln) or a statement-shaped intrinsic
        like writeln (inlinen / a synthesized blockn) on the worker thread }
      if not assigned(left) or not (left.nodetype in [calln,inlinen,blockn]) then
        begin
          if assigned(left) then
            MessagePos(left.fileinfo,parser_e_async_needs_call)
          else
            Message(parser_e_async_needs_call);
          result:=generrordef;
          exit;
        end;
      { a statement intrinsic (writeln etc.) is moved to the worker verbatim, so
        it must not read the spawning routine's locals - require the block form }
      if left.nodetype in [inlinen,blockn] then
        begin
          refslocal:=false;
          foreachnodestatic(pm_postprocess,left,@async_refs_local,@refslocal);
          if refslocal then
            begin
              MessagePos(left.fileinfo,parser_e_async_stmt_captures_local);
              result:=generrordef;
              exit;
            end;
        end;
      { a nested routine reads its parent's frame, which the worker outlives;
        this also catches procvars with the nested calling convention }
      if (left.nodetype=calln) and
         assigned(tcallnode(left).procdefinition) and
         is_nested_pd(tcallnode(left).procdefinition) then
        begin
          MessagePos(left.fileinfo,parser_e_async_no_nested);
          result:=generrordef;
          exit;
        end;
      { a var/out argument cannot survive the by-value snapshot: the worker
        would write to the copy and the caller's variable would never change }
      if left.nodetype=calln then
        begin
          cpn:=tcallparanode(tcallnode(left).left);
          while assigned(cpn) do
            begin
              if assigned(cpn.parasym) and
                 not (vo_is_hidden_para in cpn.parasym.varoptions) and
                 (cpn.parasym.varspez in [vs_var,vs_out]) then
                begin
                  MessagePos(cpn.fileinfo,parser_e_async_no_var_param);
                  result:=generrordef;
                  exit;
                end;
              { an open array has no value of its own to snapshot; only a
                real array (see async_snapshot_arg) can be passed for it }
              if assigned(cpn.parasym) and is_open_array(cpn.parasym.vardef) and
                 is_open_array(async_snapshot_arg(cpn.left,false).resultdef) then
                begin
                  MessagePos(cpn.fileinfo,parser_e_async_no_open_array_param);
                  result:=generrordef;
                  exit;
                end;
              cpn:=tcallparanode(cpn.right);
            end;
        end;
      if not assigned(left.resultdef) or is_void(left.resultdef) then
        result:=get_future_intf_def(nil)
      else
        result:=get_future_intf_def(left.resultdef);
    end;


  type
    pasynclowerctx = ^tasynclowerctx;
    tasynclowerctx = record
      pi : tprocinfo;
    end;

  var
    { monotonic sequence for naming the per-call-site future-impl classes; a
      routine's defid is not unique here (unregistered defs share defid_not_registered),
      so the name must not be derived from it }
    asyncimplseq : longint = 0;


  { queue a synthesized module-level method for typecheck + code generation at
    module finish (where current_procinfo is nil, like unit init/final) }
  procedure async_defer_method(pd:tprocdef;body:tnode);
    var
      mpi : tcgprocinfo;
    begin
      pd.forwarddef:=true;
      if not assigned(current_module.async_thunks) then
        current_module.async_thunks:=tfplist.create;
      mpi:=tcgprocinfo(cprocinfo.create(nil));
      mpi.procdef:=pd;
      mpi.code:=body;
      current_module.async_thunks.add(mpi);
    end;


  function async_find_self(pd:tprocdef):tsym;
    var
      i : longint;
      sym : tsym;
    begin
      result:=nil;
      for i:=0 to pd.parast.symlist.count-1 do
        begin
          sym:=tsym(pd.parast.symlist[i]);
          if (sym.typ=paravarsym) and (vo_is_self in tparavarsym(sym).varoptions) then
            exit(sym);
        end;
    end;


  { synthesize `destructor Destroy; override;` on a future-impl class: releases
    the RTL event, a swallowed worker exception (never awaited), and the thread
    handle. no `inherited` call - TObject.Destroy is an empty stub and the
    managed fields are finalized by FreeInstance after the destructor chain }
  procedure async_add_destructor(clsdef:tobjectdef;fEvent,fExc,fTid:tfieldvarsym);
    var
      pd : tprocdef;
      oldstack : tsymtablestack;
      selfsym,sym : tsym;
      body : tnode;
      stmt : tstatementnode;
      i : longint;

    function fld(f:tfieldvarsym):tnode;
      begin
        result:=csubscriptnode.create(f,cloadnode.create(selfsym,selfsym.owner));
      end;

    begin
      oldstack:=symtablestack;
      symtablestack:=nil;
      pd:=cprocdef.create(normal_function_level,false);
      pd.struct:=clsdef;
      pd.proctypeoption:=potype_destructor;
      pd.returndef:=voidtype;
      pd.proccalloption:=pocall_default;
      include(pd.procoptions,po_hascallingconvention);
      include(pd.procoptions,po_virtualmethod);
      include(pd.procoptions,po_overridingmethod);
      exclude(pd.procoptions,po_delphi_nested_cc);
      pd.forwarddef:=false;
      pd.procsym:=cprocsym.create('Destroy');
      pd.visibility:=vis_public;
      clsdef.symtable.insertsym(pd.procsym);
      clsdef.symtable.insertdef(pd);
      handle_calling_convention(pd,hcc_default_actions_impl);
      proc_add_definition(pd);
      insert_funcret_local(pd);
      pd.calcparas;
      symtablestack:=oldstack;
      { the hidden `$vmt` parameter got a fresh classrefdef while the symtable
        stack was nil, leaving it unowned - codegen walks a def's owner chain,
        so adopt it into the module }
      for i:=0 to pd.parast.symlist.count-1 do
        begin
          sym:=tsym(pd.parast.symlist[i]);
          if (sym.typ=paravarsym) and (vo_is_vmt in tparavarsym(sym).varoptions) and
             not assigned(tparavarsym(sym).vardef.owner) then
            current_module.localsymtable.insertdef(tparavarsym(sym).vardef);
        end;
      selfsym:=async_find_self(pd);
      body:=internalstatements(stmt);
      addstatement(stmt,cifnode.create(
        caddnode.create(unequaln,fld(fEvent),cnilnode.create),
        ccallnode.createintern('RTLEVENTDESTROY',ccallparanode.create(fld(fEvent),nil)),
        nil));
      addstatement(stmt,cifnode.create(
        caddnode.create(unequaln,fld(fExc),cnilnode.create),
        ccallnode.create(nil,tprocsym(class_tobject.symtable.find('FREE')),class_tobject.symtable,fld(fExc),[],nil),
        nil));
      { TThreadID is ordinal on some targets and pointer-like on others, so
        compare against a zero constant cast to it (folds at typecheck) }
      addstatement(stmt,cifnode.create(
        caddnode.create(unequaln,
          fld(fTid),
          ctypeconvnode.create_internal(cordconstnode.create(0,ptruinttype,false),fTid.vardef)),
        ccallnode.createintern('CLOSETHREAD',ccallparanode.create(fld(fTid),nil)),
        nil));
      async_defer_method(pd,body);
    end;


  { synthesize the worker-control methods on a future-impl class: `Cancel`
    raises the cooperative flag, `Cancelled`/`Done` read the flags without
    blocking, `ThreadID` returns the id BeginThread handed back (usable with
    the RTL thread API) }
  procedure async_add_control_methods(clsdef:tobjectdef;fCancel,fDone,fTid:tfieldvarsym);

    function new_method(const mname:string;rettype:tdef):tprocdef;
      var
        oldstack : tsymtablestack;
      begin
        oldstack:=symtablestack;
        symtablestack:=nil;
        result:=cprocdef.create(normal_function_level,false);
        result.struct:=clsdef;
        if assigned(rettype) then
          begin
            result.proctypeoption:=potype_function;
            result.returndef:=rettype;
          end
        else
          begin
            result.proctypeoption:=potype_procedure;
            result.returndef:=voidtype;
          end;
        result.proccalloption:=pocall_default;
        include(result.procoptions,po_hascallingconvention);
        include(result.procoptions,po_virtualmethod);
        exclude(result.procoptions,po_delphi_nested_cc);
        result.forwarddef:=false;
        result.procsym:=cprocsym.create(mname);
        result.visibility:=vis_public;
        clsdef.symtable.insertsym(result.procsym);
        clsdef.symtable.insertdef(result);
        handle_calling_convention(result,hcc_default_actions_impl);
        proc_add_definition(result);
        insert_funcret_local(result);
        result.calcparas;
        symtablestack:=oldstack;
      end;

    function self_field(pd:tprocdef;f:tfieldvarsym):tnode;
      var
        s : tsym;
      begin
        s:=async_find_self(pd);
        result:=csubscriptnode.create(f,cloadnode.create(s,s.owner));
      end;

    procedure add_getter(const mname:string;f:tfieldvarsym;rettype:tdef);
      var
        pd : tprocdef;
        body : tnode;
        stmt : tstatementnode;
      begin
        pd:=new_method(mname,rettype);
        body:=internalstatements(stmt);
        addstatement(stmt,cassignmentnode.create(
          cloadnode.create(pd.funcretsym,pd.funcretsym.owner),self_field(pd,f)));
        async_defer_method(pd,body);
      end;

    var
      pd : tprocdef;
      body : tnode;
      stmt : tstatementnode;
    begin
      pd:=new_method('Cancel',nil);
      body:=internalstatements(stmt);
      addstatement(stmt,cassignmentnode.create(self_field(pd,fCancel),
        cordconstnode.create(1,pasbool8type,false)));
      async_defer_method(pd,body);
      add_getter('Cancelled',fCancel,pasbool8type);
      add_getter('Done',fDone,pasbool8type);
      add_getter('ThreadID',fTid,fTid.vardef);
    end;


  { `await f` -> f.__Await (a plain interface method call) }
  function build_one_await(an:tawaitnode):tnode;
    var
      futureintf : tobjectdef;
      awaitsym : tsym;
      fnode : tnode;
    begin
      result:=an;
      if not assigned(an.left) or not is_future_intf(an.left.resultdef) then
        exit;
      futureintf:=tobjectdef(an.left.resultdef);
      awaitsym:=tsym(futureintf.symtable.find('__AWAIT'));
      if not assigned(awaitsym) or (awaitsym.typ<>procsym) then
        internalerror(2026061304);
      fnode:=an.left;
      an.left:=nil;
      result:=ccallnode.create(nil,tprocsym(awaitsym),futureintf.symtable,fnode,[],nil);
      an.free;
    end;


  { `async f(args)` -> $async$N.__Spawn(args): a synthesized TInterfacedObject
    that snapshots the arguments, runs the call on a worker thread, and exposes
    the result (or exception) through the future interface's `__Await` method }
  function build_one_async_call(an:tasyncnode;ctx:pasynclowerctx):tnode;
    var
      clsdef,
      futureintf : tobjectdef;
      origcall : tcallnode;
      origprocsym : tprocsym;
      origst : tsymtable;
      elemdef,
      selfdef,
      pvdef : tdef;
      isvoid,
      ismethod,
      isprocvar,
      isinline : boolean;
      inlinework,
      argnode : tnode;
      argdef : tdef;
      argnodes,
      argdefs,
      argfields,
      spawnargsyms : tfplist;
      fEvent,fExc,fKeep,fRes,fSelf,fPv,fTid,fCancel,fDone : tfieldvarsym;
      thunkpd,spawnpd,awaitpd : tprocdef;
      implsym : tlocalvarsym;
      pparam : tparavarsym;
      spawnselfpara : tparavarsym;
      i : longint;
      cpn : tcallparanode;
      body,thenblk : tnode;
      stmt,thenstmt : tstatementnode;
      workcall : tnode;
      newparams,callparams : tcallparanode;
      excloc : tlocalvarsym;
      clsname : tsymstr;
      clssym : ttypesym;

    function add_field(const fname:string;ftype:tdef):tfieldvarsym;
      begin
        result:=cfieldvarsym.create(fname,vs_value,ftype,[]);
        clsdef.symtable.insertsym(result);
        tabstractrecordsymtable(clsdef.symtable).addfield(result,vis_public);
      end;

    function new_method(const mname:string;rettype:tdef;isstatic:boolean):tprocdef;
      var
        oldstack : tsymtablestack;
      begin
        oldstack:=symtablestack;
        symtablestack:=nil;
        result:=cprocdef.create(normal_function_level,false);
        result.struct:=clsdef;
        if assigned(rettype) then
          begin
            result.proctypeoption:=potype_function;
            result.returndef:=rettype;
          end
        else
          begin
            result.proctypeoption:=potype_procedure;
            result.returndef:=voidtype;
          end;
        result.proccalloption:=pocall_default;
        include(result.procoptions,po_hascallingconvention);
        if isstatic then
          begin
            include(result.procoptions,po_classmethod);
            include(result.procoptions,po_staticmethod);
          end
        else
          include(result.procoptions,po_virtualmethod);
        exclude(result.procoptions,po_delphi_nested_cc);
        result.forwarddef:=false;
        result.procsym:=cprocsym.create(mname);
        result.visibility:=vis_public;
        clsdef.symtable.insertsym(result.procsym);
        clsdef.symtable.insertdef(result);
        symtablestack:=oldstack;
      end;

    procedure finish_method(pd:tprocdef);
      var
        oldstack : tsymtablestack;
      begin
        oldstack:=symtablestack;
        symtablestack:=nil;
        handle_calling_convention(pd,hcc_default_actions_impl);
        proc_add_definition(pd);
        insert_funcret_local(pd);
        pd.calcparas;
        symtablestack:=oldstack;
      end;

    function field_on(f:tfieldvarsym;objnode:tnode):tnode;
      begin
        result:=csubscriptnode.create(f,objnode);
      end;

    function self_field(pd:tprocdef;f:tfieldvarsym):tnode;
      var
        s : tsym;
      begin
        s:=async_find_self(pd);
        result:=csubscriptnode.create(f,cloadnode.create(s,s.owner));
      end;

    function impl_field(f:tfieldvarsym):tnode;
      begin
        result:=csubscriptnode.create(f,cloadnode.create(implsym,implsym.owner));
      end;

    function rtl(const name:string;params:tnode):tnode;
      begin
        result:=ccallnode.createintern(name,params);
      end;

    begin
      result:=an;
      futureintf:=tobjectdef(an.resultdef);
      if not is_future_intf(futureintf) then
        exit;
      if not assigned(an.left) or not (an.left.nodetype in [calln,inlinen,blockn]) then
        exit;
      origcall:=nil;
      origprocsym:=nil;
      origst:=nil;
      elemdef:=nil;
      ismethod:=false;
      selfdef:=nil;
      argnodes:=tfplist.create;
      argdefs:=tfplist.create;
      argfields:=tfplist.create;
      spawnargsyms:=tfplist.create;
      { a statement-shaped intrinsic (writeln etc.) is moved to the worker as-is
        and yields a bare future; a routine call snapshots its arguments }
      isprocvar:=false;
      pvdef:=nil;
      isinline:=an.left.nodetype<>calln;
      if isinline then
        begin
          inlinework:=an.left;
          an.left:=nil;
          isvoid:=true;
        end
      else
        begin
          inlinework:=nil;
          origcall:=tcallnode(an.left);
          an.left:=nil;
          elemdef:=origcall.resultdef;
          isvoid:=(elemdef=nil) or is_void(elemdef);
          origprocsym:=origcall.symtableprocentry;
          origst:=origcall.symtableproc;
          { for a specialized generic, re-resolving through the generic's
            procsym would land on the unspecialized def (T still open); bind
            the rebuilt call to the specialization's own symbol instead }
          if assigned(origcall.procdefinition) and
             (origcall.procdefinition.typ=procdef) and
             (df_specialization in origcall.procdefinition.defoptions) then
            begin
              origprocsym:=tprocsym(tprocdef(origcall.procdefinition).procsym);
              origst:=origprocsym.owner;
            end;
          ismethod:=assigned(origcall.methodpointer);
          { a call through a procedural variable carries the procvar expression
            in `right`; snapshot it like any other argument }
          isprocvar:=assigned(origcall.right);
          if isprocvar then
            pvdef:=origcall.right.resultdef;
          { collect the call arguments (detaching them so they move to the
            factory call), recording each type for the snapshot field/parameter }
          cpn:=tcallparanode(origcall.left);
          while assigned(cpn) do
            begin
              { skip compiler-inserted hidden parameters (e.g. the managed-result
                buffer); the rebuilt call regenerates them at its own firstpass }
              if not (assigned(cpn.parasym) and (vo_is_hidden_para in cpn.parasym.varoptions)) then
                begin
                  argnode:=async_snapshot_arg(cpn.left,true);
                  argnodes.add(argnode);
                  { an array literal is stored as a dynamic array of the
                    parameter's element type }
                  if argnode.nodetype=arrayconstructorn then
                    begin
                      argdef:=carraydef.create(0,-1,ptruinttype);
                      tarraydef(argdef).arrayoptions:=tarraydef(argdef).arrayoptions+[ado_IsDynamicArray];
                      tarraydef(argdef).elementdef:=tarraydef(cpn.parasym.vardef).elementdef;
                      argdefs.add(argdef);
                    end
                  else
                    argdefs.add(argnode.resultdef);
                  cpn.left:=nil;
                end;
              cpn:=tcallparanode(cpn.right);
            end;
        end;

      { the impl class and all its methods live at module level (and are
        code-generated at module finish) so nothing captures the caller frame:
        the worker thread holds only a raw pointer and a static thunk address }
      inc(asyncimplseq);
      clsname:='$async$'+tostr(asyncimplseq);
      clsdef:=cobjectdef.create(odt_class,clsname,
        tobjectdef(search_system_type('TINTERFACEDOBJECT').typedef),false);
      current_module.localsymtable.insertdef(clsdef);
      { never looked up by name, so the unused-symbol pass must skip it }
      clssym:=ctypesym.create(clsname,clsdef);
      include(clssym.symoptions,sp_internal);
      current_module.localsymtable.insertsym(clssym);
      clsdef.register_implemented_interface(futureintf,true);

      fEvent:=add_field('__event',search_system_type('PRTLEVENT').typedef);
      fExc:=add_field('__exc',class_tobject);
      fKeep:=add_field('__keepalive',interface_iunknown);
      fTid:=add_field('__tid',search_system_type('TTHREADID').typedef);
      fCancel:=add_field('__cancel',pasbool8type);
      fDone:=add_field('__done',pasbool8type);
      fRes:=nil;
      if not isvoid then
        fRes:=add_field('__res',elemdef);
      fSelf:=nil;
      if ismethod then
        begin
          selfdef:=origcall.methodpointer.resultdef;
          fSelf:=add_field('__self',selfdef);
        end;
      fPv:=nil;
      if isprocvar then
        fPv:=add_field('__pv',pvdef);
      for i:=0 to argdefs.count-1 do
        argfields.add(add_field('__a'+tostr(i),tdef(argdefs[i])));

      { ---- __Thunk: the TThreadFunc-compatible static thread entry. its address
        is passed to BeginThread; being a static method of a module-level class
        makes it a plain global code pointer that captures no frame ---- }
      thunkpd:=new_method('__Thunk',ptrsinttype,true);
      pparam:=cparavarsym.create('p',10,vs_value,voidpointertype,[]);
      thunkpd.parast.insertsym(pparam);
      finish_method(thunkpd);
      implsym:=clocalvarsym.create('__impl',vs_value,clsdef,[]);
      thunkpd.localst.insertsym(implsym);
      excloc:=nil;

      if isinline then
        { the statement intrinsic carries its own (literal) operands; run it directly }
        workcall:=inlinework
      else
        begin
          { rebuild the original call against the snapshot fields. the parameter
            chain is in reverse source order (first node = last argument), so
            `__a0` holds the last argument and prepending has to start at the
            highest field index to put them back in their original slots }
          newparams:=nil;
          for i:=argfields.count-1 downto 0 do
            newparams:=ccallparanode.create(impl_field(tfieldvarsym(argfields[i])),newparams);
          { visibility was already checked when the async site resolved the
            call; the rebuilt call typechecks inside the impl class, where a
            strict private target would wrongly drop out of the candidates }
          if isprocvar then
            workcall:=ccallnode.create_procvar(newparams,impl_field(fPv))
          else if ismethod then
            workcall:=ccallnode.create(newparams,origprocsym,origst,impl_field(fSelf),[cnf_ignore_visibility],nil)
          else
            workcall:=ccallnode.create(newparams,origprocsym,origst,nil,[cnf_ignore_visibility],nil);
          if not isvoid then
            workcall:=cassignmentnode.create(impl_field(fRes),workcall);
        end;

      body:=internalstatements(stmt);
      addstatement(stmt,cassignmentnode.create(cloadnode.create(implsym,implsym.owner),
        ctypeconvnode.create_internal(cloadnode.create(pparam,pparam.owner),clsdef)));
      { try work except __exc := AcquireExceptionObject; the catch-all handler
        is the third argument (the second is the `on` chain, here empty) }
      addstatement(stmt,ctryexceptnode.create(
        workcall,
        nil,
        cassignmentnode.create(impl_field(fExc),
          ctypeconvnode.create_internal(rtl('ACQUIREEXCEPTIONOBJECT',nil),class_tobject))));
      // the work (or its exception capture) is complete - publish it for the
      // non-blocking `Done` probe before releasing any awaiter
      addstatement(stmt,cassignmentnode.create(impl_field(fDone),
        cordconstnode.create(1,pasbool8type,false)));
      addstatement(stmt,rtl('RTLEVENTSETEVENT',ccallparanode.create(impl_field(fEvent),nil)));
      addstatement(stmt,cassignmentnode.create(impl_field(fKeep),cnilnode.create));
      addstatement(stmt,cassignmentnode.create(cloadnode.create(thunkpd.funcretsym,thunkpd.funcretsym.owner),
        cordconstnode.create(0,ptrsinttype,false)));
      async_defer_method(thunkpd,body);

      { ---- __Await: the future interface method awaited on the caller ---- }
      if isvoid then
        awaitpd:=new_method('__Await',nil,false)
      else
        awaitpd:=new_method('__Await',elemdef,false);
      finish_method(awaitpd);
      excloc:=clocalvarsym.create('__e',vs_value,class_tobject,[]);
      awaitpd.localst.insertsym(excloc);
      body:=internalstatements(stmt);
      addstatement(stmt,rtl('RTLEVENTWAITFOR',ccallparanode.create(self_field(awaitpd,fEvent),nil)));
      { re-arm so a second await also passes and reads the cached result }
      addstatement(stmt,rtl('RTLEVENTSETEVENT',ccallparanode.create(self_field(awaitpd,fEvent),nil)));
      { if assigned(__exc) then begin __e:=__exc; __exc:=nil; raise __e end }
      thenblk:=internalstatements(thenstmt);
      addstatement(thenstmt,cassignmentnode.create(cloadnode.create(excloc,excloc.owner),self_field(awaitpd,fExc)));
      addstatement(thenstmt,cassignmentnode.create(self_field(awaitpd,fExc),cnilnode.create));
      addstatement(thenstmt,craisenode.create(cloadnode.create(excloc,excloc.owner),nil,nil));
      addstatement(stmt,cifnode.create(
        caddnode.create(unequaln,self_field(awaitpd,fExc),cnilnode.create),
        thenblk,
        nil));
      if not isvoid then
        addstatement(stmt,cassignmentnode.create(
          cloadnode.create(awaitpd.funcretsym,awaitpd.funcretsym.owner),self_field(awaitpd,fRes)));
      async_defer_method(awaitpd,body);

      { ---- __Spawn: the static factory called at the `async` site ---- }
      spawnpd:=new_method('__Spawn',futureintf,true);
      spawnselfpara:=nil;
      if ismethod then
        begin
          spawnselfpara:=cparavarsym.create('aself',5,vs_value,selfdef,[]);
          spawnpd.parast.insertsym(spawnselfpara);
        end
      else if isprocvar then
        begin
          spawnselfpara:=cparavarsym.create('apv',5,vs_value,pvdef,[]);
          spawnpd.parast.insertsym(spawnselfpara);
        end;
      for i:=0 to argdefs.count-1 do
        begin
          pparam:=cparavarsym.create('a'+tostr(i),(i+1)*10,vs_value,tdef(argdefs[i]),[]);
          spawnpd.parast.insertsym(pparam);
          spawnargsyms.add(pparam);
        end;
      finish_method(spawnpd);
      implsym:=clocalvarsym.create('__impl',vs_value,clsdef,[]);
      spawnpd.localst.insertsym(implsym);
      body:=internalstatements(stmt);
      addstatement(stmt,cassignmentnode.create(cloadnode.create(implsym,implsym.owner),
        ccallnode.create(nil,tprocsym(class_tobject.symtable.find('CREATE')),clsdef.symtable,
          cloadvmtaddrnode.create(ctypenode.create(clsdef)),[],nil)));
      if ismethod then
        addstatement(stmt,cassignmentnode.create(impl_field(fSelf),
          cloadnode.create(spawnselfpara,spawnselfpara.owner)))
      else if isprocvar then
        addstatement(stmt,cassignmentnode.create(impl_field(fPv),
          cloadnode.create(spawnselfpara,spawnselfpara.owner)));
      for i:=0 to argdefs.count-1 do
        begin
          pparam:=tparavarsym(spawnargsyms[i]);
          addstatement(stmt,cassignmentnode.create(impl_field(tfieldvarsym(argfields[i])),
            cloadnode.create(pparam,pparam.owner)));
        end;
      addstatement(stmt,cassignmentnode.create(impl_field(fEvent),rtl('RTLEVENTCREATE',nil)));
      addstatement(stmt,cassignmentnode.create(impl_field(fKeep),cloadnode.create(implsym,implsym.owner)));
      addstatement(stmt,cassignmentnode.create(impl_field(fTid),rtl('BEGINTHREAD',
        ccallparanode.create(
          ctypeconvnode.create_internal(cloadnode.create(implsym,implsym.owner),voidpointertype),
          ccallparanode.create(
            ctypeconvnode.create_proc_to_procvar(cloadnode.create_procvar(thunkpd.procsym,thunkpd,thunkpd.procsym.owner)),
            nil)))));
      addstatement(stmt,cassignmentnode.create(
        cloadnode.create(spawnpd.funcretsym,spawnpd.funcretsym.owner),cloadnode.create(implsym,implsym.owner)));
      async_defer_method(spawnpd,body);

      async_add_destructor(clsdef,fEvent,fExc,fTid);
      async_add_control_methods(clsdef,fCancel,fDone,fTid);

      build_vmt(clsdef);

      { ---- replace the `async` site with `$async$N.__Spawn(args)`. the factory
        takes `aself` first (lowest paranr) then the call arguments, so in the
        reverse-order chain the snapshotted self ends up last ---- }
      callparams:=nil;
      if ismethod then
        begin
          callparams:=ccallparanode.create(origcall.methodpointer,nil);
          origcall.methodpointer:=nil;
        end
      else if isprocvar then
        begin
          callparams:=ccallparanode.create(origcall.right,nil);
          origcall.right:=nil;
        end;
      for i:=0 to argnodes.count-1 do
        callparams:=ccallparanode.create(tnode(argnodes[i]),callparams);
      result:=ccallnode.create(callparams,tprocsym(spawnpd.procsym),clsdef.symtable,
        cloadvmtaddrnode.create(ctypenode.create(clsdef)),[],nil);

      argnodes.free;
      argdefs.free;
      argfields.free;
      spawnargsyms.free;
      if assigned(origcall) then
        origcall.free;
    end;


  { `async begin..end` -> $async$N.__Spawn(<anonymous proc reference>): the block
    was parsed into a function reference whose capturer holds the referenced
    locals by reference, so the worker runs it and sees later mutations. always
    a bare future (no result). }
  function build_one_async_block(an:tasyncnode;ctx:pasynclowerctx):tnode;
    var
      clsdef,
      futureintf : tobjectdef;
      procnode : tnode;
      procreftype : tdef;
      fEvent,fExc,fKeep,fProc,fTid,fCancel,fDone : tfieldvarsym;
      thunkpd,spawnpd,awaitpd : tprocdef;
      implsym : tlocalvarsym;
      pparam,procparam : tparavarsym;
      excloc : tlocalvarsym;
      body,thenblk,workcall : tnode;
      stmt,thenstmt : tstatementnode;
      clsname : tsymstr;
      clssym : ttypesym;

    function add_field(const fname:string;ftype:tdef):tfieldvarsym;
      begin
        result:=cfieldvarsym.create(fname,vs_value,ftype,[]);
        clsdef.symtable.insertsym(result);
        tabstractrecordsymtable(clsdef.symtable).addfield(result,vis_public);
      end;

    function new_method(const mname:string;rettype:tdef;isstatic:boolean):tprocdef;
      var
        oldstack : tsymtablestack;
      begin
        oldstack:=symtablestack;
        symtablestack:=nil;
        result:=cprocdef.create(normal_function_level,false);
        result.struct:=clsdef;
        if assigned(rettype) then
          begin
            result.proctypeoption:=potype_function;
            result.returndef:=rettype;
          end
        else
          begin
            result.proctypeoption:=potype_procedure;
            result.returndef:=voidtype;
          end;
        result.proccalloption:=pocall_default;
        include(result.procoptions,po_hascallingconvention);
        if isstatic then
          begin
            include(result.procoptions,po_classmethod);
            include(result.procoptions,po_staticmethod);
          end
        else
          include(result.procoptions,po_virtualmethod);
        exclude(result.procoptions,po_delphi_nested_cc);
        result.forwarddef:=false;
        result.procsym:=cprocsym.create(mname);
        result.visibility:=vis_public;
        clsdef.symtable.insertsym(result.procsym);
        clsdef.symtable.insertdef(result);
        symtablestack:=oldstack;
      end;

    procedure finish_method(pd:tprocdef);
      var
        oldstack : tsymtablestack;
      begin
        oldstack:=symtablestack;
        symtablestack:=nil;
        handle_calling_convention(pd,hcc_default_actions_impl);
        proc_add_definition(pd);
        insert_funcret_local(pd);
        pd.calcparas;
        symtablestack:=oldstack;
      end;

    function self_field(pd:tprocdef;f:tfieldvarsym):tnode;
      var
        s : tsym;
      begin
        s:=async_find_self(pd);
        result:=csubscriptnode.create(f,cloadnode.create(s,s.owner));
      end;

    function impl_field(f:tfieldvarsym):tnode;
      begin
        result:=csubscriptnode.create(f,cloadnode.create(implsym,implsym.owner));
      end;

    function rtl(const name:string;params:tnode):tnode;
      begin
        result:=ccallnode.createintern(name,params);
      end;

    begin
      result:=an;
      futureintf:=tobjectdef(an.resultdef);
      if not is_future_intf(futureintf) then
        exit;
      procnode:=an.left;
      an.left:=nil;
      if not assigned(procnode) or not assigned(procnode.resultdef) then
        exit;
      procreftype:=procnode.resultdef;

      inc(asyncimplseq);
      clsname:='$async$'+tostr(asyncimplseq);
      clsdef:=cobjectdef.create(odt_class,clsname,
        tobjectdef(search_system_type('TINTERFACEDOBJECT').typedef),false);
      current_module.localsymtable.insertdef(clsdef);
      { never looked up by name, so the unused-symbol pass must skip it }
      clssym:=ctypesym.create(clsname,clsdef);
      include(clssym.symoptions,sp_internal);
      current_module.localsymtable.insertsym(clssym);
      clsdef.register_implemented_interface(futureintf,true);

      fEvent:=add_field('__event',search_system_type('PRTLEVENT').typedef);
      fExc:=add_field('__exc',class_tobject);
      fKeep:=add_field('__keepalive',interface_iunknown);
      fProc:=add_field('__proc',procreftype);
      fTid:=add_field('__tid',search_system_type('TTHREADID').typedef);
      fCancel:=add_field('__cancel',pasbool8type);
      fDone:=add_field('__done',pasbool8type);

      { ---- __Thunk: invoke the captured reference on the worker thread ---- }
      thunkpd:=new_method('__Thunk',ptrsinttype,true);
      pparam:=cparavarsym.create('p',10,vs_value,voidpointertype,[]);
      thunkpd.parast.insertsym(pparam);
      finish_method(thunkpd);
      implsym:=clocalvarsym.create('__impl',vs_value,clsdef,[]);
      thunkpd.localst.insertsym(implsym);
      // the block reads the cancel flag through its `Cancelled` constref
      // parameter, so hand it the impl's field
      workcall:=ccallnode.create_procvar(
        ccallparanode.create(impl_field(fCancel),nil),
        impl_field(fProc));
      body:=internalstatements(stmt);
      addstatement(stmt,cassignmentnode.create(cloadnode.create(implsym,implsym.owner),
        ctypeconvnode.create_internal(cloadnode.create(pparam,pparam.owner),clsdef)));
      addstatement(stmt,ctryexceptnode.create(
        workcall,
        nil,
        cassignmentnode.create(impl_field(fExc),
          ctypeconvnode.create_internal(rtl('ACQUIREEXCEPTIONOBJECT',nil),class_tobject))));
      // the work (or its exception capture) is complete - publish it for the
      // non-blocking `Done` probe before releasing any awaiter
      addstatement(stmt,cassignmentnode.create(impl_field(fDone),
        cordconstnode.create(1,pasbool8type,false)));
      addstatement(stmt,rtl('RTLEVENTSETEVENT',ccallparanode.create(impl_field(fEvent),nil)));
      addstatement(stmt,cassignmentnode.create(impl_field(fKeep),cnilnode.create));
      addstatement(stmt,cassignmentnode.create(cloadnode.create(thunkpd.funcretsym,thunkpd.funcretsym.owner),
        cordconstnode.create(0,ptrsinttype,false)));
      async_defer_method(thunkpd,body);

      { ---- __Await: join, then re-raise any captured exception ---- }
      awaitpd:=new_method('__Await',nil,false);
      finish_method(awaitpd);
      excloc:=clocalvarsym.create('__e',vs_value,class_tobject,[]);
      awaitpd.localst.insertsym(excloc);
      body:=internalstatements(stmt);
      addstatement(stmt,rtl('RTLEVENTWAITFOR',ccallparanode.create(self_field(awaitpd,fEvent),nil)));
      addstatement(stmt,rtl('RTLEVENTSETEVENT',ccallparanode.create(self_field(awaitpd,fEvent),nil)));
      thenblk:=internalstatements(thenstmt);
      addstatement(thenstmt,cassignmentnode.create(cloadnode.create(excloc,excloc.owner),self_field(awaitpd,fExc)));
      addstatement(thenstmt,cassignmentnode.create(self_field(awaitpd,fExc),cnilnode.create));
      addstatement(thenstmt,craisenode.create(cloadnode.create(excloc,excloc.owner),nil,nil));
      addstatement(stmt,cifnode.create(
        caddnode.create(unequaln,self_field(awaitpd,fExc),cnilnode.create),
        thenblk,
        nil));
      async_defer_method(awaitpd,body);

      { ---- __Spawn: store the reference, arm the event, spawn ---- }
      spawnpd:=new_method('__Spawn',futureintf,true);
      procparam:=cparavarsym.create('aproc',10,vs_value,procreftype,[]);
      spawnpd.parast.insertsym(procparam);
      finish_method(spawnpd);
      implsym:=clocalvarsym.create('__impl',vs_value,clsdef,[]);
      spawnpd.localst.insertsym(implsym);
      body:=internalstatements(stmt);
      addstatement(stmt,cassignmentnode.create(cloadnode.create(implsym,implsym.owner),
        ccallnode.create(nil,tprocsym(class_tobject.symtable.find('CREATE')),clsdef.symtable,
          cloadvmtaddrnode.create(ctypenode.create(clsdef)),[],nil)));
      addstatement(stmt,cassignmentnode.create(impl_field(fProc),
        cloadnode.create(procparam,procparam.owner)));
      addstatement(stmt,cassignmentnode.create(impl_field(fEvent),rtl('RTLEVENTCREATE',nil)));
      addstatement(stmt,cassignmentnode.create(impl_field(fKeep),cloadnode.create(implsym,implsym.owner)));
      addstatement(stmt,cassignmentnode.create(impl_field(fTid),rtl('BEGINTHREAD',
        ccallparanode.create(
          ctypeconvnode.create_internal(cloadnode.create(implsym,implsym.owner),voidpointertype),
          ccallparanode.create(
            ctypeconvnode.create_proc_to_procvar(cloadnode.create_procvar(thunkpd.procsym,thunkpd,thunkpd.procsym.owner)),
            nil)))));
      addstatement(stmt,cassignmentnode.create(
        cloadnode.create(spawnpd.funcretsym,spawnpd.funcretsym.owner),cloadnode.create(implsym,implsym.owner)));
      async_defer_method(spawnpd,body);

      async_add_destructor(clsdef,fEvent,fExc,fTid);
      async_add_control_methods(clsdef,fCancel,fDone,fTid);

      build_vmt(clsdef);

      result:=ccallnode.create(ccallparanode.create(procnode,nil),tprocsym(spawnpd.procsym),clsdef.symtable,
        cloadvmtaddrnode.create(ctypenode.create(clsdef)),[],nil);

      an.free;
    end;


  function lower_async_node(var n:tnode;arg:pointer):foreachnoderesult;
    var
      ctx : pasynclowerctx absolute arg;
    begin
      result:=fen_true;
      if n.nodetype=awaitn then
        n:=build_one_await(tawaitnode(n))
      else if n.nodetype=asyncn then
        begin
          if tasyncnode(n).isblock then
            n:=build_one_async_block(tasyncnode(n),ctx)
          else
            n:=build_one_async_call(tasyncnode(n),ctx);
        end;
    end;


  procedure lower_async(pi:tprocinfo);
    var
      ctx : tasynclowerctx;
    begin
      if not (m_asyncawait in current_settings.modeswitches) then
        exit;
      if not assigned(tcgprocinfo(pi).code) then
        exit;
      ctx.pi:=pi;
      foreachnodestatic(pm_postprocess,tcgprocinfo(pi).code,@lower_async_node,@ctx);
    end;


  function create_outline_procdef(const basesymname: string; astruct: tabstractrecorddef; potype: tproctypeoption; resultdef: tdef): tprocdef;
    var
      st:TSymTable;
      checkstack: psymtablestackitem;
      oldsymtablestack: tsymtablestack;
      sym:tprocsym;
    begin
      { get actual procedure symtable (skip withsymtables, etc.) }
      st:=nil;
      checkstack:=symtablestack.stack;
      while assigned(checkstack) do
        begin
          st:=checkstack^.symtable;
          if st.symtabletype in [staticsymtable,globalsymtable,localsymtable] then
            break;
          checkstack:=checkstack^.next;
        end;
      { Create a nested procedure, even from main_program_level.
        Furthermore, force procdef and procsym into the same symtable
        (by default, defs are registered with symtablestack.top which may be
        something temporary like exceptsymtable - in that case, procdef can be
        destroyed before procsym, leaving invalid pointers). }
      oldsymtablestack:=symtablestack;
      symtablestack:=nil;
      result:=cprocdef.create(max(normal_function_level,st.symtablelevel)+1,true);
      result.returndef:=resultdef;
      { if the parent is a generic or a specialization, the new function is one
        as well }
      if st.symtabletype=localsymtable then
        result.defoptions:=result.defoptions+(tstoreddef(st.defowner).defoptions*[df_generic,df_specialization]);
      symtablestack:=oldsymtablestack;
      st.insertdef(result);
      result.struct:=astruct;
      { tabstractprocdef constructor sets po_delphi_nested_cc whenever
        nested procvars modeswitch is active. We must be independent of this switch. }
      exclude(result.procoptions,po_delphi_nested_cc);
      result.proctypeoption:=potype;
      { always use the default calling convention }
      result.proccalloption:=pocall_default;
      include(result.procoptions,po_hascallingconvention);
      handle_calling_convention(result,hcc_default_actions_impl);
      sym:=cprocsym.create(basesymname+result.unique_id_str);
      st.insertsym(sym);

      result.procsym:=sym;
      proc_add_definition(result);
      { the code will be assigned directly to the "code" field later }
      result.forwarddef:=false;
      result.aliasnames.insert(result.mangledname);
    end;


  function fileinfo_to_suffix(const fileinfo:tfileposinfo):tsymstr;inline;
    begin
      result:=tostr(fileinfo.moduleindex)+'_'+
              tostr(fileinfo.fileindex)+'_'+
              tostr(fileinfo.line)+'_'+
              tostr(fileinfo.column);
    end;


  const
    anon_funcref_prefix='$FuncRef_';
    capturer_class_name='$CapturerClass';
    { the leading $ is only added when registering the var symbol }
    capturer_var_name='Capturer';
    keepalive_suffix='_keepalive';
    outer_self_field_name='OuterSelf';


  procedure convert_to_funcref_intf(const n:tidstring;var def:tdef);
    var
      oldsymtablestack : tsymtablestack;
      pvdef : tprocvardef absolute def;
      intfdef : tobjectdef;
      invokedef : tprocdef;
      sym : tsym;
      i : longint;
      name : tidstring;
    begin
      if def.typ<>procvardef then
        internalerror(2021040201);
      if not (po_is_function_ref in tprocvardef(pvdef).procoptions) then
        internalerror(2021022101);
      if n='' then
        name:=anon_funcref_prefix+fileinfo_to_suffix(current_filepos)
      else
        name:=n;
      intfdef:=cobjectdef.create(odt_interfacecom,name,interface_iunknown,true);
      include(intfdef.objectoptions,oo_is_funcref);
      include(intfdef.objectoptions,oo_is_invokable);
      include(intfdef.objectoptions,oo_has_virtual);
      intfdef.typesym:=pvdef.typesym;
      pvdef.typesym:=nil;

      intfdef.defoptions:=intfdef.defoptions+pvdef.defoptions*[df_generic,df_specialization];
      { also inherit the general flags from the surrounding structured type or
        function }
      if assigned(current_structdef) then
        begin
          intfdef.defoptions:=intfdef.defoptions+current_structdef.defoptions*[df_generic,df_specialization];
        end
      else if assigned(current_procinfo) then
        begin
          intfdef.defoptions:=intfdef.defoptions+current_procinfo.procdef.defoptions*[df_generic,df_specialization];
        end;

      if cs_generate_rtti in current_settings.localswitches then
        include(intfdef.objectoptions,oo_can_have_published);

      oldsymtablestack:=symtablestack;
      symtablestack:=nil;

      invokedef:=tprocdef(pvdef.getcopyas(procdef,pc_normal_no_paras,'',false));
      invokedef.struct:=intfdef;
      invokedef.forwarddef:=false;

      include(invokedef.procoptions,po_overload);
      include(invokedef.procoptions,po_virtualmethod);

      invokedef.procsym:=cprocsym.create(method_name_funcref_invoke_decl);
      if cs_generate_rtti in current_settings.localswitches then
        invokedef.visibility:=vis_published
      else
        invokedef.visibility:=vis_public;

      intfdef.symtable.insertsym(invokedef.procsym);
      intfdef.symtable.insertdef(invokedef);

      { we need to do this even if the def isn't a generic/specialization itself,
        but *belongs* to one }
      if intfdef.defoptions*[df_generic,df_specialization]<>[] then
        begin
          if assigned(pvdef.genericdef) and (pvdef.genericdef.typ<>objectdef) then
            internalerror(2021040501);
          intfdef.genericdef:=pvdef.genericdef;
          { in case of a generic we move all involved syms/defs to the interface }
          intfdef.genericparas:=pvdef.genericparas;
          pvdef.genericparas:=nil;
          if assigned(intfdef.genericparas) then
            for i:=0 to intfdef.genericparas.count-1 do
              begin
                sym:=tsym(intfdef.genericparas[i]);
                if sym.owner<>pvdef.parast then
                  continue;
                sym.changeowner(intfdef.symtable);
                if (sym.typ=typesym) and (ttypesym(sym).typedef.owner=pvdef.parast) then
                  ttypesym(sym).typedef.changeowner(intfdef.symtable);
              end;
        end;

      { now move the symtable over }
      invokedef.parast.free;
      invokedef.parast:=pvdef.parast;
      invokedef.parast.defowner:=invokedef;
      pvdef.parast:=nil;

      for i:=0 to invokedef.parast.symlist.count-1 do
        begin
          sym:=tsym(invokedef.parast.symlist[i]);
          if sym.typ<>paravarsym then
            continue;
          if tparavarsym(sym).vardef=pvdef then
            tparavarsym(sym).vardef:=intfdef;
        end;

      symtablestack:=oldsymtablestack;

      if invokedef.returndef=pvdef then
        invokedef.returndef:=intfdef;

      handle_calling_convention(invokedef,hcc_default_actions_intf_struct);
      proc_add_definition(invokedef);
      invokedef.calcparas;
      { def is not owned, so it can be simply freed }
      def.free;
      def:=intfdef;
    end;


  function adjust_funcref(var def:tdef;sym,dummysym:tsym):boolean;
    var
      sympos : tfileposinfo;
      name : string;
    begin
      result:=false;
      if (def.typ<>procvardef) and not is_funcref(def) then
        internalerror(2022020401);
      if assigned(sym) and not (sym.typ=typesym) then
        internalerror(2022020402);
      { these always support everything, no "of object" or
        "is_nested" is allowed }
      if is_nested_pd(tprocvardef(def)) or
         is_methodpointer(def) then
        cgmessage(type_e_function_reference_kind);
      if not (po_is_block in tprocvardef(def).procoptions) then
        begin
          if assigned(dummysym) then
            ttypesym(dummysym).typedef:=nil;
          if assigned(sym) then
            begin
              ttypesym(sym).typedef:=nil;
              name:=sym.name;
            end
          else
            name:='';
          convert_to_funcref_intf(name,def);
          if assigned(sym) then
            ttypesym(sym).typedef:=def;
          if assigned(dummysym) then
            ttypesym(dummysym).typedef:=def;
          build_vmt(tobjectdef(def));
          result:=true;
        end
      else
        begin
          if assigned(sym) and (sym.refs>0) then
            begin
              { find where the symbol was used and trigger
                a "symbol not completely defined" error }
              if not fileinfo_of_typesym_in_def(def,sym,sympos) then
                sympos:=sym.fileinfo;
              messagepos1(sympos,type_e_type_is_not_completly_defined,sym.realname);
            end;
        end;
    end;


  function funcref_intf_for_proc(pd:tabstractprocdef;const suffix:string):tobjectdef;
    var
      name : tsymstr;
      sym : tsym;
      symowner : tsymtable;
      oldsymtablestack: TSymtablestack;
      invokedef: tprocdef;
    begin
      if pd.is_generic then
        internalerror(2022010710);

      name:='funcrefintf_'+suffix;
      if pd.owner.symtabletype=globalsymtable then
        symowner:=current_module.localsymtable
      else
        symowner:=pd.owner;
      sym:=tsym(symowner.find(name));
      if assigned(sym) then
        begin
          if sym.typ<>typesym then
            internalerror(2022010708);
          if not is_funcref(ttypesym(sym).typedef) then
            internalerror(2022010709);
          result:=tobjectdef(ttypesym(sym).typedef);
          exit;
        end;

      name:='$'+name;

      result:=cobjectdef.create(odt_interfacecom,name,interface_iunknown,false);
      include(result.objectoptions,oo_is_funcref);
      include(result.objectoptions,oo_is_invokable);

      sym:=ctypesym.create(name,result);

      oldsymtablestack:=symtablestack;
      symtablestack:=nil;

      invokedef:=tprocdef(pd.getcopyas(procdef,pc_normal_no_hidden,'',false));
      invokedef.struct:=result;
      invokedef.visibility:=vis_public;
      invokedef.procsym:=cprocsym.create(method_name_funcref_invoke_decl);
      invokedef.parast.symtablelevel:=normal_function_level;
      invokedef.localst.symtablelevel:=normal_function_level;
      include(invokedef.procoptions,po_virtualmethod);
      exclude(invokedef.procoptions,po_staticmethod);
      exclude(invokedef.procoptions,po_classmethod);
      invokedef.forwarddef:=false;

      symtablestack:=oldsymtablestack;

      result.symtable.insertsym(invokedef.procsym);
      result.symtable.insertdef(invokedef);

      proc_add_definition(invokedef);
      invokedef.calcparas;
      include(result.objectoptions,oo_has_virtual);

      symowner.insertsym(sym);
      symowner.insertdef(result);
      addsymref(sym);

      build_vmt(result);
    end;


  function async_block_funcref(pd:tprocdef):tobjectdef;
    begin
      result:=funcref_intf_for_proc(pd,fileinfo_to_suffix(pd.fileinfo));
    end;


  function anon_proc_funcref(pd:tprocdef):tobjectdef;
    begin
      result:=funcref_intf_for_proc(pd,fileinfo_to_suffix(pd.fileinfo));
    end;


  {.$define DEBUG_CAPTURER}

  function acceptable_typ(sym:tabstractvarsym;typ :tsymtyp) : boolean;
    begin
      acceptable_typ:=false;
      if (sym.typ=typ) then
        acceptable_typ:=true
      else if (sym.typ=absolutevarsym) and (tabsolutevarsym(sym).reftyp=typ) then
        acceptable_typ:=true;
    end;

  function get_capturer(pd:tprocdef):tabstractvarsym;

    function getsym(st:tsymtable;typ:tsymtyp):tabstractvarsym;
      begin
        result:=tabstractvarsym(st.find(capturer_var_name));
        if not assigned(result) then
          internalerror(2022010703);
       if not acceptable_typ(result,typ) then
          internalerror(2022010704);
        if not is_class(result.vardef) then
          internalerror(2022010705);
      end;

    begin
      case pd.proctypeoption of
        potype_unitfinalize,
        potype_unitinit,
        potype_proginit:
          begin
            if not assigned(pd.owner) then
              internalerror(2022052401);
            if pd.owner.symtabletype<>staticsymtable then
              internalerror(2022052402);
            result:=getsym(pd.owner,staticvarsym);
          end;
        else
          begin
            if not assigned(pd.localst) then
              internalerror(2022020502);
            result:=getsym(pd.localst,localvarsym);
          end;
      end;
    end;


  function get_capturer_alive(pd:tprocdef):tabstractvarsym;

    function getsym(st:tsymtable;typ:tsymtyp):tabstractvarsym;
      begin
        result:=tabstractvarsym(st.find(capturer_var_name+keepalive_suffix));
        if not assigned(result) then
          internalerror(2022051703);
        if not acceptable_typ(result,typ) then
          internalerror(2022051704);
        if not is_interfacecom(result.vardef) then
          internalerror(2022051705);
      end;

    begin
      case pd.proctypeoption of
        potype_unitfinalize,
        potype_unitinit,
        potype_proginit:
          begin
            if not assigned(pd.owner) then
              internalerror(2022052403);
            if pd.owner.symtabletype<>staticsymtable then
              internalerror(2022052404);
            result:=getsym(pd.owner,staticvarsym);
          end;
        else
          begin
            if not assigned(pd.localst) then
              internalerror(2022051702);
            result:=getsym(pd.localst,localvarsym);
          end;
      end;
    end;


  function get_or_create_capturer(pd:tprocdef):tsym;
    var
      name : tsymstr;
      parent,
      def : tobjectdef;
      typesym : tsym;
      keepalive : tabstractvarsym;
      st : tsymtable;
    begin
      if pd.has_capturer then
        begin
          result:=get_capturer(pd);
        end
      else
        begin
          parent:=tobjectdef(search_system_type('TINTERFACEDOBJECT').typedef);
          if not is_class(parent) then
            internalerror(2022010706);

          name:=capturer_class_name+'_'+fileinfo_to_suffix(pd.fileinfo);

          case pd.proctypeoption of
            potype_unitfinalize,
            potype_unitinit,
            potype_proginit:
              st:=pd.owner;
            else
              st:=pd.localst;
          end;

          def:=cobjectdef.create(odt_class,name,parent,false);
          include(def.objectoptions,oo_is_capturer);
          typesym:=ctypesym.create(name,def);
          typesym.fileinfo:=pd.fileinfo;
          st.insertdef(def);
          st.insertsym(typesym);
          addsymref(typesym);

          if df_generic in pd.defoptions then
            include(def.defoptions,df_generic);
          { don't set df_specialization as in that case genericdef needs to be
            set, but the local symtables are freed once a unit is finished }
          {if df_specialization in pd.defoptions then
            begin
              if not assigned(pd.genericdef) or (pd.genericdef.typ<>procdef) then
                internalerror(2022020501);
              def.genericdef:=tstoreddef(get_capturer(tprocdef(pd.genericdef)).vardef);
              include(def.defoptions,df_specialization);
            end;}

          if st.symtabletype=localsymtable then
            result:=clocalvarsym.create('$'+capturer_var_name,vs_value,def,[vo_is_internal])
          else
            result:=cstaticvarsym.create('$'+capturer_var_name,vs_value,def,[vo_is_internal]);
          result.fileinfo:=pd.fileinfo;
          st.insertsym(result);
          addsymref(result);

          if st.symtabletype=localsymtable then
            keepalive:=clocalvarsym.create('$'+capturer_var_name+keepalive_suffix,vs_value,interface_iunknown,[vo_is_internal])
          else
            keepalive:=cstaticvarsym.create('$'+capturer_var_name+keepalive_suffix,vs_value,interface_iunknown,[vo_is_internal]);
          keepalive.fileinfo:=pd.fileinfo;
          st.insertsym(keepalive);
          addsymref(keepalive);

          if st.symtabletype<>localsymtable then
            begin
              cnodeutils.insertbssdata(tstaticvarsym(result));
              cnodeutils.insertbssdata(tstaticvarsym(keepalive));
            end;

          { avoid warnings as these symbols are initialized using initialize_capturer
            after parsing the body }
          tabstractvarsym(result).varstate:=vs_readwritten;
          keepalive.varstate:=vs_readwritten;

          pd.has_capturer:=true;
        end;
    end;


  function can_be_captured(sym:tsym;curpd:tprocdef):boolean;
    begin
      result:=false;
      if (sym.typ=procsym) and assigned(curpd) and (curpd.procsym=sym) then
        exit(true);
      if not (sym.typ in [localvarsym,paravarsym]) then
        exit;
      if tabstractnormalvarsym(sym).varoptions*[vo_is_result,vo_is_funcret]<>[] then
        exit;
      if sym.typ=paravarsym then
        begin
          if (tparavarsym(sym).varspez in [vs_out,vs_var]) and
              not (vo_is_self in tparavarsym(sym).varoptions) then
            exit;
          if is_open_array(tparavarsym(sym).vardef) then
            exit;
        end;
      result:=true;
    end;


  type
    tsym_mapping = record
      oldsym:tsym;
      newsym:tsym;
    end;
    psym_mapping = ^tsym_mapping;


  function replace_self_sym(var n:tnode;arg:pointer):foreachnoderesult;
    var
      mapping : psym_mapping absolute arg;
      ld : tloadnode;
    begin
      if n.nodetype=loadn then
        begin
          ld:=tloadnode(n);
          if ld.symtableentry=mapping^.oldsym then
            begin
              ld.symtableentry:=mapping^.newsym;
              { make sure that the node is processed again }
              ld.resultdef:=nil;
              if assigned(ld.left) then
                begin
                  { no longer loaded through the frame pointer }
                  ld.left.free;
                  ld.left:=nil;
                end;
              typecheckpass(n);
            end;
        end;
      result:=fen_true;
    end;


  procedure capture_captured_syms(pd:tprocdef;owner:tprocinfo;capturedef:tobjectdef;oldpd:tprocdef);
    var
      curpd : tprocdef;
      subcapturer : tobjectdef;
      symstodo : TFPList;
      i : longint;
      sym : tsym;
      fieldsym : tfieldvarsym;
      fieldname : tsymstr;
      fielddef : tdef;
    begin
      if not pd.was_anonymous or not assigned(pd.capturedsyms) or (pd.capturedsyms.count=0) then
        exit;
      { capture all variables that the original procdef captured }
      curpd:=owner.procdef;
      subcapturer:=capturedef;
      symstodo:=tfplist.create;
      for i:=0 to pd.capturedsyms.count-1 do
        if can_be_captured(pcapturedsyminfo(pd.capturedsyms[i])^.sym,oldpd) and
            (pcapturedsyminfo(pd.capturedsyms[i])^.sym.typ<>procsym) then
          symstodo.add(pcapturedsyminfo(pd.capturedsyms[i])^.sym);
      while symstodo.count>0 do
        begin
          { we know we have symbols left to capture thus we either have a
            symbol that's located in the capturer of the current procdef or
            we need to put in the OuterSelf reference }
          if curpd=owner.procdef then
            subcapturer:=capturedef
          else
            subcapturer:=tobjectdef(tabstractvarsym(get_or_create_capturer(curpd)).vardef);
          i:=0;
          while i<symstodo.count do
            begin
              sym:=tsym(symstodo[i]);
              { block-scoped inline vars sit in a blocksymtable whose
                defowner was inherited from the enclosing localst, so
                they belong to curpd just like ordinary locals }
              if (sym.owner=curpd.localst) or
                  (sym.owner=curpd.parast) or
                  ((sym.owner.symtabletype=blocksymtable) and
                   (sym.owner.defowner=curpd)) then
                begin
                  {$ifdef DEBUG_CAPTURER}writeln('Symbol ',sym.name,' captured from ',curpd.procsym.name);{$endif}
                  { the symbol belongs to the current procdef, so add a field to
                    the capturer if it doesn't already exist }
                  if vo_is_self in tabstractnormalvarsym(sym).varoptions then
                    fieldname:=outer_self_field_name
                  else
                    fieldname:=sym.name;
                  fieldsym:=tfieldvarsym(subcapturer.symtable.find(fieldname));
                  if not assigned(fieldsym) then
                    begin
                      {$ifdef DEBUG_CAPTURER}writeln('Adding field ',fieldname,' to ',subcapturer.typesym.name);{$endif}
                      fielddef:=tabstractvarsym(sym).vardef;
                      if vo_is_self in tabstractnormalvarsym(sym).varoptions then
                        begin
                          fieldname:='$'+fieldname;
                          if not is_implicit_pointer_object_type(fielddef) then
                            fielddef:=cpointerdef.getreusable(fielddef);
                        end;
                      fieldsym:=cfieldvarsym.create(fieldname,vs_value,fielddef,[]);
                      fieldsym.fileinfo:=sym.fileinfo;
                      subcapturer.symtable.insertsym(fieldsym);
                      tabstractrecordsymtable(subcapturer.symtable).addfield(fieldsym,vis_public);
                    end;
                  if not assigned(tabstractnormalvarsym(sym).capture_sym) then
                    tabstractnormalvarsym(sym).capture_sym:=fieldsym
                  else if tabstractnormalvarsym(sym).capture_sym<>fieldsym then
                    internalerror(2022011602);
                  symstodo.delete(i);
                end
              else if sym=pd.procsym then
                { no explicit capturing needed here }
                symstodo.delete(i)
              else
                inc(i);
            end;
          if symstodo.count>0 then
            begin
              if curpd.owner.symtabletype<>localsymtable then
                internalerror(2022011001);
              { there are still symbols left, so before we move to the parent
                procdef we add the OuterSelf field to set up the chain of
                capturers }
              {$ifdef DEBUG_CAPTURER}writeln('Initialize capturer for ',curpd.procsym.name);{$endif}
              { we no longer need the curpd, but we need the parent, so change
                curpd here }
                curpd:=tprocdef(curpd.owner.defowner);
                if curpd.typ<>procdef then
                  internalerror(2022011002);
              if not assigned(subcapturer.symtable.find(outer_self_field_name)) then
                begin
                  {$ifdef DEBUG_CAPTURER}writeln('Adding field OuterSelf to ',subcapturer.typesym.name);{$endif}
                  if subcapturer.owner.symtablelevel>normal_function_level then
                    begin
                      { the outer self is the capturer of the outer procdef }
                      sym:=get_or_create_capturer(curpd);
                      { ensure that the outer capturer isn't put into a register anymore }
                      tabstractvarsym(sym).different_scope:=true;
                      tabstractvarsym(sym).varregable:=vr_none;
                    end
                  else
                    begin
                      { the outer self is the self of the method }
                      if not (curpd.owner.symtabletype in [objectsymtable,recordsymtable]) then
                        internalerror(2022011603);
                      sym:=tsym(curpd.parast.find('self'));
                      if not assigned(sym) then
                        internalerror(2022011604);
                    end;
                  { add the keep alive IUnknown symbol }
                  fieldsym:=cfieldvarsym.create('$'+outer_self_field_name+keepalive_suffix,vs_value,interface_iunknown,[]);
                  fieldsym.fileinfo:=sym.fileinfo;
                  subcapturer.symtable.insertsym(fieldsym);
                  tabstractrecordsymtable(subcapturer.symtable).addfield(fieldsym,vis_public);
                  { add the capturer symbol }
                  fieldsym:=cfieldvarsym.create('$'+outer_self_field_name,vs_value,tabstractvarsym(sym).vardef,[]);
                  fieldsym.fileinfo:=sym.fileinfo;
                  subcapturer.symtable.insertsym(fieldsym);
                  tabstractrecordsymtable(subcapturer.symtable).addfield(fieldsym,vis_public);
                  if (sym.typ=paravarsym) and (vo_is_self in tparavarsym(sym).varoptions) then
                    begin
                      if assigned(tparavarsym(sym).capture_sym) then
                        internalerror(2022011705);
                      tparavarsym(sym).capture_sym:=fieldsym;
                    end;
                end;
            end;
        end;
      symstodo.free;
      symstodo := nil;
    end;


  function retrieve_sym_for_filepos(var n:tnode;arg:pointer):foreachnoderesult;
    var
      sym : ^tsym absolute arg;
    begin
      if assigned(sym^) then
        exit(fen_norecurse_true);
      result:=fen_false;
      if not (n.resultdef.typ in [procdef,procvardef]) then
        exit;
      if n.nodetype=loadn then
        begin
          sym^:=tloadnode(n).symtableentry;
          result:=fen_norecurse_true;
        end
      else if n.nodetype=subscriptn then
        begin
          sym^:=tsubscriptnode(n).vs;
          result:=fen_norecurse_true;
        end;
    end;


  function collect_syms_to_capture(var n:tnode;arg:pointer):foreachnoderesult;
    var
      pd : tprocdef absolute arg;
      sym : tsym;
    begin
      result:=fen_false;
      if n.nodetype<>loadn then
        exit;
      sym:=tsym(tloadnode(n).symtableentry);
      if not (sym.owner.symtabletype in [parasymtable,localsymtable,blocksymtable]) then
        exit;
      if sym.owner.symtablelevel>normal_function_level then begin
        pd.add_captured_sym(sym,tloadnode(n).resultdef,n.fileinfo);
        result:=fen_true;
      end;
    end;


  type
    tselfinfo=record
      selfsym:tsym;
      ignore:tsym;
    end;
    pselfinfo=^tselfinfo;


  function find_self_sym(var n:tnode;arg:pointer):foreachnoderesult;
    var
      info : pselfinfo absolute arg;
    begin
      result:=fen_false;
      if assigned(info^.selfsym) then
        exit(fen_norecurse_true);
      if n.nodetype<>loadn then
        exit;
      if tloadnode(n).symtableentry.typ<>paravarsym then
        exit;
      if tloadnode(n).symtableentry=info^.ignore then
        exit;
      if vo_is_self in tparavarsym(tloadnode(n).symtableentry).varoptions then
        begin
          info^.selfsym:=tparavarsym(tloadnode(n).symtableentry);
          result:=fen_norecurse_true;
        end;
    end;


  function find_outermost_loaded_sym(var n:tnode;arg:pointer):foreachnoderesult;
    var
      sym : ^tsym absolute arg;
    begin
      if assigned(sym^) then
        exit(fen_norecurse_true);
      result:=fen_false;
      if n.nodetype<>loadn then
        exit;
      if not (n.resultdef.typ in [procdef,procvardef]) then
        exit;
      sym^:=tloadnode(n).symtableentry;
      result:=fen_norecurse_true;
    end;


  function find_procdef(var n:tnode;arg:pointer):foreachnoderesult;
    var
      pd : ^tprocdef absolute arg;
    begin
      if assigned(pd^) then
        exit(fen_norecurse_true);
      result:=fen_false;
      if n.resultdef.typ<>procdef then
        exit;
      pd^:=tprocdef(n.resultdef);
      result:=fen_norecurse_true;
    end;


  function capturer_add_procvar_or_proc(owner:tprocinfo;n:tnode;out capturer:tsym;out capturen:tnode):tobjectdef;

    function create_paras(pd:tprocdef):tcallparanode;
      var
        para : tparavarsym;
        i : longint;
      begin
        result:=nil;
        for i:=0 to pd.paras.count-1 do
          begin
            para:=tparavarsym(pd.paras[i]);
            if vo_is_hidden_para in para.varoptions then
              continue;
            result:=ccallparanode.create(cloadnode.create(para,pd.parast),result);
          end;
      end;

      function find_nested_procinfo(pd:tprocdef):tcgprocinfo;
        var
          tmp,
          res : tprocinfo;
        begin
          tmp:=owner;
          while assigned(tmp) and (tmp.procdef.parast.symtablelevel>=normal_function_level) do
            begin
              res:=tmp.find_nestedproc_by_pd(pd);
              if assigned(res) then
                exit(tcgprocinfo(res));
              tmp:=tmp.parent;
            end;
          result:=nil;
        end;

      procedure swap_symtable(var st1,st2:tsymtable);
        var
          st : tsymtable;
          owner : tdefentry;
          level : byte;
        begin
          { first swap the symtables themselves }
          st:=st1;
          st1:=st2;
          st2:=st;
          { then swap the symtables' owners }
          owner:=st1.defowner;
          st1.defowner:=st2.defowner;
          st2.defowner:=owner;
          { and finally the symtable level }
          level:=st1.symtablelevel;
          st1.symtablelevel:=st2.symtablelevel;
          st2.symtablelevel:=level;
        end;

      procedure print_procinfo(pi:tcgprocinfo);
        begin
          { Print the node to tree.log }
          if paraprintnodetree <> 0 then
            pi.printproc('after parsing');

{$ifdef DEBUG_NODE_XML}
          { Methods of generic classes don't get any code generated, so output
            the node tree here }
          if (df_generic in pi.procdef.defoptions) then
            pi.XMLPrintProc(True);
{$endif DEBUG_NODE_XML}
        end;

    var
      ps : tprocsym;
      oldpd,
      pd : tprocdef;
      pinested,
      pi : tcgprocinfo;
      sym,
      fpsym,
      selfsym : tsym;
      invokename : tsymstr;
      capturedef : tobjectdef;
      capturesyms : tfplist;
      captured : pcapturedsyminfo;
      implintf : TImplementedInterface;
      i : longint;
      stmt : tstatementnode;
      n1 : tnode;
      fieldsym : tfieldvarsym;
      selfinfo : tselfinfo;
    begin
      if not (n.resultdef.typ in [procdef,procvardef]) then
        internalerror(2022022101);

      capturer:=nil;
      capturen:=nil;
      pinested:=nil;
      oldpd:=nil;

      { determine a unique name for the variable, field for function of the
        node we're trying to load }

      sym:=nil;
      if not foreachnodestatic(pm_preprocess,n,@find_outermost_loaded_sym,@sym) then
        internalerror(2022022102);

      result:=funcref_intf_for_proc(tabstractprocdef(n.resultdef),fileinfo_to_suffix(sym.fileinfo));

      if (sym.typ=procsym) and (sym.owner.symtabletype=localsymtable) then
        begin
          { this is assigning a nested function, so retrieve the correct procdef
            so that we can then retrieve the procinfo for it }
          if n.resultdef.typ=procdef then
            pd:=tprocdef(n.resultdef)
          else
            begin
              pd:=nil;
              if not foreachnodestatic(pm_preprocess,n,@find_procdef,@pd) then
                internalerror(2022041801);
              if not assigned(pd) then
                internalerror(2022041802);
            end;
          { check whether all captured symbols can indeed be captured }
          capturesyms:=pd.capturedsyms;
          if assigned(capturesyms) then
            for i:=0 to capturesyms.count-1 do
              begin
                captured:=pcapturedsyminfo(capturesyms[i]);
                if not can_be_captured(captured^.sym,pd) then
                  MessagePos1(captured^.fileinfo,sym_e_symbol_no_capture,captured^.sym.realname);
              end;
          if not (df_generic in owner.procdef.defoptions) then
            begin
              pinested:=find_nested_procinfo(pd);
              if not assigned(pinested) then
                internalerror(2022041803);
              oldpd:=pd;
              if pinested.parent<>owner then
                begin
                  { we need to capture this into the owner of the nested function
                    instead }
                  owner:=pinested;
                  capturer:=get_or_create_capturer(pinested.procdef);
                  if not assigned(capturer) then
                    internalerror(2022041804);
                end;
            end;
        end
      else if (n.resultdef.typ=procvardef) and
          (po_delphi_nested_cc in tprocvardef(n.resultdef).procoptions) then
        begin
          MessagePos(n.fileinfo,type_e_nested_procvar_to_funcref);
          exit;
        end
      else
        pinested:=nil;

      if df_generic in owner.procdef.defoptions then
        exit;

      if not assigned(capturer) then
        capturer:=get_or_create_capturer(owner.procdef);

      if not (capturer.typ in [localvarsym,staticvarsym]) then
        internalerror(2022022103);
      capturedef:=tobjectdef(tabstractvarsym(capturer).vardef);
      if not is_class(capturedef) then
        internalerror(2022022104);
      implintf:=find_implemented_interface(capturedef,result);
      if assigned(implintf) then
        begin
          { this is already captured into a method of the capturer, so nothing
            further to do }
          exit;
        end;
      implintf:=capturedef.register_implemented_interface(result,true);

      invokename:=method_name_funcref_invoke_decl+'__FPCINTERNAL__'+fileinfo_to_suffix(sym.fileinfo);

      ps:=cprocsym.create(invokename);
      pd:=tprocdef(tabstractprocdef(n.resultdef).getcopyas(procdef,pc_normal_no_hidden,'',false));
      pd.aliasnames.clear;

      pd.procsym:=ps;
      pd.struct:=capturedef;
      pd.changeowner(capturedef.symtable);
      pd.parast.symtablelevel:=normal_function_level;
      pd.localst.symtablelevel:=normal_function_level;
      { reset procoptions }
      pd.procoptions:=[];
      ps.ProcdefList.Add(pd);
      pd.forwarddef:=false;
      { set procinfo and current_procinfo.procdef }
      pi:=tcgprocinfo(cprocinfo.create(nil));
      pi.procdef:=pd;
      if not assigned(pinested) then
        begin
          insert_funcret_para(pd);
          insert_funcret_local(pd);
          { we always do a call, namely to the provided function }
          include(pi.flags,pi_do_call);
        end
      else
        begin
          { the original nested function now calls the method }
          include(pinested.flags,pi_do_call);
          { swap the para and local symtables of the nested and new routine }
          swap_symtable(pinested.procdef.parast,pd.parast);
          swap_symtable(pinested.procdef.localst,pd.localst);
          { fix function return symbol }
          pd.funcretsym:=pinested.procdef.funcretsym;
          pinested.procdef.funcretsym:=nil;
          pinested.procdef.reset_after_conv;
          insert_funcret_para(pinested.procdef);
          insert_funcret_local(pinested.procdef);
          { the nested function needs access to the parent's framepointer to
            access the capturer }
          insert_parentfp_para(pinested.procdef);
          pd.copied_from:=pinested.procdef;
        end;
      { to simplify some checks, but only after insert_funcret_para }
      pd.was_anonymous:=true;
      capturedef.symtable.insertsym(ps);
      owner.addnestedproc(pi);

      { remove self and parentfp parameter if any as that will be replaced by
        the capturer }
      selfsym:=nil;
      fpsym:=nil;
      for i:=0 to pd.parast.symlist.count-1 do
        begin
          sym:=tsym(pd.parast.symlist[i]);
          if sym.typ<>paravarsym then
            continue;
          if vo_is_self in tparavarsym(sym).varoptions then
            selfsym:=sym
          else if vo_is_parentfp in tparavarsym(sym).varoptions then
            fpsym:=sym;
          if assigned(selfsym) and assigned(fpsym) then
            break;
        end;
      if assigned(selfsym) then
        pd.parast.deletesym(selfsym);
      if assigned(fpsym) then
        pd.parast.deletesym(fpsym);
      pd.calcparas;
      if assigned(pinested) then
        pinested.procdef.calcparas;

      insert_self_and_vmt_para(pd);

      if assigned(pinested) then
        begin
          { when we're assigning a nested function to a function reference we
            move the code of the nested function to the newly created capturer
            method (including the captured symbols) and have the original nested
            function simply call that function-turned-method }
          pi.code:=pinested.code;
          pinested.code:=internalstatements(stmt);
        end
      else
        pi.code:=internalstatements(stmt);

      selfinfo.selfsym:=nil;
      selfinfo.ignore:=nil;

      fieldsym:=nil;
      if assigned(pinested) then
        begin
          n1:=ccallnode.create(create_paras(pinested.procdef),ps,capturedef.symtable,cloadnode.create(capturer,capturer.owner),[],nil);
          { captured variables cannot be in registers }
          make_not_regable(tcallnode(n1).methodpointer,[ra_addr_regable,ra_addr_taken]);
        end
      else if n.resultdef.typ=procvardef then
        begin
          { store the procvar in a field so that it won't be changed if the
            procvar itself is changed }
          fieldsym:=cfieldvarsym.create('$'+fileinfo_to_suffix(n.fileinfo),vs_value,n.resultdef,[]);
          fieldsym.fileinfo:=n.fileinfo;
          capturedef.symtable.insertsym(fieldsym);
          tabstractrecordsymtable(capturedef.symtable).addfield(fieldsym,vis_public);

          capturen:=csubscriptnode.create(fieldsym,cloadnode.create(capturer,capturer.owner));

          selfsym:=tsym(pd.parast.find('self'));
          if not assigned(selfsym) then
            internalerror(2022052301);
          selfinfo.ignore:=selfsym;
          n1:=ccallnode.create_procvar(create_paras(pd),csubscriptnode.create(fieldsym,cloadnode.create(selfsym,selfsym.owner)));
        end
      else
        begin
          if n.nodetype<>loadn then
            internalerror(2022032401);
          if tloadnode(n).symtableentry.typ<>procsym then
            internalerror(2022032402);
          n1:=ccallnode.create(create_paras(pd),tprocsym(tloadnode(n).symtableentry),tloadnode(n).symtable,tloadnode(n).left,[],nil);
          tloadnode(n).left:=nil;
        end;
      if assigned(pd.returndef) and not is_void(pd.returndef) then
        begin
          if assigned(pinested) then
            sym:=pinested.procdef.funcretsym
          else
            sym:=pd.funcretsym;
          n1:=cassignmentnode.create(
                      cloadnode.create(sym,sym.owner),
                      n1
                    );
          { captured variables cannot be in registers }
          make_not_regable(tassignmentnode(n1).left,[ra_addr_regable,ra_addr_taken]);
        end;
      addstatement(stmt,n1);
      pd.aliasnames.insert(pd.mangledname);

      if assigned(pinested) then
        begin
          { transfer all captured syms }
          capturesyms:=pinested.procdef.capturedsyms;
          if assigned(capturesyms) then
            begin
              for i:=0 to capturesyms.count-1 do
                begin
                  captured:=pcapturedsyminfo(capturesyms[i]);
                  pi.add_captured_sym(captured^.sym,captured^.def,captured^.fileinfo);
                  dispose(captured);
                end;
              capturesyms.clear;
            end;
          { the original nested function now needs to capture only the capturer }
          pinested.procdef.add_captured_sym(capturer,capturedef,n.fileinfo);
        end
      { does this need to capture Self? }
      else if not foreachnodestatic(pm_postprocess,n,@find_self_sym,@selfinfo) then
        begin
          { is this a method of the current class? }
          if (n.resultdef.typ=procdef) and
              assigned(tprocdef(n.resultdef).struct) and
              not (po_staticmethod in tprocdef(n.resultdef).procoptions) and
              assigned(current_procinfo.procdef.struct) and
              def_is_related(current_procinfo.procdef.struct,tprocdef(n.resultdef).struct) then
            begin
              selfinfo.selfsym:=tsym(current_procinfo.procdef.parast.find('self'));
              if not assigned(selfinfo.selfsym) then
                internalerror(2022110601);
            end
          else
            { does this need some other local variable or parameter? }
            foreachnodestatic(pm_postprocess,n,@collect_syms_to_capture,@pd)
        end;

      if assigned(selfinfo.selfsym) and not assigned(fieldsym) then
        { this isn't a procdef that was captured into a field, so capture the
          self }
        pd.add_captured_sym(selfinfo.selfsym,tabstractvarsym(selfinfo.selfsym).vardef,n.fileinfo);

      print_procinfo(pi);
      if assigned(pinested) then
        print_procinfo(pinested);

      implintf.AddMapping(upcase(result.objrealname^+'.')+method_name_funcref_invoke_find,upcase(invokename));

      capture_captured_syms(pd,owner,capturedef,oldpd);
    end;


  function capturer_add_anonymous_proc(owner:tprocinfo;pd:tprocdef;out capturer:tsym):tobjectdef;
    var
      capturedef : tobjectdef;
      implintf : TImplementedInterface;
      invokename : tsymstr;
      i : longint;
      outerself,
      fpsym,
      selfsym,
      sym : tsym;
      info : pcapturedsyminfo;
      pi : tprocinfo;
      mapping : tsym_mapping;
    begin
      capturer:=nil;
      result:=funcref_intf_for_proc(pd,fileinfo_to_suffix(pd.fileinfo));

      if df_generic in pd.defoptions then
        begin
          if (po_anonymous in pd.procoptions) and
              assigned(pd.capturedsyms) and
              (pd.capturedsyms.count>0) then
            begin
              { only check whether the symbols can be captured, but don't
                convert anything to avoid problems }
              for i:=0 to pd.capturedsyms.count-1 do
                begin
                  info:=pcapturedsyminfo(pd.capturedsyms[i]);
                  if not can_be_captured(info^.sym,pd) then
                    MessagePos1(info^.fileinfo,sym_e_symbol_no_capture,info^.sym.realname)
                end;
            end;
          exit;
        end;

      capturer:=get_or_create_capturer(owner.procdef);

      if not (capturer.typ in [localvarsym,staticvarsym]) then
        internalerror(2022010711);
      capturedef:=tobjectdef(tabstractvarsym(capturer).vardef);
      if not is_class(capturedef) then
        internalerror(2022010712);
      implintf:=find_implemented_interface(capturedef,result);
      if assigned(implintf) then
        begin
          { this can only already be an implemented interface if a named procdef
            was assigned to a function ref at an earlier point, an anonymous
            function can be used only once }
          if po_anonymous in pd.procoptions then
            internalerror(2022010713);
          exit;
        end;
      implintf:=capturedef.register_implemented_interface(result,true);

      invokename:=method_name_funcref_invoke_decl+'__FPCINTERNAL__'+fileinfo_to_suffix(pd.fileinfo);
      if po_anonymous in pd.procoptions then
        begin
          { turn the anonymous function into a method of the capturer }
          pd.changeowner(capturedef.symtable);
          pd.struct:=capturedef;
          exclude(pd.procoptions,po_anonymous);
          exclude(pd.procoptions,po_delphi_nested_cc);
          exclude(pd.procoptions,po_staticmethod);
          exclude(pd.procoptions,po_classmethod);
          pd.was_anonymous:=true;
          pd.procsym.ChangeOwnerAndName(capturedef.symtable,upcase(invokename));
          pd.procsym.realname:=invokename;
          pd.parast.symtablelevel:=normal_function_level;
          pd.localst.symtablelevel:=normal_function_level;
          { retrieve framepointer and self parameters if any }
          fpsym:=nil;
          selfsym:=nil;
          for i:=0 to pd.parast.symlist.count-1 do
            begin
              sym:=tsym(pd.parast.symlist[i]);
              if sym.typ<>paravarsym then
                continue;
              if vo_is_parentfp in tparavarsym(sym).varoptions then
                fpsym:=sym
              else if vo_is_self in tparavarsym(sym).varoptions then
                selfsym:=sym;
              if assigned(fpsym) and assigned(selfsym) then
                break;
            end;
          { get rid of the framepointer parameter }
          if assigned(fpsym) then
            pd.parast.deletesym(fpsym);
          outerself:=nil;
          { complain about all symbols that can't be captured and add the symbols
            to this procdefs capturedsyms if it isn't a top level function }
          if assigned(pd.capturedsyms) and (pd.capturedsyms.count>0) then
            begin
              for i:=0 to pd.capturedsyms.count-1 do
                begin
                  info:=pcapturedsyminfo(pd.capturedsyms[i]);
                  if not can_be_captured(info^.sym,pd) then
                    MessagePos1(info^.fileinfo,sym_e_symbol_no_capture,info^.sym.realname)
                  else if info^.sym=selfsym then
                    begin
                      { we need to replace the captured "dummy" self parameter
                        with the real self parameter symbol from the surrounding
                        method }
                      if not assigned(outerself) then
                        outerself:=tsym(owner.get_normal_proc.procdef.parast.find('self'));
                      if not assigned(outerself) then
                        internalerror(2022010905);

                      { the anonymous function can only be a direct child of the
                        owner }
                      pi:=owner.get_first_nestedproc;
                      while assigned(pi) do
                        begin
                          if pi.procdef=pd then
                            break;
                          pi:=tprocinfo(pi.next);
                        end;

                      if not assigned(pi) then
                        internalerror(2022010906);

                      mapping.oldsym:=selfsym;
                      mapping.newsym:=outerself;

                      { replace all uses of the captured Self by the new Self
                        parameter }
                      foreachnodestatic(pm_preprocess,tcgprocinfo(pi).code,@replace_self_sym,@mapping);

                      { update the captured symbol }
                      info^.sym:=outerself;
                      info^.def:=tabstractvarsym(outerself).vardef;
                    end
                  else if info^.sym.owner.defowner<>owner.procdef then
                    owner.procdef.add_captured_sym(info^.sym,info^.def,info^.fileinfo);
                end;
            end;
          { delete the original self parameter }
          if assigned(selfsym) then
            pd.parast.deletesym(selfsym);
          { note: don't call insert_self_and_vmt_para here, as that is later on
                  done when building the VMT }
        end
      else
        internalerror(2022022201);
      implintf.AddMapping(upcase(result.objrealname^+'.')+method_name_funcref_invoke_find,upcase(invokename));

      capture_captured_syms(pd,owner,capturedef,nil);
    end;


  function load_capturer(capturer:tabstractvarsym):tnode;inline;
    begin
      result:=cloadnode.create(capturer,capturer.owner);
    end;


  function instantiate_capturer(capturer_sym:tabstractvarsym):tnode;
    var
      capturer_def : tobjectdef;
      ctor : tprocsym;
    begin
      capturer_def:=tobjectdef(capturer_sym.vardef);

      { Neither TInterfacedObject, nor TCapturer have a custom constructor }
      ctor:=tprocsym(class_tobject.symtable.Find('CREATE'));
      if not assigned(ctor) then
        internalerror(2022010801);

      { Insert "Capturer := TCapturer.Create()" as the first statement of the routine }
      result:=cloadvmtaddrnode.create(ctypenode.create(capturer_def));
      result:=ccallnode.create(nil,ctor,capturer_def.symtable,result,[],nil);
      result:=cassignmentnode.create(load_capturer(capturer_sym),result);
    end;


  procedure initialize_captured_paras(pd:tprocdef;capturer:tabstractvarsym;var stmt:tstatementnode);
    var
      i : longint;
      psym: tparavarsym;
      n : tnode;
    begin
      for i:=0 to pd.paras.count-1 do
        begin
          psym:=tparavarsym(pd.paras[i]);
          if not psym.is_captured then
            continue;
          {$ifdef DEBUG_CAPTURER}writeln(#9'initialize captured parameter ',psym.RealName);{$endif}
          n:=cloadnode.create(psym,psym.owner);
          if psym.capture_sym.owner.defowner<>capturer.vardef then
            internalerror(2022010903);
          if (vo_is_self in psym.varoptions) and not is_implicit_pointer_object_type(psym.vardef) then
            n:=caddrnode.create(n);
          n:=cassignmentnode.create(
               csubscriptnode.create(psym.capture_sym,cloadnode.create(capturer,capturer.owner)),
               n
               );
          addstatement(stmt,n);
        end;
    end;


  procedure attach_outer_capturer(ctx:tprocinfo;capturer:tabstractvarsym;var stmt:tstatementnode);
    var
      alivefield,
      selffield : tfieldvarsym;
      outeralive,
      outercapturer : tabstractvarsym;
      alivenode,
      selfnode : tnode;
    begin
      if not ctx.procdef.was_anonymous and
          not (ctx.procdef.owner.symtabletype=localsymtable) then
        exit;
      selffield:=tfieldvarsym(tobjectdef(capturer.vardef).symtable.find(outer_self_field_name));
      if not assigned(selffield) then
        { we'll simply assume that we don't need the outer capturer }
        exit;
      alivefield:=tfieldvarsym(tobjectdef(capturer.vardef).symtable.find(outer_self_field_name+keepalive_suffix));
      if not assigned(alivefield) then
        internalerror(2022051701);
      if ctx.procdef.was_anonymous then
        begin
          selfnode:=load_self_node;
          alivenode:=selfnode.getcopy;
        end
      else
        begin
          outercapturer:=get_capturer(tprocdef(ctx.procdef.owner.defowner));
          if not assigned(outercapturer) then
            internalerror(2022011605);
          selfnode:=cloadnode.create(outercapturer,outercapturer.owner);
          make_not_regable(selfnode,[ra_different_scope]);
          outeralive:=get_capturer_alive(tprocdef(ctx.procdef.owner.defowner));
          if not assigned(outeralive) then
            internalerror(2022051706);
          alivenode:=cloadnode.create(outeralive,outeralive.owner);
          make_not_regable(alivenode,[ra_different_scope]);
        end;
      addstatement(stmt,cassignmentnode.create(
                          csubscriptnode.create(
                            selffield,
                            cloadnode.create(
                              capturer,
                              capturer.owner
                              )
                            ),
                            selfnode));
      addstatement(stmt,cassignmentnode.create(
                          csubscriptnode.create(
                            alivefield,
                            cloadnode.create(
                              capturer,
                              capturer.owner
                              )
                            ),
                            alivenode));
    end;


  procedure initialize_capturer(ctx:tprocinfo;var stmt:tstatementnode);
    var
      capturer_sym,
      keepalive_sym : tabstractvarsym;
    begin
      if ctx.procdef.has_capturer then
        begin
          capturer_sym:=get_capturer(ctx.procdef);
          {$ifdef DEBUG_CAPTURER}writeln('initialize_capturer @ ',ctx.procdef.procsym.RealName);{$endif}

          addstatement(stmt,instantiate_capturer(capturer_sym));
          attach_outer_capturer(ctx,capturer_sym,stmt);
          initialize_captured_paras(ctx.procdef,capturer_sym,stmt);

          keepalive_sym:=get_capturer_alive(ctx.procdef);
          if not assigned(keepalive_sym) then
            internalerror(2022010701);
          addstatement(stmt,cassignmentnode.create(cloadnode.create(keepalive_sym,keepalive_sym.owner),load_capturer(capturer_sym)));
        end;
    end;


  procedure postprocess_capturer(ctx: tprocinfo);
    var
      def: tobjectdef;
    begin
      if not ctx.procdef.has_capturer then
        exit;

      def:=tobjectdef(get_capturer(ctx.procdef).vardef);
      {$ifdef DEBUG_CAPTURER}writeln('process capturer ',def.typesym.Name);{$endif}
      { These two are delayed until this point because
        ... we have been adding fields on-the-fly }
      tabstractrecordsymtable(def.symtable).addalignmentpadding;
      { ... we have been adding interfaces on-the-fly }
      build_vmt(def);
    end;


  type
    tconvert_arg=record
      mappings:tfplist;
    end;
    pconvert_arg=^tconvert_arg;

    tconvert_mapping=record
      oldsym:tsym;
      newsym:tsym;
      olddef:tdef;
      selfnode:tnode;
    end;
    pconvert_mapping=^tconvert_mapping;


  function convert_captured_sym(var n:tnode;arg:pointer):foreachnoderesult;
    var
      convertarg : pconvert_arg absolute arg;
      mapping : pconvert_mapping;
      i : longint;
      old_filepos : tfileposinfo;
      loadprocvar : boolean;
      usageflags : tnodeflags;
      paras: tnode;
      cnf : tcallnodeflags;
      paraold,
      paranew : tcallparanode;
    begin
      result:=fen_true;
      if not (n.nodetype in [loadn,calln]) then
        exit;
      for i:=0 to convertarg^.mappings.count-1 do
        begin
          mapping:=convertarg^.mappings[i];
          case n.nodetype of
            loadn:
              begin
                if tloadnode(n).symtableentry<>mapping^.oldsym then
                  continue;
                old_filepos:=current_filepos;
                current_filepos:=n.fileinfo;
                loadprocvar:=nf_load_procvar in n.flags;
                { keep the usage flags of the replaced load: optimizer passes
                  (cse, constant propagation, dfa) rely on them to tell writes
                  and modifies apart from plain reads }
                usageflags:=n.flags*[nf_write,nf_modify,nf_address_taken];
                n.free;
                n:=csubscriptnode.create(mapping^.newsym,mapping^.selfnode.getcopy);
                if loadprocvar then
                  include(n.flags,nf_load_procvar);
                if (mapping^.oldsym.typ=paravarsym) and
                    (vo_is_self in tparavarsym(mapping^.oldsym).varoptions) and
                    not is_implicit_pointer_object_type(tparavarsym(mapping^.oldsym).vardef) then
                  n:=cderefnode.create(n);
                n.flags:=n.flags+usageflags;
                typecheckpass(n);
                current_filepos:=old_filepos;
                break;
              end;
            calln:
              begin
                if mapping^.oldsym.typ<>procsym then
                  continue;
                if tcallnode(n).symtableprocentry<>tprocsym(mapping^.oldsym) then
                  continue;
                if tcallnode(n).procdefinition<>tprocdef(mapping^.olddef) then
                  continue;
                old_filepos:=current_filepos;
                current_filepos:=n.fileinfo;
                loadprocvar:=nf_load_procvar in n.flags;
                paras:=tcallnode(n).left;
                paraold:=tcallparanode(paras);
                paranew:=nil;
                while assigned(paraold) do
                  begin
                    if not (vo_is_hidden_para in paraold.parasym.varoptions) then
                      begin
                        paranew:=ccallparanode.create(paraold.left,paranew);
                        paraold.left:=nil;
                      end;
                    paraold:=tcallparanode(paraold.right);
                  end;
                reverseparameters(paranew);
                if assigned(tcallnode(n).methodpointer) then
                  internalerror(2023120802);
                cnf:=tcallnode(n).callnodeflags;
                n.free;
                n:=ccallnode.create(paranew,tprocsym(mapping^.newsym),mapping^.newsym.owner,mapping^.selfnode.getcopy,cnf,nil);
                if loadprocvar then
                  include(n.flags,nf_load_procvar);
                typecheckpass(n);
                current_filepos:=old_filepos;
                break;
              end;
            else
              internalerror(2023120801);
          end;
        end;
    end;


  procedure convert_captured_syms(pd:tprocdef;tree:tnode);

    function self_tree_for_sym(selfsym:tsym;fieldsym:tsym):tnode;
      var
        fieldowner : tdef;
        newsym : tsym;
      begin
        result:=cloadnode.create(selfsym,selfsym.owner);
        fieldowner:=tdef(fieldsym.owner.defowner);
        newsym:=selfsym;
        while (tabstractvarsym(newsym).vardef<>fieldowner) do
          begin
            newsym:=tsym(tobjectdef(tabstractvarsym(newsym).vardef).symtable.find(outer_self_field_name));
            if not assigned(newsym) then
              internalerror(2022011101);
            result:=csubscriptnode.create(newsym,result);
          end;
      end;

    var
      i, blk_i: longint;
      capturer : tobjectdef;
      tocapture,
      capturedsyms : tfplist;
      convertarg : tconvert_arg;
      mapping : pconvert_mapping;
      selfsym,
      sym : tsym;
    begin
      {$ifdef DEBUG_CAPTURER}writeln('Converting captured symbols of ',pd.procsym.name);{$endif}

      convertarg.mappings:=tfplist.create;

      capturedsyms:=tfplist.create;

      if pd.was_anonymous and
          assigned(pd.capturedsyms) and
          (pd.capturedsyms.count>0) then
        begin
          {$ifdef DEBUG_CAPTURER}writeln('Converting symbols of converted anonymous function ',pd.procsym.name);{$endif}

          { this is a converted anonymous function, so rework all symbols that
            now belong to the new Self }

          selfsym:=tsym(pd.parast.find('self'));
          if not assigned(selfsym) then
            internalerror(2022010809);

          for i:=0 to pd.capturedsyms.count-1 do
            begin
              sym:=tsym(pcapturedsyminfo(pd.capturedsyms[i])^.sym);
              if not can_be_captured(sym,pd) and
                  not (
                    (sym.typ=procsym) and
                    assigned(pd.copied_from) and
                    (pd.copied_from.procsym=sym)
                  ) then
                continue;
              {$ifdef DEBUG_CAPTURER}writeln('Replacing symbol ',sym.Name);{$endif}
              new(mapping);
              mapping^.oldsym:=sym;
              if sym.typ=procsym then
                begin
                  if not assigned(pd.copied_from) or
                      (pd.copied_from.procsym<>sym) then
                    internalerror(2023123001);
                  mapping^.newsym:=pd.procsym;
                end
              else
                mapping^.newsym:=tabstractnormalvarsym(sym).capture_sym;
              mapping^.olddef:=pcapturedsyminfo(pd.capturedsyms[i])^.def;
              if not assigned(mapping^.newsym) then
                internalerror(2022010810);
              mapping^.selfnode:=self_tree_for_sym(selfsym,mapping^.newsym);
              convertarg.mappings.add(mapping);
              capturedsyms.add(sym);
            end;
        end;

      if (pd.parast.symtablelevel>normal_function_level) and
          assigned(pd.capturedsyms) and
          (pd.capturedsyms.count>0) then
        begin
          if pd.was_anonymous then
            internalerror(2022081201);

          {$ifdef DEBUG_CAPTURER}writeln('Converting symbols of nested function ',pd.procsym.name);{$endif}

          { this is a nested function, so rework all symbols that are used from
            a parent function, but that might have been captured }

          for i:=0 to pd.capturedsyms.count-1 do
            begin
              sym:=tsym(pcapturedsyminfo(pd.capturedsyms[i])^.sym);
              if not can_be_captured(sym,pd) or
                  (sym.typ=procsym) or
                  not assigned(tabstractnormalvarsym(sym).capture_sym) then
                continue;
              {$ifdef DEBUG_CAPTURER}writeln('Replacing symbol ',sym.Name);{$endif}
              new(mapping);
              mapping^.oldsym:=sym;
              mapping^.newsym:=tabstractnormalvarsym(sym).capture_sym;
              mapping^.olddef:=pcapturedsyminfo(pd.capturedsyms[i])^.def;
              capturer:=tobjectdef(mapping^.newsym.owner.defowner);
              if not is_class(capturer) then
                internalerror(2022012701);
              if not (capturer.typesym.owner.symtabletype in [localsymtable,staticsymtable]) then
                internalerror(2022012702);
              selfsym:=tsym(capturer.typesym.owner.find(capturer_var_name));
              if not assigned(selfsym) then
                internalerror(2022012703);
              mapping^.selfnode:=self_tree_for_sym(selfsym,mapping^.newsym);
              convertarg.mappings.add(mapping);
              capturedsyms.add(sym);
            end;
        end;

      if pd.has_capturer then
        begin
          {$ifdef DEBUG_CAPTURER}writeln('Converting symbols of function ',pd.procsym.name,' with capturer');{$endif}
          { this procedure has a capturer, so rework all symbols that are
            captured in that capturer }

          selfsym:=get_capturer(pd);

          { only capture those symbols that weren't captured already by one of
            the above if-clauses and thus are now listed in capturedsyms }
          tocapture:=tfplist.create;

          for i:=0 to pd.localst.symlist.count-1 do
            begin
              sym:=tsym(pd.localst.symlist[i]);
              if sym.typ<>localvarsym then
                continue;
              if assigned(tabstractnormalvarsym(sym).capture_sym) then
                if capturedsyms.indexof(sym)<0 then
                  tocapture.add(sym);
            end;

          { block-scoped inline vars live in pd.blocklocalsymtables, not in
            pd.localst - include them so writes in the outer (`c2 := 0`,
            `c2 += 1`) are remapped to the same capturer field that the
            closure reads }
          if assigned(pd.blocklocalsymtables) then
            for blk_i:=0 to pd.blocklocalsymtables.count-1 do
              for i:=0 to TSymtable(pd.blocklocalsymtables[blk_i]).symlist.count-1 do
                begin
                  sym:=tsym(TSymtable(pd.blocklocalsymtables[blk_i]).symlist[i]);
                  if sym.typ<>localvarsym then
                    continue;
                  if assigned(tabstractnormalvarsym(sym).capture_sym) then
                    if capturedsyms.indexof(sym)<0 then
                      tocapture.add(sym);
                end;

          for i:=0 to pd.parast.symlist.count-1 do
            begin
              sym:=tsym(pd.parast.symlist[i]);
              if sym.typ<>paravarsym then
                continue;
              if assigned(tabstractnormalvarsym(sym).capture_sym) and
                  { no need to adjust accesses to the outermost Self inside the
                    outermost method }
                  not (vo_is_self in tabstractvarsym(sym).varoptions) then
                if capturedsyms.indexof(sym)<0 then
                  tocapture.add(sym);
            end;

          convertarg.mappings.capacity:=convertarg.mappings.count+tocapture.count;
          for i:=0 to tocapture.count-1 do
            begin
              new(mapping);
              mapping^.oldsym:=tsym(tocapture[i]);
              {$ifdef DEBUG_CAPTURER}writeln('Replacing symbol ',mapping^.oldsym.Name);{$endif}
              mapping^.newsym:=tabstractnormalvarsym(mapping^.oldsym).capture_sym;
              if not assigned(mapping^.newsym) then
                internalerror(2022010805);
              mapping^.selfnode:=self_tree_for_sym(selfsym,mapping^.newsym);
              convertarg.mappings.add(mapping);
            end;

          tocapture.free;
          tocapture := nil;
        end;

      { not required anymore }
      capturedsyms.free;
      capturedsyms := nil;

      if convertarg.mappings.count>0 then
        foreachnodestatic(pm_postprocess,tree,@convert_captured_sym,@convertarg);

      for i:=0 to convertarg.mappings.count-1 do
        begin
          mapping:=pconvert_mapping(convertarg.mappings[i]);
          mapping^.selfnode.free; // no nil needed
          dispose(mapping);
        end;

      convertarg.mappings.free; // no nil needed
    end;


initialization
  { break the nbas -> procdefutil cycle: nbas calls this to resolve an `async`
    operand's future type during typecheck }
  asyncfutureresolver:=@resolve_async_future;
end.

