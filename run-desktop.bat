@echo off
cd /d "%~dp0"
if not exist node_modules (
  echo Installation des dependances du logiciel...
  call npm install
  if errorlevel 1 pause & exit /b 1
)
call npm start