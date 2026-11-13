{ a unit loaded with -Fa that is compiled from source along with the program }
unit uw42101;

interface

var
  loaded: boolean = false;

implementation

initialization
  loaded := true;
end.
