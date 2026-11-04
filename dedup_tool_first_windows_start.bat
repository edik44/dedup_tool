@echo off
rem dedup_tool_first_windows_start.bat - the first start of dedup_tool.sh on Windows.
rem The script runs in Git Bash, so this file checks for Git for Windows; if it is
rem missing, offers to install it with winget or to open the download page; then
rem runs the script in this folder (arguments go to it as they are). Put it next
rem to dedup_tool.sh in the folder with your dictionaries and double-click it.
rem Once Git is there, a double click on the script itself works as well.
rem The script: dedup_tool.sh, otherwise the newest dedup_tool_vX.Y.Z.sh here.
rem For tests: DEDUP_TEST_NOGIT=1 - as if Git is not installed (winget and the
rem browser are not started, the commands are printed), DEDUP_TEST_NOWINGET=1 -
rem as if there is no winget, DEDUP_TEST_NOWSL=1 - as if there is no WSL,
rem DEDUP_TEST_SHASSOC=<ProgId> - what .sh files open with.
rem Keep this file with CRLF line ends and without BOM.
setlocal EnableExtensions DisableDelayedExpansion

rem The messages are UTF-8: switch the console to it, restore the old page later.
set "DT_CP="
for /f "tokens=2 delims=:" %%a in ('chcp') do set "DT_CP=%%a"
if not defined DT_CP goto cp_done
set "DT_CP=%DT_CP: =%"
set "DT_CP=%DT_CP:.=%"
chcp 65001 >nul 2>&1
:cp_done

rem Started by a double click (cmd /c): keep the window open after an error.
set "DT_DBL="
set "DT_CL=%cmdcmdline:"=%"
if /i not "%DT_CL:/c =%"=="%DT_CL%" set "DT_DBL=1"

set "DT_RC=0"
pushd "%~dp0" || (set "DT_RC=1" & goto end)

rem Language: --lang, DEDUP_LANG, then the Windows display language.
set "DT_L="
if /i "%~1"=="--lang" set "DT_L=%~2"
if not defined DT_L set "DT_L=%DEDUP_LANG%"
if not defined DT_L set "DT_L=%DEDUP_TEST_WINLANG%"
if not defined DT_L for /f "tokens=1,2,*" %%a in ('reg query "HKCU\Control Panel\Desktop" /v PreferredUILanguages 2^>nul') do if /i "%%a"=="PreferredUILanguages" set "DT_L=%%c"
if not defined DT_L for /f "tokens=1,2,*" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Nls\Language" /v InstallLanguage 2^>nul') do if /i "%%a"=="InstallLanguage" if "%%c"=="0419" (set "DT_L=ru") else set "DT_L=en"
if not defined DT_L for /f "tokens=1,2,*" %%a in ('reg query "HKCU\Control Panel\International" /v LocaleName 2^>nul') do if /i "%%a"=="LocaleName" set "DT_L=%%c"
if not defined DT_L set "DT_L=en"
set "DT_RU="
if /i "%DT_L:~0,2%"=="ru" set "DT_RU=1"
if defined DT_RU goto msg_ru

set "T_NOSCRIPT1=dedup_tool.sh was not found next to %~nx0."
set "T_NOSCRIPT2=Put both files into one folder, the one with your dictionaries."
set "T_NOGIT1=Git for Windows was not found."
set "T_NOGIT2=The script runs in Git Bash: bash and the sort, grep, sed and iconv tools"
set "T_NOGIT3=it uses come with Git for Windows. It is free."
set "T_WSL1=Dictionaries up to about 1 GB are fine in Git Bash. Bigger ones are faster in"
set "T_WSL2=WSL, and you have it: open a terminal in this folder and type: wsl bash"
set "T_WINGET=It can be installed now with winget; Windows will ask for administrator rights."
set "T_ASKW=Install Git for Windows now?"
set "T_INST=Installing Git for Windows with winget..."
set "T_OK=Git for Windows is installed."
set "T_RUN=- starting"
set "T_ONCE=From now on this file is not needed: you can double-click the script itself."
set "T_FAIL=Installing with winget failed, code"
set "T_NOTFOUND=Git for Windows is installed, but bash was not found. Close this window and run %~nx0 again."
set "T_URL=Download Git for Windows: https://git-scm.com/download/win"
set "T_ASKP=Open this page in the browser?"
set "T_AFTER=Install it - the default settings are fine - and run %~nx0 again."
set "T_LATER=OK. When Git for Windows is installed, run %~nx0 again."
set "T_YN=Type Y or N"
goto msg_done

