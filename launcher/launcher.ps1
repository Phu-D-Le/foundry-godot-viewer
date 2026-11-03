# Tiny local helper that lets the Foundry module start the Godot viewer.
# Browsers can't launch programs, so the module asks this helper over HTTP instead.
# Plain Windows PowerShell; nothing to install.
#
#   powershell -ExecutionPolicy Bypass -File launcher.ps1 [-Godot <path to godot.exe>] [-Project <viewer folder>] [-Port 8766]
#
# Endpoints (127.0.0.1 only):
#   GET  /status  -> {"viewer": true|false}
#   POST /launch  -> starts the viewer unless it's already running -> {"launched": bool, "viewer": true}
param(
  [string]$Godot = "",
  [string]$Project = "",
  [int]$Port = 8766  # must match LAUNCHER_PORT in the Foundry module
)

$LauncherPort = $Port
$ViewerPort = 8765
$GodotGiven = [bool]$Godot

if (-not $Project) { $Project = Split-Path $PSScriptRoot -Parent }
if (-not $Godot) {
  $bundled = Join-Path $Project "bin\godot.exe"
  if (Test-Path $bundled) {
    $Godot = $bundled
  } else {
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) { $Godot = $cmd.Source }
  }
}
if (-not $Godot) {
  Write-Host "launcher: Godot not found. Put godot.exe in $Project\bin or pass -Godot <path>."
  exit 1
}

# The viewer is running if something is listening on its WebSocket port.
function Test-Viewer {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $attempt = $client.BeginConnect("127.0.0.1", $ViewerPort, $null, $null)
    return ($attempt.AsyncWaitHandle.WaitOne(500) -and $client.Connected)
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

$script:launchedAt = [datetime]::MinValue

function Invoke-Launch {
  if (Test-Viewer) { return @{ launched = $false; viewer = $true } }
  # The viewer takes a few seconds to open its port; don't start a second copy meanwhile.
  if (((Get-Date) - $script:launchedAt).TotalSeconds -lt 15) { return @{ launched = $false; viewer = $true } }
  $script:launchedAt = Get-Date
  # Through the double-click launcher when it's there, so a portable copy updates itself first.
  $exe = Join-Path $Project "Foundry Godot Viewer.exe"
  if (-not $GodotGiven -and (Test-Path $exe)) {
    $process = Start-Process -FilePath $exe -PassThru
    Write-Host "launcher: started $exe (pid $($process.Id))"
  } else {
    $process = Start-Process -FilePath $Godot -ArgumentList @("--path", "`"$Project`"") -PassThru
    Write-Host "launcher: started $Godot --path $Project (pid $($process.Id))"
  }
  return @{ launched = $true; viewer = $true; pid = $process.Id }
}

function Send-Response($stream, [string]$status, $body) {
  $json = if ($null -eq $body) { "" } else { $body | ConvertTo-Json -Compress }
  $payload = [Text.Encoding]::UTF8.GetBytes($json)
  # Foundry runs on another origin (e.g. http://localhost:30000), so allow cross-origin calls.
  $head = "HTTP/1.1 $status`r`n" +
    "Access-Control-Allow-Origin: *`r`n" +
    "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
    "Access-Control-Allow-Headers: *`r`n" +
    "Access-Control-Allow-Private-Network: true`r`n" +
    "Content-Type: application/json`r`n" +
    "Content-Length: $($payload.Length)`r`n" +
    "Connection: close`r`n`r`n"
  $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($headBytes, 0, $headBytes.Length)
  $stream.Write($payload, 0, $payload.Length)
}

# TcpListener instead of HttpListener: HttpListener needs admin rights or a URL ACL.
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $LauncherPort)
try {
  $listener.Start()
} catch {
  Write-Host "launcher: port $LauncherPort is in use (already running?)"
  exit 0
}
Write-Host "launcher: listening on http://127.0.0.1:$LauncherPort (godot: $Godot, project: $Project)"
Write-Host "launcher: keep this window open; press Ctrl+C to stop."

try {
  while ($true) {
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
    $client = $listener.AcceptTcpClient()
    try {
      $client.ReceiveTimeout = 2000
      $stream = $client.GetStream()
      $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::ASCII)
      $requestLine = $reader.ReadLine()
      if (-not $requestLine) { continue }
      do { $line = $reader.ReadLine() } while ($line)  # skip headers; requests have no body we need
      $parts = $requestLine.Split(" ")
      $route = "$($parts[0]) $($parts[1].Split('?')[0])"
      switch ($route) {
        "GET /status"  { Send-Response $stream "200 OK" @{ viewer = (Test-Viewer) } }
        "POST /launch" { Send-Response $stream "200 OK" (Invoke-Launch) }
        default {
          if ($parts[0] -eq "OPTIONS") { Send-Response $stream "204 No Content" $null }
          else { Send-Response $stream "404 Not Found" @{ error = "not found" } }
        }
      }
    } catch {
      Write-Host "launcher: request failed: $_"
    } finally {
      $client.Close()
    }
  }
} finally {
  $listener.Stop()
}
