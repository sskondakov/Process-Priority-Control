unit PriorityEngine;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

// Один проход по процессам: находит процессы по таблице правил и приводит
// их приоритеты (CPU, ввод-вывод, память) к нужным. Вызывается по таймеру.
procedure ApplyRules;

implementation

uses
  Windows, AppStorage, AppLog;

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

  // Если приоритет прочитать не удалось, считаем его обычным
  NormalCpu = NORMAL_PRIORITY_CLASS;
  NormalIo  = 2;
  NormalMem = 5;

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
  CurName: UnicodeString;  // процесс, который сейчас обрабатывается (для журнала)
  CurPid: DWORD;
  CurMemMB: Int64 = -1;  // рабочий набор обрабатываемого процесса, Мбайт (-1 — неизвестно)
  PendingChanges: UnicodeString;  // изменения приоритетов текущего процесса для одной строки журнала

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

function CpuText(C: Int64): UnicodeString;
var
  I: Integer;
begin
  for I := 2 to High(CpuClasses) do
    if CpuClasses[I] = C then
      Exit(CpuCaptions[I]);
  Result := IntToText(Integer(C));
end;

// Ввод-вывод: значение Windows 0..3 -> подпись (индекс в IoCaptions = значение + 2)
function IoText(C: Int64): UnicodeString;
begin
  if (C >= 0) and (C + 2 <= High(IoCaptions)) then
    Result := IoCaptions[C + 2]
  else
    Result := IntToText(Integer(C));
end;

// Память: значение Windows 1..5 -> подпись (индекс в MemCaptions = значение + 1)
function MemText(C: Int64): UnicodeString;
begin
  if (C >= 1) and (C + 1 <= High(MemCaptions)) then
    Result := MemCaptions[C + 1]
  else
    Result := IntToText(Integer(C));
end;

function ProcText: UnicodeString;
begin
  Result := CurName + ' (PID ' + IntToText(Integer(CurPid)) + ')';
end;

// Код ошибки: Win32 — десятичный, NTSTATUS (старший бит) — шестнадцатеричный;
// 0 — функция Windows недоступна на этой системе
function CodeText(Code: Cardinal): UnicodeString;
const
  Digits: array[0..15] of WideChar = '0123456789ABCDEF';
var
  I: Integer;
begin
  if Code = 0 then
    Exit('функция Windows недоступна');
  if Code < $80000000 then
    Exit('код ' + IntToText(Integer(Code)));
  Result := '';
  for I := 7 downto 0 do
    Result := Result + Digits[(Code shr (I * 4)) and 15];
  Result := 'код 0x' + Result;
end;

// Ошибка — в журнал при каждом возникновении. Param пустой — ошибка не относится к приоритету.
procedure LogError(const What, Param: UnicodeString; Code: Cardinal);
begin
  if Param = '' then
    LogLine('ОШИБКА ' + What + ': ' + ProcText + ', ' + CodeText(Code))
  else
    LogLine('ОШИБКА ' + What + ' приоритета «' + Param + '»: ' + ProcText + ', ' + CodeText(Code));
end;

// Изменения приоритетов процесса копятся и пишутся одной строкой (FlushChanges)
procedure LogChange(const Param, OldText, NewText: UnicodeString);
begin
  if PendingChanges <> '' then
    PendingChanges := PendingChanges + ', ';
  PendingChanges := PendingChanges + '«' + Param + '» ' + OldText + ' → ' + NewText;
end;

procedure FlushChanges;
var
  MemInfo: UnicodeString;
begin
  if PendingChanges = '' then
    Exit;
  // Объём памяти процесса в момент смены; если измерить не удалось — это ошибка, уже в журнале
  if CurMemMB >= 0 then
  begin
    MemInfo := IntToText(Integer(CurMemMB)) + ' Мбайт';
    LogLine('Изменены приоритеты ' + CurName + ' (PID ' + IntToText(Integer(CurPid)) + ', ' + MemInfo +
      '): ' + PendingChanges);
  end
  else
  begin
    LogLine('Изменены приоритеты ' + ProcText + ': ' + PendingChanges);
  end;
  PendingChanges := '';
end;

// Читают текущий приоритет; при ошибке пишут в журнал и возвращают «обычный»
function ReadCpu(H: THandle): Int64;
var
  C: DWORD;
begin
  C := GetPriorityClass(H);
  if C = 0 then
  begin
    LogError('чтения', 'CPU', GetLastError);
    Result := NormalCpu;
  end
  else
    Result := C;
end;

function ReadIo(H: THandle): Int64;
var
  C: ULONG;
  St: LongInt;
begin
  Result := NormalIo;
  if not Assigned(NtQueryInformationProcess) then
  begin
    LogError('чтения', 'Ввод-вывод', 0);
    Exit;
  end;
  St := NtQueryInformationProcess(H, ProcessIoPriority, @C, SizeOf(C), nil);
  if St >= 0 then
    Result := C
  else
    LogError('чтения', 'Ввод-вывод', Cardinal(St));
