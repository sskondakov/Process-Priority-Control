unit SettingsWindow;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Windows;

var
  // Вызывается после успешного сохранения настроек по кнопке «ОК»
  OnSettingsSaved: procedure = nil;

function RegisterSettingsClass: Boolean;
procedure ShowSettingsWindow;
procedure CloseSettingsWindow;

implementation

uses
  Messages, CommCtrl, AppStorage, ToolbarIcons;

const
  ID_LIST     = 201;
  ID_ADD      = 202;
  ID_DEL      = 203;
  ID_OK       = 204;
  ID_CANCEL   = 205;
  ID_INTERVAL = 206;
  ID_LABEL    = 207;
  ID_EDITOR   = 208;
  ID_SEC      = 209;
  ID_UP       = 210;
  ID_DOWN     = 211;

  WM_ENDEDIT = WM_APP + 1;  // wParam — окно-редактор, lParam — 1: сохранить, 0: отмена

  COL_NAME = 0;
  COL_CPU  = 1;
  COL_IO   = 2;
  COL_MEM  = 3;
  COL_FILT = 4;

  NewRuleMemMB = 1024;  // значение фильтра памяти для новой строки

  SettingsClass: UnicodeString = 'PPControlSettingsWindow';
  AppTitle:      UnicodeString = 'Контроль приоритетов процессов — Настройки';
  TipAdd:        UnicodeString = 'Добавить строку';
  TipDel:        UnicodeString = 'Удалить выбранную строку';
  TipUp:         UnicodeString = 'Переместить вверх';
  TipDown:       UnicodeString = 'Переместить вниз';

var
  hSettings, hList, hLabel, hInterval, hSec, hAdd, hDel, hUp, hDown, hOk, hCancel: HWND;
  hIconPlus, hIconMinus, hIconUp, hIconDown: HICON;
  hEditor: HWND = 0;
  EditorOldProc: WNDPROC;
  EdItem, EdSub: Integer;
  Work: array of TRule;  // рабочая копия таблицы, пишется в Rules по кнопке «ОК»

procedure SetFont(Wnd: HWND);
begin
  SendMessageW(Wnd, WM_SETFONT, WPARAM(GetStockObject(DEFAULT_GUI_FONT)), 1);
end;

function TrimText(const S: UnicodeString): UnicodeString;
var
  A, B: Integer;
begin
  A := 1;
  B := Length(S);
  while (A <= B) and (S[A] <= ' ') do
    Inc(A);
  while (B >= A) and (S[B] <= ' ') do
    Dec(B);
  Result := Copy(S, A, B - A + 1);
end;

function WindowText(Wnd: HWND): UnicodeString;
var
  Buf: array[0..259] of WideChar;
begin
  GetWindowTextW(Wnd, @Buf[0], Length(Buf));
  Result := UnicodeString(PWideChar(@Buf[0]));
end;

// ---------- Таблица ----------

procedure SetCell(Item, Sub: Integer; const Text: UnicodeString);
var
  LI: LVITEMW;
begin
  FillChar(LI, SizeOf(LI), 0);
  LI.iSubItem := Sub;
  LI.pszText := PWideChar(Text);
  SendMessageW(hList, LVM_SETITEMTEXTW, Item, LPARAM(@LI));
end;

procedure RefreshRow(Item: Integer);
begin
  SetCell(Item, COL_NAME, Work[Item].Name);
  SetCell(Item, COL_CPU, CpuCaptions[Work[Item].Cpu]);
  SetCell(Item, COL_IO, IoCaptions[Work[Item].Io]);
  SetCell(Item, COL_MEM, MemCaptions[Work[Item].Mem]);
  SetCell(Item, COL_FILT, IntToText(Work[Item].MinMemMB));
end;

procedure InsertRow(Item: Integer);
var
  LI: LVITEMW;
begin
  FillChar(LI, SizeOf(LI), 0);
  LI.mask := LVIF_TEXT;
  LI.iItem := Item;
  LI.pszText := PWideChar(Work[Item].Name);
  SendMessageW(hList, LVM_INSERTITEMW, 0, LPARAM(@LI));
  RefreshRow(Item);
end;

