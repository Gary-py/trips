@echo off
setlocal
cd /d "%~dp0"
git add -- .gitignore AGENTS.md README.md index.html _tools _Travel-Template PUBLISH_LIBRARY.cmd
git diff --cached --quiet -- .gitignore AGENTS.md README.md index.html _tools _Travel-Template PUBLISH_LIBRARY.cmd
if errorlevel 1 (
    git commit -m "Update Trips library"
    if errorlevel 1 goto :fail
    git push origin main
    if errorlevel 1 goto :fail
) else (
    echo No shared/root changes to publish.
)
pause
exit /b 0
:fail
echo Library publish failed. Review the Git output; no force push was attempted.
pause
exit /b 1
