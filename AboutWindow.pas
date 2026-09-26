unit AboutWindow;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Windows;

function RegisterAboutClass: Boolean;
// Owner — скрытое главное окно: с владельцем у окна нет кнопки в панели задач
procedure ShowAboutWindow(Owner: HWND);
procedure CloseAboutWindow;
// Для цикла сообщений: Esc, Enter и Tab работают как в диалоге. True — сообщение обработано.
function IsAboutDialogMessage(var Msg: TMSG): Boolean;

implementation

uses
  CommCtrl, ShellAPI, ToolbarIcons;

type
  // Уведомление SysLink (NMLINK/LITEM из commctrl.h)
  TLinkItem = record
    mask: UINT;
    iLink: Integer;
    state: UINT;
    stateMask: UINT;
    szID: array[0..47] of WideChar;
    szUrl: array[0..2083] of WideChar;
  end;
  TNMLink = record
    hdr: TNMHdr;
    item: TLinkItem;
  end;
  PNMLink = ^TNMLink;

const
  AboutClass: UnicodeString = 'PPControlAboutWindow';
  AboutTitle: UnicodeString = 'О программе';

  AppNameText: UnicodeString = 'Контроль приоритетов процессов';  // жирным

  // Текст: обычные строки, затем строки со ссылками (префикс обычным шрифтом,
  // кликабельно только название). Число строк используется в расчёте раскладки.
  BodyBefore: UnicodeString =
    'Версия 1.0 (26.09.2026)'#13#10 +
    #13#10 +
    'Программа для автоматической установки приоритетов процессов.'#13#10 +
    #13#10;
  LinesBefore = 4;
  LinkLines   = 6;  // постановка, Lazarus, иконка, код, Free Pascal, описание
  GapLines    = 3;  // пустые строки между четырьмя группами ссылок

  AuthorUrl: UnicodeString = 'mailto:sergei.s.kondakov@gmail.com';
  ClaudeUrl: UnicodeString = 'https://claude.com/';

  LazarusVersion = '3.2';
  LazarusUrl: UnicodeString = 'https://www.lazarus-ide.org/';
  FpcUrl: UnicodeString = 'https://www.freepascal.org/';
  LinkPrefix: UnicodeString = 'Иконка приложения: ';
  LinkCaption: UnicodeString = 'surang - Flaticon';
  LinkUrl: UnicodeString = 'https://www.flaticon.com/ru/free-icon/checking_3852607';

  ClientW = 460;
  BtnW    = 90;
  BtnH    = 26;
  Margin  = 12;
  Pad     = 10;  // отступ текста от рамки

  ICC_LINK = $00008000;  // класс SysLink (comctl32 v6)

var
  hAbout: HWND = 0;
  hBoldFont: HFONT = 0;
  TextH: Integer = 13;    // высота строки обычного шрифта
  ClientH: Integer = 260; // считается в MeasureLayout

function FrameHeight: Integer;
begin
  // заголовок + обычный текст + строки со ссылками + пустая строка
  Result := Pad + (TextH + 2) + (LinesBefore + LinkLines + GapLines) * TextH + Pad + 2;
end;

procedure MeasureLayout;
var
  DC: HDC;
  Old: HGDIOBJ;
  TM: TEXTMETRICW;
begin
  DC := GetDC(0);
  Old := SelectObject(DC, GetStockObject(DEFAULT_GUI_FONT));
  GetTextMetricsW(DC, @TM);
  SelectObject(DC, Old);
  ReleaseDC(0, DC);
  TextH := TM.tmHeight;
  ClientH := Margin + FrameHeight + Margin + BtnH + Margin;
end;

function NewStatic(Wnd: HWND; const Text: UnicodeString; X, Y, W, H: Integer; Font: HFONT): HWND;
begin
  Result := CreateWindowExW(0, 'STATIC', PWideChar(Text),
    WS_CHILD or WS_VISIBLE or SS_LEFT or SS_NOPREFIX, X, Y, W, H, Wnd, 0, HINSTANCE, nil);
  SendMessageW(Result, WM_SETFONT, PtrUInt(Font), 1);
end;

