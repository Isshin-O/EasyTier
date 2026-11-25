# Fork only: Windows smoke test of the release zip, run by Fork Release Check
# on a GitHub Windows runner (an administrator, so Wintun can create adapters).
#
# Node "a" runs without TUN and stands in for a remote peer; it answers ping
# on its virtual IP itself. Node "b" creates a real Wintun adapter, so every
# ping from Windows to a's virtual IP crosses b's TUN and the tunnel to a.
param(
  [Parameter(Mandatory = $true)][string]$Zip,
  [string]$ExpectVersion = '',
  [int]$SoakSeconds = 60
)

$ErrorActionPreference = 'Stop'
$failed = $false
$rows = @()
function Pass($msg) { Write-Host "ok: $msg"; $script:rows += "| ✅ | $msg |" }
function Fail($msg) { Write-Host "::error::$msg"; $script:rows += "| ❌ | $msg |"; $script:failed = $true }

function Wait-Until([int]$Seconds, [string]$What, [scriptblock]$Check) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    try { if (& $Check) { Pass $What; return $true } } catch { }
    Start-Sleep -Seconds 2
  }
  Fail "$What (not within ${Seconds}s)"
  return $false
}

$work = Join-Path $env:RUNNER_TEMP 'et-win'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Expand-Archive -Path $Zip -DestinationPath $work
$bin = (Get-ChildItem $work -Recurse -Filter easytier-core.exe | Select-Object -First 1).DirectoryName
$core = Join-Path $bin 'easytier-core.exe'
$cli = Join-Path $bin 'easytier-cli.exe'
$logs = Join-Path $env:GITHUB_WORKSPACE 'windows-logs'
New-Item -ItemType Directory -Force $logs | Out-Null

$version = & $core --version
Write-Host $version
if ($version -match '^easytier-core ') { Pass "easytier-core starts: $version" } else { Fail "unexpected --version: $version" }
if ($ExpectVersion -and -not $version.Contains($ExpectVersion)) { Fail "version does not contain $ExpectVersion" }
foreach ($b in 'easytier-cli.exe', 'easytier-web-embed.exe') {
  & (Join-Path $bin $b) --version | Out-Null
  if ($LASTEXITCODE -eq 0) { Pass "$b starts" } else { Fail "$b does not start" }
}

$secret = "smoke-$(Get-Random)"
$common = @('--network-name', 'smoke', '--network-secret', $secret, '--stun-servers', '127.0.0.1:11010', '--console-log-level', 'info')
$a = Start-Process -FilePath $core -PassThru -NoNewWindow `
  -RedirectStandardOutput "$logs\a.log" -RedirectStandardError "$logs\a.err.log" `
  -ArgumentList ($common + @('--no-tun', '-i', '10.144.0.1', '--hostname', 'smoke-a',
    '-l', 'tcp://127.0.0.1:11010', '-l', 'udp://127.0.0.1:11010', '-r', '127.0.0.1:15888'))
$b = Start-Process -FilePath $core -PassThru -NoNewWindow `
  -RedirectStandardOutput "$logs\b.log" -RedirectStandardError "$logs\b.err.log" `
  -ArgumentList ($common + @('-i', '10.144.0.2', '--hostname', 'smoke-b', '--no-listener',
    '-p', 'tcp://127.0.0.1:11010', '-r', '127.0.0.1:15889'))

try {
  $null = Wait-Until 60 'b creates a Wintun adapter with 10.144.0.2' {
    Get-NetIPAddress -IPAddress 10.144.0.2 -AddressFamily IPv4 -ErrorAction Stop
  }
  $adapter = Get-NetIPAddress -IPAddress 10.144.0.2 -ErrorAction SilentlyContinue | Get-NetAdapter -ErrorAction SilentlyContinue
  if ($adapter) { Write-Host "adapter: $($adapter.Name) / $($adapter.InterfaceDescription) / $($adapter.Status)" }

  $null = Wait-Until 60 'b sees a as a peer' {
    $peers = & $cli -p 127.0.0.1:15889 -o json peer | ConvertFrom-Json
    $peers | Where-Object { $_.ipv4 -eq '10.144.0.1' }
  }
  $null = Wait-Until 60 'Windows pings a through the TUN adapter' {
    Test-Connection -TargetName 10.144.0.1 -Count 1 -TimeoutSeconds 2 -Quiet
  }

  # Ping keeps working over the TUN for a while.
  $count = [Math]::Max(10, $SoakSeconds)
  $replies = @(Test-Connection -TargetName 10.144.0.1 -Count $count -TimeoutSeconds 2 -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Success' }).Count
  $loss = [Math]::Round(100 * ($count - $replies) / $count, 1)
  if ($loss -le 2) { Pass "$count pings over the TUN, loss $loss%" } else { Fail "$count pings over the TUN, loss $loss% (limit 2%)" }

  foreach ($p in @($a, $b)) {
    if ($p.HasExited) { Fail "process $($p.Id) exited with $($p.ExitCode)" }
  }
  if (-not $a.HasExited -and -not $b.HasExited) { Pass 'both nodes are still running' }
}
finally {
  foreach ($p in @($a, $b)) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
  Start-Sleep -Seconds 2
  $panics = Select-String -Path "$logs\*.log" -Pattern 'panicked at' -SimpleMatch -ErrorAction SilentlyContinue
  if ($panics) { Fail "a node panicked: $($panics[0].Line)" }

  $summary = @('### Windows smoke test (x86_64)', '', '| | Check |', '|---|---|') + $rows + ''
  if ($env:GITHUB_STEP_SUMMARY) { $summary | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY }
}

if ($failed) { exit 1 }
