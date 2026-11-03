@echo off
rem Starts the helper that lets Foundry open the Godot viewer. Keep this window open (it starts minimized).
start "Foundry Godot launcher" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1"
