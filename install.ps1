# BST Install - catalogo remoto, PowerShell 5.1+
$ErrorActionPreference = 'Stop'
$CatalogUrl = 'https://raw.githubusercontent.com/britos1213/bst-install-public/main/programas.json'
$DownloadDir = Join-Path $env:TEMP 'BST-Install'
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

function Ler-Catalogo {
    try {
        $data = Invoke-RestMethod -Uri $CatalogUrl -UseBasicParsing -TimeoutSec 30
        if ($null -eq $data.programas) { throw 'Campo programas ausente' }
        return @($data.programas | Where-Object { $_.ativo -eq $true })
    } catch { throw "Nao foi possivel carregar o catalogo: $($_.Exception.Message)" }
}
function Instalar-Programa($p) {
    Write-Host "`nPreparando: $($p.nome)" -ForegroundColor Cyan
    if ($p.metodo -eq 'winget') {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'Winget nao encontrado' }
        & winget install --id $p.id_pacote --exact --source winget --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "Winget retornou codigo $LASTEXITCODE" }
    } elseif ($p.metodo -eq 'arquivo') {
        $uri = [Uri]$p.url
        if ($uri.Scheme -ne 'https') { throw 'Somente HTTPS e permitido' }
        if ($p.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'SHA256 obrigatorio: 64 caracteres hexadecimais' }
        if ($p.tipo -notin @('exe','msi')) { throw 'Tipo deve ser exe ou msi' }
        $file = Join-Path $DownloadDir ("bst-" + [guid]::NewGuid().ToString('N') + '.' + $p.tipo)
        try {
            Invoke-WebRequest -Uri $p.url -OutFile $file -UseBasicParsing -TimeoutSec 600
            $hash = (Get-FileHash -Path $file -Algorithm SHA256).Hash
            if ($hash -ine $p.sha256) { throw 'Hash SHA256 nao confere. Instalacao cancelada.' }
            $sig = Get-AuthenticodeSignature -FilePath $file
            if ($sig.Status -ne 'Valid') { throw "Assinatura digital invalida/ausente: $($sig.Status)" }
            if ($p.tipo -eq 'msi') {
                $proc = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $file + '"'), '/passive', '/norestart') -Wait -PassThru
            } else {
                # Sem argumentos silenciosos arbitrarios: interface normal do fornecedor.
                $proc = Start-Process -FilePath $file -Wait -PassThru
            }
            if ($proc.ExitCode -notin @(0,3010,1641)) { throw "Instalador retornou codigo $($proc.ExitCode)" }
        } finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    } else { throw "Metodo nao suportado: $($p.metodo)" }
    Write-Host "Finalizado: $($p.nome)" -ForegroundColor Green
}

try { $programas = @(Ler-Catalogo) } catch { Write-Host $_ -ForegroundColor Red; Read-Host 'ENTER para sair'; exit 1 }
while ($true) {
    Clear-Host
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '       BST INSTALL - PROGRAMAS' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    for ($i=0; $i -lt $programas.Count; $i++) { Write-Host ('[{0}] {1}' -f ($i+1),$programas[$i].nome) }
    Write-Host '[R] Recarregar catalogo'
    Write-Host '[0] Sair'
    $opcao = (Read-Host 'Escolha (ex.: 1,2,3)').Trim()
    if ($opcao -eq '0') { break }
    if ($opcao -match '^[rR]$') {
        try { $programas = @(Ler-Catalogo) } catch { Write-Host $_ -ForegroundColor Red; Read-Host 'ENTER para continuar' }
        continue
    }
    $selecoes = @($opcao -split ',' | ForEach-Object { $_.Trim() })
    if ($selecoes.Count -eq 0 -or @($selecoes | Where-Object { $_ -notmatch '^\d+$' -or [int]$_ -lt 1 -or [int]$_ -gt $programas.Count }).Count -gt 0) {
        Write-Host 'Opcao invalida.' -ForegroundColor Yellow; Read-Host 'ENTER para continuar'; continue
    }
    foreach ($n in ($selecoes | Select-Object -Unique)) {
        try { Instalar-Programa $programas[([int]$n)-1] }
        catch { Write-Host "Falha: $($_.Exception.Message)" -ForegroundColor Red }
    }
    Read-Host 'ENTER para voltar ao menu'
}
