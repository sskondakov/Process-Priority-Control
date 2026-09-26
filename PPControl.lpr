program PPControl;

{$mode objfpc}{$H+}
{$codepage utf8}
{$apptype gui}

{$R res\resources.res}  // манифест (стиль comctl32 v6) и иконки; см. res\resources.rc

uses
  Windows, Messages, ShellAPI, AppStorage, SettingsWindow, AboutWindow, AppLog, PriorityEngine, ToolbarIcons;

const
  WM_TRAYICON = WM_USER + 1;
  TRAY_ID     = 1;
  TIMER_ID    = 1;

  CMD_SETTINGS  = 1001;
  CMD_AUTOSTART = 1002;
  CMD_EXIT      = 1003;
  CMD_ABOUT     = 1004;
  CMD_HISTORY   = 1005;

  AppName:   UnicodeString = 'Контроль приоритетов процессов';
  MainClass: UnicodeString = 'PPControlHiddenWindow';
  MutexName: UnicodeString = 'Local\PPControl_SingleInstance';

var
  WM_TASKBARCREATED: UINT;
  Nid: NOTIFYICONDATAW;
  MainWnd: HWND;
  TrayIcon: HICON;

// ---------- Трей ----------

// Подсказка иконки: название и последние события, сколько поместится (максимум 127 символов)
procedure UpdateTrayTip;
var
  Tip: UnicodeString;
begin
  Tip := TrayTipText(AppName, Length(Nid.szTip) - 1);
  if Tip = UnicodeString(PWideChar(@Nid.szTip[0])) then
    Exit;
  Nid.uFlags := NIF_TIP;
  lstrcpynW(@Nid.szTip[0], PWideChar(Tip), Length(Nid.szTip));
  Shell_NotifyIconW(NIM_MODIFY, @Nid);
end;

procedure AddTrayIcon(Wnd: HWND);
begin
  FillChar(Nid, SizeOf(Nid), 0);
  Nid.cbSize           := SizeOf(Nid);
  Nid.hWnd             := Wnd;
  Nid.uID              := TRAY_ID;
  Nid.uFlags           := NIF_ICON or NIF_MESSAGE or NIF_TIP;
  Nid.uCallbackMessage := WM_TRAYICON;
  if TrayIcon = 0 then
    TrayIcon := LoadAppIcon(GetSystemMetrics(SM_CXSMICON));
  Nid.hIcon            := TrayIcon;
  lstrcpynW(@Nid.szTip[0], PWideChar(TrayTipText(AppName, Length(Nid.szTip) - 1)), Length(Nid.szTip));
  Shell_NotifyIconW(NIM_ADD, @Nid);
end;

procedure RemoveTrayIcon;
begin
  Shell_NotifyIconW(NIM_DELETE, @Nid);
end;

// ---------- Таймер ----------

// Проход по процессам и обновление подсказки иконки
procedure RunRules;
begin
  ApplyRules;
  UpdateTrayTip;
end;

// (Пере)запуск таймера с текущим интервалом и немедленный проход по процессам
procedure RestartTimer;
begin
  SetTimer(MainWnd, TIMER_ID, UINT(IntervalSec) * 1000, nil);
  RunRules;
end;

procedure ShowTrayMenu(Wnd: HWND);
var
  Menu: HMENU;
  Pt: TPOINT;
  Flags: UINT;
begin
  Menu := CreatePopupMenu;
  AppendMenuW(Menu, MF_STRING, CMD_SETTINGS, 'Настройки');
  Flags := MF_STRING;
  if IsAutostartEnabled then
    Flags := Flags or MF_CHECKED;
  AppendMenuW(Menu, Flags, CMD_AUTOSTART, 'Автозагрузка');
  AppendMenuW(Menu, MF_SEPARATOR, 0, nil);
  AppendMenuW(Menu, MF_STRING, CMD_HISTORY, 'История работы');
  AppendMenuW(Menu, MF_STRING, CMD_ABOUT, 'О программе');
  AppendMenuW(Menu, MF_STRING, CMD_EXIT, 'Выход');
  SetMenuDefaultItem(Menu, CMD_SETTINGS, 0);

  GetCursorPos(Pt);
  SetForegroundWindow(Wnd);  // иначе меню не закрывается по клику вне него
  TrackPopupMenu(Menu, TPM_RIGHTBUTTON, Pt.X, Pt.Y, 0, Wnd, nil);
  PostMessageW(Wnd, WM_NULL, 0, 0);
  DestroyMenu(Menu);