:msg_ru
set "T_NOSCRIPT1=Рядом с %~nx0 нет скрипта dedup_tool.sh."
set "T_NOSCRIPT2=Положите оба файла в одну папку — в ту, где лежат словари."
set "T_NOGIT1=Git for Windows не найден."
set "T_NOGIT2=Скрипт работает в Git Bash: bash и утилиты sort, grep, sed, iconv, которыми"
set "T_NOGIT3=он пользуется, ставятся вместе с Git for Windows. Он бесплатный."
set "T_WSL1=Словари примерно до 1 ГБ удобно обрабатывать и в Git Bash. С большими быстрее"
set "T_WSL2=WSL, он у вас есть: откройте терминал в этой папке и наберите: wsl bash"
set "T_WINGET=Его можно установить сейчас через winget — Windows спросит разрешение администратора."
set "T_ASKW=Установить Git for Windows сейчас?"
set "T_INST=Устанавливаю Git for Windows через winget..."
set "T_OK=Git for Windows установлен."
set "T_RUN=— запускаю"
set "T_ONCE=Дальше этот файл не нужен: скрипт можно запускать двойным нажатием на него самого."
set "T_FAIL=Установить через winget не получилось, код"
set "T_NOTFOUND=Git for Windows установлен, но bash не найден. Закройте окно и запустите %~nx0 снова."
set "T_URL=Скачать Git for Windows: https://git-scm.com/download/win"
set "T_ASKP=Открыть эту страницу в браузере?"
set "T_AFTER=Установите его — настройки по умолчанию подходят — и запустите %~nx0 снова."
set "T_LATER=Хорошо. Когда установите Git for Windows, запустите %~nx0 снова."
set "T_YN=Введите Y или N"
:msg_done

