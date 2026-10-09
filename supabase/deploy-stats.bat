@echo off
setlocal
cd /d "%~dp0.."
where supabase >nul 2>nul
if errorlevel 1 (
  echo Supabase CLI introuvable. Installe-le puis connecte-toi avec: supabase login
  pause
  exit /b 1
)
call supabase functions deploy yurei-stats --project-ref dziwedssqmojnhbsjslz
if errorlevel 1 pause & exit /b 1
echo Fonction yurei-stats mise a jour sur Supabase.
pause
