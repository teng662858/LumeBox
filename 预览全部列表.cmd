@echo off
cd /d "%~dp0"
call C:\flutter\bin\flutter.bat run -d windows -t tool/lists_preview.dart
pause
