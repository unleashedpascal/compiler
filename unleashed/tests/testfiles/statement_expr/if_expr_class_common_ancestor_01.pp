program if_expr_class_common_ancestor_01;

{$mode unleashed}

uses Classes;

type
  TBase = object
    i: integer;
  end;
  TChild1 = object(TBase) end;
  TChild2 = object(TBase) end;
  IFoo = interface ['{2b4d9f2e-1c0a-4e6b-9a41-6f8d0c3b7e11}'] end;
  IBar = interface ['{7a1e3c55-9d2b-4f60-8c7e-0b5a4d2f9e33}'] end;
  TImpl = class(TInterfacedObject, IFoo, IBar) end;

function c1: TChild1;
begin
  result.i := 42;
end;

function c2: TChild2;
begin
  result.i := 32;
end;

var
  flag: boolean;
begin
  flag := true;

  // two class types unify to their common ancestor
  var s: TStream := if flag then TStringStream.Create('') else TMemoryStream.Create;
  if not (s is TStringStream) then halt(1);
  s.Free;

  // nil against a class instance
  s := if flag then nil else TMemoryStream.Create;
  if assigned(s) then halt(2);
  s := if flag then TMemoryStream.Create else nil;
  if not assigned(s) then halt(3);
  s.Free;

  // object types
  var b: TBase := if flag then c1 else c2;
  if b.i <> 42 then halt(4);

  // interfaces
  var iu: IUnknown := if flag then TImpl.Create as IBar else TImpl.Create as IFoo;
  if not (iu is TImpl) then halt(5);
end.