procedure SelectRow(Item: Integer);
var
  LI: LVITEMW;
begin
  FillChar(LI, SizeOf(LI), 0);
  LI.state := LVIS_SELECTED or LVIS_FOCUSED;
  LI.stateMask := LVIS_SELECTED or LVIS_FOCUSED;
  SendMessageW(hList, LVM_SETITEMSTATE, Item, LPARAM(@LI));
  SendMessageW(hList, LVM_ENSUREVISIBLE, Item, 0);
end;

procedure AddColumn(Index, Width: Integer; const Title: UnicodeString);
var
  C: LVCOLUMNW;
begin
  FillChar(C, SizeOf(C), 0);
  C.mask := LVCF_TEXT or LVCF_WIDTH or LVCF_SUBITEM;
  C.cx := Width;
  C.iSubItem := Index;
  C.pszText := PWideChar(Title);
  SendMessageW(hList, LVM_INSERTCOLUMNW, Index, LPARAM(@C));
end;

// ---------- Редактирование ячейки ----------

function EditorProc(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
begin
  case Msg of
    WM_KEYDOWN:
      case wParam of
        VK_RETURN: begin PostMessageW(hSettings, WM_ENDEDIT, PtrUInt(Wnd), 1); Exit(0); end;
        VK_ESCAPE: begin PostMessageW(hSettings, WM_ENDEDIT, PtrUInt(Wnd), 0); Exit(0); end;
      end;
    WM_CHAR:
      if (wParam = VK_RETURN) or (wParam = VK_ESCAPE) then
        Exit(0);  // без системного «бипа»
  end;
  Result := CallWindowProcW(EditorOldProc, Wnd, Msg, wParam, lParam);
end;

procedure EndEdit(Commit: Boolean);
var
  Ed: HWND;
  Txt: UnicodeString;
  Sel: Integer;
begin
  if hEditor = 0 then
    Exit;
  Ed := hEditor;
  hEditor := 0;  // сбросить до DestroyWindow: потеря фокуса больше не сработает

  Sel := -1;
  Txt := '';
  if Commit then
  begin
    if (EdSub = COL_NAME) or (EdSub = COL_FILT) then
      Txt := TrimText(WindowText(Ed))
    else
      Sel := Integer(SendMessageW(Ed, CB_GETCURSEL, 0, 0));
  end;
  DestroyWindow(Ed);

  if (not Commit) or (EdItem < 0) or (EdItem >= Length(Work)) then
    Exit;

  case EdSub of
    COL_NAME:
      if Txt <> '' then
        Work[EdItem].Name := Txt;
    COL_CPU:
      if Sel >= 0 then Work[EdItem].Cpu := Sel;
    COL_IO:
      if Sel >= 0 then Work[EdItem].Io := Sel;
    COL_MEM:
      if Sel >= 0 then Work[EdItem].Mem := Sel;
    COL_FILT:
      Work[EdItem].MinMemMB := TextToInt(Txt, Work[EdItem].MinMemMB);
  end;
  if Work[EdItem].MinMemMB < 0 then
    Work[EdItem].MinMemMB := 0;
  RefreshRow(EdItem);
end;

procedure BeginEdit(Item, Sub: Integer);
var
  R: TRECT;
  Style: DWORD;
  I, Count, Cur: Integer;
begin
  EndEdit(True);
  if (Item < 0) or (Item >= Length(Work)) then
    Exit;

  R.left := LVIR_LABEL;
  R.top := Sub;
  if SendMessageW(hList, LVM_GETSUBITEMRECT, Item, LPARAM(@R)) = 0 then
    Exit;
  MapWindowPoints(hList, hSettings, @R, 2);

  EdItem := Item;
  EdSub := Sub;

  if (Sub = COL_NAME) or (Sub = COL_FILT) then
  begin
    Style := WS_CHILD or WS_VISIBLE or WS_BORDER or ES_AUTOHSCROLL;
    if Sub = COL_FILT then
      Style := Style or ES_NUMBER;
    hEditor := CreateWindowExW(0, 'EDIT', '', Style,
      R.left, R.top, R.right - R.left, R.bottom - R.top,
      hSettings, ID_EDITOR, HINSTANCE, nil);
    if hEditor = 0 then
      Exit;
    if Sub = COL_NAME then
      SetWindowTextW(hEditor, PWideChar(Work[Item].Name))
    else
      SetWindowTextW(hEditor, PWideChar(IntToText(Work[Item].MinMemMB)));
  end
  else
  begin
    hEditor := CreateWindowExW(0, 'COMBOBOX', '',
      WS_CHILD or WS_VISIBLE or WS_VSCROLL or CBS_DROPDOWNLIST,
      R.left, R.top, R.right - R.left, 200,
      hSettings, ID_EDITOR, HINSTANCE, nil);
    if hEditor = 0 then
      Exit;
    case Sub of
      COL_CPU:
        begin
          Count := Length(CpuCaptions);
          Cur := Work[Item].Cpu;
        end;
      COL_IO:
        begin
          Count := Length(IoCaptions);
          Cur := Work[Item].Io;
        end;
    else
      Count := Length(MemCaptions);
      Cur := Work[Item].Mem;
    end;
    for I := 0 to Count - 1 do
      case Sub of
        COL_CPU: SendMessageW(hEditor, CB_ADDSTRING, 0, LPARAM(PWideChar(CpuCaptions[I])));
        COL_IO:  SendMessageW(hEditor, CB_ADDSTRING, 0, LPARAM(PWideChar(IoCaptions[I])));
      else
        SendMessageW(hEditor, CB_ADDSTRING, 0, LPARAM(PWideChar(MemCaptions[I])));
      end;
    SendMessageW(hEditor, CB_SETCURSEL, Cur, 0);
  end;

  SetFont(hEditor);
  EditorOldProc := WNDPROC(SetWindowLongPtrW(hEditor, GWL_WNDPROC, LONG_PTR(@EditorProc)));
  SetFocus(hEditor);
  if (Sub = COL_NAME) or (Sub = COL_FILT) then
    SendMessageW(hEditor, EM_SETSEL, 0, -1)
  else
    SendMessageW(hEditor, CB_SHOWDROPDOWN, 1, 0);
end;

// ---------- Кнопки ----------

procedure OnAdd;
var
  R: TRule;
  Idx: Integer;
begin
  EndEdit(True);
  R.Name := 'process.exe';
  R.Cpu := 0;
  R.Io := 0;
  R.Mem := 0;
  R.MinMemMB := NewRuleMemMB;
  Idx := Length(Work);
  SetLength(Work, Idx + 1);
  Work[Idx] := R;
  InsertRow(Idx);
  SelectRow(Idx);
  BeginEdit(Idx, COL_NAME);
end;

procedure OnDelete;
var
  Idx, I: Integer;
begin
  EndEdit(True);
  Idx := Integer(SendMessageW(hList, LVM_GETNEXTITEM, High(WPARAM), LVNI_SELECTED));
  if (Idx < 0) or (Idx >= Length(Work)) then
    Exit;
  for I := Idx to High(Work) - 1 do
    Work[I] := Work[I + 1];
  SetLength(Work, Length(Work) - 1);
  SendMessageW(hList, LVM_DELETEITEM, Idx, 0);
  if Length(Work) > 0 then
  begin
    if Idx > High(Work) then
      Idx := High(Work);
    SelectRow(Idx);
  end;
end;

// Сдвиг выбранной строки на Delta (-1 вверх, +1 вниз): порядок строк — порядок применения правил
procedure OnMove(Delta: Integer);
var
  Idx, NewIdx: Integer;
  Tmp: TRule;
begin
  EndEdit(True);
  Idx := Integer(SendMessageW(hList, LVM_GETNEXTITEM, High(WPARAM), LVNI_SELECTED));
  NewIdx := Idx + Delta;
  if (Idx < 0) or (NewIdx < 0) or (NewIdx >= Length(Work)) then
    Exit;
  Tmp := Work[Idx];
  Work[Idx] := Work[NewIdx];
  Work[NewIdx] := Tmp;
  RefreshRow(Idx);
  RefreshRow(NewIdx);
  SelectRow(NewIdx);
end;

procedure OnOk;
var
  V: Integer;
begin
  EndEdit(True);
  V := TextToInt(TrimText(WindowText(hInterval)), IntervalSec);
  if V < 1 then
    V := 1;
  if V > MaxIntervalSec then
    V := MaxIntervalSec;

  Rules := Copy(Work);
  IntervalSec := V;
  if not (SaveRules and SaveIntervalSec) then
  begin
    MessageBoxW(hSettings, 'Не удалось сохранить настройки.', PWideChar(AppTitle),
      MB_OK or MB_ICONERROR);
    Exit;
  end;
  if Assigned(OnSettingsSaved) then
    OnSettingsSaved;
  DestroyWindow(hSettings);
end;

// ---------- Окно ----------

procedure AddTip(Tip, Target: HWND; const Text: UnicodeString);
var
  TI: TOOLINFOW;
begin
  FillChar(TI, SizeOf(TI), 0);
  // Без манифеста comctl32 v6 принимает структуру только до поля lParam (V2-размер)
  TI.cbSize := PtrUInt(@TI.lpReserved) - PtrUInt(@TI);
  TI.uFlags := TTF_IDISHWND or TTF_SUBCLASS;
  TI.hwnd := hSettings;
  TI.uId := UINT_PTR(Target);
  TI.lpszText := PWideChar(Text);
  SendMessageW(Tip, TTM_ADDTOOLW, 0, LPARAM(@TI));
end;

procedure CreateControls(Wnd: HWND);
var
  ICC: TINITCOMMONCONTROLSEX;
  Tip: HWND;
  I: Integer;
begin
  ICC.dwSize := SizeOf(ICC);
  ICC.dwICC := ICC_WIN95_CLASSES;
  InitCommonControlsEx(ICC);

  hList := CreateWindowExW(WS_EX_CLIENTEDGE, 'SysListView32', '',
    WS_CHILD or WS_VISIBLE or WS_TABSTOP or LVS_REPORT or LVS_SINGLESEL or LVS_SHOWSELALWAYS,
    0, 0, 0, 0, Wnd, ID_LIST, HINSTANCE, nil);
  SendMessageW(hList, LVM_SETEXTENDEDLISTVIEWSTYLE, 0, LVS_EX_FULLROWSELECT or LVS_EX_GRIDLINES);
  AddColumn(COL_NAME, 170, 'Имя процесса');
  AddColumn(COL_CPU,  130, 'Приоритет CPU');
  AddColumn(COL_IO,   110, 'Приоритет ввода-вывода');
  AddColumn(COL_MEM,  130, 'Приоритет памяти');
  AddColumn(COL_FILT, 200, 'Фильтр: память ≥ Мбайт (0 — любая)');

  hLabel := CreateWindowExW(0, 'STATIC', 'Интервал опроса:',
    WS_CHILD or WS_VISIBLE, 0, 0, 0, 0, Wnd, ID_LABEL, HINSTANCE, nil);
  hSec := CreateWindowExW(0, 'STATIC', 'сек.',
    WS_CHILD or WS_VISIBLE, 0, 0, 0, 0, Wnd, ID_SEC, HINSTANCE, nil);
  hInterval := CreateWindowExW(WS_EX_CLIENTEDGE, 'EDIT', '',
    WS_CHILD or WS_VISIBLE or WS_TABSTOP or ES_AUTOHSCROLL or ES_NUMBER,
    0, 0, 0, 0, Wnd, ID_INTERVAL, HINSTANCE, nil);
  hAdd := CreateWindowExW(0, 'BUTTON', '',
    WS_CHILD or WS_VISIBLE or WS_TABSTOP or BS_ICON, 0, 0, 0, 0, Wnd, ID_ADD, HINSTANCE, nil);
  hDel := CreateWindowExW(0, 'BUTTON', '',
    WS_CHILD or WS_VISIBLE or WS_TABSTOP or BS_ICON, 0, 0, 0, 0, Wnd, ID_DEL, HINSTANCE, nil);
  hUp := CreateWindowExW(0, 'BUTTON', '',
    WS_CHILD or WS_VISIBLE or WS_TABSTOP or BS_ICON, 0, 0, 0, 0, Wnd, ID_UP, HINSTANCE, nil);
  hDown := CreateWindowExW(0, 'BUTTON', '',
    WS_CHILD or WS_VISIBLE or WS_TABSTOP or BS_ICON, 0, 0, 0, 0, Wnd, ID_DOWN, HINSTANCE, nil);
  hIconPlus := CreatePlusIcon;
  hIconMinus := CreateMinusIcon;
  hIconUp := CreateUpIcon;
  hIconDown := CreateDownIcon;
  SendMessageW(hAdd, BM_SETIMAGE, IMAGE_ICON, LPARAM(hIconPlus));
  SendMessageW(hDel, BM_SETIMAGE, IMAGE_ICON, LPARAM(hIconMinus));
  SendMessageW(hUp, BM_SETIMAGE, IMAGE_ICON, LPARAM(hIconUp));
  SendMessageW(hDown, BM_SETIMAGE, IMAGE_ICON, LPARAM(hIconDown));

  Tip := CreateWindowExW(WS_EX_TOPMOST, PWideChar(TOOLTIPS_CLASSW), nil,
    WS_POPUP or TTS_ALWAYSTIP, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
    Wnd, 0, HINSTANCE, nil);
  AddTip(Tip, hAdd, TipAdd);
  AddTip(Tip, hDel, TipDel);
  AddTip(Tip, hUp, TipUp);
  AddTip(Tip, hDown, TipDown);
  hOk := CreateWindowExW(0, 'BUTTON', 'ОК',
    WS_CHILD or WS_VISIBLE or WS_TABSTOP or BS_DEFPUSHBUTTON, 0, 0, 0, 0, Wnd, ID_OK, HINSTANCE, nil);
  hCancel := CreateWindowExW(0, 'BUTTON', 'Отмена',
    WS_CHILD or WS_VISIBLE or WS_TABSTOP, 0, 0, 0, 0, Wnd, ID_CANCEL, HINSTANCE, nil);

  SetFont(hList);
  SetFont(hLabel);
  SetFont(hInterval);
  SetFont(hSec);
  SetFont(hAdd);
  SetFont(hDel);
  SetFont(hOk);
  SetFont(hCancel);

  SetWindowTextW(hInterval, PWideChar(IntToText(IntervalSec)));

  Work := Copy(Rules);
  for I := 0 to High(Work) do
    InsertRow(I);
end;

procedure Layout(W, H: Integer);
const
  M = 10;
  BtnW = 90;
  BtnH = 26;
  IcoBtn = 32;  // квадратные кнопки «+» и «−» над таблицей
var
  BarY, ListY, X: Integer;
begin
  // Сверху: «+» «−», затем «вверх» «вниз»
  MoveWindow(hAdd, M, M, IcoBtn, IcoBtn, True);
  MoveWindow(hDel, M + IcoBtn + 6, M, IcoBtn, IcoBtn, True);
  MoveWindow(hUp, M + 2 * (IcoBtn + 6) + 12, M, IcoBtn, IcoBtn, True);
  MoveWindow(hDown, M + 3 * (IcoBtn + 6) + 12, M, IcoBtn, IcoBtn, True);

  // Снизу: интервал слева, ОК/Отмена справа
  BarY := H - M - BtnH;
  ListY := M + IcoBtn + 8;
  MoveWindow(hList, M, ListY, W - 2 * M, BarY - M - ListY, True);
  MoveWindow(hLabel, M, BarY + 5, 105, 20, True);
  MoveWindow(hInterval, M + 108, BarY, 60, BtnH - 2, True);
  MoveWindow(hSec, M + 174, BarY + 5, 40, 20, True);

  X := W - M - BtnW;
  MoveWindow(hCancel, X, BarY, BtnW, BtnH, True);
  Dec(X, BtnW + 6);
  MoveWindow(hOk, X, BarY, BtnW, BtnH, True);
end;

procedure OnListDblClick(Info: PNMITEMACTIVATE);
var
  Hit: LVHITTESTINFO;
begin
  FillChar(Hit, SizeOf(Hit), 0);
  Hit.pt := Info^.ptAction;
  if Integer(SendMessageW(hList, LVM_SUBITEMHITTEST, 0, LPARAM(@Hit))) >= 0 then
    BeginEdit(Hit.iItem, Hit.iSubItem);
end;

function SettingsWndProc(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  Code: Integer;
begin
  case Msg of
    WM_CREATE:
      begin
        hSettings := Wnd;
        CreateControls(Wnd);
        Exit(0);
      end;
    WM_SIZE:
      begin
        Layout(LOWORD(lParam), HIWORD(lParam));
        Exit(0);
      end;
    WM_GETMINMAXINFO:
      begin
        PMINMAXINFO(lParam)^.ptMinTrackSize.x := 560;
        PMINMAXINFO(lParam)^.ptMinTrackSize.y := 240;
        Exit(0);
      end;
    WM_NOTIFY:
      if (HWND(PNMHdr(lParam)^.hwndFrom) = hList) and
         (Integer(PNMHdr(lParam)^.code) = NM_DBLCLK) then
      begin
        OnListDblClick(PNMITEMACTIVATE(lParam));
        Exit(0);
      end;
    WM_ENDEDIT:
      begin
        if HWND(wParam) = hEditor then
          EndEdit(lParam <> 0);
        Exit(0);
      end;
    WM_COMMAND:
      begin
        if (hEditor <> 0) and (HWND(lParam) = hEditor) then
        begin
          Code := HIWORD(wParam);
          if (EdSub = COL_NAME) or (EdSub = COL_FILT) then
          begin
            if Code = EN_KILLFOCUS then
              PostMessageW(Wnd, WM_ENDEDIT, PtrUInt(hEditor), 1);
          end
          else if (Code = CBN_SELENDOK) or (Code = CBN_KILLFOCUS) then
            PostMessageW(Wnd, WM_ENDEDIT, PtrUInt(hEditor), 1);
          Exit(0);
        end;
        if HIWORD(wParam) = BN_CLICKED then
          case LOWORD(wParam) of
            ID_ADD:    OnAdd;
            ID_DEL:    OnDelete;
            ID_UP:     OnMove(-1);
            ID_DOWN:   OnMove(1);
            ID_OK:     OnOk;
            ID_CANCEL: DestroyWindow(Wnd);
          end;
        Exit(0);
      end;
    WM_DESTROY:
      begin
        hEditor := 0;
        hSettings := 0;
        DestroyIcon(hIconPlus);
        DestroyIcon(hIconMinus);
        DestroyIcon(hIconUp);
        DestroyIcon(hIconDown);
        Exit(0);
      end;
  end;
  Result := DefWindowProcW(Wnd, Msg, wParam, lParam);
end;

function RegisterSettingsClass: Boolean;
var
  WC: WNDCLASSEXW;
begin
  FillChar(WC, SizeOf(WC), 0);
  WC.cbSize        := SizeOf(WC);
  WC.style         := CS_HREDRAW or CS_VREDRAW;
  WC.lpfnWndProc   := @SettingsWndProc;
  WC.hInstance     := HINSTANCE;
  WC.hIcon         := LoadAppIcon(GetSystemMetrics(SM_CXICON));    // Alt+Tab
  WC.hIconSm       := LoadAppIcon(GetSystemMetrics(SM_CXSMICON));  // заголовок окна
  WC.hCursor       := LoadCursor(0, IDC_ARROW);
  WC.hbrBackground := HBRUSH(COLOR_BTNFACE + 1);
  WC.lpszClassName := PWideChar(SettingsClass);
  Result := RegisterClassExW(@WC) <> 0;
end;

procedure ShowSettingsWindow;
begin
  if hSettings <> 0 then  // уже открыто — вынести на передний план
  begin
    ShowWindow(hSettings, SW_RESTORE);
    SetForegroundWindow(hSettings);
    Exit;
  end;
  if CreateWindowExW(0, PWideChar(SettingsClass), PWideChar(AppTitle),
       WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 820, 440,
       0, 0, HINSTANCE, nil) = 0 then
    Exit;
  ShowWindow(hSettings, SW_SHOWNORMAL);
  UpdateWindow(hSettings);
  SetForegroundWindow(hSettings);
end;

procedure CloseSettingsWindow;
begin
  if hSettings <> 0 then
    DestroyWindow(hSettings);
end;

end.
