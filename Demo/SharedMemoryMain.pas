unit SharedMemoryMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls,
  amSharedMemory;

type
  TRingBufferThread = class(TThread)
  private
    FRingBuffer: TSharedMemoryRingBuffer;
    FCounter: PInteger;
  public
    constructor Create(ARingBuffer: TSharedMemoryRingBuffer; var ACounter: Integer);

    property RingBuffer: TSharedMemoryRingBuffer read FRingBuffer;
    property Counter: PInteger read FCounter;
  end;

  TFormMain = class(TForm)
    ButtonProduce: TButton;
    ButtonConsume: TButton;
    ButtonStop: TButton;
    TimerUpdate: TTimer;
    LabelStatus: TLabel;
    procedure ButtonProduceClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure ButtonConsumeClick(Sender: TObject);
    procedure ButtonStopClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure TimerUpdateTimer(Sender: TObject);
  private
    FRingBuffer: TSharedMemoryRingBuffer;
    FRingBufferThread: TRingBufferThread;
    FCounter: integer;
  public
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}

uses
  Types;

{ TRingBufferThread }

constructor TRingBufferThread.Create(ARingBuffer: TSharedMemoryRingBuffer; var ACounter: Integer);
begin
  inherited Create(True);
  FRingBuffer := ARingBuffer;
  FCounter := @ACounter;
end;

type
  TRingBufferConsumerThread = class(TRingBufferThread)
  protected
    procedure Execute; override;
  end;

procedure TRingBufferConsumerThread.Execute;
begin
  while (not Terminated) do
  begin
    // Wait 500 mS for a buffer entry
    if (RingBuffer.WaitFor(500) = wrSignaled) then
    begin
      var Buffer: TBytes;
      if (RingBuffer.Dequeue(Buffer)) then
      begin
        Assert(Length(Buffer) = SizeOf(UInt64)*2);

        Assert(PUint64(@Buffer[0])^ = not PUint64(@Buffer[SizeOf(Uint64)])^);

        InterlockedIncrement(Counter^);
      end;
    end;
  end;
end;

procedure TFormMain.ButtonConsumeClick(Sender: TObject);
begin
  ButtonProduce.Visible := False;
  ButtonConsume.Enabled := False;
  ButtonStop.Enabled := True;

  FRingBufferThread := TRingBufferConsumerThread.Create(FRingBuffer, FCounter);
  FRingBufferThread.Start;

  TimerUpdate.Enabled := True;
end;

type
  TRingBufferProducerThread = class(TRingBufferThread)
  protected
    procedure Execute; override;
  end;

procedure TRingBufferProducerThread.Execute;
begin
  while (not Terminated) do
  begin
    var Buffer: TBytes;
    SetLength(Buffer, SizeOf(UInt64)*2);

    PUint64(@Buffer[0])^ := GetTickCount64;
    PUint64(@Buffer[SizeOf(Uint64)])^ := not PUint64(@Buffer[0])^;

    FRingBuffer.Enqueue(Buffer);

    InterlockedIncrement(Counter^);
  end;
end;

procedure TFormMain.ButtonProduceClick(Sender: TObject);
begin
  ButtonProduce.Enabled := False;
  ButtonConsume.Visible := False;
  ButtonStop.Enabled := True;

  FRingBufferThread := TRingBufferProducerThread.Create(FRingBuffer, FCounter);
  FRingBufferThread.Start;

  TimerUpdate.Enabled := True;
end;

procedure TFormMain.ButtonStopClick(Sender: TObject);
begin
  ButtonStop.Enabled := False;
  if (FRingBufferThread <> nil) then
  begin
    FRingBufferThread.Terminate;
    FRingBufferThread.WaitFor;
    FreeAndNil(FRingBufferThread);
  end;
end;

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FRingBuffer := TSharedMemoryRingBuffer.Create('Test', 1024*1024);
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  FRingBuffer.Free;
end;

procedure TFormMain.TimerUpdateTimer(Sender: TObject);
begin
  LabelStatus.Caption := Format('%.0n operations completed', [1.0 * FCounter]);
end;

end.

