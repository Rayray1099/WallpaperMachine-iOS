# Start the local converter in this console. No scheduled task or auto-start change.
param(
    [string]$BindAddress = "127.0.0.1",
    [int]$Port = 57351
)
$ErrorActionPreference = "Stop"
$env:PYTHONIOENCODING = "utf-8"
$converter = Join-Path $PSScriptRoot "serve_converter.py"
python -B $converter --host $BindAddress --port $Port
exit $LASTEXITCODE
