param(
    [Parameter(Mandatory=$true)][string]$Runtime,
    [Parameter(Mandatory=$true)][string]$PCM,
    [Parameter(Mandatory=$true)][string]$Helper
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$job=Join-Path $env:TEMP ('NegiPlayer-SensMeBenchmark-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $job | Out-Null
Copy-Item -LiteralPath (Join-Path $Runtime 'python-win32') -Destination $job -Recurse
Copy-Item -LiteralPath (Join-Path $Runtime 'SensMe\MMLib11.dll') -Destination (Join-Path $job 'MMLib11.dll')
Copy-Item -LiteralPath $Helper -Destination (Join-Path $job 'analyze.py')
Copy-Item -LiteralPath $PCM -Destination (Join-Path $job 'input.s16le')
$results=@()
foreach ($n in 0..2) {
    $out=Join-Path $job ('result-'+$n+'.smfmf')
    $meta=Join-Path $job ('result-'+$n+'.json')
    $timer=[Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $job 'python-win32\python.exe') (Join-Path $job 'analyze.py') --dll (Join-Path $job 'MMLib11.dll') --pcm (Join-Path $job 'input.s16le') --out $out --json $meta | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('Sony engine failed: '+$LASTEXITCODE) }
    $timer.Stop()
    $summary=Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
    $results+=@{run=$n;wallSeconds=$timer.Elapsed.TotalSeconds;engineSeconds=$summary.engine_seconds;sha256=(Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLower();bpm=$summary.bpm;engine=$summary.engine_version}
}
$results | ConvertTo-Json -Depth 5 -Compress
# The generated benchmark files remain in this private Windows temporary directory.
