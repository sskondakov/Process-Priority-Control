unit AppLog;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

// Журнал работы: текстовый файл рядом с программой (PPControl.log), не более 1024 строк.
// Строки копятся в памяти и записываются в файл по FlushLog.

// Добавляет строку с текущими датой и временем
procedure LogLine(const Text: UnicodeString);
// Текст подсказки иконки в трее: заголовок, а если в журнале есть ошибки — под ним
// «имя процесса - ошибка» для последней из них (не длиннее MaxLen символов)
function TrayTipText(const Title: UnicodeString; MaxLen: Integer): UnicodeString;
procedure FlushLog;
// Открывает журнал программой, назначенной для .log в Windows (как двойной щелчок в проводнике)
procedure OpenLogFile;

implementation

uses
  Windows, ShellAPI;

const
  MaxLines = 1024;

var
  Lines: array of UnicodeString;
  Loaded: Boolean = False;
  Dirty: Boolean = False;

function LogPath: UnicodeString;
var
  Buf: array[0..MAX_PATH] of WideChar;
  I: Integer;
begin
  GetModuleFileNameW(0, @Buf[0], MAX_PATH);
  Result := UnicodeString(PWideChar(@Buf[0]));
  I := Length(Result);
  while (I > 0) and (Result[I] <> '.') and (Result[I] <> '\') do
    Dec(I);
  if (I > 0) and (Result[I] = '.') then
    SetLength(Result, I - 1);
  Result := Result + '.log';
end;

function Pad2(N: Integer): UnicodeString;
begin
  Result := UnicodeString(WideChar(Ord('0') + N div 10)) + WideChar(Ord('0') + N mod 10);
end;

function NowText: UnicodeString;
var
  T: TSYSTEMTIME;
begin
  GetLocalTime(T);
  Result := Pad2(T.wDay) + '.' + Pad2(T.wMonth) + '.' + Pad2(T.wYear div 100) + Pad2(T.wYear mod 100) +
    ' ' + Pad2(T.wHour) + ':' + Pad2(T.wMinute) + ':' + Pad2(T.wSecond);
end;

procedure PushLine(const Text: UnicodeString);
begin
  SetLength(Lines, Length(Lines) + 1);
  Lines[High(Lines)] := Text;
  if Length(Lines) > MaxLines then
    Delete(Lines, 0, Length(Lines) - MaxLines);
end;

// Читает существующий файл (UTF-8), оставляя последние MaxLines строк
procedure LoadLog;
var
  F: THandle;
  Size, Got: DWORD;
  Raw: RawByteString;
  Wide: UnicodeString;
  Start, I, N, L: Integer;
  Line: UnicodeString;
begin
  Loaded := True;
  F := CreateFileW(PWideChar(LogPath), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if F = INVALID_HANDLE_VALUE then
    Exit;
  try
    Size := GetFileSize(F, nil);
    if (Size = 0) or (Size = INVALID_FILE_SIZE) or (Size > 16 * 1024 * 1024) then
      Exit;
    SetLength(Raw, Size);
    if not ReadFile(F, Raw[1], Size, Got, nil) then
      Exit;
    SetLength(Raw, Got);
  finally
    CloseHandle(F);
  end;
  Start := 1;
  if (Length(Raw) >= 3) and (Raw[1] = #$EF) and (Raw[2] = #$BB) and (Raw[3] = #$BF) then
    Start := 4;
  L := Length(Raw) - Start + 1;
  if L <= 0 then
    Exit;
  SetLength(Wide, L);
  N := MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(@Raw[Start]), L, PWideChar(Wide), L);
  SetLength(Wide, N);

  Line := '';
  for I := 1 to Length(Wide) do
    if Wide[I] = #10 then
    begin
      if Line <> '' then
        PushLine(Line);
      Line := '';
    end
    else if Wide[I] <> #13 then
      Line := Line + Wide[I];
  if Line <> '' then
    PushLine(Line);
end;

procedure LogLine(const Text: UnicodeString);
begin
  if not Loaded then
    LoadLog;
  PushLine(NowText + '  ' + Text);
  Dirty := True;
end;

// Имя процесса из строки об ошибке вида «... ОШИБКА чтения ...: chrome.exe (PID 123), код 5»
function ErrorProcessName(const Line: UnicodeString): UnicodeString;
var
  PidPos, Start: Integer;
begin
  Result := '';
  PidPos := Pos(UnicodeString(' (PID '), Line);
  if PidPos = 0 then
    Exit;
  Start := PidPos;
  while (Start > 1) and not ((Line[Start - 1] = ':') and (Line[Start] = ' ')) do
    Dec(Start);
  Result := Copy(Line, Start + 1, PidPos - Start - 1);
end;

function TrayTipText(const Title: UnicodeString; MaxLen: Integer): UnicodeString;
var
  I: Integer;
  Name: UnicodeString;
begin
  Result := Copy(Title, 1, MaxLen);
  if not Loaded then
    LoadLog;
  for I := High(Lines) downto 0 do
    if Pos(UnicodeString('ОШИБКА'), Lines[I]) > 0 then
    begin
      Name := ErrorProcessName(Lines[I]);
      if Name <> '' then
        Result := Copy(Result + #10 + Name + ' - ошибка', 1, MaxLen);
      Break;
    end;
end;

// Записывает файл целиком: UTF-8 с BOM, строки через CRLF
function SaveLog: Boolean;
var
  F: THandle;
  Wide: UnicodeString;
  Raw: RawByteString;
  I, N: Integer;
  Written: DWORD;
begin
  Wide := '';
  for I := 0 to High(Lines) do
    Wide := Wide + Lines[I] + #13#10;
  SetLength(Raw, Length(Wide) * 3 + 3);
  Raw[1] := #$EF;
  Raw[2] := #$BB;
  Raw[3] := #$BF;
  N := 0;
  if Length(Wide) > 0 then
    N := WideCharToMultiByte(CP_UTF8, 0, PWideChar(Wide), Length(Wide), PAnsiChar(@Raw[4]),
      Length(Raw) - 3, nil, nil);
  F := CreateFileW(PWideChar(LogPath), GENERIC_WRITE, FILE_SHARE_READ, nil,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if F = INVALID_HANDLE_VALUE then
    Exit(False);
  Result := WriteFile(F, Raw[1], DWORD(N + 3), Written, nil);
  CloseHandle(F);
end;

procedure FlushLog;
begin
  if Dirty and SaveLog then  // не удалось записать (нет прав, файл занят) — повторим в следующий раз
    Dirty := False;
end;

procedure OpenLogFile;
var
  Info: SHELLEXECUTEINFOW;
  Path: UnicodeString;
begin
  FlushLog;
  Path := LogPath;
  if GetFileAttributesW(PWideChar(Path)) = INVALID_FILE_ATTRIBUTES then
  begin
    if not Loaded then
      LoadLog;
    SaveLog;  // пустой файл, чтобы было что открывать
  end;
  FillChar(Info, SizeOf(Info), 0);
  Info.cbSize := SizeOf(Info);
  Info.fMask := SEE_MASK_FLAG_NO_UI;  // без окна «Как вы хотите открыть?», если программы для .log нет
  Info.lpVerb := 'open';
  Info.lpFile := PWideChar(Path);
  Info.nShow := SW_SHOWNORMAL;
  ShellExecuteExW(@Info);
end;

end.
