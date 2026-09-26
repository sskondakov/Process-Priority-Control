unit AppStorage;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Windows;

type
  TRule = record
    Name: UnicodeString;  // имя процесса, например chrome.exe
    Cpu: Integer;         // индекс в CpuKeys
    Io: Integer;          // индекс в IoKeys
    Mem: Integer;         // индекс в MemKeys
    MinMemMB: Integer;    // применять, если память процесса >= N МБ; 0 — без фильтра
  end;

const
  // Ключи пишутся в CSV, подписи показываются в таблице. Индекс 0 — «не менять».
  CpuKeys: array[0..6] of UnicodeString =
    ('Keep', 'Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High', 'Realtime');
  CpuCaptions: array[0..6] of UnicodeString =
    ('Не менять', 'Низкий (0)', 'Ниже среднего (1)', 'Обычный (2)', 'Выше среднего (3)', 'Высокий (4)', 'Реального времени (5)');

  IoKeys: array[0..4] of UnicodeString =
    ('Keep', 'VeryLow', 'Low', 'Normal', 'High');
  IoCaptions: array[0..4] of UnicodeString =
    ('Не менять', 'Очень низкий (0)', 'Низкий (1)', 'Обычный (2)', 'Высокий (3)');

  MemKeys: array[0..5] of UnicodeString =
    ('Keep', 'VeryLow', 'Low', 'Medium', 'BelowNormal', 'Normal');
  MemCaptions: array[0..5] of UnicodeString =
    ('Не менять', 'Очень низкий (0)', 'Низкий (1)', 'Средний (2)', 'Ниже обычного (3)', 'Обычный (4)');

  DefaultIntervalSec = 30;
  MaxIntervalSec     = 3600;

var
  Rules: array of TRule;
  IntervalSec: Integer = DefaultIntervalSec;

// Автозагрузка (HKCU\...\Run)
function IsAutostartEnabled: Boolean;
function SetAutostart(Enable: Boolean): Boolean;

// Признак первого запуска (HKCU\Software\PPControl\FirstRunDone)
function IsFirstRunDone: Boolean;
procedure MarkFirstRunDone;

// Настройки: интервал — реестр, таблица правил — CSV в %APPDATA%\PPControl
procedure LoadSettings;
function SaveRules: Boolean;
function SaveIntervalSec: Boolean;

function IntToText(N: Integer): UnicodeString;
function TextToInt(const S: UnicodeString; Default: Integer): Integer;

implementation

const
  RunKey:      UnicodeString = 'Software\Microsoft\Windows\CurrentVersion\Run';
  RunValue:    UnicodeString = 'PPControl';
  AppKey:      UnicodeString = 'Software\PPControl';
  AppDirName:  UnicodeString = 'PPControl';
  RulesFile:   UnicodeString = 'rules.csv';
  CsvHeader:   UnicodeString = 'Process;CpuPriority;IoPriority;MemoryPriority;MinMemoryMB';

type
  TStrArray = array of UnicodeString;

// ---------- Вспомогательное ----------

function IntToText(N: Integer): UnicodeString;
var
  A: AnsiString;
begin
  Str(N, A);
  Result := UnicodeString(A);
end;

function TextToInt(const S: UnicodeString; Default: Integer): Integer;
var
  V, Code: Integer;
begin
  Val(AnsiString(S), V, Code);
  if Code <> 0 then
    Result := Default
  else
    Result := V;
end;

function ExePath: UnicodeString;
var
  Buf: array[0..MAX_PATH] of WideChar;
  N: DWORD;
begin
  N := GetModuleFileNameW(0, @Buf[0], MAX_PATH);
  SetString(Result, PWideChar(@Buf[0]), N);
end;

// ---------- Реестр ----------

function RegGetDword(const SubKey, Name: UnicodeString; out Value: DWORD): Boolean;
var
  Key: HKEY;
  Typ, Size: DWORD;
begin
  Result := False;
  if RegOpenKeyExW(HKEY_CURRENT_USER, PWideChar(SubKey), 0, KEY_QUERY_VALUE, Key) <> ERROR_SUCCESS then
    Exit;
  Size := SizeOf(Value);
  Result := (RegQueryValueExW(Key, PWideChar(Name), nil, @Typ, PByte(@Value), @Size) = ERROR_SUCCESS)
    and (Typ = REG_DWORD);
  RegCloseKey(Key);
end;

function RegSetDword(const SubKey, Name: UnicodeString; Value: DWORD): Boolean;
var
  Key: HKEY;
begin
  Result := False;
  if RegCreateKeyExW(HKEY_CURRENT_USER, PWideChar(SubKey), 0, nil, 0,
       KEY_SET_VALUE, nil, Key, nil) <> ERROR_SUCCESS then
    Exit;
  Result := RegSetValueExW(Key, PWideChar(Name), 0, REG_DWORD,
    PByte(@Value), SizeOf(Value)) = ERROR_SUCCESS;
  RegCloseKey(Key);
