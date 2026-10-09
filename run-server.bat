@echo off
cd /d "%~dp0"
echo Yurei - apercu local sur http://127.0.0.1:8765
py -3 -m http.server 8765 --bind 127.0.0.1 --directory site
if errorlevel 1 (
  echo Python 3 est requis. Installe Python 3 puis relance ce fichier.
  pause
)
