{
    Copyright (c) 1998-2002 by Florian Klaempfl

    Parses variable declarations. Used for var statement and record
    definitions

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
unit pdecvar;

{$i fpcdefs.inc}

interface

    uses
      cclasses,globtype,
      symtable,symsym,symdef,symtype;

    type
      tvar_dec_option=(vd_record,vd_object,vd_threadvar,vd_class,vd_final,vd_canreorder,vd_check_generic,vd_one_variant);
      tvar_dec_options=set of tvar_dec_option;

    function  read_property_dec(is_classproperty:boolean;astruct:tabstractrecorddef;out autopropfield:tfieldvarsym):tpropertysym;

    procedure read_var_decls(options:Tvar_dec_options;out had_generic:boolean);

    procedure read_record_fields(options:Tvar_dec_options; reorderlist: TFPObjectList; variantdesc: ppvariantrecdesc;out had_generic:boolean; out attr_element_count : integer);

    { composablerecords: bridge for the pre-body modifier parsers
      (record_dec in ptype.pas and the union pre-body loop here) to feed
      the first field's already-consumed name into read_record_fields
      when a token that looked like a modifier turned out to be a field
      name (`record size: integer; end;` etc.). cleared by the read loop
      on first use. }
    var
      composable_pre_consumed_field_name: string = '';

    procedure read_public_and_external(vs: tabstractvarsym);

    procedure try_consume_sectiondirective(var asection: ansistring);

    { composablerecords: parser-wide stack of default field types
      established by `union of T` or `bitpacked record of T`. consulted by
      the C-style `name: N` / `pad N` bitfield syntax. innermost wins.
      callers must push on enter and pop on exit (paired). }
    function current_composable_default_type: tdef;
    procedure push_composable_default_type(def: tdef);
    procedure pop_composable_default_type;

    function check_allowed_for_var_or_const(def:tdef;allowdynarray:boolean):boolean;

    { rejects a stand-alone variable or typed constant of a bare flexible
      array type or of a FAM-record type: neither has a statically known
      size, both must be allocated dynamically. def becomes generrordef }
    procedure check_fam_var_type(var def:tdef;const typepos:tfileposinfo);

implementation

    uses
       SysUtils,
       { common }
       cutils,
       { global }
       globals,tokens,verbose,constexp,
       systems,
       { symtable }
       symconst,symbase,defutil,defcmp,symutil,symcreat,
{$if defined(i386) or defined(i8086) or defined(wasm)}
       symcpu,
{$endif}
       fmodule,htypechk,procdefutil,
       { pass 1 }
       node,pass_1,aasmbase,aasmdata,
       ncon,nset,ncnv,nld,nutils,
       { codegen }
       ngenutil,
       { parser }
       scanner,
       pbase,pexpr,ptype,ptconst,pdecsub,pparautl;


    function read_property_dec(is_classproperty:boolean;astruct:tabstractrecorddef;out autopropfield:tfieldvarsym):tpropertysym;

        { convert a node tree to symlist and return the last
          symbol }
        function parse_symlist(pl:tpropaccesslist;out def:tdef):boolean;
          var
            idx : longint;
            sym : tsym;
            srsymtable : TSymtable;
            st  : TSymtable;
            p   : tnode;
            carrier_chain : tfplist;
            ci : longint;
            composed : boolean;
          begin
            result:=true;
            def:=nil;
            composed:=false;
            if current_scanner.token=_ID then
             begin
               if assigned(astruct) then
                 begin
                   sym:=search_struct_member(astruct,current_scanner.pattern);
                   { fields brought in by record composition (anonymous embeds,
                     inline anonymous records, also inside union variants) live
                     on a hidden carrier field; route the access list through
                     the carrier chain }
                   if not assigned(sym) and
                      (m_composable_records in current_settings.modeswitches) and
                      lookup_in_composition(astruct,current_scanner.pattern,sym,srsymtable,carrier_chain) then
                     begin
                       if sym.typ=fieldvarsym then
                         for ci:=0 to carrier_chain.count-1 do
                           begin
                             if ci=0 then
                               pl.addsym(sl_load,tsym(carrier_chain[ci]))
                             else
                               pl.addsym(sl_subscript,tsym(carrier_chain[ci]));
                             composed:=true;
                           end
                       else
                         { only field targets map onto a property access list }
                         sym:=nil;
                       carrier_chain.free;
                     end;
                 end
               else
                 searchsym(current_scanner.pattern,sym,srsymtable);
               if assigned(sym) then
                begin
                  if assigned(astruct) and
                     not is_visible_for_object(sym,astruct) then
                    Message(parser_e_cant_access_private_member);
                  case sym.typ of
                    fieldvarsym :
                      begin
                        addsymref(sym);
                        if composed then
                          pl.addsym(sl_subscript,sym)
                        else
                          pl.addsym(sl_load,sym);
                        def:=tfieldvarsym(sym).vardef;
                      end;
                    procsym :
                      begin
                        addsymref(sym);
                        pl.addsym(sl_call,sym);
                      end;
                    else
                      begin
                        Message1(parser_e_illegal_field_or_method,current_scanner.orgpattern);
                        def:=generrordef;
                        result:=false;
                      end;
                  end;
                end
               else
                begin
                  Message1(parser_e_illegal_field_or_method,current_scanner.orgpattern);
                  def:=generrordef;
                  result:=false;
                end;
               consume(_ID);
               repeat
                 case current_scanner.token of
                   _ID,
                   _SEMICOLON :
                     begin
                       break;
                     end;
                   _POINT :
                     begin
                       if not is_object(def) and not is_record(def) then
                         message(sym_e_type_must_be_rec_or_object);
                       consume(_POINT);
                       if assigned(def) then
                        begin
                          st:=def.GetSymtable(gs_record);
                          if assigned(st) then
                           begin
                             sym:=tsym(st.Find(current_scanner.pattern));
                             if not(assigned(sym)) and is_object(def) then
                               sym:=search_struct_member(tobjectdef(def),current_scanner.pattern);
                             if assigned(sym) then
                              begin
                                pl.addsym(sl_subscript,sym);
                                case sym.typ of
                                  fieldvarsym :
                                    def:=tfieldvarsym(sym).vardef;
                                  else
                                    begin
                                      Message1(sym_e_illegal_field,current_scanner.orgpattern);
                                      result:=false;
                                    end;
                                end;
                              end
                             else
                              begin
                                Message1(sym_e_illegal_field,current_scanner.orgpattern);
                                result:=false;
                              end;
                           end
                          else
                           begin
                             Message(parser_e_invalid_qualifier);
                             result:=false;
                           end;
                        end
                       else
                        begin
                          Message(parser_e_invalid_qualifier);
                          result:=false;
                        end;
                       consume(_ID);
                     end;
                   _LECKKLAMMER :
                     begin
                       consume(_LECKKLAMMER);
                       repeat
                         if assigned(def) and (def.typ=arraydef) then
                          begin
                            idx:=0;
                            p:=comp_expr([ef_accept_equal]);
                            if (not codegenerror) then
                             begin
                               if (p.nodetype=ordconstn) then
                                 begin
                                   { type/range checking }
                                   inserttypeconv(p,tarraydef(def).rangedef);
                                   if (Tordconstnode(p).value<int64(low(longint))) or
                                      (Tordconstnode(p).value>int64(high(longint))) then
                                     message(parser_e_array_range_out_of_bounds)
                                   else
                                     idx:=Tordconstnode(p).value.svalue
                                 end
                               else
                                Message(type_e_ordinal_expr_expected)
                             end;
                            pl.addconst(sl_vec,idx,p.resultdef);
                            p.free;
                            p := nil;
                            def:=tarraydef(def).elementdef;
                          end
                         else
                          begin
                            Message(parser_e_invalid_qualifier);
                            result:=false;
                          end;
                       until not try_to_consume(_COMMA);
                       consume(_RECKKLAMMER);
                     end;
                   else
                     begin
                       Message(parser_e_ill_property_access_sym);
                       result:=false;
                       break;
                     end;
                 end;
               until false;
             end
            else
             begin
               Message(parser_e_ill_property_access_sym);
               result:=false;
             end;
          end;

          function has_implicit_default(p : tpropertysym) : boolean;

          begin
             has_implicit_default:=
               (is_string(p.propdef) or
               is_real(p.propdef) or
               is_pointer(p.propdef));
          end;

          function allow_default_property(p : tpropertysym) : boolean;

          begin
             allow_default_property:=
               (is_ordinal(p.propdef) or
{$ifndef cpu64bitaddr}
               is_64bitint(p.propdef) or
{$endif cpu64bitaddr}
               is_class(p.propdef) or
               is_single(p.propdef) or
               (p.propdef.typ in [classrefdef,pointerdef]) or
                 is_smallset(p.propdef)
               ) and not
               (
                (p.propdef.typ=arraydef) and
                (ppo_indexed in p.propoptions)
               ) and not
               (ppo_hasparameters in p.propoptions);
          end;

          procedure create_accessor_procsym(p: tpropertysym; pd: tprocdef; const prefix: string;
              accesstype: tpropaccesslisttypes);
            var
              sym: tprocsym;
            begin
              if not assigned(astruct) then
                handle_calling_convention(pd,hcc_default_actions_intf)
              else
                handle_calling_convention(pd,hcc_default_actions_intf_struct);
              sym:=cprocsym.create(prefix+lower(p.realname));
              symtablestack.top.insertsym(sym);
              pd.procsym:=sym;
              include(pd.procoptions,po_dispid);
              include(pd.procoptions,po_global);
              pd.visibility:=vis_private;
              proc_add_definition(pd);
              p.propaccesslist[accesstype].addsym(sl_call,sym);
              p.propaccesslist[accesstype].procdef:=pd;
            end;

          procedure parse_dispinterface(p : tpropertysym; readpd,writepd: tprocdef;
              var paranr: word);
            var
              hasread, haswrite: boolean;
              pt: tnode;
              hdispid: longint;
              hparavs: tparavarsym;
            begin
              p.propaccesslist[palt_read].clear;
              p.propaccesslist[palt_write].clear;

              hasread:=true;
              haswrite:=true;
              hdispid:=0;

              if try_to_consume(_READONLY) then
                haswrite:=false
              else if try_to_consume(_WRITEONLY) then
                hasread:=false;

              if try_to_consume(_DISPID) then
                begin
                  pt:=comp_expr([ef_accept_equal]);
                  if is_constintnode(pt) then
                    if (Tordconstnode(pt).value<int64(low(longint))) or (Tordconstnode(pt).value>int64(high(longint))) then
                      message3(type_e_range_check_error_bounds,tostr(Tordconstnode(pt).value),tostr(low(longint)),tostr(high(longint)))
                    else
                      hdispid:=Tordconstnode(pt).value.svalue
                  else
                    Message(parser_e_dispid_must_be_ord_const);
                  pt.free;
                  pt := nil;
                end
              else
                hdispid:=tobjectdef(astruct).get_next_dispid;

              { COM property is simply a pair of methods, tagged with 'propertyget'
                and 'propertyset' flags (or a single method if access is restricted).
                Creating these implicit accessor methods also allows the rest of compiler
                to handle dispinterface properties the same way as regular ones. }
              if hasread then
                begin
                  readpd.returndef:=p.propdef;
                  readpd.dispid:=hdispid;
                  readpd.proctypeoption:=potype_propgetter;
                  create_accessor_procsym(p,readpd,'get$',palt_read);
                end;
              if haswrite then
                begin
                  { add an extra parameter, a placeholder of the value to set }
                  inc(paranr);
                  hparavs:=cparavarsym.create('$value',10*paranr,vs_value,p.propdef,[]);
                  writepd.parast.insertsym(hparavs);

                  writepd.proctypeoption:=potype_propsetter;
                  writepd.dispid:=hdispid;
                  create_accessor_procsym(p,writepd,'put$',palt_write);
                end;
            end;

        { synthesize a strict-private backing field prefix+Name (prefix from
          autoproperty_field_prefix, default 'F') for an accessor-less property
          and return it, or nil on a name collision. a class property gets a
          class var (static) backing, an instance property an ordinary field;
          the property is later bound to it via read/write FIELD }
        function make_auto_property_field(p:tpropertysym):tfieldvarsym;
          var
            recst : tabstractrecordsymtable;
            hstaticvs : tstaticvarsym;
          begin
            result:=nil;
            recst:=tabstractrecordsymtable(astruct.symtable);
            if assigned(recst.Find(upper(autoproperty_field_prefix)+p.name)) then
              begin
                Message1(parser_e_auto_property_field_exists,autoproperty_field_prefix+p.realname);
                exit;
              end;
            result:=cfieldvarsym.create(autoproperty_field_prefix+p.realname,vs_value,p.propdef,[]);
            result.visibility:=vis_strictprivate;
            result.register_sym;
            recst.insertsym(result);
            if is_classproperty then
              begin
                hstaticvs:=make_field_static(recst,result);
                if not parse_generic then
                  cnodeutils.insertbssdata(hstaticvs);
              end
            else
              recst.addfield(result,vis_strictprivate);
          end;

      var
         sym : tsym;
         srsymtable: tsymtable;
         p : tpropertysym;
         overridden : tsym;
         varspez : tvarspez;
         hdef : tdef;
         arraytype : tdef;
         def : tdef;
         pt : tnode;
         sc : TFPObjectList;
         paranr : word;
         i      : longint;
	 s : single;
         ImplIntf     : TImplementedInterface;
         found,
         gotreadorwrite: boolean;
         hreadparavs,
         hparavs      : tparavarsym;
         storedprocdef: tprocvardef;
         readprocdef,
         writeprocdef : tprocdef;
         autofield : tfieldvarsym;
         autoinitnode : tnode;
      begin
         result:=nil;
         autopropfield:=nil;
         autoinitnode:=nil;
         { Generate temp procdefs to search for matching read/write
           procedures. the readprocdef will store all definitions }
         paranr:=0;
         readprocdef:=cprocdef.create(normal_function_level,false);
         writeprocdef:=cprocdef.create(normal_function_level,false);

         readprocdef.struct:=astruct;
         writeprocdef.struct:=astruct;

         if assigned(astruct) and is_classproperty then
           begin
             readprocdef.procoptions:=[po_staticmethod,po_classmethod];
             writeprocdef.procoptions:=[po_staticmethod,po_classmethod];
           end;

         if current_scanner.token<>_ID then
           begin
              consume(_ID);
              consume(_SEMICOLON);
              exit;
           end;
         { Generate propertysym and insert in symtablestack }
         p:=cpropertysym.create(current_scanner.orgpattern);
         p.visibility:=symtablestack.top.currentvisibility;
         p.default:=longint($80000000);
         if is_classproperty then
           include(p.symoptions, sp_static);
         symtablestack.top.insertsym(p);
         consume(_ID);
         { property parameters ? }
         if try_to_consume(_LECKKLAMMER) then
           begin
              { Published indexed properties are allowed in Delphi in interfaces compiled with $M+. }
              if (p.visibility=vis_published) and
                not((m_delphi in current_settings.modeswitches) and is_interfacecom_or_dispinterface(astruct)) then
                Message(parser_e_cant_publish_that_property);
              { create a list of the parameters }
              p.parast:=tparasymtable.create(nil,0);
              symtablestack.push(p.parast);
              sc:=TFPObjectList.create(false);
              repeat
                if try_to_consume(_VAR) then
                  varspez:=vs_var
                else if try_to_consume(_CONST) then
                  varspez:=vs_const
                else if try_to_consume(_CONSTREF) then
                  varspez:=vs_constref
                else if (m_out in current_settings.modeswitches) and try_to_consume(_OUT) then
                  varspez:=vs_out
                else
                  varspez:=vs_value;
                sc.clear;
                repeat
                  inc(paranr);
                  hreadparavs:=cparavarsym.create(current_scanner.orgpattern,10*paranr,varspez,generrordef,[]);
                  p.parast.insertsym(hreadparavs);
                  sc.add(hreadparavs);
                  consume(_ID);
                until not try_to_consume(_COMMA);
                if try_to_consume(_COLON) then
                  begin
                    if try_to_consume(_ARRAY) then
                      begin
                        consume(_OF);
                        { define range and type of range }
                        hdef:=carraydef.create_openarray;
                        hdef.owner:=astruct.symtable;
                        { define field type }
                        single_type(arraytype,[]);
                        tarraydef(hdef).elementdef:=arraytype;
                      end
                    else
                      single_type(hdef,[]);
                  end
                else
                  hdef:=cformaltype;
                for i:=0 to sc.count-1 do
                  tparavarsym(sc[i]).vardef:=hdef;
              until not try_to_consume(_SEMICOLON);
              sc.free;
              sc := nil;
              symtablestack.pop(p.parast);
              consume(_RECKKLAMMER);

              { the parser need to know if a property has parameters, the
                index parameter doesn't count (PFV) }
              if paranr>0 then
                begin
                  p.add_accessor_parameters(readprocdef,writeprocdef);
                  include(p.propoptions,ppo_hasparameters);
                end;
           end;
         { overridden property ?                                 }
         { force property interface
             there is a property parameter
             a global property }
         if (current_scanner.token=_COLON) or (paranr>0) or (astruct=nil) then
           begin
              consume(_COLON);
              single_type(p.propdef,[stoAllowSpecialization]);

              if is_dispinterface(astruct) and not is_automatable(p.propdef) then
                Message1(type_e_not_automatable,p.propdef.typename);

              if (current_scanner.idtoken=_INDEX) then
                begin
                   consume(_INDEX);
                   pt:=comp_expr([ef_accept_equal]);
                   { Only allow enum and integer indexes. Convert all integer
                     values to objpas.integer (s32int on 32- and 64-bit targets,
                     s16int on 16- and 8-bit) to be compatible with delphi,
                     because the procedure matching requires equal parameters }
                   if is_constnode(pt) and
                      is_ordinal(pt.resultdef)
                      and (not is_64bitint(pt.resultdef))
{$if defined(cpu8bitalu) or defined(cpu16bitalu)}
                      and (not is_32bitint(pt.resultdef))
{$endif}
                      then
                     begin
                       if is_integer(pt.resultdef) then
{$if defined(cpu8bitalu) or defined(cpu16bitalu)}
                         inserttypeconv_internal(pt,s16inttype);
{$else}
                         inserttypeconv_internal(pt,s32inttype);
{$endif}
                       p.index:=tordconstnode(pt).value.svalue;
                     end
                   else
                     begin
                       Message(parser_e_invalid_property_index_value);
                       p.index:=0;
                     end;
                   p.indexdef:=pt.resultdef;
                   include(p.propoptions,ppo_indexed);
                   { concat a longint to the para templates }
                   p.add_index_parameter(paranr,readprocdef,writeprocdef);
                   pt.free;
                   pt := nil;
                end;
           end
         else
           begin
              { do an property override }
              if (astruct.typ=objectdef) and assigned(tobjectdef(astruct).childof) then
                overridden:=search_struct_member(tobjectdef(astruct).childof,p.name)
              else
                overridden:=nil;
              if assigned(overridden) and
                 (overridden.typ=propertysym) and
                 not(is_dispinterface(astruct)) then
                begin
                  tpropertysym(overridden).makeduplicate(p,readprocdef,writeprocdef,paranr);
                  p.register_override(tpropertysym(overridden));
                end
              else
                begin
                  p.propdef:=generrordef;
                  message(parser_e_no_property_found_to_override);
                end;
           end;
         if ((p.visibility=vis_published) or is_dispinterface(astruct))
             and not (astruct.is_generic and (p.propdef.typ=undefineddef)) then
           begin
             { ignore is_publishable for interfaces (related to $M+ directive).
               $M has effect on visibility of default section for classes.
               Interface has always only public section (fix for problem in tb0631.pp) }
             if (sp_static in p.symoptions) or ((p.propdef.is_publishable=pp_error) and not is_interface(astruct)) then
               begin
                 Message(parser_e_cant_publish_that_property);
                 p.visibility:=vis_public;
               end
             else
             if (p.propdef.is_publishable=pp_ignore) and not is_interface(astruct) then
               begin
                 Message(parser_w_ignoring_published_property);
                 p.visibility:=vis_public;
               end;
           end;

         if not(is_dispinterface(astruct)) then
           begin
             gotreadorwrite:=false;
             { accessor-less property initializer: `property X: T = constexpr;`
               the value seeds the synthesized backing field at construction }
             if (m_autoproperties in current_settings.modeswitches) and
                (current_scanner.token=_EQ) then
               begin
                 consume(_EQ);
                 autoinitnode:=comp_expr([ef_accept_equal]);
                 inserttypeconv(autoinitnode,p.propdef);
                 if not is_constnode(autoinitnode) then
                   begin
                     Message(parser_e_auto_property_init_const);
                     autoinitnode.free;
                     autoinitnode:=nil;
                   end;
               end;
             { parse accessors }
             if try_to_consume(_READ) then
               begin
                 gotreadorwrite:=true;
                 p.propaccesslist[palt_read].clear;
                 if parse_symlist(p.propaccesslist[palt_read],def) then
                  begin
                    sym:=p.propaccesslist[palt_read].firstsym^.sym;
                    { getter is a function returning the type of the property }
                    if sym.typ=procsym then
                      begin
                        readprocdef.returndef:=p.propdef;
                        { Insert hidden parameters }
                        if assigned(astruct) then
                          handle_calling_convention(readprocdef,hcc_default_actions_intf_struct)
                        else
                          handle_calling_convention(readprocdef,hcc_default_actions_intf);
                      end;
                    p.add_getter_or_setter_for_sym(palt_read,sym,def,readprocdef);
                  end;
               end
             else
               p.inherit_accessor(palt_read);
             if try_to_consume(_WRITE) then
               begin
                 gotreadorwrite:=true;
                 p.propaccesslist[palt_write].clear;
                 if parse_symlist(p.propaccesslist[palt_write],def) then
                  begin
                    sym:=p.propaccesslist[palt_write].firstsym^.sym;
                    if sym.typ=procsym then
                      begin
                        { setter is a procedure with an extra value parameter
                          of the of the property }
                        writeprocdef.returndef:=voidtype;
                        inc(paranr);
                        hparavs:=cparavarsym.create('$value',10*paranr,vs_value,p.propdef,[]);
                        writeprocdef.parast.insertsym(hparavs);
                        { Insert hidden parameters }
                        if not assigned(astruct) then
                          handle_calling_convention(writeprocdef,hcc_default_actions_intf)
                        else
                          handle_calling_convention(writeprocdef,hcc_default_actions_intf_struct);
                      end;
                    p.add_getter_or_setter_for_sym(palt_write,sym,def,writeprocdef);
                  end;
               end
             else
               p.inherit_accessor(palt_write);
             { a new property (needs to declare a getter or setter, except in
               an interface }
             if not(ppo_overrides in p.propoptions) and
                not is_interface(astruct) and
                not gotreadorwrite then
               begin
                 { accessor-less property: synthesize a backing field and bind
                   both read and write to it; a trailing readonly/writeonly
                   directive (handled by the caller) later drops one side }
                 if (m_autoproperties in current_settings.modeswitches) and
                    assigned(astruct) and
                    (p.propdef.typ<>errordef) then
                   begin
                     if ppo_hasparameters in p.propoptions then
                       Message(parser_e_auto_property_indexed)
                     else
                       begin
                         autofield:=make_auto_property_field(p);
                         if assigned(autofield) then
                           begin
                             p.propaccesslist[palt_read].clear;
                             p.propaccesslist[palt_read].addsym(sl_load,autofield);
                             addsymref(autofield);
                             p.add_getter_or_setter_for_sym(palt_read,autofield,autofield.vardef,readprocdef);
                             p.propaccesslist[palt_write].clear;
                             p.propaccesslist[palt_write].addsym(sl_load,autofield);
                             addsymref(autofield);
                             p.add_getter_or_setter_for_sym(palt_write,autofield,autofield.vardef,writeprocdef);
                             autopropfield:=autofield;
                             { record the initializer so the constructor seeds
                               the field; only classes/objects (not records)
                               have a construction hook }
                             if assigned(autoinitnode) and (astruct.typ=objectdef) then
                               begin
                                 if not assigned(tobjectdef(astruct).auto_prop_init_fields) then
                                   begin
                                     tobjectdef(astruct).auto_prop_init_fields:=TFPList.Create;
                                     tobjectdef(astruct).auto_prop_init_values:=TFPObjectList.Create(true);
                                   end;
                                 tobjectdef(astruct).auto_prop_init_fields.Add(autofield);
                                 tobjectdef(astruct).auto_prop_init_values.Add(autoinitnode);
                                 autoinitnode:=nil;
                               end;
                           end;
                       end;
                   end
                 else
                   Consume(_READ);
               end;
           end
         else
           parse_dispinterface(p,readprocdef,writeprocdef,paranr);

         { an initializer that could not be attached (explicit accessor, indexed,
           or a record) is a misuse }
         if assigned(autoinitnode) then
           begin
             Message(parser_e_auto_property_init_context);
             autoinitnode.free;
             autoinitnode:=nil;
           end;

         { stored is not allowed for dispinterfaces, records or class properties }
         if assigned(astruct) and not(is_dispinterface(astruct) or is_record(astruct)) and not is_classproperty then
           begin
             { ppo_stored is default on for not overridden properties }
             if not assigned(p.overriddenpropsym) then
               include(p.propoptions,ppo_stored);
             if try_to_consume(_STORED) then
              begin
                include(p.propoptions,ppo_stored);
                p.propaccesslist[palt_stored].clear;
                if current_scanner.token=_ID then
                  begin
                    { in the case that idtoken=_DEFAULT }
                    { we have to do nothing except      }
                    { setting ppo_stored, it's the same }
                    { as stored true                    }
                    if current_scanner.idtoken<>_DEFAULT then
                     begin
                       { parse_symlist cannot deal with constsyms, and
                         we also don't want to put constsyms in symlists
                         since they have to be evaluated immediately rather
                         than each time the property is accessed

                         The proper fix would be to always create a parse tree
                         and then convert that one, if appropriate, to a symlist.
                         Currently, we e.g. don't support any constant expressions
                         yet either here, while Delphi does.

                       }
                       { make sure we don't let constants mask class fields/
                         methods
                       }
                       sym:=nil;
                       if (not assigned(astruct) or
                           (search_struct_member(astruct,current_scanner.pattern)=nil)) and
                          searchsym(current_scanner.pattern,sym,srsymtable) and
                          (sym.typ = constsym) then
                         begin
                            addsymref(sym);
                            if not is_boolean(tconstsym(sym).constdef) then
                              Message(parser_e_stored_property_must_be_boolean)
                            else if (tconstsym(sym).value.valueord=0) then
                              { same as for _FALSE }
                              exclude(p.propoptions,ppo_stored)
                            else
                              begin
                                { same as for _TRUE }
                                { do nothing - ppo_stored is already set to p.propoptions in "include(p.propoptions,ppo_stored);" above }
                                { especially do not reset the default value - the stored specifier is independent on the default value! }
                              end;
                            consume(_ID);
                          end
                       else if parse_symlist(p.propaccesslist[palt_stored],def) then
                        begin
                          sym:=p.propaccesslist[palt_stored].firstsym^.sym;
                          case sym.typ of
                            procsym :
                              begin
                                 { Create a temporary procvardef to handle parameters }
                                 storedprocdef:=cprocvardef.create(normal_function_level,true);
                                 include(storedprocdef.procoptions,po_methodpointer);
                                 { Return type must be boolean }
                                 storedprocdef.returndef:=pasbool1type;
                                 { Add index parameter if needed }
                                 if ppo_indexed in p.propoptions then
                                   begin
                                     hparavs:=cparavarsym.create('$index',10,vs_value,p.indexdef,[]);
                                     storedprocdef.parast.insertsym(hparavs);
                                   end;

                                 { Insert hidden parameters }
                                 if not assigned(astruct) then
                                   handle_calling_convention(storedprocdef,hcc_default_actions_intf)
                                 else
                                   handle_calling_convention(storedprocdef,hcc_default_actions_intf_struct);
                                 p.propaccesslist[palt_stored].procdef:=Tprocsym(sym).Find_procdef_bypara(storedprocdef.paras,storedprocdef.returndef,[cpo_allowdefaults,cpo_ignorehidden]);
                                 if not assigned(p.propaccesslist[palt_stored].procdef) then
                                   message(parser_e_ill_property_storage_sym);
                                 { Not needed anymore }
                                 storedprocdef.owner.deletedef(storedprocdef);
                              end;
                            fieldvarsym :
                              begin
                                if not assigned(def) then
                                  internalerror(200310073);
                                if (ppo_hasparameters in p.propoptions) or
                                   not(is_boolean(def)) then
                                 Message(parser_e_stored_property_must_be_boolean);
                              end;
                            else
                              Message(parser_e_ill_property_access_sym);
                          end;
                        end;
                     end;
                  end;
              end;
           end;
         if has_implicit_default(p) and not assigned(p.overriddenpropsym) then
           begin
              p.default:=0;
           end;
         if not is_record(astruct) and try_to_consume(_DEFAULT) then
           begin
              if not allow_default_property(p) then
                begin
                  Message(parser_e_property_cant_have_a_default_value);
                  { Error recovery }
                  pt:=comp_expr([ef_accept_equal]);
                  pt.free;
                  pt := nil;
                end
              else
                begin
                  { Get the result of the default, the firstpass is
                    needed to support values like -1 }
                  pt:=comp_expr([ef_accept_equal]);
                  if (p.propdef.typ=setdef) and
                     (pt.nodetype=arrayconstructorn) then
                    begin
                      arrayconstructor_to_set(pt);
                      do_typecheckpass(pt);
                    end;
                  inserttypeconv(pt,p.propdef);
                  if not(is_constnode(pt)) then
                    Message(parser_e_property_default_value_must_const);
                  { Set default value }
                  case pt.nodetype of
                    setconstn :
                      begin
                        if (source_info.endian=target_info.endian) then
                          p.default:=plongint(tsetconstnode(pt).value_set)^
                        else
                          p.default:=longint(reverse_longword(plongword(tsetconstnode(pt).value_set)^));
                        include(p.propoptions,ppo_default_is_set);
                      end;
                    ordconstn :
                      if is_real(p.propdef) then
                        begin
                          if TOrdconstnode(pt).value.is_negative then
                            s:=TOrdconstnode(pt).value.svalue
                          else
                            s:=TOrdconstnode(pt).value.uvalue;
                          p.default:=plongint(@s)^;
                          include(p.propoptions,ppo_default_is_single);
                        end
                      else if (Tordconstnode(pt).value<int64(low(longint))) or
                         (Tordconstnode(pt).value>int64(high(cardinal))) then
                        message3(type_e_range_check_error_bounds,tostr(Tordconstnode(pt).value),tostr(low(longint)),tostr(high(cardinal)))
                      else
                        p.default:=longint(tordconstnode(pt).value.svalue);
                    niln :
                      p.default:=0;
                    realconstn:
                      begin
                        s:=single(trealconstnode(pt).value_real);
                        p.default:=plongint(@s)^;
                        include(p.propoptions,ppo_default_is_single);
                      end;
                    else if not codegenerror then
                      internalerror(2019050525);
                  end;
                  pt.free;
                  pt := nil;
                end;
           end
         else if not is_record(astruct) and try_to_consume(_NODEFAULT) then
           begin
              p.default:=longint($80000000);
           end;
(*
         else {if allow_default_property(p) then
           begin
              p.default:=longint($80000000);
           end;
*)
         { Parse possible "implements" keyword }
         if not is_record(astruct) and try_to_consume(_IMPLEMENTS) then
           repeat
             single_type(def,[]);

             if not(is_interface(def)) then
               message(parser_e_class_implements_must_be_interface);

             if is_interface(p.propdef) then
               begin
                 { an interface type may delegate itself or one of its ancestors }
                 if not def_is_related(p.propdef,def) then
                   begin
                     message2(parser_e_implements_must_have_correct_type,def.typename,p.propdef.typename);
                     exit;
                   end;
               end
             else if is_class(p.propdef) then
               begin
                 ImplIntf:=find_implemented_interface(tobjectdef(p.propdef),tobjectdef(def));
                 if assigned(ImplIntf) then
                   begin
                     if compare_defs(ImplIntf.IntfDef,def,nothingn)<te_equal then
                       begin
                         message2(parser_e_implements_must_have_correct_type,ImplIntf.IntfDef.typename,def.typename);
                         exit;
                       end;
                   end
                 else
                   begin
                     message2(parser_e_class_doesnt_implement_interface,p.propdef.typename,def.typename);
                     exit;
                   end;
               end
             else
               begin
                 message(parser_e_implements_must_be_class_or_interface);
                 exit;
               end;


             if not assigned(p.propaccesslist[palt_read].firstsym) then
               begin
                 message(parser_e_implements_must_read_specifier);
                 exit;
               end;
             if assigned(p.propaccesslist[palt_read].procdef) and
                (tprocdef(p.propaccesslist[palt_read].procdef).proccalloption<>pocall_default) then
               message(parser_e_implements_getter_not_default_cc);
             if assigned(p.propaccesslist[palt_write].firstsym) then
               begin
                 message(parser_e_implements_must_not_have_write_specifier);
                 exit;
               end;
             if assigned(p.propaccesslist[palt_stored].firstsym) then
               begin
                 message(parser_e_implements_must_not_have_stored_specifier);
                 exit;
               end;
             found:=false;
             ImplIntf:=nil;
             for i:=0 to tobjectdef(astruct).ImplementedInterfaces.Count-1 do
               begin
                 ImplIntf:=TImplementedInterface(tobjectdef(astruct).ImplementedInterfaces[i]);

                 if compare_defs(def,ImplIntf.IntfDef,nothingn)>=te_equal then
                   begin
                     found:=true;
                     break;
                   end;
               end;
             if found then
               begin
                 { An interface may not be delegated by more than one property,
                   it also may not have method mappings. }
                 if Assigned(ImplIntf.ImplementsGetter) then
                   message1(parser_e_duplicate_implements_clause,ImplIntf.IntfDef.typename);
                 if Assigned(ImplIntf.NameMappings) then
                   message2(parser_e_mapping_no_implements,ImplIntf.IntfDef.typename,astruct.objrealname^);

                 ImplIntf.ImplementsGetter:=p;
                 ImplIntf.VtblImplIntf:=ImplIntf;
                 case p.propaccesslist[palt_read].firstsym^.sym.typ of
                   procsym :
                     begin
                       if (po_virtualmethod in tprocdef(p.propaccesslist[palt_read].procdef).procoptions) and
                           not is_objectpascal_helper(tprocdef(p.propaccesslist[palt_read].procdef).struct) then
                         ImplIntf.IType:=etVirtualMethodResult
                       else
                         ImplIntf.IType:=etStaticMethodResult;
                     end;
                   fieldvarsym :
                     begin
                       ImplIntf.IType:=etFieldValue;
                       { this must be done in a more robust way. Can't read the
                         fieldvarsym's fieldoffset yet, because it may not yet
                         be set }
                       ImplIntf.ImplementsField:=p.propaccesslist[palt_read].firstsym^.sym;
                     end
                   else
                     internalerror(200802161);
                 end;
                 if not is_interface(p.propdef) then
                   case ImplIntf.IType of
                     etVirtualMethodResult: ImplIntf.IType := etVirtualMethodClass;
                     etStaticMethodResult:  ImplIntf.IType := etStaticMethodClass;
                     etFieldValue:          ImplIntf.IType := etFieldValueClass;
                   else
                     internalerror(200912101);
                   end;
               end
             else
               message1(parser_e_implements_uses_non_implemented_interface,def.typename);
           until not try_to_consume(_COMMA);

         { register propgetter and propsetter procdefs }
         if assigned(current_module) and current_module.in_interface then
           begin
             if readprocdef.proctypeoption=potype_propgetter then
               readprocdef.register_def
             else
               readprocdef.free; // no nil needed
             if writeprocdef.proctypeoption=potype_propsetter then
               writeprocdef.register_def
             else
               writeprocdef.free; // no nil needed
           end
         else
           begin
             if readprocdef.proctypeoption=potype_propgetter then
               readprocdef.maybe_put_in_symtable_stack
             else
               readprocdef.free; // no nil needed
             if writeprocdef.proctypeoption=potype_propsetter then
               writeprocdef.maybe_put_in_symtable_stack
             else
               writeprocdef.free; // no nil needed
           end;

         result:=p;
      end;


     function maybe_parse_proc_directives(def:tdef):boolean;
       begin
         result:=false;
         { Process procvar directives before = and ; }
         if (
              (def.typ=procvardef) or
              is_funcref(def)
            ) and
            (def.typesym=nil) and
            check_proc_directive(true) then
           begin
              parse_proctype_directives(def);
              result:=true;
           end;
       end;


    var
       variantrecordlevel : longint = 0;


    procedure read_public_and_external_sc(sc:TFPObjectList);
    var
      vs: tabstractvarsym;
    begin
      { only allowed for one var }
      vs:=tabstractvarsym(sc[0]);
      if sc.count>1 then
        Message1(parser_e_directive_only_one_var,arraytokeninfo[current_scanner.idtoken].str);
      read_public_and_external(vs);
    end;


    procedure read_public_and_external(vs: tabstractvarsym);
    var
      is_dll,
      is_far,
      is_cdecl,
      is_external_var,
      is_weak_external,
      is_public_var  : boolean;
      dll_name,section_name,
      C_name,mangledname      : string;
    begin
      { only allowed for one var }
      { only allow external and public on global symbols }
      if vs.typ<>staticvarsym then
        begin
          Message(parser_e_no_local_var_external);
          exit;
        end;
      { defaults }
      is_dll:=false;
      is_far:=false;
      is_cdecl:=false;
      is_external_var:=false;
      is_public_var:=false;
      section_name := '';
      dll_name := '';
      C_name:=vs.realname;

      { macpas specific handling due to some switches}
      if (m_mac in current_settings.modeswitches) then
        begin
          if (cs_external_var in current_settings.localswitches) then
            begin {The effect of this is the same as if cvar; external; has been given as directives.}
              is_cdecl:=true;
              is_external_var:=true;
            end
          else if (cs_externally_visible in current_settings.localswitches) then
            begin {The effect of this is the same as if cvar has been given as directives and it's made public.}
              is_cdecl:=true;
              is_public_var:=true;
            end;
        end;

      { cdecl }
      if try_to_consume(_CVAR) then
        begin
          consume(_SEMICOLON);
          is_cdecl:=true;
        end;

      { external }
      is_weak_external:=try_to_consume(_WEAKEXTERNAL);
      if is_weak_external or
         try_to_consume(_EXTERNAL) then
        begin
          is_external_var:=true;
          { near/far? }
          if target_info.system in systems_allow_external_far_var then
            begin
              if try_to_consume(_FAR) then
                is_far:=true
              else if try_to_consume(_NEAR) then
                is_far:=false;
            end;
          if (current_scanner.idtoken<>_NAME) and (current_scanner.token<>_SEMICOLON) then
            begin
              is_dll:=true;
              dll_name:=get_stringconst;
              if ExtractFileExt(dll_name)='' then
                dll_name:=ChangeFileExt(dll_name,target_info.sharedlibext);
            end;
          if not(is_cdecl) and try_to_consume(_NAME) then
            C_name:=get_stringconst;
          consume(_SEMICOLON);
        end;

      { export or public }
      if current_scanner.idtoken in [_EXPORT,_PUBLIC] then
        begin
          consume(_ID);
          if is_external_var then
            Message(parser_e_not_external_and_export)
          else
            is_public_var:=true;
          if try_to_consume(_NAME) then
            C_name:=get_stringconst;
          if (target_info.system in systems_allow_section_no_semicolon) and
             (vs.typ=staticvarsym) and
             try_to_consume (_SECTION) then
            section_name:=get_stringconst;
          consume(_SEMICOLON);
        end;

      { Windows uses an indirect reference using import tables }
      if is_dll and
         (target_info.system in systems_all_windows) then
        include(vs.varoptions,vo_is_dll_var);

      { This can only happen if vs.typ=staticvarsym }
      if section_name<>'' then
        begin
          tstaticvarsym(vs).section:=section_name;
          include(vs.varoptions,vo_has_section);
        end;


      { Add C _ prefix }
      if is_cdecl or
         (
          is_dll and
          (target_info.system in systems_darwin)
         ) then
        C_Name := target_info.Cprefix+C_Name;

      if is_public_var then
        begin
          include(vs.varoptions,vo_is_public);
          vs.varregable := vr_none;
          { mark as referenced }
          inc(vs.refs);
        end;

      mangledname:=C_name;
      { now we can insert it in the import lib if its a dll, or
        add it to the externals }
      if is_external_var then
        begin
          if vo_is_typed_const in vs.varoptions then
            Message(parser_e_initialized_not_for_external);
          include(vs.varoptions,vo_is_external);
          if is_far then
            include(vs.varoptions,vo_is_far);
          if (is_weak_external) then
            begin
              if not(target_info.system in systems_weak_linking) then
                message(parser_e_weak_external_not_supported);
              include(vs.varoptions,vo_is_weak_external);
            end;
          vs.varregable := vr_none;
          if is_dll then
            begin
              if target_info.system in (systems_all_windows + systems_nativent +
                                       [system_i386_emx, system_i386_os2]) then
                mangledname:=make_dllmangledname(dll_name,C_name,0,pocall_none);

              current_module.AddExternalImport(dll_name,C_Name,mangledname,0,true,false);
            end
          else
            if tf_has_dllscanner in target_info.flags then
              current_module.dllscannerinputlist.Add(vs.mangledname,vs);
        end;

      { Set the assembler name }
      tstaticvarsym(vs).set_mangledbasename(mangledname);
      tstaticvarsym(vs).set_mangledname(mangledname);
    end;


    procedure try_consume_sectiondirective(var asection: ansistring);
      begin
        if current_scanner.idtoken=_SECTION then
          begin
            consume(_ID);
            asection:=get_stringconst;
            consume(_SEMICOLON);
          end;
      end;


    procedure try_read_field_external(vs: tabstractvarsym);
      var
        extname: string;
      begin
        if try_to_consume(_EXTERNAL) then
          begin
            consume(_NAME);
            extname:=get_stringconst;
            tfieldvarsym(vs).set_externalname(extname);
            consume(_SEMICOLON);
          end;
      end;


    procedure try_read_field_external_sc(sc:TFPObjectList);
    var
      vs: tabstractvarsym;
    begin
      { only allowed for one var }
      vs:=tabstractvarsym(sc[0]);
      if sc.count>1 then
        Message1(parser_e_directive_only_one_var,arraytokeninfo[current_scanner.idtoken].str);
      try_read_field_external(vs);
    end;


    procedure check_fam_var_type(var def:tdef;const typepos:tfileposinfo);
      begin
        if is_flexible_array(def) then
          begin
            Messagepos(typepos,parser_e_fam_outside_record);
            def:=generrordef;
          end
        else if record_has_flexible_array_field(def) then
          begin
            Messagepos1(typepos,parser_e_fam_record_on_stack,def.typename);
            def:=generrordef;
          end;
      end;


    procedure read_var_decls(options:Tvar_dec_options;out had_generic:boolean);

        procedure read_default_value(sc : TFPObjectList);
        var
          vs : tabstractnormalvarsym;
          tcsym : tstaticvarsym;
          templist : tasmlist;
          i : longint;
          tokenbuf : tdynamicarray;
          already_recording : boolean;
        begin
          vs:=tabstractnormalvarsym(sc[0]);
          if (sc.count>1) and
             not(m_multi_var_init in current_settings.modeswitches) then
            Message(parser_e_initialized_only_one_var);
          if vo_is_thread_var in vs.varoptions then
            Message(parser_e_initialized_not_for_threadvar);
          consume(_EQ);
          case vs.typ of
            localvarsym :
              begin
                tcsym:=cstaticvarsym.create('$default'+vs.realname,vs_const,vs.vardef,[]);
                include(tcsym.symoptions,sp_internal);
                symtablestack.top.insertsym(tcsym);
                templist:=tasmlist.create;
                read_typed_const(templist,tcsym,false);
                { in case of a generic routine, this initialisation value is not
                  used, and will be re-parsed during specialisations (and the
                  current version is not type-correct and hence breaks code
                  generation for LLVM) }
                if not parse_generic then
                  begin
                    for i:=0 to sc.count-1 do
                      begin
                        tabstractnormalvarsym(sc[i]).defaultconstsym:=tcsym;
                        tabstractnormalvarsym(sc[i]).varstate:=vs_initialised;
                      end;
                    current_asmdata.asmlists[al_typedconsts].concatlist(templist);
                  end;
                templist.free;
                templist := nil;
              end;
            staticvarsym :
              begin
                maybe_guarantee_record_typesym(vs.vardef,vs.vardef.owner);
                if sc.count<=1 then
                  read_typed_const(current_asmdata.asmlists[al_typedconsts],tstaticvarsym(vs),false)
                else
                  begin
                    { record tokens so we can replay them for each variable }
                    already_recording:=current_scanner.is_recording_tokens;
                    tokenbuf:=tdynamicarray.create(256);
                    if not already_recording then
                      current_scanner.startrecordtokens(tokenbuf);
                    read_typed_const(current_asmdata.asmlists[al_typedconsts],tstaticvarsym(vs),false);
                    if not already_recording then
                      current_scanner.stoprecordtokens;
                    for i:=1 to sc.count-1 do
                      begin
                        maybe_guarantee_record_typesym(tabstractnormalvarsym(sc[i]).vardef,tabstractnormalvarsym(sc[i]).vardef.owner);
                        tokenbuf.seek(0);
                        current_scanner.startreplaytokens(tokenbuf,false);
                        read_typed_const(current_asmdata.asmlists[al_typedconsts],tstaticvarsym(sc[i]),false);
                      end;
                    tokenbuf.free;
                  end;
              end;
            else
              internalerror(200611051);
          end;
          for i:=0 to sc.count-1 do
            tabstractnormalvarsym(sc[i]).varstate:=vs_initialised;
        end;

{$ifdef gpc_mode}
        procedure read_gpc_name(sc : TFPObjectList);
        var
          vs : tabstractnormalvarsym;
          C_Name : string;
        begin
          consume(_ID);
          C_Name:=get_stringconst;
          vs:=tabstractnormalvarsym(sc[0]);
          if sc.count>1 then
            Message(parser_e_directive_only_one_var,'ABSOLUTE');
          if vs.typ=staticvarsym then
            begin
              tstaticvarsym(vs).set_mangledname(C_Name);
              include(vs.varoptions,vo_is_external);
            end
          else
            Message(parser_e_no_local_var_external);
        end;
{$endif}

        procedure read_absolute(sc : TFPObjectList);
        var
          vs     : tabstractvarsym;
          abssym : tabsolutevarsym;
          pt,hp  : tnode;
          st     : tsymtable;
          {$if defined(i386) or defined(i8086)}
          tmpaddr : int64;
          {$endif defined(i386) or defined(i8086)}
        begin
          abssym:=nil;
          { only allowed for one var }
          vs:=tabstractvarsym(sc[0]);
          if sc.count>1 then
            Message1(parser_e_directive_only_one_var,'ABSOLUTE');
          if vo_is_typed_const in vs.varoptions then
            Message(parser_e_initialized_not_for_external);
          { parse the rest }
          pt:=expr(true);
          { check allowed absolute types }
          if (pt.nodetype=stringconstn) or
            (is_constcharnode(pt)) then
            begin
              abssym:=cabsolutevarsym.create(vs.realname,vs.vardef);
              abssym.fileinfo:=vs.fileinfo;
              if pt.nodetype=stringconstn then
                abssym.asmname:=stringdup(tstringconstnode(pt).asrawbytestring)
              else
                abssym.asmname:=stringdup(chr(tordconstnode(pt).value.svalue));
              abssym.abstyp:=toasm;
            end
          { address }
          else if is_constintnode(pt) then
            begin
              abssym:=cabsolutevarsym.create(vs.realname,vs.vardef);
              abssym.fileinfo:=vs.fileinfo;
              abssym.abstyp:=toaddr;
{$ifndef cpu64bitaddr}
              { on 64 bit systems, abssym.addroffset is a qword and hence this
                test is useless (value is a 64 bit entity) and will always fail
                for positive values (since int64(high(abssym.addroffset))=-1
              }
              if (Tordconstnode(pt).value<int64(low(abssym.addroffset))) or
                 (Tordconstnode(pt).value>int64(high(abssym.addroffset))) then
                message3(type_e_range_check_error_bounds,tostr(Tordconstnode(pt).value),tostr(low(abssym.addroffset)),tostr(high(abssym.addroffset)))
             else
{$endif}
                abssym.addroffset:=Tordconstnode(pt).value.svalue;
{$if defined(i386) or defined(i8086)}
              tcpuabsolutevarsym(abssym).absseg:=false;
              if (target_info.system in [system_i386_go32v2,system_i386_watcom,system_i8086_msdos,system_i8086_win16,system_i8086_embedded]) and
                  try_to_consume(_COLON) then
                begin
                  pt.free;
                  pt:=expr(true);
                  if is_constintnode(pt) then
                    begin
                      {$if defined(i8086)}
                        tcpuabsolutevarsym(abssym).addrsegment:=abssym.addroffset;
                        tmpaddr:=tordconstnode(pt).value.svalue;
                        if (tmpaddr<int64(low(abssym.addroffset))) or
                           (tmpaddr>int64(high(abssym.addroffset))) then
                          message3(type_e_range_check_error_bounds,tostr(Tordconstnode(pt).value),tostr(low(abssym.addroffset)),tostr(high(abssym.addroffset)))
                        else
                          abssym.addroffset:=tmpaddr;
                      {$elseif defined(i386)}
                        tmpaddr:=abssym.addroffset shl 4+tordconstnode(pt).value.svalue;
                        if (tmpaddr<int64(low(abssym.addroffset))) or
                           (tmpaddr>int64(high(abssym.addroffset))) then
                          message3(type_e_range_check_error_bounds,tostr(Tordconstnode(pt).value),tostr(low(abssym.addroffset)),tostr(high(abssym.addroffset)))
                        else
                          abssym.addroffset:=tmpaddr;
                      {$endif}
                      tcpuabsolutevarsym(abssym).absseg:=true;
                    end
                  else
                    Message(type_e_ordinal_expr_expected);
                end;
{$endif i386 or i8086}
            end
          { variable }
          else
            begin
              { we have to be able to take the address of the absolute
                expression
              }
              valid_for_addr(pt,true);
              { remove subscriptn before checking for loadn }
              hp:=pt;
              while (hp.nodetype in [subscriptn,typeconvn,vecn]) do
                begin
                  { check for implicit dereferencing and reject it }
                  if (hp.nodetype in [subscriptn,vecn]) then
                    begin
                      if (tunarynode(hp).left.resultdef.typ in [pointerdef,classrefdef]) then
                        break;
                      { catch, e.g., 'var b: char absolute pchar_var[5];"
                        (pchar_var[5] is a pchar_2_string typeconv ->
                         the vecn only sees an array of char)
                        I don't know if all of these type conversions are
                        possible, but they're definitely all bad.
                      }
                      if (tunarynode(hp).left.nodetype=typeconvn) and
                         (ttypeconvnode(tunarynode(hp).left).convtype in
                           [tc_pchar_2_string,tc_pointer_2_array,
                            tc_intf_2_string,tc_intf_2_guid,
                            tc_dynarray_2_variant,tc_interface_2_variant,
                            tc_array_2_dynarray]) then
                        break;

                      if (tunarynode(hp).left.resultdef.typ=stringdef) and
                         not(tstringdef(tunarynode(hp).left.resultdef).stringtype in [st_shortstring,st_longstring]) then
                        break;
                      if (tunarynode(hp).left.resultdef.typ=objectdef) and
                         (tobjectdef(tunarynode(hp).left.resultdef).objecttype<>odt_object) then
                        break;
                      if is_dynamic_array(tunarynode(hp).left.resultdef) then
                        break;
                    end;
                  hp:=tunarynode(hp).left;
                end;
              if (hp.nodetype=loadn) then
                begin
                  { we should check the result type of loadn }
                  if not (tloadnode(hp).symtableentry.typ in [fieldvarsym,staticvarsym,localvarsym,paravarsym,absolutevarsym]) then
                    Message(parser_e_absolute_only_to_var_or_const);
                  if vs=tloadnode(hp).symtableentry then
                    Message(parser_e_absolute_sym_cannot_reference_itself)
                  else
                    begin
                      abssym:=cabsolutevarsym.create(vs.realname,vs.vardef);
                      abssym.fileinfo:=vs.fileinfo;
                      abssym.abstyp:=tovar;
                      abssym.ref:=node_to_propaccesslist(pt);
                      { if the sizes are different, can't be a regvar since you }
                      { can't be "absolute upper 8 bits of a register" (except  }
                      { if its a record field of the same size of a record      }
                      { regvar, but in that case pt.resultdef.size will have    }
                      { the same size since it refers to the field and not to   }
                      { the whole record -- which is why we use pt and not hp)  }

                      { we can't take the size of an open array or an array of const }
                      if is_open_array(pt.resultdef) or
                         is_array_of_const(pt.resultdef) or
                         (vs.vardef.size <> pt.resultdef.size) then
                        make_not_regable(pt,[ra_addr_regable]);
                      tabsolutevarsym(abssym).adjust_varregable;
                    end;
                end
              else
                Message(parser_e_absolute_only_to_var_or_const);
            end;
          pt.free;
          pt := nil;
          { replace old varsym with the new absolutevarsym }
          if assigned(abssym) then
            begin
              st:=vs.owner;
              vs.owner.Deletesym(vs);
              st.insertsym(abssym);
              sc[0]:=abssym;
            end;
        end;

      var
         sc   : TFPObjectList;
         vs   : tabstractvarsym;
         hdef : tdef;
         i    : longint;
         flags : thccflags;
         first,
         isgeneric,
         semicoloneaten,
         allowdefaultvalue,
         hasdefaultvalue : boolean;
         hintsymoptions  : tsymoptions;
         deprecatedmsg   : pshortstring;
         old_block_type  : tblock_type;
         sectionname : ansistring;
         typepos,
         tmp_filepos,
         old_current_filepos     : tfileposinfo;
      begin
         old_block_type:=block_type;
         block_type:=bt_var;
         { Force an expected ID error message }
         if not (current_scanner.token in [_ID,_CASE,_END]) then
           consume(_ID);
         { read vars }
         sc:=TFPObjectList.create(false);
         first:=true;
         had_generic:=false;
         vs:=nil;
         fillchar(tmp_filepos,sizeof(tmp_filepos),0);
         while (current_scanner.token=_ID) do
           begin
             semicoloneaten:=false;
             hasdefaultvalue:=false;
             allowdefaultvalue:=true;
             sc.clear;
             repeat
               if (current_scanner.token = _ID) then
                 begin
                   isgeneric:=(vd_check_generic in options) and
                                not (m_implicit_generics in current_settings.modeswitches) and
                                (current_scanner.idtoken=_GENERIC);
                   case symtablestack.top.symtabletype of
                     localsymtable :
                       vs:=clocalvarsym.create(current_scanner.orgpattern,vs_value,generrordef,[]);
                     staticsymtable,
                     globalsymtable :
                       begin
                         vs:=cstaticvarsym.create(current_scanner.orgpattern,vs_value,generrordef,[]);
                         if vd_threadvar in options then
                           include(vs.varoptions,vo_is_thread_var);
                       end;
                     else
                       internalerror(200411064);
                   end;
                   sc.add(vs);
                   if isgeneric then
                     tmp_filepos:=current_filepos;
                 end
               else
                 isgeneric:=false;
               consume(_ID);
               { when the first variable had been read the next declaration could be
                 a "generic procedure", "generic function" or
                 "generic class (function/procedure)" }
               if not first
                   and isgeneric
                   and (sc.count=1)
                   and (current_scanner.token in [_PROCEDURE,_FUNCTION,_CLASS]) then
                 begin
                   vs.free;
                   vs := nil;
                   sc.clear;
                   had_generic:=true;
                   break;
                 end
               else
                 begin
                   vs.register_sym;
                   if isgeneric then
                     begin
                       { ensure correct error position }
                       old_current_filepos:=current_filepos;
                       current_filepos:=tmp_filepos;
                       symtablestack.top.insertsym(vs);
                       current_filepos:=old_current_filepos;
                     end
                   else
                     symtablestack.top.insertsym(vs);
                 end;
             until not try_to_consume(_COMMA);

             if had_generic then
               break;

             { read variable type def }
             block_type:=bt_var_type;
             consume(_COLON);
             typepos:=current_tokenpos;

{$ifdef gpc_mode}
             if (m_gpc in current_settings.modeswitches) and
                (token=_ID) and
                (current_scanner.orgpattern='__asmname__') then
               read_gpc_name(sc);
{$endif}

             read_anon_type(hdef,false,nil);
             maybe_guarantee_record_typesym(hdef,symtablestack.top);
             check_fam_var_type(hdef,typepos);
             for i:=0 to sc.count-1 do
               begin
                 vs:=tabstractvarsym(sc[i]);
                 vs.vardef:=hdef;
               end;
             block_type:=bt_var;

             { Process procvar directives }
             if maybe_parse_proc_directives(hdef) then
               semicoloneaten:=true;

             { check for absolute }
             if try_to_consume(_ABSOLUTE) then
               begin
                 read_absolute(sc);
                 allowdefaultvalue:=false;
               end;

             { Check for EXTERNAL etc directives before a semicolon }
             if (current_scanner.idtoken in [_EXPORT,_EXTERNAL,_PUBLIC,_CVAR]) or (current_scanner.idtoken = _WEAKEXTERNAL) then
               begin
                 read_public_and_external_sc(sc);
                 allowdefaultvalue:=false;
                 semicoloneaten:=true;
               end;

             { try to parse the hint directives }
             hintsymoptions:=[];
             deprecatedmsg:=nil;
             try_consume_hintdirective(hintsymoptions,deprecatedmsg);
             for i:=0 to sc.count-1 do
               begin
                 vs:=tabstractvarsym(sc[i]);
                 vs.symoptions := vs.symoptions + hintsymoptions;
                 if deprecatedmsg<>nil then
                   vs.deprecatedmsg:=stringdup(deprecatedmsg^);
               end;
             stringdispose(deprecatedmsg);

             { Handling of Delphi typed const = initialized vars }
             if allowdefaultvalue and
                (current_scanner.token=_EQ) and
                not(m_tp7 in current_settings.modeswitches) and
                (symtablestack.top.symtabletype<>parasymtable) then
               begin
                 { Add calling convention for procvar }
                 if (
                      (hdef.typ=procvardef) or
                      is_funcref(hdef)
                    ) and
                    (hdef.typesym=nil) then
                   begin
                     if po_is_function_ref in tprocvardef(hdef).procoptions then
                       begin
                         if not (m_function_references in current_settings.modeswitches) and
                             not (po_is_block in tprocvardef(hdef).procoptions) then
                           messagepos(typepos,sym_e_error_in_type_def)
                         else
                           begin
                             if adjust_funcref(hdef,nil,nil) then
                               { the def was changed, so update it }
                               for i:=0 to sc.count-1 do
                                 begin
                                   vs:=tabstractvarsym(sc[i]);
                                   vs.vardef:=hdef;
                                 end;
                             if current_scanner.replay_stack_depth=0 then
                               hdef.register_def;
                           end;
                       end;
                     handle_calling_convention(hdef,hcc_default_actions_intf);
                   end;
                 read_default_value(sc);
                 hasdefaultvalue:=true;
               end
             else
               begin
                 if not(semicoloneaten) then
                   consume(_SEMICOLON);
               end;

             { Support calling convention for procvars after semicolon }
             if not(hasdefaultvalue) and
                (
                  (hdef.typ=procvardef) or
                  is_funcref(hdef)
                ) and
                (hdef.typesym=nil) then
               begin
                 { Parse procvar directives after ; }
                 maybe_parse_proc_directives(hdef);
                 if (hdef.typ=procvardef) and (po_is_function_ref in tprocvardef(hdef).procoptions) then
                   begin
                     if not (m_function_references in current_settings.modeswitches) and
                         not (po_is_block in tprocvardef(hdef).procoptions) then
                       messagepos(typepos,sym_e_error_in_type_def)
                     else
                       begin
                         if adjust_funcref(hdef,nil,nil) then
                           { the def was changed, so update it }
                           for i:=0 to sc.count-1 do
                             begin
                               vs:=tabstractvarsym(sc[i]);
                               vs.vardef:=hdef;
                             end;
                         if current_scanner.replay_stack_depth=0 then
                           hdef.register_def;
                       end;
                   end;
                 { Add calling convention for procvar }
                 if hdef.typ=procvardef then
                   flags:=hcc_default_actions_intf
                 else
                   flags:=hcc_default_actions_intf_struct;
                 handle_calling_convention(hdef,flags);
                 { Handling of Delphi typed const = initialized vars }
                 if (current_scanner.token=_EQ) and
                    not(m_tp7 in current_settings.modeswitches) and
                    (symtablestack.top.symtabletype<>parasymtable) then
                   begin
                     read_default_value(sc);
                     hasdefaultvalue:=true;
                   end;
               end;

             { Check for EXTERNAL etc directives or, in macpas, if cs_external_var is set}
             if (
                 (
                  ((current_scanner.idtoken in [_EXPORT,_EXTERNAL,_PUBLIC,_CVAR]) or (current_scanner.idtoken = _WEAKEXTERNAL)) and
                  (m_cvar_support in current_settings.modeswitches)
                 ) or
                 (
                  (m_mac in current_settings.modeswitches) and
                  (
                   (cs_external_var in current_settings.localswitches) or
                   (cs_externally_visible in current_settings.localswitches)
                  )
                 )
                ) then
               read_public_and_external_sc(sc);

             { try to parse a section directive }
             if (target_info.system in systems_allow_section) and
                (symtablestack.top.symtabletype in [staticsymtable,globalsymtable]) and
                (current_scanner.idtoken=_SECTION) then
               begin
                 try_consume_sectiondirective(sectionname);
                 if sectionname<>'' then
                   begin
                     for i:=0 to sc.count-1 do
                       begin
                         vs:=tabstractvarsym(sc[i]);
                         if (vs.varoptions *[vo_is_external,vo_is_weak_external])<>[] then
                           Message(parser_e_externals_no_section);
                         if vs.typ<>staticvarsym then
                           Message(parser_e_section_no_locals);
                         tstaticvarsym(vs).section:=sectionname;
                         include(vs.varoptions, vo_has_section);
                       end;
                   end;
               end;

             { allocate normal variable (non-external and non-typed-const) staticvarsyms }
             for i:=0 to sc.count-1 do
               begin
                 vs:=tabstractvarsym(sc[i]);
                 if (vs.typ=staticvarsym) and
                    not(vo_is_typed_const in vs.varoptions) and
                    not(vo_is_external in vs.varoptions) then
                   cnodeutils.insertbssdata(tstaticvarsym(vs));
                 if vo_is_public in vs.varoptions then
                   current_module.add_public_asmsym(vs.mangledname,AB_GLOBAL,AT_DATA);
               end;

             first:=false;
           end;
         block_type:=old_block_type;
         { free the list }
         sc.free;
         sc := nil;
      end;


    function check_allowed_for_var_or_const(def:tdef;allowdynarray:boolean):boolean;
      var
        stowner,tmpdef : tdef;
        st : tsymtable;

      { digs through a tuple's fields (recursively, arrays stripped like in
        the main loop) for a type that embeds the still-incomplete stowner;
        returns it, or nil if the tuple is safe }
      function tuple_embedded_incomplete_ref(tupledef:tdef):tdef;
        var
          i : longint;
          sym : tsym;
          fdef : tdef;
        begin
          result:=nil;
          for i:=0 to trecorddef(tupledef).symtable.symlist.count-1 do
            begin
              sym:=tsym(trecorddef(tupledef).symtable.symlist[i]);
              if sym.typ<>fieldvarsym then
                continue;
              fdef:=tfieldvarsym(sym).vardef;
              while (fdef.typ=arraydef) do
                begin
                  if allowdynarray and (ado_IsDynamicArray in tarraydef(fdef).arrayoptions) then
                    begin
                      fdef:=nil;
                      break;
                    end;
                  fdef:=tarraydef(fdef).elementdef;
                end;
              if not assigned(fdef) then
                continue;
              if (fdef.typ=recorddef) and (df_tuple in fdef.defoptions) then
                result:=tuple_embedded_incomplete_ref(fdef)
              else if (is_object(fdef) or is_record(fdef)) and
                  is_owned_by(tabstractrecorddef(stowner),tabstractrecorddef(fdef)) then
                result:=fdef;
              if assigned(result) then
                exit;
            end;
        end;

      begin
        result:=true;
        st:=symtablestack.top;
        if not (st.symtabletype in [recordsymtable,objectsymtable]) then
          exit;
        stowner:=tdef(st.defowner);
        while assigned(stowner) and (stowner.typ in [objectdef,recorddef]) do
          begin
            if def.typ=arraydef then
              begin
                tmpdef:=def;
                while (tmpdef.typ=arraydef) do
                  begin
                    { dynamic arrays are allowed in certain cases }
                    if allowdynarray and (ado_IsDynamicArray in tarraydef(tmpdef).arrayoptions) then
                      begin
                        tmpdef:=nil;
                        break;
                      end;
                    tmpdef:=tarraydef(tmpdef).elementdef;
                  end;
              end
            else
              tmpdef:=def;
            { a tuple is never the incomplete host itself, but its fields can
              embed it - dig for the offending type }
            if assigned(tmpdef) and (tmpdef.typ=recorddef) and
               (df_tuple in tmpdef.defoptions) then
              tmpdef:=tuple_embedded_incomplete_ref(tmpdef);
            if assigned(tmpdef) and
                (is_object(tmpdef) or is_record(tmpdef)) and
                is_owned_by(tabstractrecorddef(stowner),tabstractrecorddef(tmpdef)) then
              begin
                Message1(type_e_type_is_not_completly_defined,tabstractrecorddef(tmpdef).RttiName);
                result:=false;
                break;
              end;
            stowner:=tdef(stowner.owner.defowner);
          end;
      end;


    { stack of default field types established by `union of T` or
      `bitpacked record of T`. inner scope inherits from outer until a new
      `of T` is encountered (innermost wins). consulted by the C-style
      `name: N` / `pad N` bitfield syntax. }
    var
      composable_default_type_stack: tfplist;

    function current_composable_default_type: tdef;
      begin
        if assigned(composable_default_type_stack) and
           (composable_default_type_stack.count>0) then
          result:=tdef(composable_default_type_stack[composable_default_type_stack.count-1])
        else
          result:=nil;
      end;

    procedure push_composable_default_type(def: tdef);
      begin
        if not assigned(composable_default_type_stack) then
          composable_default_type_stack:=tfplist.create;
        composable_default_type_stack.add(def);
      end;

    procedure pop_composable_default_type;
      begin
        if assigned(composable_default_type_stack) and
           (composable_default_type_stack.count>0) then
          composable_default_type_stack.delete(composable_default_type_stack.count-1);
      end;

    { walk a record def's symtable + its own composition chain, collecting
      every user-facing field name into `names`. internal carriers
      ($compose$N) are descended through, not added. used to detect
      collisions when registering a new composition. }
    procedure collect_flattened_field_names(def: tabstractrecorddef; names: tfphashlist);
      var
        i: integer;
        sym: tsym;
        fv: tfieldvarsym;
      begin
        if not assigned(def) then exit;
        for i:=0 to def.symtable.symlist.count-1 do
          begin
            sym:=tsym(def.symtable.symlist[i]);
            if sym.typ<>fieldvarsym then continue;
            fv:=tfieldvarsym(sym);
            if copy(sym.realname,1,9)='$compose$' then
              begin
                if fv.vardef.typ in [recorddef,objectdef] then
                  collect_flattened_field_names(tabstractrecorddef(fv.vardef),names);
              end
            else
              if names.find(sym.name)=nil then
                names.add(sym.name,sym);
          end;
      end;

    { check whether any flattened field name from `target_def` collides with
      the already-present user-facing name space of `recst`. returns the
      first colliding name, '' if none. }
    function find_composition_collision(recst: tabstractrecordsymtable;
                                        target_def: tdef): string;
      var
        outer_names, target_names: tfphashlist;
        i: integer;
        nm: shortstring;
      begin
        result:='';
        if not (target_def.typ in [recorddef,objectdef]) then exit;
        outer_names:=tfphashlist.create;
        target_names:=tfphashlist.create;
        try
          collect_flattened_field_names(tabstractrecorddef(recst.defowner),outer_names);
          collect_flattened_field_names(tabstractrecorddef(target_def),target_names);
          for i:=0 to target_names.count-1 do
            begin
              nm:=target_names.nameofindex(i);
              if outer_names.find(nm)<>nil then
                exit(nm);
            end;
        finally
          outer_names.free;
          target_names.free;
        end;
      end;

    { collect ONLY the composition-flattened field names of `def` (the names
      brought in via $compose$N carriers). direct user fields are skipped.
      symmetric counterpart of `collect_flattened_field_names` used when the
      check goes the other way: a new direct field / union variant being
      added to `def` needs to make sure it does not shadow a name already
      reachable through a previously declared embed / inline anonymous
      record. }
    procedure collect_composition_flat_names(def: tabstractrecorddef; names: tfphashlist);
      var
        i: integer;
        uce: pcomposition_entry;
      begin
        if not assigned(def) then exit;
        for i:=0 to def.composition_count-1 do
          begin
            uce:=def.composition_at(i);
            if not assigned(uce) or not assigned(uce^.carrier) then continue;
            if tfieldvarsym(uce^.carrier).vardef.typ in [recorddef,objectdef] then
              collect_flattened_field_names(
                tabstractrecorddef(tfieldvarsym(uce^.carrier).vardef),names);
          end;
      end;

    { check whether `fname` collides with any composition-flattened name
      already reachable on `recst`. on collision, emits
      parser_e_composition_duplicate_id and returns true. mirror of the
      collision pass `add_composition_carrier` already runs in the other
      direction; this one covers fields and union variants added AFTER an
      embed. }
    function field_collides_with_compositions(recst: tabstractrecordsymtable;
                                              const fname: TIDString): boolean;
      var
        composed_names: tfphashlist;
      begin
        result:=false;
        if tabstractrecorddef(recst.defowner).composition_count=0 then exit;
        composed_names:=tfphashlist.create;
        try
          collect_composition_flat_names(
            tabstractrecorddef(recst.defowner),composed_names);
          result:=composed_names.find(fname)<>nil;
          if result then
            Message1(parser_e_composition_duplicate_id,fname);
        finally
          composed_names.free;
        end;
      end;

    { create a hidden carrier field for record composition (anonymous embed or
      inline anonymous record). storage lives on the carrier; lookup-time
      resolution flattens its members into the surrounding record's name space
      via the composition link recorded on the parent record def. carrier name
      is auto-generated as $compose$N (N = sym count in recst) so it never
      collides with user identifiers.

      duplicate detection: every field name brought in by the new composition
      (recursively through its own embeds) is checked against the surrounding
      record's already-visible flat name space. a hit raises
      parser_e_composition_duplicate_id and skips registration. }
    function add_composition_carrier(recst: tabstractrecordsymtable;
                                     target_def: tdef;
                                     vis: tvisibility;
                                     kind: tcomposition_kind): tfieldvarsym;
      var
        collision: string;
      begin
        result:=nil;
        collision:=find_composition_collision(recst,target_def);
        if collision<>'' then
          begin
            Message1(parser_e_composition_duplicate_id,collision);
            exit;
          end;
        { target_def.unique_id_str gives a module-wide unique number,
          so two carriers under the same outer record (one direct, one
          through a union variant merged into the parent symtable) do
          not collide on `$compose$N` even though their local symtables
          number from zero independently }
        result:=cfieldvarsym.create('$compose$'+target_def.unique_id_str,vs_value,target_def,[]);
        result.visibility:=vis;
        result.register_sym;
        recst.insertsym(result);
        recst.addfield(result,vis);
        tabstractrecorddef(recst.defowner).add_composition(result,kind);
      end;


    { parse one `union ... end;` block in modern composable records syntax.
      caller already consumed the `union` keyword; we own the body up to and
      including the closing `end` (and any trailing `;`). variants overlay
      from the same offset, identical layout to legacy `case` of variant
      records but with no tag selector. }
    { walk a (possibly nested) union member symtable and create the
      static access members in recst. direct fields become sp_static
      fieldvarsyms whose absolutevarsym alias subscripts the blob;
      `$compose$` carriers (inline anon records / embeds inside a
      variant) recurse with the carrier appended to the subscript
      chain, replicating the instance-path name flattening. }
    procedure add_static_union_members(recst: tabstractrecordsymtable; blob: tstaticvarsym; carrier_path: tfpobjectlist; st: trecordsymtable);
      var
        i, j : longint;
        msym, fv : tfieldvarsym;
        sl : tpropaccesslist;
      begin
        for i:=0 to st.SymList.Count-1 do
          begin
            if tsym(st.SymList[i]).typ<>fieldvarsym then
              begin
                { anonymous enum constants / type defs would need a scope
                  move out of the union symtable, which must stay intact
                  as the blob's type - not supported in static storage }
                if tsym(st.SymList[i]).typ in [enumsym,typesym,constsym] then
                  Message1(parser_e_composition_in_class_var,'anonymous enum');
                continue;
              end;
            msym:=tfieldvarsym(st.SymList[i]);
            if (copy(msym.realname,1,9)='$compose$') and
               (msym.vardef.typ=recorddef) then
              begin
                carrier_path.add(msym);
                add_static_union_members(recst,blob,carrier_path,trecordsymtable(trecorddef(msym.vardef).symtable));
                carrier_path.delete(carrier_path.count-1);
                continue;
              end;
            if tabstractrecorddef(recst.defowner).composition_count>0 then
              field_collides_with_compositions(recst,msym.name);
            fv:=cfieldvarsym.create(msym.realname,vs_value,msym.vardef,[]);
            include(fv.symoptions,sp_static);
            fv.visibility:=recst.currentvisibility;
            recst.insertsym(fv);
            sl:=tpropaccesslist.create;
            sl.addsym(sl_load,blob);
            for j:=0 to carrier_path.count-1 do
              sl.addsym(sl_subscript,tfieldvarsym(carrier_path[j]));
            sl.addsym(sl_subscript,msym);
            recst.insertsym(cabsolutevarsym.create_ref('$'+lower(generate_nested_name(recst,'_'))+'_'+fv.name,fv.vardef,sl));
          end;
      end;


    procedure parse_modern_union(recst: tabstractrecordsymtable;
                                 target_size: asizeint;
                                 target_align: longword;
                                 target_bitsize: longint;
                                 target_bitalign: longint;
                                 to_static: boolean;
                                 per_thread: boolean);
      { target_size = -1 means "no explicit size", otherwise force the union
        to occupy exactly that many bytes (assert + pad). target_align = 0
        means "no explicit alignment", otherwise force the union's record
        alignment to that value. target_bitsize = -1 means "no explicit bit
        constraint", otherwise assert max(variant bit size) <= N and pad
        union storage to ceil(N/8) bytes. target_bitalign = 0 means "no
        explicit bit alignment", otherwise behaves like `align ceil(N/8)`
        - the union is byte-overlay so any bit-level alignment value
        collapses to byte alignment, but accepting `bitalign` here keeps
        the modifier set symmetric with record pre-body modifiers.
        to_static = the union sits in a `class var` / `class threadvar`
        section: back it with one hidden static blob instead of instance
        layout. per_thread additionally marks the blob as a thread var. }
      var
        unionsymtable : trecordsymtable;
        uniondef : trecorddef;
        startvarrecsize, maxsize, max_bit_size : asizeint;
        startvarrecalign, startpadalign,
        maxalignment, maxpadalign,
        usedalign : shortint;
        offset : longint;
        hadgendummy : boolean;
        dummyattrelementcount : integer;
        i : longint;
        uce : pcomposition_entry;
        carrier : tfieldvarsym;
        blob : tstaticvarsym;
        carrier_path : tfpobjectlist;
      begin
        unionsymtable:=trecordsymtable.create('',current_settings.packrecords,current_settings.alignment.recordalignmin);
        uniondef:=crecorddef.create('',unionsymtable);
        uniondef.isunion:=true;

        startvarrecsize:=unionsymtable.datasize;
        startvarrecalign:=unionsymtable.fieldalignment;
        startpadalign:=unionsymtable.padalignment;

        maxsize:=0;
        maxalignment:=0;
        maxpadalign:=0;
        max_bit_size:=0;

        symtablestack.push(unionsymtable);
        inc(variantrecordlevel);
        try
          while current_scanner.token<>_END do
            begin
              read_record_fields([vd_record,vd_one_variant],nil,nil,hadgendummy,dummyattrelementcount);

              { variant boundary: track max layout, then reset for next overlay.
                for bit_size, use the actual bit usage of any bit-packed sub-
                record carrier this variant produced - byte-rounded
                unionsymtable.current_bit_offset would over-report when the
                inner record's payload is sub-byte. }
              if unionsymtable.datasize>maxsize then maxsize:=unionsymtable.datasize;
              i:=unionsymtable.current_bit_offset;
              { peek the most recently added field; if it's an inline
                bitpacked record carrier, use its precise databitsize so
                a 20-bit payload doesn't get over-reported as 24 due to
                byte-boundary padding on the inner record }
              if (unionsymtable.symlist.count>0) and
                 (tsym(unionsymtable.symlist[unionsymtable.symlist.count-1]).typ=fieldvarsym) and
                 (tfieldvarsym(unionsymtable.symlist[unionsymtable.symlist.count-1]).vardef.typ=recorddef) and
                 trecorddef(tfieldvarsym(unionsymtable.symlist[unionsymtable.symlist.count-1]).vardef).is_packed then
                i:=trecordsymtable(trecorddef(tfieldvarsym(unionsymtable.symlist[unionsymtable.symlist.count-1]).vardef).symtable).current_bit_offset;
              if i>max_bit_size then max_bit_size:=i;
              if unionsymtable.fieldalignment>maxalignment then maxalignment:=unionsymtable.fieldalignment;
              if unionsymtable.padalignment>maxpadalign then maxpadalign:=unionsymtable.padalignment;
              unionsymtable.datasize:=startvarrecsize;
              unionsymtable.fieldalignment:=startvarrecalign;
              unionsymtable.padalignment:=startpadalign;
            end;
        finally
          dec(variantrecordlevel);
          symtablestack.pop(unionsymtable);
        end;

        consume(_END);

        { explicit `union bitsize N`: assert variants fit in N bits; if
          they do, the union's byte storage is forced to ceil(N/8) }
        if target_bitsize>=0 then
          begin
            if max_bit_size>target_bitsize then
              Message2(parser_e_union_exceeds_bitsize,tostr(max_bit_size),tostr(target_bitsize));
            maxsize:=(target_bitsize+7) div 8;
          end;

        { explicit `union size N`: variants must fit in N, else error;
          when they do, pad the union to exactly N bytes (similar to how
          field-level `size N` widens a field's slot) }
        if target_size>=0 then
          begin
            if maxsize>target_size then
              Message2(parser_e_union_exceeds_size,tostr(maxsize),tostr(target_size));
            maxsize:=target_size;
          end;
        unionsymtable.datasize:=maxsize;
        unionsymtable.fieldalignment:=maxalignment;
        unionsymtable.addalignmentpadding;

        { explicit `union align N`: bump the union's record-level alignment
          up to N. propagates to parent record via the recordalignment
          comparison below. `bitalign N` collapses to ceil(N/8) byte
          alignment because the union is byte-overlay (bit-level
          alignment within a byte-overlay container has no meaning). }
        if target_bitalign>0 then
          begin
            i:=(target_bitalign+7) div 8;
            if longword(i)>target_align then
              target_align:=longword(i);
          end;
        if target_align>0 then
          begin
            { recordalignment / explicitrecordalignment are shortint -
              cap composable records-driven alignments that overflow
              the stock infrastructure's range }
            if target_align>high(shortint) then
              begin
                unionsymtable.recordalignment:=high(shortint);
                unionsymtable.explicitrecordalignment:=high(shortint);
              end
            else
              begin
                if shortint(target_align)>unionsymtable.recordalignment then
                  unionsymtable.recordalignment:=shortint(target_align);
                if shortint(target_align)>unionsymtable.explicitrecordalignment then
                  unionsymtable.explicitrecordalignment:=shortint(target_align);
              end;
          end;

        { `class var` / `class threadvar` union: one hidden static blob of
          the union's record type backs all variants, and every variant
          field becomes a static member whose access alias points at its
          slot in the blob (same absolutevarsym redirect that
          make_field_static builds, only sharing one storage). instance
          layout of the surrounding record stays untouched. }
        if to_static then
          begin
            { the union def stays alive as the blob's type; it has no
              generic linkage of its own, so mark it internal or the
              specialization walk trips over it }
            include(uniondef.defoptions,df_internal);
            carrier:=cfieldvarsym.create('$union$'+uniondef.unique_id_str,vs_value,uniondef,[]);
            include(carrier.symoptions,sp_internal);
            include(carrier.symoptions,sp_static);
            recst.insertsym(carrier);
            blob:=make_field_static(recst,carrier);
            if per_thread then
              include(blob.varoptions,vo_is_thread_var);
            if not parse_generic then
              cnodeutils.insertbssdata(blob);
            carrier_path:=tfpobjectlist.create(false);
            try
              add_static_union_members(recst,blob,carrier_path,unionsymtable);
            finally
              carrier_path.free;
            end;
            { register variant compositions on the surrounding record: the
              generic specialization replay maps inline anon defs to their
              generic counterparts by composition position, so the outer
              def must carry them here as well. name lookup is unaffected -
              the static members created above shadow the flatten names. }
            for i:=0 to uniondef.composition_count-1 do
              begin
                uce:=uniondef.composition_at(i);
                tabstractrecorddef(recst.defowner).add_composition(uce^.carrier,uce^.kind);
              end;
            exit;
          end;

        if target_align>0 then
          { explicit `union align N` bypasses the recordalignmax clamp -
            user asked for N, give them N (capped at shortint range for
            the usedalign locale that drives field placement) }
          if target_align>high(shortint) then
            usedalign:=high(shortint)
          else
            usedalign:=shortint(target_align)
        else
          case recst.usefieldalignment of
            0,
            C_alignment:
              usedalign:=used_align(unionsymtable.recordalignment,current_settings.alignment.recordalignmin,current_settings.alignment.maxCrecordalign);
            bit_alignment:
              usedalign:=1;
            mac68k_alignment:
              usedalign:=2;
            else
              usedalign:=used_align(recst.fieldalignment,current_settings.alignment.recordalignmin,current_settings.alignment.recordalignmax);
          end;
        offset:=align(recst.datasize,usedalign);
        recst.datasize:=offset+unionsymtable.datasize;

        { with a positive packrecords value fieldalignment is the packing
          cap for later fields, not a running max - widening it to the
          union's natural alignment would over-align every union that
          follows (a packed record with several u64 unions would place
          them at 8-byte offsets instead of back to back) }
        if (recst.usefieldalignment<=0) and
           (unionsymtable.recordalignment>recst.fieldalignment) then
          recst.fieldalignment:=unionsymtable.recordalignment;
        if unionsymtable.explicitrecordalignment>recst.explicitrecordalignment then
          recst.explicitrecordalignment:=unionsymtable.explicitrecordalignment;
        { propagate explicit `union align N` / `union bitalign N` past
          the parent record's recordalignmax clamp - if the user asked
          for cache-line alignment on the union, the surrounding record
          must respect it too (otherwise AlignOf(outer) would silently
          drop back to the platform default) }
        if (unionsymtable.explicitrecordalignment>0) and
           (unionsymtable.explicitrecordalignment>recst.recordalignment) then
          recst.recordalignment:=unionsymtable.explicitrecordalignment;

        { variant field names are about to flatten into the surrounding
          record; catch any that shadow a previously declared composition }
        if tabstractrecorddef(recst.defowner).composition_count>0 then
          for i:=0 to unionsymtable.symlist.count-1 do
            begin
              if tsym(unionsymtable.symlist[i]).typ<>fieldvarsym then continue;
              if copy(tsym(unionsymtable.symlist[i]).realname,1,9)='$compose$' then continue;
              field_collides_with_compositions(recst,tsym(unionsymtable.symlist[i]).name);
            end;

        trecordsymtable(recst).insertunionst(unionsymtable,offset);
        { compositions added on the union def (anon embed / inline anon inside
          a variant) belong to the surrounding record since the carriers are
          now flattened into it. migrate before deletedef frees the list. }
        for i:=0 to uniondef.composition_count-1 do
          begin
            uce:=uniondef.composition_at(i);
            tabstractrecorddef(recst.defowner).add_composition(uce^.carrier,uce^.kind);
          end;
        uniondef.owner.deletedef(uniondef);
      end;


    procedure read_record_fields(options:Tvar_dec_options; reorderlist: TFPObjectList; variantdesc : ppvariantrecdesc;out had_generic:boolean; out attr_element_count : integer);
      var
         sc : TFPObjectList;
         i  : longint;
         hs,sorg : string;
         gendef,hdef,casetype : tdef;
         { maxsize contains the max. size of a variant }
         { startvarrec contains the start of the variant part of a record }
         maxsize, startvarrecsize : asizeint;
         usedalign,
         maxalignment,startvarrecalign,
         maxpadalign, startpadalign: shortint;
         pt : tnode;
         fieldvs   : tfieldvarsym;
         hstaticvs : tstaticvarsym;
         vs    : tabstractvarsym;
         srsym : tsym;
         srsymtable : TSymtable;
         visibility : tvisibility;
         recst : tabstractrecordsymtable;
         unionsymtable : trecordsymtable;
         offset : longint;
         uniondef : trecorddef;
         carrier : tfieldvarsym;
         carrier_path : tfpobjectlist;
         static_variant : boolean;
         hintsymoptions : tsymoptions;
         deprecatedmsg : pshortstring;
         hadgendummy,
         semicoloneaten,
         removeclassoption,
         primed_first_field: boolean;
         primed_first_sorg: string;
         anon_target_def: tdef;
         dummyattrelementcount : integer;
         { composablerecords per-field sizing/alignment overrides parsed off
           the post-suffix `align N` / `bitalign N` / `size N` / `bitsize N` }
         parsed_custom_align,
         parsed_custom_bitalign : longword;
         parsed_custom_size,
         parsed_custom_bitsize : longint;
         { temporaries for subrange-vs-C-style disambiguation:
           `name: N` is a bitfield, `name: N..M` is a subrange type }
         parsed_potential_low,
         parsed_potential_high : tconstexprint;
         { per-field post-suffix uniqueness flags (separate from the pre-body
           reuse pattern - per-field path runs after `maybe_parse_proc_directives`
           which already touches semicoloneaten/hadgendummy for procvar fields) }
         pf_seen_size,
         pf_seen_bitsize,
         pf_seen_align,
         pf_seen_bitalign : boolean;
         { union pre-body `bitalign N` modifier (4th flag - the other 3
           reuse pre-existing locals as seen_size/seen_bitsize/seen_align) }
         seen_bitalign : boolean;
         parsed_union_bitalign : longint;
         { tracks whether the body opened with `of <type>` and pushed a
           default type onto the composable_default_type_stack }
         pushed_default_type : boolean;
         priorfields, k : longint;
         scidx : longint;
         is_in_sc : boolean;
         { used during generic specialisation to map the current inline
           anon record back to its origin in the generic's composition
           list, so read_anon_type can specialise the nested record }
         uce : pcomposition_entry;
{$if defined(powerpc) or defined(powerpc64)}
         tempdef: tdef;
         is_first_type: boolean;
{$endif powerpc or powerpc64}
         old_block_type: tblock_type;
         typepos : tfileposinfo;
      begin
         old_block_type:=block_type;
         block_type:=bt_var;
         recst:=tabstractrecordsymtable(symtablestack.top);
{$if defined(powerpc) or defined(powerpc64)}
         is_first_type:=true;
{$endif powerpc or powerpc64}
         { composablerecords: `bitpacked record of T` opens a scope with
           T as the default type for the C-style `name: N` and `pad N`
           bitfield syntax below. plain `record of T` is rejected. }
         pushed_default_type:=false;
         if (vd_record in options) and
            (m_composable_records in current_settings.modeswitches) and
            (current_scanner.token=_OF) then
           begin
             if recst.usefieldalignment<>bit_alignment then
               begin
                 Message(parser_e_record_of_requires_bitpacked);
                 consume(_OF);
                 if current_scanner.token=_ID then
                   consume(_ID);
               end
             else
               begin
                 consume(_OF);
                 if current_scanner.token=_ID then
                   begin
                     searchsym_type(current_scanner.pattern,srsym,srsymtable);
                     if assigned(srsym) and (srsym.typ=typesym) then
                       begin
                         push_composable_default_type(ttypesym(srsym).typedef);
                         pushed_default_type:=true;
                         consume(_ID);
                       end
                     else
                       begin
                         Message1(sym_e_id_no_member,current_scanner.orgpattern);
                         consume(_ID);
                       end;
                   end
                 else
                   consume(_ID);
               end;
           end;
         try
         { Force an expected ID error message }
         if not (current_scanner.token in [_ID,_CASE,_END]) and
            not((vd_record in options) and
                (m_composable_records in current_settings.modeswitches) and
                (current_scanner.token in [_RECORD,_PACKED,_BITPACKED])) and
            (composable_pre_consumed_field_name='') then
           consume(_ID);
         { read vars }
         sc:=TFPObjectList.create(false);
         removeclassoption:=false;
         had_generic:=false;
         attr_element_count:=0;
         while ((current_scanner.token=_ID) or
                ((vd_record in options) and
                 (m_composable_records in current_settings.modeswitches) and
                 (current_scanner.token in [_RECORD,_PACKED,_BITPACKED])) or
                { pre-body modifier parser fed us a first field name whose id
                  was already consumed - kick the loop even though the current
                  token is `:` / `,` / `;` rather than _ID }
                (composable_pre_consumed_field_name<>'')) and
            not(((vd_object in options) or
                 ((vd_record in options) and (m_advanced_records in current_settings.modeswitches))) and
                ((current_scanner.idtoken in [_PUBLIC,_PRIVATE,_PUBLISHED,_PROTECTED,_STRICT]) or
                 ((m_final_fields in current_settings.modeswitches) and
                  (current_scanner.idtoken=_FINAL)))) do
           begin
             { a flexible array member must be the last field of the record;
               the record itself is asked so the rule holds across field
               groups (visibility sections, methods, `class var` sections).
               static fields do not take part in the layout }
             if not (vd_class in options) and
                record_has_flexible_array_field(tdef(recst.defowner)) then
               Message(parser_e_fam_must_be_last_field);
             { inline anonymous record `record fields end;` solo (optionally
               prefixed with `packed` / `bitpacked`): parse an unnamed record
               def and embed via composition carrier }
             if (vd_record in options) and
                (m_composable_records in current_settings.modeswitches) and
                (current_scanner.token in [_RECORD,_PACKED,_BITPACKED]) then
               begin
                 { instance layout construct - meaningless as static storage }
                 if vd_class in options then
                   Message1(parser_e_composition_in_class_var,'record');
                 { during generic specialisation the inline anon record
                   needs a genericdef hint so its nested record_dec runs
                   in specialisation mode (matching what the regular
                   field-decl path computes via field-name lookup). use
                   the position-based mapping: the k-th composition we
                   are about to add corresponds to the k-th composition
                   in the generic's def, so feed that carrier's vardef
                   as the hint }
                 gendef:=nil;
                 if (current_structdef<>nil) and
                    (df_specialization in current_structdef.defoptions) and
                    (current_structdef.genericdef<>nil) and
                    (current_structdef.genericdef.typ in [recorddef,objectdef]) then
                   begin
                     k:=tabstractrecorddef(recst.defowner).composition_count;
                     if k<tabstractrecorddef(current_structdef.genericdef).composition_count then
                       begin
                         uce:=tabstractrecorddef(current_structdef.genericdef).composition_at(k);
                         if assigned(uce) and assigned(uce^.carrier) then
                           gendef:=tfieldvarsym(uce^.carrier).vardef;
                       end;
                   end;
                 read_anon_type(anon_target_def,false,tstoreddef(gendef));
                 add_composition_carrier(recst,anon_target_def,symtablestack.top.currentvisibility,ck_inline_record);
                 if current_scanner.token=_SEMICOLON then
                   consume(_SEMICOLON);
                 if vd_one_variant in options then
                   break
                 else
                   continue;
               end;
             { contextual `union` keyword (composablerecords): treat as the
               start of a memory-overlap block ONLY if the next token is not
               `:` or `,`. preserves backward compat for records that use
               `union` as a field name (e.g. jwawinuser.pas: `union: record`). }
             primed_first_field:=false;
             primed_first_sorg:='';
             { pre-body modifier parsers (record_dec, union pre-body loop) hand
               off here when a SIZE/BITSIZE/ALIGN/BITALIGN id turned out to be
               a field name. inject it as the first field and clear the bridge. }
             if composable_pre_consumed_field_name<>'' then
               begin
                 primed_first_field:=true;
                 primed_first_sorg:=composable_pre_consumed_field_name;
                 composable_pre_consumed_field_name:='';
               end
             else
             if ((vd_record in options) or (vd_object in options)) and
                (m_composable_records in current_settings.modeswitches) and
                (current_scanner.pattern='UNION') then
               begin
                 sorg:=current_scanner.orgpattern;
                 consume(_ID);
                 if current_scanner.token in [_COLON,_COMMA] then
                   begin
                     { it was a field name -- seed the field collection and
                       fall through to the regular field-decl path }
                     primed_first_field:=true;
                     primed_first_sorg:=sorg;
                   end
                 else
                   begin
                     { unions define raw record layout - no support in
                       class/object layout }
                     if vd_object in options then
                       Message1(parser_e_composition_only_in_records,'union');
                     { modifiers after `union` keyword:
                       - `of TYPE`: anchor; size := sizeof(TYPE),
                         align := AlignOf(TYPE). these become defaults that
                         can still be overridden by an explicit `size` or
                         `align` on the same line.
                       - `size <constexpr>`: forces union to N bytes
                         (assert + pad).
                       - `bitsize <constexpr>`: forces union to ceil(N/8)
                         bytes (bit-precise variant assertion).
                       - `align <constexpr>`: forces record alignment.
                       - `bitalign <constexpr>`: same as `align ceil(N/8)`
                         (kept for symmetry with record pre-body).
                       any order, each at most once, of-first, size/bitsize
                       mutex, align/bitalign mutex. }
                     parsed_custom_size:=-1;
                     parsed_custom_align:=0;
                     parsed_custom_bitsize:=-1;
                     parsed_union_bitalign:=0;
                     anon_target_def:=nil;
                     { strict modifier ordering for union:
                       1. `of T` first if present
                       2. `size N` XOR `bitsize N`
                       3. `align N` XOR `bitalign N`
                       4. each modifier at most once
                       5. `of T` after another modifier = error }
                     if current_scanner.token=_OF then
                       begin
                         consume(_OF);
                         if current_scanner.token=_ID then
                           begin
                             searchsym_type(current_scanner.pattern,srsym,srsymtable);
                             if assigned(srsym) and (srsym.typ=typesym) then
                               begin
                                 parsed_custom_size:=ttypesym(srsym).typedef.size;
                                 parsed_custom_align:=ttypesym(srsym).typedef.alignment;
                                 anon_target_def:=ttypesym(srsym).typedef;
                                 consume(_ID);
                               end
                             else
                               begin
                                 Message1(sym_e_id_no_member,current_scanner.orgpattern);
                                 consume(_ID);
                               end;
                           end
                         else
                           consume(_ID);
                       end;
                     primed_first_field:=false; { = seen_size  }
                     hadgendummy:=false;        { = seen_bitsize }
                     semicoloneaten:=false;     { = seen_align }
                     seen_bitalign:=false;
                     while current_scanner.token=_ID do
                       begin
                         { same lookahead as record_dec pre-body: an id matching
                           a modifier name might actually be the first variant's
                           field name (`union size: integer; end;`). save it,
                           consume, peek next token, hand off as pre-consumed if
                           the next token is `:` / `,` / `;` - bail out before
                           the mutex / dup checks (which apply to real modifiers
                           only, not to field names). }
                         sorg:=current_scanner.orgpattern;
                         if current_scanner.pattern='SIZE' then
                           begin
                             consume(_ID);
                             if current_scanner.token in [_COLON,_COMMA,_SEMICOLON] then
                               begin
                                 composable_pre_consumed_field_name:=sorg;
                                 break;
                               end;
                             if primed_first_field then
                               Message1(parser_e_duplicate_modifier,'size');
                             if hadgendummy then
                               Message(parser_e_size_bitsize_exclusive);
                             primed_first_field:=true;
                             parsed_custom_size:=get_intconst.svalue;
                             if parsed_custom_size<0 then
                               begin
                                 Message(parser_e_illegal_expression);
                                 parsed_custom_size:=-1;
                               end;
                           end
                         else if current_scanner.pattern='BITSIZE' then
                           begin
                             consume(_ID);
                             if current_scanner.token in [_COLON,_COMMA,_SEMICOLON] then
                               begin
                                 composable_pre_consumed_field_name:=sorg;
                                 break;
                               end;
                             if hadgendummy then
                               Message1(parser_e_duplicate_modifier,'bitsize');
                             if primed_first_field then
                               Message(parser_e_size_bitsize_exclusive);
                             hadgendummy:=true;
                             parsed_custom_bitsize:=get_intconst.svalue;
                             parsed_custom_size:=-1;
                             if parsed_custom_bitsize<1 then
                               begin
                                 Message(parser_e_illegal_expression);
                                 parsed_custom_bitsize:=-1;
                               end;
                           end
                         else if current_scanner.pattern='ALIGN' then
                           begin
                             consume(_ID);
                             if current_scanner.token in [_COLON,_COMMA,_SEMICOLON] then
                               begin
                                 composable_pre_consumed_field_name:=sorg;
                                 break;
                               end;
                             if semicoloneaten then
                               Message1(parser_e_duplicate_modifier,'align');
                             if seen_bitalign then
                               Message(parser_e_align_bitalign_exclusive);
                             semicoloneaten:=true;
                             parsed_custom_align:=get_intconst.svalue;
                             if (parsed_custom_align<1) or
                                ((parsed_custom_align and (parsed_custom_align-1))<>0) then
                               begin
                                 Message(parser_e_illegal_expression);
                                 parsed_custom_align:=0;
                               end;
                           end
                         else if current_scanner.pattern='BITALIGN' then
                           begin
                             consume(_ID);
                             if current_scanner.token in [_COLON,_COMMA,_SEMICOLON] then
                               begin
                                 composable_pre_consumed_field_name:=sorg;
                                 break;
                               end;
                             if seen_bitalign then
                               Message1(parser_e_duplicate_modifier,'bitalign');
                             if semicoloneaten then
                               Message(parser_e_align_bitalign_exclusive);
                             seen_bitalign:=true;
                             parsed_union_bitalign:=get_intconst.svalue;
                             if parsed_union_bitalign<1 then
                               begin
                                 Message(parser_e_illegal_expression);
                                 parsed_union_bitalign:=0;
                               end;
                           end
                         else
                           break;
                       end;
                     if current_scanner.token=_OF then
                       begin
                         Message(parser_e_of_must_be_first);
                         consume(_OF);
                         if current_scanner.token=_ID then
                           consume(_ID);
                       end;
                     primed_first_field:=false;
                     hadgendummy:=false;
                     semicoloneaten:=false;
                     seen_bitalign:=false;
                     { propagate `union of T` default type to variant bodies }
                     if assigned(anon_target_def) then
                       push_composable_default_type(anon_target_def);
                     try
                       parse_modern_union(recst,parsed_custom_size,parsed_custom_align,parsed_custom_bitsize,parsed_union_bitalign,
                         (vd_class in options) and not(vd_object in options),vd_threadvar in options);
                     finally
                       if assigned(anon_target_def) then
                         pop_composable_default_type;
                     end;
                     if current_scanner.token=_SEMICOLON then
                       consume(_SEMICOLON);
                     if vd_one_variant in options then
                       break
                     else
                       continue;
                   end;
               end;
             { contextual `embed` keyword (composablerecords): consumes a
               record/object type name followed by `;` to register an
               anonymous embed. backward compat: if the next token after
               `embed` is `:` or `,`, treat `embed` as a field name (stock
               FPC accepts records with `embed: T;` / `embed, x: T;` and
               those must keep parsing). }
             if ((vd_record in options) or (vd_object in options)) and
                (m_composable_records in current_settings.modeswitches) and
                (current_scanner.pattern='EMBED') then
               begin
                 sorg:=current_scanner.orgpattern;
                 consume(_ID);
                 if current_scanner.token in [_COLON,_COMMA] then
                   begin
                     primed_first_field:=true;
                     primed_first_sorg:=sorg;
                   end
                 else
                   begin
                     { embeds merge instance fields: no static storage
                       counterpart, and no support in class/object layout }
                     if vd_object in options then
                       Message1(parser_e_composition_only_in_records,'embed')
                     else if vd_class in options then
                       Message1(parser_e_composition_in_class_var,'embed');
                     if current_scanner.token=_ID then
                       begin
                         searchsym(upper(current_scanner.orgpattern),srsym,srsymtable);
                         if assigned(srsym) and (srsym.typ=typesym) and
                            (ttypesym(srsym).typedef.typ=recorddef) then
                           begin
                             anon_target_def:=ttypesym(srsym).typedef;
                             consume(_ID);
                             { the tail of a FAM-record cannot overlay
                               other variants }
                             if (variantrecordlevel>0) and
                                record_has_flexible_array_field(anon_target_def) then
                               Message1(parser_e_fam_record_nested,anon_target_def.typename);
                             add_composition_carrier(recst,anon_target_def,
                                                     symtablestack.top.currentvisibility,
                                                     ck_anon_embed);
                             consume(_SEMICOLON);
                             if vd_one_variant in options then
                               break
                             else
                               continue;
                           end;
                       end;
                     Message(parser_e_embed_needs_record_type);
                     { recovery: skip to the next semicolon to keep the
                       record body parsable }
                     while not (current_scanner.token in [_SEMICOLON,_END,_EOF]) do
                       consume(current_scanner.token);
                     if current_scanner.token=_SEMICOLON then
                       consume(_SEMICOLON);
                     if vd_one_variant in options then
                       break
                     else
                       continue;
                   end;
               end;
             { contextual `pad` keyword (composablerecords): anonymous
               padding bits inside a bitpacked record. `pad N` for N > 0
               reserves N bits with no accessible field; `pad 0` aligns
               the next field to the next storage-unit boundary - of
               the active default type if any, otherwise of a byte.
               backward compat: if `pad` is followed by `:` or `,` it
               is treated as a regular field name. }
             if (vd_record in options) and
                (m_composable_records in current_settings.modeswitches) and
                (recst.usefieldalignment=bit_alignment) and
                (current_scanner.pattern='PAD') then
               begin
                 sorg:=current_scanner.orgpattern;
                 consume(_ID);
                 if current_scanner.token in [_COLON,_COMMA] then
                   begin
                     primed_first_field:=true;
                     primed_first_sorg:=sorg;
                   end
                 else
                   begin
                     { pad reserves instance bits - meaningless as static storage }
                     if vd_class in options then
                       Message1(parser_e_composition_in_class_var,'pad');
                     k:=get_intconst.svalue;
                     if k<0 then
                       begin
                         Message(scanner_e_illegal_alignment_directive);
                         k:=0;
                       end;
                     if k=0 then
                       begin
                         { `pad 0` aligns to the next storage-unit
                           boundary; default type if present sets the
                           unit width, otherwise fall back to a byte }
                         if assigned(current_composable_default_type) then
                           i:=current_composable_default_type.size*8
                         else
                           i:=8;
                         if i<=0 then i:=8;
                         k:=(i-(recst.current_bit_offset mod i)) mod i;
                       end;
                     if k>0 then
                       begin
                         { carrier type for the anonymous pad slot;
                           default type when active, byte otherwise -
                           the field is strict private and only its
                           custom_bitsize is observed by codegen }
                         if assigned(current_composable_default_type) then
                           vs:=cfieldvarsym.create(
                             '$pad$'+tostr(recst.SymList.Count),
                             vs_value,current_composable_default_type,[])
                         else
                           vs:=cfieldvarsym.create(
                             '$pad$'+tostr(recst.SymList.Count),
                             vs_value,u8inttype,[]);
                         tfieldvarsym(vs).custom_bitsize:=k;
                         vs.visibility:=vis_strictprivate;
                         { compiler-generated padding, keep it out of
                           "never used" notes }
                         include(vs.symoptions,sp_internal);
                         vs.register_sym;
                         recst.insertsym(vs);
                         recst.addfield(tfieldvarsym(vs),vis_strictprivate);
                         { mark record as having field sizing overrides
                           for the PPU section }
                         include(tabstractrecorddef(recst.defowner).objectoptions,oo_has_field_sizing);
                       end;
                     if current_scanner.token=_SEMICOLON then
                       consume(_SEMICOLON);
                     if vd_one_variant in options then
                       break
                     else
                       continue;
                   end;
               end;
             visibility:=symtablestack.top.currentvisibility;
             semicoloneaten:=false;
             anon_target_def:=nil;
             sc.clear;
             repeat
               if primed_first_field then
                 begin
                   { a UNION/EMBED that turned out to be a field name was
                     already consumed by the keyword probe; seed the collection
                     without re-reading and without consuming another _ID }
                   sorg:=primed_first_sorg;
                   vs:=cfieldvarsym.create(sorg,vs_value,generrordef,[]);
                   vs.visibility:=visibility;
                   primed_first_field:=false;
                 end
               else
                 begin
                   sorg:=current_scanner.orgpattern;
                   if current_scanner.token=_ID then
                     begin
                       vs:=cfieldvarsym.create(sorg,vs_value,generrordef,[]);

                       { normally the visibility is set via addfield, but sometimes
                         we collect symbols so we can add them in a batch of
                         potentially mixed visibility, and then the individual
                         symbols need to have their visibility already set }
                       vs.visibility:=visibility;
                       if (vd_check_generic in options) and (current_scanner.idtoken=_GENERIC) then
                         had_generic:=true;
                     end
                   else
                     vs:=nil;
                   consume(_ID);
                 end;
               if assigned(vs) and
                  (
                    not had_generic or
                    not (current_scanner.token in [_PROCEDURE,_FUNCTION,_CLASS])
                  ) then
                 begin
                   vs.register_sym;
                   sc.add(vs);
                   { catch a field name that shadows something already
                     reachable through a previously declared embed /
                     inline anonymous record. vs.name is not populated
                     until insertsym registers the symbol with its hash
                     list, so probe against upper(realname) here. }
                   field_collides_with_compositions(recst,upper(vs.realname));
                   recst.insertsym(vs);
                   had_generic:=false;
                 end
               else
                 vs.free; // no nil needed
             until not try_to_consume(_COMMA);
             if m_delphi in current_settings.modeswitches then
               block_type:=bt_var_type
             else
               block_type:=old_block_type;
             if had_generic and (sc.count=0) then
               break;
             consume(_COLON);
             if attr_element_count=0 then
               attr_element_count:=sc.Count;

             typepos:=current_filepos;

             { make sure that the correct genericdef is set up, especially if
               we're dealing with anonymous type declarations }
             gendef:=nil;
             if df_specialization in current_structdef.defoptions then
               begin
                 srsymtable:=current_structdef.genericdef.getsymtable(gs_record);
                 if not assigned(srsymtable) then
                   internalerror(2024041204);
                 srsym:=tsym(srsymtable.find(tabstractvarsym(sc[0]).name));
                 if not assigned(srsym) then
                   internalerror(2024041205);
                 if srsym.typ<>fieldvarsym then
                   internalerror(2024041206);
                 gendef:=tfieldvarsym(srsym).vardef;
               end;

             { composablerecords C-style bitfield: `name: N;` where N is an
               integer literal and the surrounding scope established a
               DEFAULT_TYPE via `of T` on a bit-aligned record. translates
               to `name: T bitsize N` without invoking read_anon_type.
               disambiguation: if `..` follows the integer, this is a
               subrange type (`Low..High`), not a bitfield width - build
               the subrange manually and fall through to the normal path
               so per-field modifiers (`bitsize N` etc.) keep working. }
             parsed_custom_align:=0;
             parsed_custom_bitalign:=0;
             parsed_custom_size:=-1;
             parsed_custom_bitsize:=-1;
             if (m_composable_records in current_settings.modeswitches) and
                (current_scanner.token=_INTCONST) and
                assigned(current_composable_default_type) and
                (recst.usefieldalignment=bit_alignment) then
               begin
                 parsed_potential_low:=get_intconst;
                 if current_scanner.token=_POINTPOINT then
                   begin
                     consume(_POINTPOINT);
                     parsed_potential_high:=get_intconst;
                     hdef:=corddef.create(
                       range_to_basetype(parsed_potential_low,parsed_potential_high),
                       parsed_potential_low,parsed_potential_high,true);
                   end
                 else
                   begin
                     parsed_custom_bitsize:=parsed_potential_low.svalue;
                     if parsed_custom_bitsize<1 then
                       begin
                         Message(scanner_e_illegal_alignment_directive);
                         parsed_custom_bitsize:=1;
                       end;
                     hdef:=current_composable_default_type;
                   end;
               end
             else
               read_anon_type(hdef,false,tstoreddef(gendef));
             maybe_guarantee_record_typesym(hdef,symtablestack.top);
{$ifdef wasm}
             if is_wasm_reference_type(hdef) then
               messagepos(typepos,sym_e_wasm_ref_types_cannot_be_used_in_records);
{$endif wasm}
             { flexible array member: only one identifier per declaration,
               only as an instance field of a plain record, not in a variant
               part, not as a class/static or threadvar field }
             if is_flexible_array(hdef) then
               begin
                 if not (vd_record in options) or
                    (vd_class in options) or
                    (vd_threadvar in options) or
                    (variantrecordlevel>0) then
                   begin
                     Messagepos(typepos,parser_e_fam_outside_record);
                     hdef:=generrordef;
                   end
                 else if sc.count<>1 then
                   begin
                     Messagepos(typepos,parser_e_fam_must_be_last_field);
                     hdef:=generrordef;
                   end
                 else
                   begin
                     priorfields:=0;
                     for k:=0 to recst.SymList.count-1 do
                       begin
                         if TSymEntry(recst.SymList[k]).typ<>fieldvarsym then
                           continue;
                         is_in_sc:=false;
                         for scidx:=0 to sc.count-1 do
                           if sc[scidx]=recst.SymList[k] then
                             begin
                               is_in_sc:=true;
                               break;
                             end;
                         if not is_in_sc then
                           inc(priorfields);
                       end;
                     if priorfields=0 then
                       begin
                         Messagepos(typepos,parser_e_fam_record_needs_other_field);
                         hdef:=generrordef;
                       end
                     else
                       begin
                         { auto-infer count: pick the last ordinal sibling
                           field declared before the FAM; lets the debugger
                           pretty-print the array without a `count` clause
                           in the source. An explicit `count IDENT` below
                           overrides this default }
                         for k:=0 to recst.SymList.count-1 do
                           begin
                             srsym:=tsym(recst.SymList[k]);
                             if (srsym.typ=fieldvarsym) and (srsym<>tsym(sc[0])) and
                                is_ordinal(tfieldvarsym(srsym).vardef) and
                                (tfieldvarsym(srsym).vardef.size in [1,2,4,8]) then
                               tarraydef(hdef).flexcountfield:=srsym;
                           end;
                       end;
                   end;
                 { context-sensitive `count IDENT` clause: binds the
                   FAM to a sibling integer field that holds the runtime
                   element count; consumed in any case so the rest of
                   the field declaration parses cleanly even on error }
                 if (current_scanner.token=_ID) and (current_scanner.pattern='COUNT') then
                   begin
                     consume(_ID);
                     if current_scanner.token<>_ID then
                       consume(_ID)
                     else
                       begin
                         srsym:=tsym(recst.Find(current_scanner.pattern));
                         if (srsym=nil) or (srsym.typ<>fieldvarsym) then
                           Messagepos1(current_filepos,parser_e_fam_count_unknown,current_scanner.orgpattern)
                         else if (sc.count=1) and (srsym=tsym(sc[0])) then
                           Messagepos1(current_filepos,parser_e_fam_count_after,current_scanner.orgpattern)
                         else if not is_ordinal(tfieldvarsym(srsym).vardef) then
                           Messagepos1(current_filepos,parser_e_fam_count_not_ordinal,current_scanner.orgpattern)
                         else if is_flexible_array(hdef) then
                           tarraydef(hdef).flexcountfield:=srsym;
                         consume(_ID);
                       end;
                   end;
               end
             else if record_has_flexible_array_field(hdef) then
               begin
                 Messagepos1(typepos,parser_e_fam_record_nested,hdef.typename);
                 hdef:=generrordef;
               end;
             block_type:=bt_var;
             { allow only static fields reference to struct where they are declared }
             if not (vd_class in options) then
               begin
                 if not check_allowed_for_var_or_const(hdef,true) then
                   { for error recovery or compiler will crash later }
                   hdef:=generrordef;
               end;

             { field type is a generic param so set a flag in the struct }
             if assigned(hdef.typesym) and (sp_generic_para in hdef.typesym.symoptions) then
               include(current_structdef.defoptions,df_has_generic_fields);

             { Process procvar directives }
             if maybe_parse_proc_directives(hdef) then
               semicoloneaten:=true;

{$if defined(powerpc) or defined(powerpc64)}
             { from gcc/gcc/config/rs6000/rs6000.h:
              /* APPLE LOCAL begin Macintosh alignment 2002-1-22 ff */
              /* Return the alignment of a struct based on the Macintosh PowerPC
                 alignment rules.  In general the alignment of a struct is
                 determined by the greatest alignment of its elements.  However, the
                 PowerPC rules cause the alignment of a struct to peg at word
                 alignment except when the first field has greater than word
                 (32-bit) alignment, in which case the alignment is determined by
                 the alignment of the first field.  */
             }
             { TODO: check whether this is also for AIX }
             if (target_info.abi in [abi_powerpc_aix,abi_powerpc_darwin]) and
                is_first_type and
                (symtablestack.top.symtabletype=recordsymtable) and
                (trecordsymtable(symtablestack.top).usefieldalignment=C_alignment) then
               begin
                 tempdef:=hdef;
                 while tempdef.typ=arraydef do
                   tempdef:=tarraydef(tempdef).elementdef;
                 if tempdef.typ<>recorddef then
                   maxpadalign:=tempdef.alignment
                 else
                   maxpadalign:=trecorddef(tempdef).padalignment;

                 if (maxpadalign>4) and
                    (maxpadalign>trecordsymtable(symtablestack.top).padalignment) then
                   trecordsymtable(symtablestack.top).padalignment:=maxpadalign;
                 is_first_type:=false;
               end;
{$endif powerpc or powerpc64}

             { types that use init/final are not allowed in variant parts, but
               classes are allowed }
             if (variantrecordlevel>0) then
               if is_managed_type(hdef) then
                 Message(parser_e_cant_use_inittable_here);

             { composablerecords post-suffix sizing/alignment overrides:
                 `Field: Type [align N] [bitalign M] [size N] [bitsize M];`
               applied uniformly to every identifier in sc[]. parser only
               here; layout integration is in addfield. defaults were set
               before read_anon_type to allow the C-style `name: N` syntax
               to pre-populate parsed_custom_bitsize. same uniqueness and
               mutual-exclusion rules as the pre-body modifier set: each
               modifier at most once, `size`/`bitsize` and `align`/`bitalign`
               are exclusive pairs. }
             if m_composable_records in current_settings.modeswitches then
               begin
                 pf_seen_size:=false;
                 pf_seen_bitsize:=false;
                 pf_seen_align:=false;
                 pf_seen_bitalign:=false;
                 while (current_scanner.token=_ID) and
                       ((current_scanner.pattern='ALIGN') or
                        (current_scanner.pattern='BITALIGN') or
                        (current_scanner.pattern='SIZE') or
                        (current_scanner.pattern='BITSIZE')) do
                   begin
                     if current_scanner.pattern='ALIGN' then
                       begin
                         if pf_seen_align then
                           Message1(parser_e_duplicate_modifier,'align');
                         if pf_seen_bitalign then
                           Message(parser_e_align_bitalign_exclusive);
                         pf_seen_align:=true;
                         consume(_ID);
                         parsed_custom_align:=get_intconst.svalue;
                         if (parsed_custom_align<1) or
                            ((parsed_custom_align and (parsed_custom_align-1))<>0) then
                           begin
                             Message(scanner_e_illegal_alignment_directive);
                             parsed_custom_align:=0;
                           end;
                       end
                     else if current_scanner.pattern='BITALIGN' then
                       begin
                         if pf_seen_bitalign then
                           Message1(parser_e_duplicate_modifier,'bitalign');
                         if pf_seen_align then
                           Message(parser_e_align_bitalign_exclusive);
                         pf_seen_bitalign:=true;
                         consume(_ID);
                         parsed_custom_bitalign:=get_intconst.svalue;
                         if parsed_custom_bitalign<1 then
                           begin
                             Message(scanner_e_illegal_alignment_directive);
                             parsed_custom_bitalign:=0;
                           end;
                       end
                     else if current_scanner.pattern='SIZE' then
                       begin
                         if pf_seen_size then
                           Message1(parser_e_duplicate_modifier,'size');
                         if pf_seen_bitsize then
                           Message(parser_e_size_bitsize_exclusive);
                         pf_seen_size:=true;
                         consume(_ID);
                         parsed_custom_size:=get_intconst.svalue;
                         if parsed_custom_size<1 then
                           begin
                             Message(scanner_e_illegal_alignment_directive);
                             parsed_custom_size:=-1;
                           end;
                       end
                     else { BITSIZE }
                       begin
                         if pf_seen_bitsize then
                           Message1(parser_e_duplicate_modifier,'bitsize');
                         if pf_seen_size then
                           Message(parser_e_size_bitsize_exclusive);
                         pf_seen_bitsize:=true;
                         consume(_ID);
                         parsed_custom_bitsize:=get_intconst.svalue;
                         if parsed_custom_bitsize<1 then
                           begin
                             Message(scanner_e_illegal_alignment_directive);
                             parsed_custom_bitsize:=-1;
                           end;
                       end;
                   end;
               end;

             { try to parse the hint directives }
             hintsymoptions:=[];
             deprecatedmsg:=nil;
             try_consume_hintdirective(hintsymoptions,deprecatedmsg);

             { update variable type and hints }
             for i:=0 to sc.count-1 do
               begin
                 fieldvs:=tfieldvarsym(sc[i]);
                 fieldvs.vardef:=hdef;
                 { insert any additional hint directives }
                 fieldvs.symoptions := fieldvs.symoptions + hintsymoptions;
                 if deprecatedmsg<>nil then
                   fieldvs.deprecatedmsg:=stringdup(deprecatedmsg^);
                 { apply per-field sizing overrides }
                 if parsed_custom_align<>0 then
                   fieldvs.custom_align:=parsed_custom_align;
                 if parsed_custom_bitalign<>0 then
                   fieldvs.custom_bitalign:=parsed_custom_bitalign;
                 if parsed_custom_size<>-1 then
                   fieldvs.custom_size:=parsed_custom_size;
                 if parsed_custom_bitsize<>-1 then
                   fieldvs.custom_bitsize:=parsed_custom_bitsize;
               end;
               stringdispose(deprecatedmsg);
             { composablerecords: a `bitsize N` or `bitalign N` field forces
               the containing record into bit-packed alignment so the bit-level
               offsets are computed correctly. switching happens lazily on the
               first such field. }
             if (parsed_custom_bitsize<>-1) or (parsed_custom_bitalign<>0) then
               recst.usefieldalignment:=bit_alignment;
             { composablerecords: any per-field override sets the marker flag
               on the parent record def so ppu read/write know to (de)serialise
               the per-field sizing list }
             if (parsed_custom_align<>0) or (parsed_custom_bitalign<>0) or
                (parsed_custom_size<>-1) or (parsed_custom_bitsize<>-1) then
               include(tabstractrecorddef(recst.defowner).objectoptions,oo_has_field_sizing);

             { Records and objects can't have default values }
             { for a record there doesn't need to be a ; before the END or )    }
             if not(current_scanner.token in [_END,_RKLAMMER]) and
                not(semicoloneaten) then
               consume(_SEMICOLON);

             { Parse procvar directives after ; }
             maybe_parse_proc_directives(hdef);

             { Add calling convention for procvar }
             if (
                 (hdef.typ=procvardef) or
                 is_funcref(hdef)
               ) and (hdef.typesym=nil) then
               begin
                 if (hdef.typ=procvardef) and (po_is_function_ref in tprocvardef(hdef).procoptions) then
                   begin
                     if not (m_function_references in current_settings.modeswitches) and
                         not (po_is_block in tprocvardef(hdef).procoptions) then
                       messagepos(typepos,sym_e_error_in_type_def)
                     else
                       begin
                         if adjust_funcref(hdef,nil,nil) then
                           { the def was changed, so update it }
                           for i:=0 to sc.count-1 do
                             begin
                               fieldvs:=tfieldvarsym(sc[i]);
                               fieldvs.vardef:=hdef;
                             end;
                         if current_scanner.replay_stack_depth=0 then
                           hdef.register_def;
                       end;
                   end;
                 handle_calling_convention(hdef,hcc_default_actions_intf);
               end;

             if (vd_object in options) then
               begin
                 { if it is not a class var section and token=STATIC then it is a class field too }
                 if not (vd_class in options) and try_to_consume(_STATIC) then
                   begin
                     consume(_SEMICOLON);
                     include(options,vd_class);
                     removeclassoption:=true;
                   end;
                 { Fields in Java classes/interfaces can have a separately
                   specified external name }
                 if is_java_class_or_interface(tdef(recst.defowner)) and
                    (oo_is_external in tobjectdef(recst.defowner).objectoptions) then
                   try_read_field_external_sc(sc);
               end;
             if (visibility=vis_published) and
                not(is_class(hdef)) then
               begin
                 MessagePos(tfieldvarsym(sc[0]).fileinfo,parser_e_cant_publish_that);
                 visibility:=vis_public;
               end;

             if (visibility=vis_published) and
                not(oo_can_have_published in tobjectdef(hdef).objectoptions) and
                not(m_delphi in current_settings.modeswitches) then
               begin
                 MessagePos(tfieldvarsym(sc[0]).fileinfo,parser_e_only_publishable_classes_can_be_published);
                 visibility:=vis_public;
               end;
             if vd_class in options then
               begin
                 { add static flag and staticvarsyms }
                 for i:=0 to sc.count-1 do
                   begin
                     fieldvs:=tfieldvarsym(sc[i]);
                     fieldvs.visibility:=visibility;
                     hstaticvs:=make_field_static(recst,fieldvs);
                     if vd_threadvar in options then
                       include(hstaticvs.varoptions,vo_is_thread_var);
                     if not parse_generic then
                       cnodeutils.insertbssdata(hstaticvs);
                     if vd_final in options then
                       hstaticvs.varspez:=vs_final;
                   end;
                 if removeclassoption then
                   begin
                     exclude(options,vd_class);
                     removeclassoption:=false;
                   end;
               end;
             if vd_final in options then
               begin
                 { add final flag }
                 for i:=0 to sc.count-1 do
                   begin
                     fieldvs:=tfieldvarsym(sc[i]);
                     fieldvs.varspez:=vs_final;
                   end;
               end;

             if not(vd_canreorder in options) then
               { add field(s) to the recordsymtable }
               recst.addfieldlist(sc,false)
             else
               { we may reorder the fields before adding them to the symbol
                 table }
               reorderlist.concatlistcopy(sc);

             { single-iteration mode for parsing one union variant at a time }
             if vd_one_variant in options then
               break;
           end;

         if m_delphi in current_settings.modeswitches then
           block_type:=bt_var_type
         else
           block_type:=old_block_type;
         { single-variant invocation does not consume case/union construct }
         if vd_one_variant in options then
           begin
             sc.free;
             sc:=nil;
             block_type:=old_block_type;
             exit;
           end;
         { Check for Case }
         if (vd_record in options) and
            try_to_consume(_CASE) then
           begin
              { a variant part after a flexible array member would overlay
                its tail }
              if not (vd_class in options) and
                 record_has_flexible_array_field(tdef(recst.defowner)) then
                Message(parser_e_fam_must_be_last_field);
              maxsize:=0;
              maxalignment:=0;
              maxpadalign:=0;

              UnionSymtable:=trecordsymtable.create('',current_settings.packrecords,current_settings.alignment.recordalignmin);
              UnionDef:=crecorddef.create('',unionsymtable);
              uniondef.isunion:=true;

              { a variant part in a `class var` / `class threadvar` section
                overlays one hidden static blob instead of instance layout }
              static_variant:=vd_class in options;

              { already inside a variant record? if not, setup a new variantdesc chain }
              if static_variant then
                { the blob's record type owns the variant description }
                variantdesc:=@uniondef.variantrecdesc
              else if not(assigned(variantdesc)) then
                variantdesc:=@trecorddef(trecordsymtable(recst).defowner).variantrecdesc;

              { else just concat the info to the given one }
              new(variantdesc^);
              fillchar(variantdesc^^,sizeof(tvariantrecdesc),0);

              { including a field declaration? }
              fieldvs:=nil;
              if current_scanner.token=_ID then
                begin
                  sorg:=current_scanner.orgpattern;
                  hs:=current_scanner.pattern;
                  searchsym(hs,srsym,srsymtable);
                  if not(assigned(srsym) and (srsym.typ in [typesym,unitsym])) then
                    begin
                      consume(_ID);
                      consume(_COLON);
                      fieldvs:=cfieldvarsym.create(sorg,vs_value,generrordef,[]);
                      variantdesc^^.variantselector:=fieldvs;
                      symtablestack.top.insertsym(fieldvs);
                    end;
                end;
              read_anon_type(casetype,true,nil);
              block_type:=bt_var;
              if assigned(fieldvs) then
                begin
                  fieldvs.vardef:=casetype;
                  if static_variant then
                    begin
                      { the variant selector becomes a plain class var }
                      fieldvs.visibility:=recst.currentvisibility;
                      hstaticvs:=make_field_static(recst,fieldvs);
                      if vd_threadvar in options then
                        include(hstaticvs.varoptions,vo_is_thread_var);
                      if not parse_generic then
                        cnodeutils.insertbssdata(hstaticvs);
                    end
                  else
                    recst.addfield(fieldvs,recst.currentvisibility);
                end;
              if not(is_ordinal(casetype))
{$ifndef cpu64bitaddr}
                 or is_64bitint(casetype)
{$endif cpu64bitaddr}
                 then
                Message(type_e_ordinal_expr_expected);
              consume(_OF);

              startvarrecsize:=UnionSymtable.datasize;
              { align the bitpacking to the next byte }
              UnionSymtable.datasize:=startvarrecsize;
              startvarrecalign:=UnionSymtable.fieldalignment;
              startpadalign:=Unionsymtable.padalignment;
              symtablestack.push(UnionSymtable);
              repeat
                SetLength(variantdesc^^.branches,length(variantdesc^^.branches)+1);
                fillchar(variantdesc^^.branches[high(variantdesc^^.branches)],
                  sizeof(variantdesc^^.branches[high(variantdesc^^.branches)]),0);
                repeat
                  pt:=comp_expr([ef_accept_equal]);
                  if not(pt.nodetype=ordconstn) then
                    Message(parser_e_illegal_expression);
                  inserttypeconv(pt,casetype);
                  { iso pascal does not support ranges in variant record definitions }
                  if (([m_iso,m_extpas]*current_settings.modeswitches)=[]) and try_to_consume(_POINTPOINT) then
                    pt:=crangenode.create(pt,comp_expr([ef_accept_equal]))
                  else
                    begin
                      with variantdesc^^.branches[high(variantdesc^^.branches)] do
                        begin
                          SetLength(values,length(values)+1);
                          values[high(values)]:=tordconstnode(pt).value;
                        end;
                    end;
                  pt.free;
                  pt := nil;
                  if current_scanner.token=_COMMA then
                    consume(_COMMA)
                  else
                    break;
                until false;
                if m_delphi in current_settings.modeswitches then
                  block_type:=bt_var_type
                else
                  block_type:=old_block_type;
                consume(_COLON);
                { read the vars }
                consume(_LKLAMMER);
                inc(variantrecordlevel);
                if current_scanner.token<>_RKLAMMER then
                  read_record_fields([vd_record],nil,@variantdesc^^.branches[high(variantdesc^^.branches)].nestedvariant,hadgendummy,dummyattrelementcount);
                dec(variantrecordlevel);
                consume(_RKLAMMER);

                { calculates maximal variant size }
                maxsize:=max(maxsize,unionsymtable.datasize);
                maxalignment:=max(maxalignment,unionsymtable.fieldalignment);
                maxpadalign:=max(maxpadalign,unionsymtable.padalignment);
                { the items of the next variant are overlayed }
                unionsymtable.datasize:=startvarrecsize;
                unionsymtable.fieldalignment:=startvarrecalign;
                unionsymtable.padalignment:=startpadalign;
                if (current_scanner.token<>_END) and (current_scanner.token<>_RKLAMMER) then
                  consume(_SEMICOLON)
                else
                  break;
              until (current_scanner.token=_END) or (current_scanner.token=_RKLAMMER);
              symtablestack.pop(UnionSymtable);
              { at last set the record size to that of the biggest variant }
              unionsymtable.datasize:=maxsize;
              unionsymtable.fieldalignment:=maxalignment;
              unionsymtable.addalignmentpadding;
              { `class var` / `class threadvar` variant part: one hidden
                static blob of the union's record type backs all variants,
                and every variant field becomes a static member whose
                access alias points at its slot in the blob (same
                absolutevarsym redirect that make_field_static builds,
                only sharing one storage). instance layout of the
                surrounding record stays untouched. }
              if static_variant then
                begin
                  { the union def stays alive as the blob's type; it has no
                    generic linkage of its own, so mark it internal or the
                    specialization walk trips over it }
                  include(uniondef.defoptions,df_internal);
                  carrier:=cfieldvarsym.create('$union$'+uniondef.unique_id_str,vs_value,uniondef,[]);
                  include(carrier.symoptions,sp_internal);
                  include(carrier.symoptions,sp_static);
                  recst.insertsym(carrier);
                  hstaticvs:=make_field_static(recst,carrier);
                  if vd_threadvar in options then
                    include(hstaticvs.varoptions,vo_is_thread_var);
                  if not parse_generic then
                    cnodeutils.insertbssdata(hstaticvs);
                  carrier_path:=tfpobjectlist.create(false);
                  try
                    add_static_union_members(recst,hstaticvs,carrier_path,unionsymtable);
                  finally
                    carrier_path.free;
                  end;
                  { see parse_modern_union: the outer def must carry inline
                    anon compositions for generic specialization replay }
                  for i:=0 to uniondef.composition_count-1 do
                    begin
                      uce:=uniondef.composition_at(i);
                      tabstractrecorddef(recst.defowner).add_composition(uce^.carrier,uce^.kind);
                    end;
                end
              else
                begin
{$if defined(powerpc) or defined(powerpc64)}
                  { parent inherits the alignment padding if the variant is the first "field" of the parent record/variant }
                  if (target_info.system in [system_powerpc_darwin, system_powerpc_macosclassic, system_powerpc64_darwin]) and
                     is_first_type and
                     (recst.usefieldalignment=C_alignment) and
                     (maxpadalign>recst.padalignment) then
                    recst.padalignment:=maxpadalign;
{$endif powerpc or powerpc64}
                  { Align the offset where the union symtable is added }
                  case recst.usefieldalignment of
                    { allow the unionsymtable to be aligned however it wants }
                    { (within the global min/max limits)                     }
                    0, { default }
                    C_alignment:
                      usedalign:=used_align(unionsymtable.recordalignment,current_settings.alignment.recordalignmin,current_settings.alignment.maxCrecordalign);
                    { 1 byte alignment if we are bitpacked }
                    bit_alignment:
                      usedalign:=1;
                    mac68k_alignment:
                      usedalign:=2;
                    { otherwise alignment at the packrecords alignment of the }
                    { current record                                          }
                    else
                      usedalign:=used_align(recst.fieldalignment,current_settings.alignment.recordalignmin,current_settings.alignment.recordalignmax);
                  end;
                  offset:=align(recst.datasize,usedalign);
                  recst.datasize:=offset+unionsymtable.datasize;

                  if unionsymtable.recordalignment>recst.fieldalignment then
                    recst.fieldalignment:=unionsymtable.recordalignment;

                  if unionsymtable.explicitrecordalignment>recst.explicitrecordalignment then
                    recst.explicitrecordalignment:=unionsymtable.explicitrecordalignment;

                  trecordsymtable(recst).insertunionst(Unionsymtable,offset);
                  uniondef.owner.deletedef(uniondef);
                end;
           end;
         { free the list }
         sc.free;
         sc := nil;
{$ifdef powerpc}
         is_first_type := false;
{$endif powerpc}
         block_type:=old_block_type;
         finally
           if pushed_default_type then
             pop_composable_default_type;
         end;
      end;

end.