end;

function IsAutostartEnabled: Boolean;
var
  Key: HKEY;
  Typ, Size: DWORD;
begin
  Result := False;
  if RegOpenKeyExW(HKEY_CURRENT_USER, PWideChar(RunKey), 0, KEY_QUERY_VALUE, Key) <> ERROR_SUCCESS then
    Exit;
  Size := 0;
  Result := RegQueryValueExW(Key, PWideChar(RunValue), nil, @Typ, nil, @Size) = ERROR_SUCCESS;
  RegCloseKey(Key);
end;

function SetAutostart(Enable: Boolean): Boolean;
var
  Key: HKEY;
  Cmd: UnicodeString;
begin
  Result := False;
  if RegCreateKeyExW(HKEY_CURRENT_USER, PWideChar(RunKey), 0, nil, 0,
       KEY_SET_VALUE, nil, Key, nil) <> ERROR_SUCCESS then
    Exit;
  if Enable then
  begin
    Cmd := '"' + ExePath + '"';  // кавычки — на случай пробелов в пути
    Result := RegSetValueExW(Key, PWideChar(RunValue), 0, REG_SZ,
      PByte(PWideChar(Cmd)), (Length(Cmd) + 1) * SizeOf(WideChar)) = ERROR_SUCCESS;
  end
  else
    Result := RegDeleteValueW(Key, PWideChar(RunValue)) in [ERROR_SUCCESS, ERROR_FILE_NOT_FOUND];
  RegCloseKey(Key);
end;

function IsFirstRunDone: Boolean;
var
  V: DWORD;
begin
  Result := RegGetDword(AppKey, 'FirstRunDone', V) and (V = 1);
end;

procedure MarkFirstRunDone;
begin
  RegSetDword(AppKey, 'FirstRunDone', 1);
end;

function SaveIntervalSec: Boolean;
begin
  Result := RegSetDword(AppKey, 'IntervalSec', DWORD(IntervalSec));
end;

// ---------- Файлы ----------

function RulesPath(CreateDir: Boolean): UnicodeString;
var
  Buf: array[0..MAX_PATH] of WideChar;
  N: DWORD;
  Dir: UnicodeString;
begin
  Result := '';
  N := GetEnvironmentVariableW('APPDATA', @Buf[0], MAX_PATH);
  if (N = 0) or (N > MAX_PATH) then
    Exit;
  SetString(Dir, PWideChar(@Buf[0]), N);
  Dir := Dir + '\' + AppDirName;
  if CreateDir then
    CreateDirectoryW(PWideChar(Dir), nil);  // уже существует — не страшно
  Result := Dir + '\' + RulesFile;
end;

function ReadFileUtf8(const Path: UnicodeString; out S: UnicodeString): Boolean;
var
  H: THandle;
  Size, Got: DWORD;
  Buf: RawByteString;
  Off, N: Integer;
begin
  Result := False;
  S := '';
  H := CreateFileW(PWideChar(Path), GENERIC_READ, FILE_SHARE_READ, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then
    Exit;
  Size := GetFileSize(H, nil);
  if (Size = INVALID_FILE_SIZE) or (Size > 16 * 1024 * 1024) then
  begin
    CloseHandle(H);
    Exit;
  end;
  SetLength(Buf, Size);
  Got := 0;
  if Size > 0 then
    Result := ReadFile(H, PAnsiChar(Buf)^, Size, Got, nil)
  else
    Result := True;
  CloseHandle(H);
  if not Result then
    Exit;

  Off := 0;
  if (Got >= 3) and (Buf[1] = #$EF) and (Buf[2] = #$BB) and (Buf[3] = #$BF) then
    Off := 3;  // BOM
  if Integer(Got) - Off <= 0 then
    Exit;
  N := MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(Buf) + Off, Integer(Got) - Off, nil, 0);
  SetLength(S, N);
  if N > 0 then
    MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(Buf) + Off, Integer(Got) - Off, PWideChar(S), N);
end;

function WriteFileUtf8(const Path, S: UnicodeString): Boolean;
const
  Bom: array[0..2] of Byte = ($EF, $BB, $BF);  // BOM — чтобы Excel открыл в UTF-8
var
  Tmp: UnicodeString;
  H: THandle;
  Utf8: RawByteString;
  N: Integer;
  Written: DWORD;
