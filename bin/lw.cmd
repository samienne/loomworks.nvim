@echo off
rem loomworks launcher `lw` (Windows).
rem
rem Stage: dev / nvim-hosted. Resolves the loomworks home (a checkout or an
rem installed dist) and runs the CLI under headless Neovim. The standalone
rem luvi + shim runtime slots into the marked RUNTIME section later without
rem changing this interface (`lw build`, `lw profiles`, ...).
rem
rem Home resolution: %LOOMWORKS_HOME% if set, else the parent of this
rem script's directory (works when bin\ is on PATH).
setlocal EnableExtensions

if not defined LOOMWORKS_HOME (
  for %%I in ("%~dp0..") do set "LOOMWORKS_HOME=%%~fI"
)

set "CLI=%LOOMWORKS_HOME%\lua\loomworks\cli.lua"
if not exist "%CLI%" (
  echo lw: cannot find the CLI at "%CLI%" 1>&2
  echo lw: set LOOMWORKS_HOME to your loomworks.nvim checkout or dist 1>&2
  exit /b 1
)

rem --- RUNTIME (dev: headless Neovim; later: luvi + vim shim) ---------------
where nvim >nul 2>nul
if errorlevel 1 (
  echo lw: nvim not found on PATH ^(required by the current dev launcher^) 1>&2
  exit /b 1
)

nvim --headless -u NONE -l "%CLI%" %*
exit /b %ERRORLEVEL%
