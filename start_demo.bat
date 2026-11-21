@echo off
title AvaxSentinel AI V2 - 1-Click Demo Launcher
color 0C
cls
echo ======================================================================
echo    AVAXSENTINEL AI V2 (ENTERPRISE EDITION) - DEMO LAUNCHER
echo    Team CTST: Vo Phuc Loc ^& Nguyen Xuan Nghi (HCMUS)
echo    Competition: Team1 Vietnam UniHack 2026: Build on Avalanche
echo ======================================================================
echo.

echo [1/3] Running AI/ML Risk Engine Demonstration...
echo ----------------------------------------------------------------------
python ai_engine\risk_scorer.py
if %ERRORLEVEL% NEQ 0 (
    echo [WARNING] Python not found or script error. Proceeding anyway...
)
echo.

echo [2/3] Evaluating Transaction Anomaly ML Model (1,500 records)...
echo ----------------------------------------------------------------------
python ai_engine\train_model.py
echo.

echo [3/3] Launching Web3 Cyber Dashboard in your browser...
echo ----------------------------------------------------------------------
start index.html
echo [SUCCESS] Dashboard opened in your browser!
echo.
echo ======================================================================
echo   READY FOR SUBMISSION ^& JUDGE EVALUATION!
echo   * Local dApp: index.html
echo   * Presentation Deck: slides.html
echo   * Fuji Contract: 0x48e123B5F54F9D1c9A3B5f22E33b006A7bBf321A
echo ======================================================================
pause