begin
  Result := False;
  N := WideCharToMultiByte(CP_UTF8, 0, PWideChar(S), Length(S), nil, 0, nil, nil);
  SetLength(Utf8, N);
  if N > 0 then
    WideCharToMultiByte(CP_UTF8, 0, PWideChar(S), Length(S), PAnsiChar(Utf8), N, nil, nil);

  // Пишем во временный файл и подменяем — старый файл не теряется при сбое
  Tmp := Path + '.tmp';
  H := CreateFileW(PWideChar(Tmp), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then
    Exit;
  Result := WriteFile(H, Bom, SizeOf(Bom), Written, nil);
  if Result and (N > 0) then
    Result := WriteFile(H, PAnsiChar(Utf8)^, N, Written, nil);
  CloseHandle(H);
  if Result then
    Result := MoveFileExW(PWideChar(Tmp), PWideChar(Path), MOVEFILE_REPLACE_EXISTING)
  else
    DeleteFileW(PWideChar(Tmp));
end;

// ---------- CSV (разделитель «;», как в русской локали Excel) ----------

function CsvEscape(const S: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := S;
  if (Pos(';', S) = 0) and (Pos('"', S) = 0) then
    Exit;
  Result := '"';
  for I := 1 to Length(S) do
  begin
    if S[I] = '"' then
      Result := Result + '""'
    else
      Result := Result + S[I];
  end;
  Result := Result + '"';
end;

procedure AddField(var A: TStrArray; const S: UnicodeString);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function ParseCsvLine(const L: UnicodeString): TStrArray;
var
  I: Integer;
  C: WideChar;
  Cur: UnicodeString;
  InQ: Boolean;
begin
  Result := nil;
  Cur := '';
  InQ := False;
  I := 1;
  while I <= Length(L) do
  begin
    C := L[I];
    if InQ then
    begin
      if C = '"' then
      begin
        if (I < Length(L)) and (L[I + 1] = '"') then
        begin
          Cur := Cur + '"';
          Inc(I);
        end
        else
          InQ := False;
      end
      else
        Cur := Cur + C;
    end
    else if C = '"' then
      InQ := True
    else if C = ';' then
    begin
      AddField(Result, Cur);
      Cur := '';
    end
    else
      Cur := Cur + C;
    Inc(I);
  end;
  AddField(Result, Cur);
end;

function FindKey(const Keys: array of UnicodeString; const K: UnicodeString): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Keys) do
    if lstrcmpiW(PWideChar(Keys[I]), PWideChar(K)) = 0 then
      Exit(I);
  Result := 0;  // неизвестное значение — «не менять»
end;

function FieldAt(const F: TStrArray; I: Integer): UnicodeString;
begin
  if I <= High(F) then
    Result := F[I]
  else
    Result := '';
end;

procedure ParseRules(const Text: UnicodeString);
var
  P, Start, Len: Integer;
  Line: UnicodeString;
  F: TStrArray;
  R: TRule;
begin
  Rules := nil;
  Len := Length(Text);
  Start := 1;
  while Start <= Len do
  begin
    P := Start;
    while (P <= Len) and (Text[P] <> #10) do
      Inc(P);
    Line := Copy(Text, Start, P - Start);
    Start := P + 1;
    if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    if Line = '' then
      Continue;

    F := ParseCsvLine(Line);
    if (lstrcmpiW(PWideChar(FieldAt(F, 0)), 'Process') = 0) or (FieldAt(F, 0) = '') then
      Continue;  // заголовок или пустое имя

    R.Name := FieldAt(F, 0);
    R.Cpu := FindKey(CpuKeys, FieldAt(F, 1));
    R.Io := FindKey(IoKeys, FieldAt(F, 2));
    R.Mem := FindKey(MemKeys, FieldAt(F, 3));
    R.MinMemMB := TextToInt(FieldAt(F, 4), 0);
    if R.MinMemMB < 0 then
      R.MinMemMB := 0;
    SetLength(Rules, Length(Rules) + 1);
    Rules[High(Rules)] := R;
  end;
end;

// ---------- Загрузка / сохранение ----------

procedure LoadSettings;
var
  V: DWORD;
  Path, Text: UnicodeString;
begin
  IntervalSec := DefaultIntervalSec;
  if RegGetDword(AppKey, 'IntervalSec', V) and (V >= 1) and (V <= MaxIntervalSec) then
    IntervalSec := Integer(V);

  Rules := nil;
  Path := RulesPath(False);
  if (Path <> '') and ReadFileUtf8(Path, Text) then
    ParseRules(Text);
end;

function SaveRules: Boolean;
var
  I: Integer;
  S, Path: UnicodeString;
begin
  Path := RulesPath(True);
  if Path = '' then
    Exit(False);
  S := CsvHeader + #13#10;
  for I := 0 to High(Rules) do
    S := S + CsvEscape(Rules[I].Name) + ';' + CpuKeys[Rules[I].Cpu] + ';' +
      IoKeys[Rules[I].Io] + ';' + MemKeys[Rules[I].Mem] + ';' +
      IntToText(Rules[I].MinMemMB) + #13#10;
  Result := WriteFileUtf8(Path, S);
end;

end.