end;

// ---------- Скрытое главное окно ----------

function MainWndProc(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
begin
  if Msg = WM_TASKBARCREATED then  // Explorer перезапущен — вернуть иконку
  begin
    AddTrayIcon(Wnd);
    Exit(0);
  end;

  case Msg of
    WM_TIMER:
      begin
        if wParam = TIMER_ID then
          RunRules;
        Exit(0);
      end;
    WM_TRAYICON:
      begin
        case lParam of
          WM_RBUTTONUP:     ShowTrayMenu(Wnd);
          WM_LBUTTONDBLCLK: ShowSettingsWindow;
        end;
        Exit(0);
      end;
    WM_COMMAND:
      begin
        case LOWORD(wParam) of
          CMD_SETTINGS:  ShowSettingsWindow;
          CMD_HISTORY:   OpenLogFile;
          CMD_ABOUT:     ShowAboutWindow(Wnd);
          CMD_AUTOSTART: SetAutostart(not IsAutostartEnabled);
          CMD_EXIT:      DestroyWindow(Wnd);
        end;
        Exit(0);
      end;
    WM_DESTROY:
      begin
        KillTimer(Wnd, TIMER_ID);
        CloseSettingsWindow;
        CloseAboutWindow;
        RemoveTrayIcon;
        PostQuitMessage(0);
        Exit(0);
      end;
  end;
  Result := DefWindowProcW(Wnd, Msg, wParam, lParam);
end;

function RegisterMainClass: Boolean;
var
  WC: WNDCLASSEXW;
begin
  FillChar(WC, SizeOf(WC), 0);
  WC.cbSize        := SizeOf(WC);
  WC.hInstance     := HINSTANCE;
  WC.lpfnWndProc   := @MainWndProc;
  WC.lpszClassName := PWideChar(MainClass);
  Result := RegisterClassExW(@WC) <> 0;
end;

var
  Wnd: HWND;
  M: TMSG;
  Mutex: THandle;

begin
  // Только один экземпляр
  Mutex := CreateMutexW(nil, True, PWideChar(MutexName));
  if GetLastError = ERROR_ALREADY_EXISTS then
    Halt(0);

  WM_TASKBARCREATED := RegisterWindowMessageW('TaskbarCreated');

  // Первый запуск — прописаться в автозагрузку, дальше выбор за пользователем
  if not IsFirstRunDone then
  begin
    SetAutostart(True);
    MarkFirstRunDone;
  end;

  LoadSettings;

  if not (RegisterMainClass and RegisterSettingsClass and RegisterAboutClass) then
    Halt(1);

  Wnd := CreateWindowExW(WS_EX_TOOLWINDOW, PWideChar(MainClass), PWideChar(AppName),
    WS_POPUP, 0, 0, 0, 0, 0, 0, HINSTANCE, nil);
  if Wnd = 0 then
    Halt(1);

  MainWnd := Wnd;
  AddTrayIcon(Wnd);
  OnSettingsSaved := @RestartTimer;
  RestartTimer;

  while GetMessageW(M, 0, 0, 0) do
  begin
    if not IsAboutDialogMessage(M) then  // Esc/Enter/Tab в окне «О программе»
    begin
      TranslateMessage(M);
      DispatchMessageW(M);
    end;
  end;

  if TrayIcon <> 0 then
    DestroyIcon(TrayIcon);
  CloseHandle(Mutex);
  Halt(M.wParam);
end.
