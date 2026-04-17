@echo off
title Master Electronics — Developer Setup Guide
color 0A

echo.
echo  Starting Developer Setup Guide...
echo  (Close this window at any time to exit)
echo.

:: Change to the chatbot directory so relative requires work
cd /d "%~dp0"

:: Install dependencies if node_modules is missing (should already be done by IT)
if not exist node_modules (
    echo  Installing dependencies — this only happens once...
    call npm install --no-fund --no-audit
    echo.
)

:: Run the chatbot
node index.js

echo.
echo  Setup guide exited. Press any key to close this window.
pause > nul
