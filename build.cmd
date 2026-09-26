@echo off
rem Builds PPControl.exe with Free Pascal from Lazarus (or fpc from PATH).
setlocal
set FPCDIR=C:\lazarus\fpc\3.2.2\bin\x86_64-win64
set FPC=%FPCDIR%\fpc.exe
set FPCRES=%FPCDIR%\fpcres.exe
if not exist "%FPC%" set FPC=fpc
if not exist "%FPCRES%" set FPCRES=fpcres

rem Resources: manifest (visual styles) and toolbar icons
cd /d "%~dp0res"
"%FPCRES%" -o resources.res -of res resources.rc
if errorlevel 1 exit /b 1

cd /d "%~dp0"
"%FPC%" -Fcutf8 -O2 -Xs PPControl.lpr
set RESULT=%errorlevel%

rem Cleanup of intermediate build files (also after a failed build)
del /q *.o *.ppu *.obj *.a 2>nul

if not %RESULT%==0 exit /b %RESULT%
echo Done: PPControl.exe

rem Archive with the ready program (committed to the repository instead of the exe)
powershell -NoProfile -Command "Compress-Archive -Path PPControl.exe -DestinationPath PPControl.zip -Force"
if errorlevel 1 exit /b 1
echo Done: PPControl.zip
