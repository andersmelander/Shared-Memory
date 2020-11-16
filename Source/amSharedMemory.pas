{$WARN SYMBOL_PLATFORM OFF}
unit amSharedMemory;

(*
  Version: MPL 1.1/GPL 2.0/LGPL 2.1

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

  Software distributed under the License is distributed on an "AS IS" basis,
  WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
  for the specific language governing rights and limitations under the License.

  The Original Code is amSharedMemory

  The Initial Developer of the Original Code is Anders Melander.

  Portions created by the Initial Developer are Copyright (C) 2001
  the Initial Developer. All Rights Reserved.

  Contributor(s):
    -

  Alternatively, the contents of this file may be used under the terms of
  either the GNU General Public License Version 2 or later (the "GPL"), or
  the GNU Lesser General Public License Version 2.1 or later (the "LGPL"),
  in which case the provisions of the GPL or the LGPL are applicable instead
  of those above. If you wish to allow use of your version of this file only
  under the terms of either the GPL or the LGPL, and not to allow others to
  use your version of this file under the terms of the MPL, indicate your
  decision by deleting the provisions above and replace them with the notice
  and other provisions required by the GPL or the LGPL. If you do not delete
  the provisions above, a recipient may use your version of this file under
  the terms of any one of the MPL, the GPL or the LGPL.
*)

interface

uses
  SysUtils, Classes, SyncObjs;

//------------------------------------------------------------------------------
//
//      TSharedMem
//
//------------------------------------------------------------------------------
// Note: The theoretical size of a memory mapped file is a 64-bit value but since
// we need random access via a pointer we would have to limit the size to what
// can be adressed by a pointer. To work around this the API fortunately allows
// us to specify the offset, in 64-bit, of the memory area being mapped.
//------------------------------------------------------------------------------
type
  TSharedMem = class(THandleObject)
  strict private
    FName: string;
    FSize: UInt64;
    FOffset: UInt64;
    FCreated: Boolean;
    FBuffer: Pointer;
  public
    constructor Create(const AName: string; ASize: UInt64; AOffset: UInt64 = 0);
    destructor Destroy; override;

    property Name: string read FName;
    property Size: UInt64 read FSize;
    property Offset: UInt64 read FOffset;
    property Buffer: Pointer read FBuffer;

    property Created: Boolean read FCreated;
  end;


//------------------------------------------------------------------------------
//
//      TSharedMemoryRingBuffer
//
//------------------------------------------------------------------------------
// A FIFO ring buffer backed by shared memory.
// The size of the buffer is fixed but the entries can be variable sized.
// Adding an item to a full buffer will discard the oldest entries to make room
// for the new one.
//------------------------------------------------------------------------------
type
  (*
  ** Layout of shared memory:
  **
  **   QueueHeader: TQueueHeader;
  **   Data: array[...] of record
  **     ItemHeader: TQItemHeader;
  **     ItemData: array[...] of byte;
  **   end;
  **
  ** where
  **
  **   QueueHeader.HeadOffset   The offset of the first item in the ring buffer
  **                            or zero if the list is empty and has not been
  **                            initialized.
  **
  **   QueueHeader.TailOffset   The offset of the last item in the ring buffer.
  **
  **   Data[].ItemHeader.Next   The offset of the next item in the ring buffer
  **                            or zero if the item is the last in the list.
  **
  **   Data[].ItemHeader.Size   The size of ItemData.
  **
  ** All offsets are in bytes and calculated from the start of the shared memory.
  *)
  TSharedMemoryRingBuffer = class(TObject)
  strict private type
    TQueueHeader = record
      HeadOffset: NativeUInt;
      TailOffset: NativeUInt;
    end;
    PQueueHeader = ^TQueueHeader;

    TQItemHeader = record
      Next: NativeUInt;
      Size: Cardinal;
    end;
    PQItemHeader = ^TQItemHeader;

  strict private
    FSharedMem: TSharedMem;
    FMutex: TMutex;
    FSemaphore: TSemaphore;
    FQueueHeader: PQueueHeader;
    FItemCount: integer;
  strict protected
    function MakePointer(AOffset: NativeUInt): PQItemHeader;
    function FirstEntry: PQItemHeader;
    function Head: PQItemHeader;
    function Tail: PQItemHeader;
    function GetHandle: THandle;

    procedure Discard;
  public
    constructor Create(const AName: string; ASize: NativeUInt);
    destructor Destroy; override;

    // Enqueue: Adds an item to the buffer.
    // The semaphore count is automatically incremented.
    procedure Enqueue(const AData: string); overload;
    procedure Enqueue(const AData: TBytes); overload;
    procedure Enqueue(AData: pointer; ASize: Cardinal); overload;

    // Dequeue: Retrieves an item from the buffer.
    // The semaphore count must have been previously decremented either
    // via the Handle property or the WaitFor method.
    function Dequeue(var Value: string): boolean; overload;
    function Dequeue(var Value: TBytes): boolean; overload;

    // Removes all items from the buffer and resets the semaphore count to zero.
    procedure Clear;

    function WaitFor(Timeout: Cardinal): TWaitResult;
    // Semaphore handle.
    // Sempahore will be incremented when an item is added to the buffer.
    // It is the responsibility of the user to ensure that the semaphore count
    // is maintained correctly. That said the user is not required to use the
    // semaphore at all if they prefer polling the buffer instead.
    property Handle: THandle read GetHandle;

    // Level: Semaphore count at time of last Enqueue.
    // Only updated on the instance where Enqueue is called.
    property ItemCount: integer read FItemCount;
  end;

  ESharedMemoryRingBuffer = class(Exception);