// Ширина текста в обычном шрифте — чтобы кликабельная область ссылки не растягивалась на всё окно
function TextWidth(Font: HFONT; const Text: UnicodeString): Integer;
var
  DC: HDC;
  Old: HGDIOBJ;
  Sz: TSIZE;
begin
  DC := GetDC(0);
  Old := SelectObject(DC, Font);
  GetTextExtentPoint32W(DC, PWideChar(Text), Length(Text), @Sz);
  SelectObject(DC, Old);
  ReleaseDC(0, DC);
  Result := Sz.cx;
end;

// Строка «Префикс: <ссылка>»; кликабельна только ссылка
procedure AddLinkLine(Wnd: HWND; Font: HFONT; X, Y: Integer;
  const Prefix, Caption, Url: UnicodeString);
var
  Link: HWND;
begin
  Link := CreateWindowExW(0, 'SysLink',
    PWideChar(Prefix + '<a href="' + Url + '">' + Caption + '</a>'),
    WS_CHILD or WS_VISIBLE or WS_TABSTOP, X, Y,
    TextWidth(Font, Prefix + Caption) + 4, TextH + 2, Wnd, 0, HINSTANCE, nil);
  SendMessageW(Link, WM_SETFONT, PtrUInt(Font), 1);
end;

procedure CreateContent(Wnd: HWND);
var
  Std: HFONT;
  LF: LOGFONTW;
  ICC: TINITCOMMONCONTROLSEX;
  Btn: HWND;
  X, Y, W: Integer;
begin
  ICC.dwSize := SizeOf(ICC);
  ICC.dwICC := ICC_LINK;
  InitCommonControlsEx(ICC);

  Std := HFONT(GetStockObject(DEFAULT_GUI_FONT));
  GetObjectW(Std, SizeOf(LF), @LF);
  LF.lfWeight := FW_BOLD;
  hBoldFont := CreateFontIndirectW(LF);

  // Тонкая рамка, внутри неё — текст, прижатый к левому краю
  CreateWindowExW(0, 'STATIC', nil, WS_CHILD or WS_VISIBLE or SS_ETCHEDFRAME,
    Margin, Margin, ClientW - 2 * Margin, FrameHeight, Wnd, 0, HINSTANCE, nil);

  X := Margin + Pad;
  W := ClientW - 2 * (Margin + Pad);
  Y := Margin + Pad;

  NewStatic(Wnd, AppNameText, X, Y, W, TextH + 2, hBoldFont);
  Inc(Y, TextH + 2);

  NewStatic(Wnd, BodyBefore, X, Y, W, LinesBefore * TextH + 2, Std);
  Inc(Y, LinesBefore * TextH);

  // Ссылки открываются в браузере по умолчанию (см. WM_NOTIFY)
  AddLinkLine(Wnd, Std, X, Y, 'Постановка и отладка: ', 'Сергей Кондаков', AuthorUrl);
  Inc(Y, TextH + TextH);
  AddLinkLine(Wnd, Std, X, Y, 'Иконки кнопок: ', 'Lazarus ' + LazarusVersion, LazarusUrl);
  Inc(Y, TextH);
  AddLinkLine(Wnd, Std, X, Y, LinkPrefix, LinkCaption, LinkUrl);
  Inc(Y, TextH + TextH);
  AddLinkLine(Wnd, Std, X, Y, 'Генерация кода: ', 'Claude Sonnet 5 от Anthropic', ClaudeUrl);
  Inc(Y, TextH);
  AddLinkLine(Wnd, Std, X, Y, 'Компилятор: ', 'Free Pascal ' + {$I %FPCVERSION%}, FpcUrl);
  Inc(Y, TextH + TextH);
  AddLinkLine(Wnd, Std, X, Y, 'Генерация описания: ', 'Claude Sonnet 5 от Anthropic', ClaudeUrl);

  Btn := CreateWindowExW(0, 'BUTTON', 'ОК',
    WS_CHILD or WS_VISIBLE or WS_TABSTOP or BS_DEFPUSHBUTTON,
    (ClientW - BtnW) div 2, ClientH - Margin - BtnH, BtnW, BtnH,
    Wnd, IDOK, HINSTANCE, nil);
  SendMessageW(Btn, WM_SETFONT, PtrUInt(Std), 1);