rem The script: dedup_tool.sh, otherwise the newest dedup_tool_vX.Y.Z.sh.
set "DT_SCRIPT="
set "DT_BEST=-1"
if exist "dedup_tool.sh" set "DT_SCRIPT=dedup_tool.sh"
if not defined DT_SCRIPT for %%f in (dedup_tool_v*.sh) do call :ver "%%~nxf"
if defined DT_SCRIPT goto have_script
echo(
echo(%T_NOSCRIPT1%
echo(%T_NOSCRIPT2%
set "DT_RC=1"
goto end
:have_script

call :find_git
if defined DT_BASH goto run

rem No Git for Windows: offer winget, otherwise the download page.
set "DT_WINGET="
if not defined DEDUP_TEST_NOWINGET for /f "delims=" %%w in ('where winget.exe 2^>nul') do if not defined DT_WINGET set "DT_WINGET=%%w"
set "DT_WSL="
if not defined DEDUP_TEST_NOWSL for /f "tokens=1,2,*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss" /s /v DistributionName 2^>nul') do if /i "%%a"=="DistributionName" if /i not "%%c"=="docker-desktop" if /i not "%%c"=="docker-desktop-data" set "DT_WSL=1"
echo(
echo(%T_NOGIT1%
echo(%T_NOGIT2%
echo(%T_NOGIT3%
if not defined DT_WSL goto nogit_wsl_done
echo(
echo(%T_WSL1%
echo(%T_WSL2% %DT_SCRIPT%
:nogit_wsl_done
echo(
if not defined DT_WINGET goto page
echo(%T_WINGET%
call :ask "%T_ASKW%"
if not defined DT_YES goto later
echo(
echo(%T_INST%
if defined DEDUP_TEST_NOGIT goto winget_test
"%DT_WINGET%" install --id Git.Git -e --source winget
set "DT_WRC=%errorlevel%"
goto winget_done
:winget_test
echo [test] winget install --id Git.Git -e --source winget
set "DT_WRC=0"
:winget_done
set "DT_AFTER=1"
call :find_git
if not defined DT_BASH goto winget_bad
echo(
echo(%T_OK%
goto run
:winget_bad
echo(
if "%DT_WRC%"=="0" goto winget_nobash
echo(%T_FAIL% %DT_WRC%.
goto page
:winget_nobash
echo(%T_NOTFOUND%
set "DT_RC=1"
goto end

:page
echo(%T_URL%
call :ask "%T_ASKP%"
if not defined DT_YES goto page_done
if defined DEDUP_TEST_NOGIT goto page_test
start "" "https://git-scm.com/download/win"
goto page_done
:page_test
echo [test] start https://git-scm.com/download/win
:page_done
echo(%T_AFTER%
set "DT_RC=1"
goto end

:later
echo(%T_LATER%
echo(%T_URL%
set "DT_RC=1"
goto end

:run
call :sh_assoc
echo(Git for Windows: %DT_GITDIR% %T_RUN% %DT_SCRIPT%
if defined DT_SHOK echo(%T_ONCE%
if defined DT_CP chcp %DT_CP% >nul 2>&1
"%DT_BASH%" "%DT_SCRIPT%" %*
set "DT_RC=%errorlevel%"

:end
if defined DT_CP chcp %DT_CP% >nul 2>&1
popd
if defined DT_DBL if not "%DT_RC%"=="0" pause
exit /b %DT_RC%

rem ---- subroutines ----

rem The newest dedup_tool_vX.Y.Z.sh: X*1000000 + Y*1000 + Z.
:ver
set "DT_N=%~n1"
set "DT_N=%DT_N:*_v=%"
set "DT_K=-1"
for /f "tokens=1-3 delims=." %%a in ("%DT_N%") do set /a "DT_K=%%a*1000000+%%b*1000+%%c" 2>nul
if %DT_K% gtr %DT_BEST% (set "DT_BEST=%DT_K%" & set "DT_SCRIPT=%~nx1")
exit /b 0

rem Git for Windows: registry, the usual folders, git.exe in PATH. Not the bash.exe
rem of WSL: only <Git>\bin\bash.exe next to <Git>\usr\bin\sort.exe.
:find_git
set "DT_BASH="
if defined DEDUP_TEST_NOGIT if not defined DT_AFTER exit /b 0
for %%k in ("HKLM\SOFTWARE\GitForWindows" "HKCU\SOFTWARE\GitForWindows" "HKLM\SOFTWARE\WOW6432Node\GitForWindows") do for /f "tokens=1,2,*" %%a in ('reg query "%%~k" /v InstallPath 2^>nul') do if /i "%%a"=="InstallPath" call :try_git "%%c"
for %%k in ("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1" "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1" "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1") do for /f "tokens=1,2,*" %%a in ('reg query "%%~k" /v InstallLocation 2^>nul') do if /i "%%a"=="InstallLocation" call :try_git "%%c"
for %%d in ("%ProgramW6432%\Git" "%ProgramFiles%\Git" "%ProgramFiles(x86)%\Git" "%LocalAppData%\Programs\Git" "%USERPROFILE%\scoop\apps\git\current") do call :try_git "%%~d"
for /f "delims=" %%i in ('where git.exe 2^>nul') do (call :try_git "%%~dpi.." & call :try_git "%%~dpi..\..")
exit /b 0

:try_git
if defined DT_BASH exit /b 0
if "%~1"=="" exit /b 0
set "DT_R="
for %%p in ("%~1") do set "DT_R=%%~fp"
if not defined DT_R exit /b 0
if "%DT_R:~-1%"=="\" set "DT_R=%DT_R:~0,-1%"
if exist "%DT_R%\bin\bash.exe" if exist "%DT_R%\usr\bin\sort.exe" (set "DT_BASH=%DT_R%\bin\bash.exe" & set "DT_GITDIR=%DT_R%")
exit /b 0

rem Does a double click on a .sh file open Git Bash (Git's sh_auto_file)? A choice
rem made in "Open with" (UserChoice, UserChoiceLatest) wins over assoc.
:sh_assoc
set "DT_SHOK="
set "DT_SHPROG="
for /f "tokens=2 delims==" %%a in ('assoc .sh 2^>nul') do set "DT_SHPROG=%%a"
for %%k in (UserChoice UserChoiceLatest) do for /f "tokens=1,2,*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.sh\%%k" /v ProgId 2^>nul') do if /i "%%a"=="ProgId" set "DT_SHPROG=%%c"
if defined DEDUP_TEST_SHASSOC set "DT_SHPROG=%DEDUP_TEST_SHASSOC%"
if /i "%DT_SHPROG%"=="sh_auto_file" set "DT_SHOK=1"
exit /b 0

rem A [Y/n] question; DT_YES=1 for yes. Enter (or the end of input) is yes. The
rem question is printed in UTF-8, the answer is read in the old code page: with
rem 65001 some consoles give an empty line for non-Latin letters.
:ask
set "DT_YES="
:ask_again
set "DT_ANS="
<nul set /p "=%~1 [Y/n] "
if defined DT_CP chcp %DT_CP% >nul 2>&1
set /p "DT_ANS="
if defined DT_CP chcp 65001 >nul 2>&1
if not defined DT_ANS (set "DT_YES=1" & exit /b 0)
set "DT_ANS=%DT_ANS:"=%"
if not defined DT_ANS goto ask_bad
if /i "%DT_ANS:~0,1%"=="y" (set "DT_YES=1" & exit /b 0)
if /i "%DT_ANS:~0,1%"=="n" exit /b 0
:ask_bad
echo(%T_YN%
goto ask_again
