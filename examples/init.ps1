# Native Windows version of the local three-window layout.
$gitbash = 'C:\Program Files\Git\bin\bash.exe'
$compo = $env:COMPO_BIN
if (!$compo -or !$env:COMPO_SOCKET) { throw 'Run this script using compo --init.' }

function Invoke-Compo {
    & $compo ctl --quiet @args
    if ($LASTEXITCODE -ne 0) { throw "compo ctl failed: $args" }
}

Invoke-Compo default-shell $gitbash
# Match the live local layout: 14% sidebar, 24% top scratch area on the right.
Invoke-Compo create --tile --name sidebar --cwd $env:USERPROFILE
Invoke-Compo create --tile --name main --target sidebar --edge right --ratio 8600 --cwd $env:USERPROFILE
Invoke-Compo create --tile --name scratch --target main --edge top --ratio 2400 --cwd "$env:USERPROFILE\src\compost"
Invoke-Compo focus main