end;

// Открывает только веб-ссылки и почтовые адреса; адрес берётся из href нажатой ссылки
procedure OpenLink(Wnd: HWND; const Url: UnicodeString);
begin
  if (Copy(Url, 1, 8) = 'https://') or (Copy(Url, 1, 7) = 'mailto:') then
    ShellExecuteW(Wnd, 'open', PWideChar(Url), nil, nil, SW_SHOWNORMAL);
end;

function AboutWndProc(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
begin
  case Msg of
    WM_CREATE:
      begin
        CreateContent(Wnd);
        Exit(0);
      end;
    WM_NOTIFY:
      // Клик мышью или Enter по ссылке SysLink
      if (Integer(PNMHdr(lParam)^.code) = NM_CLICK) or (Integer(PNMHdr(lParam)^.code) = NM_RETURN) then
      begin
        OpenLink(Wnd, PNMLink(lParam)^.item.szUrl);
        Exit(0);
      end;
    WM_COMMAND:
      begin
        // IDOK — кнопка или Enter, IDCANCEL — Esc (их шлёт IsDialogMessage)
        if (LOWORD(wParam) = IDOK) or (LOWORD(wParam) = IDCANCEL) then
          DestroyWindow(Wnd);
        Exit(0);
      end;
    WM_DESTROY:
      begin
        hAbout := 0;
        if hBoldFont <> 0 then
          DeleteObject(hBoldFont);
        hBoldFont := 0;
        Exit(0);
      end;
  end;
  Result := DefWindowProcW(Wnd, Msg, wParam, lParam);
end;

function RegisterAboutClass: Boolean;
var
  WC: WNDCLASSEXW;
begin
  FillChar(WC, SizeOf(WC), 0);
  WC.cbSize        := SizeOf(WC);
  WC.style         := CS_HREDRAW or CS_VREDRAW;
  WC.lpfnWndProc   := @AboutWndProc;
  WC.hInstance     := HINSTANCE;
  WC.hIcon         := LoadAppIcon(GetSystemMetrics(SM_CXICON));
  WC.hIconSm       := LoadAppIcon(GetSystemMetrics(SM_CXSMICON));  // значок в заголовке
  WC.hCursor       := LoadCursor(0, IDC_ARROW);
  WC.hbrBackground := HBRUSH(COLOR_BTNFACE + 1);
  WC.lpszClassName := PWideChar(AboutClass);
  Result := RegisterClassExW(@WC) <> 0;
end;

procedure ShowAboutWindow(Owner: HWND);
const
  Style   = WS_POPUP or WS_CAPTION or WS_SYSMENU;
  ExStyle = 0;  // без WS_EX_DLGMODALFRAME рамка тонкая (WS_CAPTION включает WS_BORDER)
var
  R: TRECT;
  W, H: Integer;
begin
  if hAbout <> 0 then  // уже открыто — вынести на передний план
  begin
    SetForegroundWindow(hAbout);
    Exit;
  end;
  MeasureLayout;
  // Внешний размер считаем от нужного размера клиентской области
  R.left := 0;
  R.top := 0;
  R.right := ClientW;
  R.bottom := ClientH;
  AdjustWindowRectEx(R, Style, False, ExStyle);
  W := R.right - R.left;
  H := R.bottom - R.top;

  hAbout := CreateWindowExW(ExStyle, PWideChar(AboutClass), PWideChar(AboutTitle), Style,
    (GetSystemMetrics(SM_CXSCREEN) - W) div 2, (GetSystemMetrics(SM_CYSCREEN) - H) div 2,
    W, H, Owner, 0, HINSTANCE, nil);
  if hAbout = 0 then
    Exit;
  ShowWindow(hAbout, SW_SHOWNORMAL);
  UpdateWindow(hAbout);
  SetForegroundWindow(hAbout);
  SetFocus(GetDlgItem(hAbout, IDOK));
end;

procedure CloseAboutWindow;
begin
  if hAbout <> 0 then
    DestroyWindow(hAbout);
end;

function IsAboutDialogMessage(var Msg: TMSG): Boolean;
begin
  Result := (hAbout <> 0) and IsDialogMessageW(hAbout, Msg);
end;

end.
