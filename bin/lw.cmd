@echo off
rem loomworks launcher `lw` (Windows).
rem
rem Resolves the loomworks home (a checkout or an installed dist) and runs the
rem CLI. It prefers the standalone luvi host (no Neovim); if luvi isn't
rem available it falls back to headless Neovim. The `lw <cmd>` interface is
rem identical either way.
rem
rem Home resolution: %LOOMWORKS_HOME%, else the parent of this script's dir.
rem luvi resolution: %LW_LUVI%, else `luvi` on PATH.
setlocal EnableExtensions

if not defined LOOMWORKS_HOME (
  for %%I in ("%~dp0..") do set "LOOMWORKS_HOME=%%~fI"
)

set "LUA_DIR=%LOOMWORKS_HOME%\lua"
set "CLI=%LUA_DIR%\loomworks\cli.lua"
if not exist "%CLI%" (
  echo lw: cannot find the CLI at "%CLI%" 1>&2
  echo lw: set LOOMWORKS_HOME to your loomworks.nvim checkout or dist 1>&2
  exit /b 1
)

rem Put the console into UTF-8 so diagnostic text (em dashes, arrows) renders
rem correctly; restore the previous code page on the way out.
set "LW_OLDCP="
for /f "tokens=2 delims=:" %%C in ('chcp') do set "LW_OLDCP=%%C"
set "LW_OLDCP=%LW_OLDCP: =%"
chcp 65001 >nul

rem --- RUNTIME: prefer standalone luvi (no Neovim), else headless Neovim ----
set "LUVI=%LW_LUVI%"
if defined LUVI goto runluvi
for /f "delims=" %%L in ('where luvi 2^>nul') do set "LUVI=%%L"
if defined LUVI goto runluvi
goto runnvim

:runluvi
set "LW_LUA=%LUA_DIR%"
set "LW_ROOT=%CD%"
pushd "%LUA_DIR%"
"%LUVI%" . --main loomworks/cli_main.lua -- %*
set "RC=%ERRORLEVEL%"
popd
goto done

:runnvim
where nvim >nul 2>nul
if errorlevel 1 (
  echo lw: neither luvi nor nvim found ^(set LW_LUVI, or install one^) 1>&2
  set "RC=1"
  goto done
)
nvim --headless -u NONE -l "%CLI%" %*
set "RC=%ERRORLEVEL%"
goto done

:done
if defined LW_OLDCP chcp %LW_OLDCP% >nul
exit /b %RC%
