program SharedMemory;

uses
  Vcl.Forms,
  SharedMemoryMain in 'SharedMemoryMain.pas' {FormMain};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.

