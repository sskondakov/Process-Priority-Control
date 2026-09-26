unit PriorityEngine;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

// Один проход по процессам: находит процессы по таблице правил и приводит
// их приоритеты (CPU, ввод-вывод, память) к нужным. Вызывается по таймеру.
procedure ApplyRules;

implementation

uses
  Windows, AppStorage;

const
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  PROCESS_SET_INFORMATION           = $0200;

  ProcessIoPriority     = 33;  // NtQuery/SetInformationProcess
  ProcessMemoryPriority = 0;   // Get/SetProcessInformation

  // Индекс из CpuKeys -> класс приоритета Windows (0 — «не менять», 1 — «по умолчанию»)
  CpuClasses: array[0..7] of DWORD = (
    0, 0, IDLE_PRIORITY_CLASS, BELOW_NORMAL_PRIORITY_CLASS, NORMAL_PRIORITY_CLASS,
    ABOVE_NORMAL_PRIORITY_CLASS, HIGH_PRIORITY_CLASS, REALTIME_PRIORITY_CLASS);

  TH32CS_SNAPPROCESS = $00000002;

  // Пункт «По умолчанию» (индекс в CpuKeys / IoKeys / MemKeys) — вернуть
  // приоритет, который был у процесса с этим именем при первом обнаружении
  DefaultIdx = 1;

type
  // Toolhelp32 в FPC для Win64 не поставляется — объявляем нужное сами
  PROCESSENTRY32W = record
    dwSize: DWORD;
    cntUsage: DWORD;
    th32ProcessID: DWORD;
    th32DefaultHeapID: ULONG_PTR;
    th32ModuleID: DWORD;
    cntThreads: DWORD;
    th32ParentProcessID: DWORD;
    pcPriClassBase: LongInt;
    dwFlags: DWORD;
    szExeFile: array[0..MAX_PATH - 1] of WideChar;
  end;

  PROCESS_MEMORY_COUNTERS = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize: SIZE_T;
    WorkingSetSize: SIZE_T;
    QuotaPeakPagedPoolUsage: SIZE_T;
    QuotaPagedPoolUsage: SIZE_T;
    QuotaPeakNonPagedPoolUsage: SIZE_T;
    QuotaNonPagedPoolUsage: SIZE_T;
    PagefileUsage: SIZE_T;
    PeakPagefileUsage: SIZE_T;
  end;

  TNtProcInfo = function(H: THandle; InfoClass: ULONG; Info: Pointer;
    Len: ULONG; RetLen: PULONG): LongInt; stdcall;
  TNtSetProcInfo = function(H: THandle; InfoClass: ULONG; Info: Pointer;
    Len: ULONG): LongInt; stdcall;
  TProcInfo = function(H: THandle; InfoClass: DWORD; Info: Pointer;
    Size: DWORD): BOOL; stdcall;

  TWanted = record
    Cpu, Io, Mem: Integer;  // индексы как в правиле, 0 — не менять
  end;

  // Исходные приоритеты процесса, зафиксированные при первом обнаружении.
  // Хранятся по имени процесса, а не по PID; -1 — значение прочитать не удалось.
  TOriginal = record
    Name: UnicodeString;
    Cpu: Int64;
    Io: Int64;
    Mem: Int64;
  end;

function CreateToolhelp32Snapshot(dwFlags, th32ProcessID: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'CreateToolhelp32Snapshot';
function Process32FirstW(hSnapshot: THandle; var lppe: PROCESSENTRY32W): BOOL; stdcall;
  external 'kernel32.dll' name 'Process32FirstW';
function Process32NextW(hSnapshot: THandle; var lppe: PROCESSENTRY32W): BOOL; stdcall;
  external 'kernel32.dll' name 'Process32NextW';

function GetProcessMemoryInfo(H: THandle; var Counters: PROCESS_MEMORY_COUNTERS;
  cb: DWORD): BOOL; stdcall; external 'kernel32.dll' name 'K32GetProcessMemoryInfo';

var
  NtQueryInformationProcess: TNtProcInfo;
  NtSetInformationProcess: TNtSetProcInfo;
  GetProcessInformationFn: TProcInfo;  // kernel32, Windows 8+
  SetProcessInformationFn: TProcInfo;
  ApiLoaded: Boolean = False;
  Originals: array of TOriginal;

procedure LoadApis;
var
  Ntdll, Kernel: HMODULE;
begin
  if ApiLoaded then
    Exit;
  ApiLoaded := True;
  Ntdll := GetModuleHandleW('ntdll.dll');
  Kernel := GetModuleHandleW('kernel32.dll');
  Pointer(NtQueryInformationProcess) := GetProcAddress(Ntdll, 'NtQueryInformationProcess');
  Pointer(NtSetInformationProcess) := GetProcAddress(Ntdll, 'NtSetInformationProcess');
  Pointer(GetProcessInformationFn) := GetProcAddress(Kernel, 'GetProcessInformation');
  Pointer(SetProcessInformationFn) := GetProcAddress(Kernel, 'SetProcessInformation');
end;

// ---------- Чтение и установка приоритетов (сначала проверка, потом запись) ----------

function ReadCpu(H: THandle): Int64;
var
  C: DWORD;
begin
  C := GetPriorityClass(H);
  if C = 0 then
    Result := -1
  else
    Result := C;
end;

function ReadIo(H: THandle): Int64;
var
  C: ULONG;
begin
  Result := -1;
  if Assigned(NtQueryInformationProcess) and
     (NtQueryInformationProcess(H, ProcessIoPriority, @C, SizeOf(C), nil) >= 0) then
    Result := C;
end;

function ReadMem(H: THandle): Int64;
var
  C: ULONG;
begin
  Result := -1;
  if Assigned(GetProcessInformationFn) and
     GetProcessInformationFn(H, ProcessMemoryPriority, @C, SizeOf(C)) then
    Result := C;
end;

// Исходные приоритеты по имени процесса; при первом обнаружении имени читаются и запоминаются
function FindOriginal(H: THandle; const Name: PWideChar): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Originals) do
    if lstrcmpiW(PWideChar(Originals[I].Name), Name) = 0 then
      Exit(I);
  Result := Length(Originals);
  SetLength(Originals, Result + 1);
  Originals[Result].Name := UnicodeString(Name);
  Originals[Result].Cpu := ReadCpu(H);
  Originals[Result].Io := ReadIo(H);
  Originals[Result].Mem := ReadMem(H);
