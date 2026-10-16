{
    Copyright (c) 2000-2002 by Florian Klaempfl

    Code generation for add nodes on the x86-64

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
unit nx64add;

{$i fpcdefs.inc}

interface

    uses
       node,nadd,cpubase,nx86add;

    type
       tx8664addnode = class(tx86addnode)
         function use_generic_mul64bit: boolean; override;
         function use_generic_int128ops: boolean; override;
         procedure second_addordinal; override;
         procedure second_add128bit; override;
         procedure second_cmp128bit; override;
         procedure second_mul;
         procedure second_mul128;
         procedure second_mul64to128;
       end;

  implementation

    uses
      globtype,globals,verbose,
      symconst,symdef,
      aasmbase,aasmdata,
      defutil,
      cgbase,cgutils,cga,cgobj,hlcgobj,cgx86,
      tgobj;

    function tx8664addnode.use_generic_mul64bit: boolean;
    begin
      result:=false;
    end;


    function tx8664addnode.use_generic_int128ops: boolean;
    begin
      { overflow-checked mul needs the 256 bit view of the helper }
      result:=(nodetype=muln) and
        (cs_check_overflow in current_settings.localswitches);
    end;


{*****************************************************************************
                                128-bit
*****************************************************************************}

    procedure tx8664addnode.second_add128bit;
      var
        op : TOpCG;
        hregister,
        hregister2 : tregister;
        hl4 : tasmlabel;
        mboverflow,
        unsigned : boolean;
      begin
        { second_mul128 runs pass_left_right itself; entering it after the
          one below would secondpass the operand trees twice }
        if nodetype=muln then
          begin
            second_mul128;
            exit;
          end;

        pass_left_right;

        mboverflow:=false;
        unsigned:=((left.resultdef.typ=orddef) and
                   (torddef(left.resultdef).ordtype=u128bit)) or
                  ((right.resultdef.typ=orddef) and
                   (torddef(right.resultdef).ordtype=u128bit));
        case nodetype of
          addn :
            begin
              op:=OP_ADD;
              mboverflow:=true;
            end;
          subn :
            begin
              op:=OP_SUB;
              mboverflow:=true;
            end;
          xorn:
            op:=OP_XOR;
          orn:
            op:=OP_OR;
          andn:
            op:=OP_AND;
          else
            internalerror(2026071008);
        end;

        { the operand modified in place must live in a register pair }
        if (left.location.loc<>LOC_REGISTER) then
          begin
            if (right.location.loc<>LOC_REGISTER) then
              begin
                hregister:=cg.getintregister(current_asmdata.CurrAsmList,OS_64);
                hregister2:=cg.getintregister(current_asmdata.CurrAsmList,OS_64);
                cg128.a_load128_loc_reg(current_asmdata.CurrAsmList,left.location,joinreg128(hregister,hregister2));
                location_reset(left.location,LOC_REGISTER,left.location.size);
                left.location.register128.reglo:=hregister;
                left.location.register128.reghi:=hregister2;
              end
            else
              begin
                location_swap(left.location,right.location);
                toggleflag(nf_swapped);
              end;
          end;

        { subtraction is not commutative, so swap back, with the right
          operand in a register pair as well }
        if (nodetype=subn) and (nf_swapped in flags) then
          begin
            if right.location.loc<>LOC_REGISTER then
              hlcg.location_force_reg(current_asmdata.CurrAsmList,right.location,right.resultdef,right.resultdef,false);
            location_swap(left.location,right.location);
            toggleflag(nf_swapped);
          end;

        if mboverflow and needoverflowcheck then
          cg.a_reg_alloc(current_asmdata.CurrAsmList,NR_DEFAULTFLAGS);

        cg128.a_op128_loc_reg(current_asmdata.CurrAsmList,op,left.location.size,
          right.location,left.location.register128);
        if right.location.loc<>LOC_REGISTER then
          location_freetemp(current_asmdata.CurrAsmList,right.location);

        { emit overflow check }
        if mboverflow and needoverflowcheck then
          begin
            current_asmdata.getjumplabel(hl4);
            if unsigned then
              cg.a_jmp_flags(current_asmdata.CurrAsmList,F_AE,hl4)
            else
              cg.a_jmp_flags(current_asmdata.CurrAsmList,F_NO,hl4);
            cg.a_reg_dealloc(current_asmdata.CurrAsmList,NR_DEFAULTFLAGS);
            cg.a_call_name(current_asmdata.CurrAsmList,'FPC_OVERFLOW',false);
            cg.a_label(current_asmdata.CurrAsmList,hl4);
          end;

        location_copy(location,left.location);
      end;


    procedure tx8664addnode.second_mul128;
      var
        t1,t2 : tregister;
      begin
        pass_left_right;

        { both operands in register pairs }
        if not (left.location.loc in [LOC_REGISTER,LOC_CREGISTER]) then
          hlcg.location_force_reg(current_asmdata.CurrAsmList,left.location,left.resultdef,left.resultdef,true);
        if not (right.location.loc in [LOC_REGISTER,LOC_CREGISTER]) then
          hlcg.location_force_reg(current_asmdata.CurrAsmList,right.location,right.resultdef,right.resultdef,true);

        { cross products of the halves; only their low 64 bits matter }
        t1:=cg.getintregister(current_asmdata.CurrAsmList,OS_64);
        cg.a_load_reg_reg(current_asmdata.CurrAsmList,OS_64,OS_64,left.location.register128.reglo,t1);
        emit_reg_reg(A_IMUL,S_Q,right.location.register128.reghi,t1);
        t2:=cg.getintregister(current_asmdata.CurrAsmList,OS_64);
        cg.a_load_reg_reg(current_asmdata.CurrAsmList,OS_64,OS_64,left.location.register128.reghi,t2);
        emit_reg_reg(A_IMUL,S_Q,right.location.register128.reglo,t2);
        emit_reg_reg(A_ADD,S_Q,t2,t1);

        { full 64x64 product of the low halves in RDX:RAX }
        cg.getcpuregister(current_asmdata.CurrAsmList,NR_RAX);
        cg.a_load_reg_reg(current_asmdata.CurrAsmList,OS_64,OS_64,left.location.register128.reglo,NR_RAX);
        cg.getcpuregister(current_asmdata.CurrAsmList,NR_RDX);
        emit_reg(A_MUL,S_Q,right.location.register128.reglo);
        { fold the cross products into the high half }
        emit_reg_reg(A_ADD,S_Q,t1,NR_RDX);
        cg.ungetcpuregister(current_asmdata.CurrAsmList,NR_RDX);
        cg.ungetcpuregister(current_asmdata.CurrAsmList,NR_RAX);

        location_reset(location,LOC_REGISTER,def_cgsize(resultdef));
        location.register128.reglo:=cg.getintregister(current_asmdata.CurrAsmList,OS_64);
        location.register128.reghi:=cg.getintregister(current_asmdata.CurrAsmList,OS_64);
        cg.a_load_reg_reg(current_asmdata.CurrAsmList,OS_64,OS_64,NR_RAX,location.register128.reglo);
        cg.a_load_reg_reg(current_asmdata.CurrAsmList,OS_64,OS_64,NR_RDX,location.register128.reghi);
      end;


    { 64 bit * 64 bit -> 128 bit, operands prepared by try_make_mul64to128;
      one MUL/IMUL leaves the whole product in RDX:RAX }
    procedure tx8664addnode.second_mul64to128;
      var
        reg : tregister;
        ref : treference;
        use_ref : boolean;
        op : tasmop;
      begin
        pass_left_right;

        reference_reset(ref,0,[]);
        reg:=NR_NO;
        use_ref:=false;
        if left.location.loc in [LOC_REGISTER,LOC_CREGISTER] then
          reg:=left.location.register
        else if left.location.loc in [LOC_REFERENCE,LOC_CREFERENCE] then
          begin
            ref:=left.location.reference;
            use_ref:=true;
          end
        else
          begin
            reg:=cg.getintregister(current_asmdata.CurrAsmList,OS_64);
            hlcg.a_load_loc_reg(current_asmdata.CurrAsmList,left.resultdef,left.resultdef,left.location,reg);
          end;
        cg.getcpuregister(current_asmdata.CurrAsmList,NR_RAX);
        hlcg.a_load_loc_reg(current_asmdata.CurrAsmList,right.resultdef,right.resultdef,right.location,NR_RAX);
        cg.getcpuregister(current_asmdata.CurrAsmList,NR_RDX);

        if is_signed(left.resultdef) then
          op:=A_IMUL
        else
          op:=A_MUL;
        if use_ref then
          emit_ref(op,S_Q,ref)
        else
          emit_reg(op,S_Q,reg);
        cg.ungetcpuregister(current_asmdata.CurrAsmList,NR_RDX);
        cg.ungetcpuregister(current_asmdata.CurrAsmList,NR_RAX);

        location_reset(location,LOC_REGISTER,def_cgsize(resultdef));
        location.register128.reglo:=cg.getintregister(current_asmdata.CurrAsmList,OS_64);
        location.register128.reghi:=cg.getintregister(current_asmdata.CurrAsmList,OS_64);
        cg.a_load_reg_reg(current_asmdata.CurrAsmList,OS_64,OS_64,NR_RAX,location.register128.reglo);
        cg.a_load_reg_reg(current_asmdata.CurrAsmList,OS_64,OS_64,NR_RDX,location.register128.reghi);
      end;


    procedure tx8664addnode.second_cmp128bit;
      var
        truelabel,
        falselabel : tasmlabel;
        href : treference;
        unsigned : boolean;

      procedure firstjmp128bitcmp;
        var
          oldnodetype : tnodetype;
        begin
          { the jump sequence is the same as for 64 bit on i386 }
          case nodetype of
            ltn,gtn:
              begin
                cg.a_jmp_flags(current_asmdata.CurrAsmList,getresflags(unsigned),location.truelabel);
                { cheat a little bit for the negative test }
                toggleflag(nf_swapped);
                cg.a_jmp_flags(current_asmdata.CurrAsmList,getresflags(unsigned),location.falselabel);
                toggleflag(nf_swapped);
              end;
            lten,gten:
              begin
                oldnodetype:=nodetype;
                if nodetype=lten then
                  nodetype:=ltn
                else
                  nodetype:=gtn;
                cg.a_jmp_flags(current_asmdata.CurrAsmList,getresflags(unsigned),location.truelabel);
                { cheat for the negative test }
                if nodetype=ltn then
                  nodetype:=gtn
                else
                  nodetype:=ltn;
                cg.a_jmp_flags(current_asmdata.CurrAsmList,getresflags(unsigned),location.falselabel);
                nodetype:=oldnodetype;
              end;
            equaln:
              cg.a_jmp_flags(current_asmdata.CurrAsmList,F_NE,location.falselabel);
            unequaln:
              cg.a_jmp_flags(current_asmdata.CurrAsmList,F_NE,location.truelabel);
            else
              internalerror(2026071009);
          end;
        end;

      procedure secondjmp128bitcmp;
        begin
          case nodetype of
            ltn,gtn,lten,gten:
              begin
                { the comparison of the low halves is always unsigned }
                cg.a_jmp_flags(current_asmdata.CurrAsmList,getresflags(true),location.truelabel);
                cg.a_jmp_always(current_asmdata.CurrAsmList,location.falselabel);
              end;
            equaln:
              begin
                cg.a_jmp_flags(current_asmdata.CurrAsmList,F_NE,location.falselabel);
                cg.a_jmp_always(current_asmdata.CurrAsmList,location.truelabel);
              end;
            unequaln:
              begin
                cg.a_jmp_flags(current_asmdata.CurrAsmList,F_NE,location.truelabel);
                cg.a_jmp_always(current_asmdata.CurrAsmList,location.falselabel);
              end;
            else
              internalerror(2026071010);
          end;
        end;

      begin
        pass_left_right;

        unsigned:=((left.resultdef.typ=orddef) and
                   (torddef(left.resultdef).ordtype=u128bit)) or
                  ((right.resultdef.typ=orddef) and
                   (torddef(right.resultdef).ordtype=u128bit));

        { we have LOC_JUMP as result }
        current_asmdata.getjumplabel(truelabel);
        current_asmdata.getjumplabel(falselabel);
        location_reset_jump(location,truelabel,falselabel);

        { one operand must live in a register pair }
        if not (left.location.loc in [LOC_REGISTER,LOC_CREGISTER]) then
          begin
            if not (right.location.loc in [LOC_REGISTER,LOC_CREGISTER]) then
              hlcg.location_force_reg(current_asmdata.CurrAsmList,left.location,left.resultdef,left.resultdef,true)
            else
              begin
                location_swap(left.location,right.location);
                toggleflag(nf_swapped);
              end;
          end;

        case right.location.loc of
          LOC_REGISTER,
          LOC_CREGISTER :
            begin
              cg.a_reg_alloc(current_asmdata.CurrAsmList,NR_DEFAULTFLAGS);
              emit_reg_reg(A_CMP,S_Q,right.location.register128.reghi,left.location.register128.reghi);
              firstjmp128bitcmp;
              emit_reg_reg(A_CMP,S_Q,right.location.register128.reglo,left.location.register128.reglo);
              secondjmp128bitcmp;
              cg.a_reg_dealloc(current_asmdata.CurrAsmList,NR_DEFAULTFLAGS);
            end;
          LOC_CREFERENCE,
          LOC_REFERENCE :
            begin
              tcgx86(cg).make_simple_ref(current_asmdata.CurrAsmList,right.location.reference);
              href:=right.location.reference;
              inc(href.offset,8);
              cg.a_reg_alloc(current_asmdata.CurrAsmList,NR_DEFAULTFLAGS);
              emit_ref_reg(A_CMP,S_Q,href,left.location.register128.reghi);
              firstjmp128bitcmp;
              emit_ref_reg(A_CMP,S_Q,right.location.reference,left.location.register128.reglo);
              secondjmp128bitcmp;
              cg.a_reg_dealloc(current_asmdata.CurrAsmList,NR_DEFAULTFLAGS);
              location_freetemp(current_asmdata.CurrAsmList,right.location);
            end;
          else
            internalerror(2026071011);
        end;
      end;

{*****************************************************************************
                                Addordinal
*****************************************************************************}

    procedure tx8664addnode.second_addordinal;
    begin
      { 64 bit operands with a 128 bit result, see try_make_mul64to128 }
      if (nodetype=muln) and is_128bitint(resultdef) then
      begin
        second_mul64to128;
        exit;
      end;

      { filter unsigned MUL opcode, which requires special handling.
        Note that when overflow checking is off, we can use IMUL instead. }
      if (nodetype=muln) and
        needoverflowcheck and
        (not(is_signed(left.resultdef)) or
         not(is_signed(right.resultdef))) then
      begin
        second_mul;
        exit;
      end;

      inherited second_addordinal;
    end;

{*****************************************************************************
                                MUL
*****************************************************************************}

    procedure tx8664addnode.second_mul;
      var
        reg,rega,regd:Tregister;
        ref:Treference;
        use_ref:boolean;
        hl4 : tasmlabel;
        cgsize:TCgSize;
        opsize:topsize;
      begin
        reference_reset(ref,0,[]);
        reg:=NR_NO;

        cgsize:=def_cgsize(resultdef);
        opsize:=TCGSize2OpSize[cgsize];
        case cgsize of
          OS_S64,OS_64:
            begin
              rega:=NR_RAX;
              regd:=NR_RDX;
            end;
          OS_S32,OS_32:
            begin
              rega:=NR_EAX;
              regd:=NR_EDX;
            end;
          else
            internalerror(2013102703);
        end;

        pass_left_right;

        { The location.register will be filled in later (JM) }
        location_reset(location,LOC_REGISTER,def_cgsize(resultdef));
        { Mul supports registers and references, so if not register/reference,
          load the location into a register}
        use_ref:=false;
        if left.location.loc in [LOC_REGISTER,LOC_CREGISTER] then
          reg:=left.location.register
        else if left.location.loc in [LOC_REFERENCE,LOC_CREFERENCE] then
          begin
            ref:=left.location.reference;
            use_ref:=true;
          end
        else
          begin
            {LOC_CONSTANT for example.}
            reg:=cg.getintregister(current_asmdata.CurrAsmList,cgsize);
            hlcg.a_load_loc_reg(current_asmdata.CurrAsmList,left.resultdef,resultdef,left.location,reg);
          end;
        { Allocate RAX. }
        cg.getcpuregister(current_asmdata.CurrAsmList,rega);
        { Load the right value. }
        hlcg.a_load_loc_reg(current_asmdata.CurrAsmList,right.resultdef,resultdef,right.location,rega);
        { Also allocate RDX, since it is also modified by a mul (JM). }
        cg.getcpuregister(current_asmdata.CurrAsmList,regd);

        if needoverflowcheck then
          cg.a_reg_alloc(current_asmdata.CurrAsmList,NR_DEFAULTFLAGS);

        if use_ref then
          emit_ref(A_MUL,opsize,ref)
        else
          emit_reg(A_MUL,opsize,reg);
        if needoverflowcheck then
         begin
           current_asmdata.getjumplabel(hl4);
           cg.a_jmp_flags(current_asmdata.CurrAsmList,F_AE,hl4);
           cg.a_reg_dealloc(current_asmdata.CurrAsmList,NR_DEFAULTFLAGS);
           cg.a_call_name(current_asmdata.CurrAsmList,'FPC_OVERFLOW',false);
           cg.a_label(current_asmdata.CurrAsmList,hl4);
         end;
        { Free RDX,RAX }
        cg.ungetcpuregister(current_asmdata.CurrAsmList,regd);
        cg.ungetcpuregister(current_asmdata.CurrAsmList,rega);
        { Allocate a new register and store the result in RAX in it. }
        location.register:=cg.getintregister(current_asmdata.CurrAsmList,cgsize);
        emit_reg_reg(A_MOV,opsize,rega,location.register);
        location_freetemp(current_asmdata.CurrAsmList,left.location);
        location_freetemp(current_asmdata.CurrAsmList,right.location);
      end;


begin
   caddnode:=tx8664addnode;
end.