//------------------------------------------------------------------------------
//------------------------------------------------------------------------------
//------------------------------------------------------------------------------

implementation

uses
  Windows;

//------------------------------------------------------------------------------
//
//      TSharedMem
//
//------------------------------------------------------------------------------
constructor TSharedMem.Create(const AName: string; ASize, AOffset: UInt64);
var
  MemoryBasicInformation: TMemoryBasicInformation;
  SecurityDescriptor: TSecurityDescriptor;
  SecurityAttributes: TSecurityAttributes;
begin
  inherited Create;

  FName := AName;
  FOffset := AOffset;

  FHandle := OpenFileMapping(FILE_MAP_WRITE, False, PChar(FName));

  if (FHandle <> 0) then
  begin

    // File already exists.

    // Get a pointer to the shared memory region
    FBuffer := MapViewOfFile(FHandle, FILE_MAP_WRITE, Int64Rec(FOffset).Hi, Int64Rec(FOffset).Lo, 0);
    if (FBuffer = nil) then
      RaiseLastOSError;

    // Determine the size of the memory region
    VirtualQuery(FBuffer, MemoryBasicInformation, SizeOf(MemoryBasicInformation));
    FSize := MemoryBasicInformation.RegionSize;

  end else
  begin

    // File does not exist - create it.

    // Use a security attribute to allow the file to be accessed by different user accounts
    Win32Check(InitializeSecurityDescriptor(@SecurityDescriptor, SECURITY_DESCRIPTOR_REVISION));

    // Add a null DACL to the security descriptor.
    Win32Check(SetSecurityDescriptorDacl(@SecurityDescriptor, True, nil, False));
    SecurityAttributes.nLength := SizeOf(SecurityAttributes);
    SecurityAttributes.lpSecurityDescriptor := @SecurityDescriptor;
    SecurityAttributes.bInheritHandle := True;

    // CreateFileMapping, when called with INVALID_HANDLE_VALUE for the handle value,
    // creates a region of shared memory.
    FSize := ASize;
    FHandle := CreateFileMapping(INVALID_HANDLE_VALUE, @SecurityAttributes, PAGE_READWRITE, Int64Rec(FSize).Hi, Int64Rec(FSize).Lo, PChar(FName));
    if (FHandle = 0) then
      RaiseLastOSError;

    // Get a pointer to the shared memory region
    FBuffer := MapViewOfFile(FHandle, FILE_MAP_WRITE, Int64Rec(FOffset).Hi, Int64Rec(FOffset).Lo, 0);
    if (FBuffer = nil) then
      RaiseLastOSError;

    FCreated := True;
  end;
end;

//------------------------------------------------------------------------------

destructor TSharedMem.Destroy;
begin
  if (FBuffer <> nil) then
    UnmapViewOfFile(FBuffer);

  inherited Destroy;
end;

