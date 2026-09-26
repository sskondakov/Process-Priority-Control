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

  // Индекс из CpuKeys -> класс приоритета Windows (0 — «не менять»)
  CpuClasses: array[0..6] of DWORD = (
    0, IDLE_PRIORITY_CLASS, BELOW_NORMAL_PRIORITY_CLASS, NORMAL_PRIORITY_CLASS,
    ABOVE_NORMAL_PRIORITY_CLASS, HIGH_PRIORITY_CLASS, REALTIME_PRIORITY_CLASS);

  TH32CS_SNAPPROCESS = $00000002;

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

procedure ApplyCpu(H: THandle; Idx: Integer);
var
  Want, Cur: DWORD;
begin
  if Idx = 0 then
    Exit;
  Want := CpuClasses[Idx];
  Cur := GetPriorityClass(H);
  if Cur <> Want then
    SetPriorityClass(H, Want);
end;

procedure ApplyIo(H: THandle; Idx: Integer);
var
  Want, Cur: ULONG;
begin
  if (Idx = 0) or (NtSetInformationProcess = nil) then
    Exit;
  Want := ULONG(Idx - 1);  // 0 очень низкий, 1 низкий, 2 обычный, 3 высокий
  if Assigned(NtQueryInformationProcess) and
     (NtQueryInformationProcess(H, ProcessIoPriority, @Cur, SizeOf(Cur), nil) >= 0) and
     (Cur = Want) then
    Exit;
  NtSetInformationProcess(H, ProcessIoPriority, @Want, SizeOf(Want));
end;

procedure ApplyMem(H: THandle; Idx: Integer);
var
  Want, Cur: ULONG;
begin
  if (Idx = 0) or (SetProcessInformationFn = nil) then
    Exit;
  Want := ULONG(Idx);  // 1 очень низкий ... 5 обычный — совпадает с MEMORY_PRIORITY_*
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
        ApplyCpu(H, W.Cpu);
        ApplyIo(H, W.Io);
        ApplyMem(H, W.Mem);
      end;
      if H <> 0 then
        CloseHandle(H);
    until not Process32NextW(Snap, PE);
  finally
    CloseHandle(Snap);
  end;
end;

end.
