@echo off
setlocal enabledelayedexpansion

set VCVARS="C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
set OUT_DIR=%~dp0bin
set IMGUI_DIR=%~dp0imgui
set IMGUI_VER=v1.91.6

if not exist %VCVARS% (
    echo [ERROR] vcvarsall.bat not found at %VCVARS%
    pause & exit /b 1
)

:: ── Download ImGui if missing ──────────────────────────────
if not exist "%IMGUI_DIR%\imgui.cpp" (
    echo [BUILD] Downloading ImGui %IMGUI_VER%...
    set IMGUI_ZIP=%TEMP%\imgui_%IMGUI_VER%.zip
    set IMGUI_TMP=%TEMP%\imgui_src
    powershell -Command "try { Invoke-WebRequest -Uri 'https://github.com/ocornut/imgui/archive/refs/tags/%IMGUI_VER%.zip' -OutFile '!IMGUI_ZIP!' } catch { exit 1 }" || (
        echo [ERROR] Failed to download ImGui. Check internet connection.
        pause & exit /b 1
    )
    powershell -Command "Expand-Archive -Path '!IMGUI_ZIP!' -DestinationPath '!IMGUI_TMP!' -Force"
    set IMGUI_EXTRACT=!IMGUI_TMP!\imgui-%IMGUI_VER:v=%
    if not exist "!IMGUI_EXTRACT!" (
        echo [ERROR] ImGui extraction failed
        pause & exit /b 1
    )
    if not exist "%IMGUI_DIR%" mkdir "%IMGUI_DIR%"
    copy /Y "!IMGUI_EXTRACT!\*.h"   "%IMGUI_DIR%\" >nul
    copy /Y "!IMGUI_EXTRACT!\*.cpp" "%IMGUI_DIR%\" >nul
    copy /Y "!IMGUI_EXTRACT!\backends\imgui_impl_dx12.h"   "%IMGUI_DIR%\" >nul
    copy /Y "!IMGUI_EXTRACT!\backends\imgui_impl_dx12.cpp" "%IMGUI_DIR%\" >nul
    copy /Y "!IMGUI_EXTRACT!\backends\imgui_impl_win32.h"   "%IMGUI_DIR%\" >nul
    copy /Y "!IMGUI_EXTRACT!\backends\imgui_impl_win32.cpp" "%IMGUI_DIR%\" >nul
    echo [BUILD] ImGui downloaded to %IMGUI_DIR%
)

:: ── Compile ────────────────────────────────────────────────
echo [BUILD] Setting up MSVC x64 environment...
call %VCVARS% x64 >nul 2>&1

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

echo [BUILD] Compiling version.dll (D3D12 + ImGui + Lua bridge)...

set IMGUI_SRCS=%IMGUI_DIR%\imgui.cpp %IMGUI_DIR%\imgui_draw.cpp %IMGUI_DIR%\imgui_widgets.cpp %IMGUI_DIR%\imgui_tables.cpp %IMGUI_DIR%\imgui_impl_dx12.cpp %IMGUI_DIR%\imgui_impl_win32.cpp

set MINHOOK_DIR=%~dp0minhook\src
set MINHOOK_SRCS=%MINHOOK_DIR%\buffer.c %MINHOOK_DIR%\hook.c %MINHOOK_DIR%\trampoline.c %MINHOOK_DIR%\hde\hde32.c %MINHOOK_DIR%\hde\hde64.c

cl.exe /nologo /O2 /EHsc /LD ^
    /I"%IMGUI_DIR%" ^
    /I"%~dp0minhook\include" ^
    /I"%~dp0minhook\src" ^
    /Fe:"%OUT_DIR%\version.dll" ^
    /Fo:"%OUT_DIR%\\" ^
    "%~dp0dllmain.cpp" ^
    %IMGUI_SRCS% ^
    %MINHOOK_SRCS% ^
    /link /DEF:"%~dp0version.def" ^
    kernel32.lib user32.lib gdi32.lib d3d12.lib dxgi.lib winhttp.lib

if %ERRORLEVEL% NEQ 0 (
    echo [FAILED] Compilation error
    pause & exit /b 1
)

echo.
echo [OK] Built: %OUT_DIR%\version.dll
echo.
echo Next step:
echo   Copy bin\version.dll to KingdomCome.exe directory ^(overwrite existing^)
echo   Launch the game
echo   Check kcd.log for: [AI NPC] ImGui overlay initialized
echo.
pause
endlocal