end;

procedure ApplyCpu(H: THandle; Idx: Integer; const Orig: TOriginal);
var
  Want, Cur: DWORD;
begin
  if Idx = 0 then
    Exit;
  if Idx = DefaultIdx then
  begin
    if Orig.Cpu <= 0 then
      Exit;
    Want := DWORD(Orig.Cpu);
  end
  else
    Want := CpuClasses[Idx];
  Cur := GetPriorityClass(H);
  if Cur <> Want then
    SetPriorityClass(H, Want);
end;

procedure ApplyIo(H: THandle; Idx: Integer; const Orig: TOriginal);
var
  Want, Cur: ULONG;
begin
  if (Idx = 0) or (NtSetInformationProcess = nil) then
    Exit;
  if Idx = DefaultIdx then
  begin
    if Orig.Io < 0 then
      Exit;
    Want := ULONG(Orig.Io);
  end
  else
    Want := ULONG(Idx - 2);  // 0 очень низкий, 1 низкий, 2 обычный, 3 высокий
  if Assigned(NtQueryInformationProcess) and
     (NtQueryInformationProcess(H, ProcessIoPriority, @Cur, SizeOf(Cur), nil) >= 0) and
     (Cur = Want) then
    Exit;
  NtSetInformationProcess(H, ProcessIoPriority, @Want, SizeOf(Want));
end;

procedure ApplyMem(H: THandle; Idx: Integer; const Orig: TOriginal);
var
  Want, Cur: ULONG;
begin
  if (Idx = 0) or (SetProcessInformationFn = nil) then
    Exit;
  if Idx = DefaultIdx then
  begin
    if Orig.Mem < 0 then
      Exit;
    Want := ULONG(Orig.Mem);
  end
  else
    Want := ULONG(Idx - 1);  // 1 очень низкий ... 5 обычный — совпадает с MEMORY_PRIORITY_*
  if Assigned(GetProcessInformationFn) and
     GetProcessInformationFn(H, ProcessMemoryPriority, @Cur, SizeOf(Cur)) and
     (Cur = Want) then
    Exit;
  SetProcessInformationFn(H, ProcessMemoryPriority, @Want, SizeOf(Want));
end;

function WorkingSetMB(H: THandle): Int64;
var
  C: PROCESS_MEMORY_COUNTERS;
begin
  FillChar(C, SizeOf(C), 0);
  C.cb := SizeOf(C);
  if GetProcessMemoryInfo(H, C, SizeOf(C)) then
    Result := Int64(C.WorkingSetSize) div (1024 * 1024)
  else
    Result := -1;
end;

// ---------- Проход по процессам ----------

procedure ApplyRules;
var
  Snap: THandle;
  PE: PROCESSENTRY32W;
  I: Integer;
  H: THandle;
  MemMB: Int64;
  Failed: Boolean;
  W: TWanted;
  O: Integer;
begin
  if Length(Rules) = 0 then
    Exit;
  LoadApis;

  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then
    Exit;
  try
    FillChar(PE, SizeOf(PE), 0);
    PE.dwSize := SizeOf(PE);
    if not Process32FirstW(Snap, PE) then
      Exit;
    repeat
      if PE.th32ProcessID <= 4 then  // Idle и System
        Continue;

      H := 0;
      MemMB := -2;  // -2: память ещё не измеряли
      Failed := False;
      FillChar(W, SizeOf(W), 0);

      // Правила сверху вниз; если несколько подходят, нижнее перекрывает верхнее
      // по тем полям, где оно что-то задаёт (не «Не менять»)
      for I := 0 to High(Rules) do
      begin
        if lstrcmpiW(PE.szExeFile, PWideChar(Rules[I].Name)) <> 0 then
          Continue;
        if H = 0 then
        begin
          H := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION or PROCESS_SET_INFORMATION,
            False, PE.th32ProcessID);
          if H = 0 then
          begin
            Failed := True;  // нет доступа (системный или защищённый процесс)
            Break;
          end;
        end;
        if Rules[I].MinMemMB > 0 then
        begin
          if MemMB = -2 then
            MemMB := WorkingSetMB(H);
          if MemMB < Rules[I].MinMemMB then
            Continue;
        end;
        if Rules[I].Cpu <> 0 then W.Cpu := Rules[I].Cpu;
        if Rules[I].Io <> 0 then W.Io := Rules[I].Io;
        if Rules[I].Mem <> 0 then W.Mem := Rules[I].Mem;
      end;

      if (H <> 0) and not Failed then
      begin
        // Исходные значения фиксируются до первого изменения приоритетов
        O := FindOriginal(H, PE.szExeFile);
        ApplyCpu(H, W.Cpu, Originals[O]);
        ApplyIo(H, W.Io, Originals[O]);
        ApplyMem(H, W.Mem, Originals[O]);
      end;
      if H <> 0 then
        CloseHandle(H);
    until not Process32NextW(Snap, PE);
  finally
    CloseHandle(Snap);
  end;
end;

end.