//------------------------------------------------------------------------------
//
//      TSharedMemoryRingBuffer
//
//------------------------------------------------------------------------------
constructor TSharedMemoryRingBuffer.Create(const AName: string; ASize: NativeUInt);
begin
  inherited Create;

  FMutex := TMutex.Create(nil, False, AName+'Mutex');
  FMutex.Acquire;
  try

    FSharedMem := TSharedMem.Create(AName+'Mem', ASize);
    // Semaphore max count is theoretical max number of entries in buffer
    FSemaphore := TSemaphore.Create(nil, 0, (ASize-SizeOf(TQueueHeader)) div SizeOf(TQItemHeader), AName+'Sem');

    FQueueHeader := PQueueHeader(FSharedMem.Buffer);

    if (FQueueHeader.HeadOffset = 0) then
      FQueueHeader.HeadOffset := SizeOf(TQueueHeader);

  finally
    FMutex.Release;
  end;
end;

//------------------------------------------------------------------------------

destructor TSharedMemoryRingBuffer.Destroy;
begin
  FMutex.Free;
  FSemaphore.Free;
  FSharedMem.Free;

  inherited Destroy;
end;

//------------------------------------------------------------------------------

function TSharedMemoryRingBuffer.MakePointer(AOffset: NativeUInt): PQItemHeader;
begin
  Result := PQItemHeader(NativeUInt(FSharedMem.Buffer) + AOffset);
end;

//------------------------------------------------------------------------------

function TSharedMemoryRingBuffer.FirstEntry: PQItemHeader;
begin
  Result := MakePointer(SizeOf(TQueueHeader));
end;

function TSharedMemoryRingBuffer.Head: PQItemHeader;
begin
  Result := MakePointer(FQueueHeader.HeadOffset);
end;

function TSharedMemoryRingBuffer.Tail: PQItemHeader;
begin
  Result := MakePointer(FQueueHeader.TailOffset);
end;

//------------------------------------------------------------------------------

procedure TSharedMemoryRingBuffer.Clear;
begin
  FMutex.Acquire;
  try

    FQueueHeader.HeadOffset := SizeOf(TQueueHeader);
    FQueueHeader.TailOffset := 0; // Zero means queue is empty
    Head.Size := 0;

    // Reset the semaphore count to zero
    while (FSemaphore.WaitFor(0) = wrSignaled) do
      ;

  finally
    FMutex.Release;
  end;
end;

//------------------------------------------------------------------------------

procedure TSharedMemoryRingBuffer.Discard;
var
  Entry: PQItemHeader;
begin
  // Does a dequeue but discards the data - For internal use only

  if (FQueueHeader.TailOffset = 0) then
    Exit;

  Entry := Tail;

  FQueueHeader.TailOffset := Entry.Next;

  Entry.Next := 0;
  Entry.Size := 0;

  // Decrement the semaphore count
  FSemaphore.WaitFor(0); // Non-blocking Acquire to avoid dead locks
end;

//------------------------------------------------------------------------------

function TSharedMemoryRingBuffer.Dequeue(var Value: string): boolean;
var
  Entry: PQItemHeader;
begin
  FMutex.Acquire;
  try

    if (FQueueHeader.TailOffset = 0) then
      Exit(False);

    Entry := Tail;

    SetLength(Value, Entry.Size div SizeOf(Char));
    if (Entry.Size <> 0) then
      Move(pointer(NativeUInt(Entry) + SizeOf(TQItemHeader))^, PChar(Value)^, Entry.Size);

    FQueueHeader.TailOffset := Entry.Next;
    Entry.Next := 0;
    Entry.Size := 0;

    Result := True;
  finally
    FMutex.Release;
  end;
end;

//------------------------------------------------------------------------------

function TSharedMemoryRingBuffer.Dequeue(var Value: TBytes): boolean;
var
  Entry: PQItemHeader;
begin
  FMutex.Acquire;
  try

    if (FQueueHeader.TailOffset = 0) then
      Exit(False);

    Entry := Tail;

    SetLength(Value, Entry.Size);
    if (Entry.Size <> 0) then
      Move(pointer(NativeUInt(Entry) + SizeOf(TQItemHeader))^, Value[0], Entry.Size);

    FQueueHeader.TailOffset := Entry.Next;
    Entry.Next := 0;
    Entry.Size := 0;

    Result := True;
  finally
    FMutex.Release;
  end;
end;

//------------------------------------------------------------------------------

procedure TSharedMemoryRingBuffer.Enqueue(const AData: string);
begin
  Enqueue(PChar(AData), Length(AData) * SizeOf(Char));