end;

function ReadMem(H: THandle): Int64;
var
  C: ULONG;
begin
  Result := NormalMem;
  if not Assigned(GetProcessInformationFn) then
  begin
    LogError('чтения', 'Память', 0);
    Exit;
  end;
  if GetProcessInformationFn(H, ProcessMemoryPriority, @C, SizeOf(C)) then
    Result := C
  else
    LogError('чтения', 'Память', GetLastError);
end;

// Исходные приоритеты по имени процесса; при первом обнаружении имени читаются,
// запоминаются и пишутся в журнал
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
  LogLine('Обнаружен процесс ' + ProcText + '; по умолчанию: CPU — ' + CpuText(Originals[Result].Cpu) +
    ', ввод-вывод — ' + IoText(Originals[Result].Io) + ', память — ' + MemText(Originals[Result].Mem));
end;

procedure ApplyCpu(H: THandle; Idx: Integer; const Orig: TOriginal);
var
  Want, Cur: DWORD;
begin
  if Idx = 0 then
    Exit;
  if Idx = DefaultIdx then
    Want := DWORD(Orig.Cpu)
  else
    Want := CpuClasses[Idx];
  Cur := DWORD(ReadCpu(H));
  if Cur = Want then
    Exit;
  if SetPriorityClass(H, Want) then
    LogChange('CPU', CpuText(Cur), CpuText(Want))
  else
    LogError('изменения', 'CPU', GetLastError);
end;

procedure ApplyIo(H: THandle; Idx: Integer; const Orig: TOriginal);
var
  Want, Cur: ULONG;
  St: LongInt;
begin
  if (Idx = 0) or (NtSetInformationProcess = nil) then
    Exit;
  if Idx = DefaultIdx then
    Want := ULONG(Orig.Io)
  else
    Want := ULONG(Idx - 2);  // 0 очень низкий, 1 низкий, 2 обычный, 3 высокий
  Cur := ULONG(ReadIo(H));
  if Cur = Want then
    Exit;
  St := NtSetInformationProcess(H, ProcessIoPriority, @Want, SizeOf(Want));
  if St >= 0 then
    LogChange('Ввод-вывод', IoText(Cur), IoText(Want))
  else
    LogError('изменения', 'Ввод-вывод', Cardinal(St));
end;

procedure ApplyMem(H: THandle; Idx: Integer; const Orig: TOriginal);
var
  Want, Cur: ULONG;
begin
  if (Idx = 0) or (SetProcessInformationFn = nil) then
    Exit;
  if Idx = DefaultIdx then
    Want := ULONG(Orig.Mem)
  else
    Want := ULONG(Idx - 1);  // 1 очень низкий ... 5 обычный — совпадает с MEMORY_PRIORITY_*
  Cur := ULONG(ReadMem(H));
  if Cur = Want then
    Exit;
  if SetProcessInformationFn(H, ProcessMemoryPriority, @Want, SizeOf(Want)) then
    LogChange('Память', MemText(Cur), MemText(Want))
  else
    LogError('изменения', 'Память', GetLastError);
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
  begin
    LogError('чтения объёма памяти', '', GetLastError);
    Result := -1;
  end;
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
  OpenErr: DWORD;
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

      CurName := UnicodeString(PWideChar(@PE.szExeFile[0]));
      CurPid := PE.th32ProcessID;
      PendingChanges := '';
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
            Failed := True;
            OpenErr := GetLastError;
            // Отказ в доступе (системный или защищённый процесс) — ошибка с кодом Windows;
            // процесс успел завершиться между снимком и открытием (ERROR_INVALID_PARAMETER) —
            // не ошибка, одна строка без кода
            if OpenErr = ERROR_ACCESS_DENIED then
              LogError('доступа к процессу', '', OpenErr)
            else if OpenErr = ERROR_INVALID_PARAMETER then
              LogLine('Процесс ' + ProcText + ' завершился до обработки')
            else
              LogError('открытия процесса', '', OpenErr);
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
        if MemMB = -2 then
          MemMB := WorkingSetMB(H);
        CurMemMB := MemMB;
        // Не удалось измерить память (ошибка уже в журнале) — процесс пропускаем, приоритеты не трогаем
        if MemMB >= 0 then
        begin
          O := FindOriginal(H, PE.szExeFile);
          ApplyCpu(H, W.Cpu, Originals[O]);
          ApplyIo(H, W.Io, Originals[O]);
          ApplyMem(H, W.Mem, Originals[O]);
          FlushChanges;
        end;
      end;
      if H <> 0 then
        CloseHandle(H);
    until not Process32NextW(Snap, PE);
  finally
    CloseHandle(Snap);
    FlushLog;
  end;
end;

end.
