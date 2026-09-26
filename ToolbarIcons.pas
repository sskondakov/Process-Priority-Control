unit ToolbarIcons;

{$mode objfpc}{$H+}

// Иконки «+», «−», «вверх», «вниз» (24x24, из Lazarus images/general_purpose:
// Add_07, Remove_07, Arrow_03, Arrow_04) лежат в ресурсах exe как RCDATA
// с содержимым .ico (res\plus.ico, minus.ico, up.ico, down.ico).
// RCDATA, а не ICON — чтобы Проводник не взял одну из них иконкой самого exe.

interface

uses
  Windows;

const
  IconSize = 24;

// Иконки нужно освобождать через DestroyIcon
function CreatePlusIcon: HICON;
function CreateMinusIcon: HICON;
function CreateUpIcon: HICON;
function CreateDownIcon: HICON;

// Иконка приложения (ресурс APPICON, он же иконка exe) нужного размера в пикселях.
// Для трея — SM_CXSMICON, для рамки окна — SM_CXICON. Освобождать через DestroyIcon.
function LoadAppIcon(Size: Integer): HICON;

implementation

const
  RT_RCDATA_ID = 10;  // MAKEINTRESOURCE(RT_RCDATA) для Unicode-версии FindResourceW

type
  TIconDirEntry = packed record
    Width, Height, ColorCount, Reserved: Byte;
    Planes, BitCount: Word;
    BytesInRes, ImageOffset: DWORD;
  end;

function LoadIconFromRcData(const ResName: UnicodeString): HICON;
var
  Res: HRSRC;
  Mem: HGLOBAL;
  Data: PByte;
  Size: DWORD;
  Entry: ^TIconDirEntry;
begin
  Result := 0;
  Res := FindResourceW(HINSTANCE, PWideChar(ResName), PWideChar(RT_RCDATA_ID));
  if Res = 0 then
    Exit;
  Mem := LoadResource(HINSTANCE, Res);
  Size := SizeofResource(HINSTANCE, Res);
  if (Mem = 0) or (Size < 6 + SizeOf(TIconDirEntry)) then
    Exit;
  Data := LockResource(Mem);

  // Файл .ico: заголовок (6 байт), затем записи каталога; берём первую (единственную)
  Entry := Pointer(Data + 6);
  if Entry^.ImageOffset + Entry^.BytesInRes > Size then
    Exit;
  Result := CreateIconFromResourceEx(Data + Entry^.ImageOffset, Entry^.BytesInRes,
    True, $00030000, IconSize, IconSize, LR_DEFAULTCOLOR);
end;

function CreatePlusIcon: HICON;
begin
  Result := LoadIconFromRcData('PLUS_ICO');
end;

function CreateMinusIcon: HICON;
begin
  Result := LoadIconFromRcData('MINUS_ICO');
end;

function LoadAppIcon(Size: Integer): HICON;
begin
  Result := HICON(LoadImageW(HINSTANCE, 'APPICON', IMAGE_ICON, Size, Size, LR_DEFAULTCOLOR));
end;

function CreateUpIcon: HICON;
begin
  Result := LoadIconFromRcData('UP_ICO');
end;

function CreateDownIcon: HICON;
begin
  Result := LoadIconFromRcData('DOWN_ICO');
end;

end.