end;

//------------------------------------------------------------------------------

procedure TSharedMemoryRingBuffer.Enqueue(const AData: TBytes);
begin
  Enqueue(@AData[0], Length(AData));
end;

//------------------------------------------------------------------------------

procedure TSharedMemoryRingBuffer.Enqueue(AData: pointer; ASize: Cardinal);
var
  Entry, PrevEntry: PQItemHeader;
  EntrySize: Cardinal;
begin
  if (ASize + SizeOf(TQueueHeader) + SizeOf(TQItemHeader) > FSharedMem.Size) then
    raise ESharedMemoryRingBuffer.Create('Buffer overrun');

  FMutex.Acquire;
  try

    PrevEntry := Head;
    if (PrevEntry.Size = 0) then
      Entry := PrevEntry
    else
      Entry := PQItemHeader(NativeUInt(PrevEntry) + PrevEntry.Size + SizeOf(TQItemHeader));
    EntrySize := ASize + SizeOf(TQItemHeader);

    // If we hit the end of the buffer, we wrap around
    if (NativeUInt(Entry) + EntrySize > NativeUInt(FSharedMem.Buffer) + FSharedMem.Size) then
    begin
      // When head overtakes tail, we must discard the data we have passed
      while (FQueueHeader.TailOffset <> 0) and (NativeUInt(Tail) >= NativeUInt(Entry)) do
        Discard;

      Entry := FirstEntry;
    end;

    // If new the entry will overrun an existing extry, we must make room in the
    // queue by discarding old entries
    while (FQueueHeader.TailOffset <> 0) and (NativeUInt(Entry) <= NativeUInt(Tail)) and
      (NativeUInt(Entry) + EntrySize > NativeUInt(Tail)) do
      Discard;

    // This entry is now the new head
    FQueueHeader.HeadOffset := NativeUInt(Entry) - NativeUInt(FSharedMem.Buffer);
    // ...and the tail if the entry is the only one
    if (FQueueHeader.TailOffset = 0) then
      FQueueHeader.TailOffset := FQueueHeader.HeadOffset;

    if (PrevEntry.Size <> 0) then
      PrevEntry.Next := FQueueHeader.HeadOffset;

    Entry.Next := 0;
    Entry.Size := ASize;
    if (ASize > 0) then
      Move(AData^, pointer(NativeUInt(Entry) + SizeOf(TQItemHeader))^, ASize);

  finally
    FMutex.Release;
  end;

  // Increment semaphore to signal availability of buffer item.
  (*
    Note that this should be done outside the mutex lock to avoid giving Enqueue an
    unfair advantage over Dequeue and wasting resources.
    If we increment the semaphore inside the mutex lock then the following scenario
    can occur:

    +---------------------------+-------------------------------+------------------------------
    | Producer                  | Consumer                      |
    +---------------------------+-------------------------------+------------------------------
    |                           | Buffer.Sempahore.WaitFor      | Blocks -> thread put to sleep
    | Buffer.Enqueue            |                               |
    | Buffer.Mutex.Lock         |                               | Lock acquired
    | Buffer.Sempahore.Release  |                               | Wakes consumer
    |                           | Buffer.Dequeue                |
    |                           | Buffer.Mutex.Lock             | Blocks -> thread put to sleep
    | Buffer.Mutex.Unlock       |                               |
    | Buffer.Enqueue            |                               |
    | Buffer.Mutex.Lock         |                               | Lock acquired (mutex isn't guaranteed to be fair)
    | etc etc.                  .                               .
    +---------------------------+-------------------------------+------------------------------
  *)
  if (not ReleaseSemaphore(FSemaphore.Handle, 1, @FItemCount)) then
    // Allow semaphore overrun since we cannot rely on user to use the
    // semaphore correctly - or at all.
    if (GetLastError <> ERROR_TOO_MANY_POSTS) then
      RaiseLastOSError;
end;

//------------------------------------------------------------------------------

function TSharedMemoryRingBuffer.WaitFor(Timeout: Cardinal): TWaitResult;
begin
  Result := FSemaphore.WaitFor(Timeout);
end;

//------------------------------------------------------------------------------

function TSharedMemoryRingBuffer.GetHandle: THandle;
begin
  Result := FSemaphore.Handle;
end;

//------------------------------------------------------------------------------

end.
