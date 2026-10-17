# SPDX-License-Identifier: MIT
# Both launchers use the same validation and device transaction implementation.
$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (Get-Command python -ErrorAction SilentlyContinue) {
    & python (Join-Path $Here "flash.py") @args
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    & py -3 (Join-Path $Here "flash.py") @args
} else {
    throw "Python 3 is required. Install it before running the flashing tool."
}
exit $LASTEXITCODE
