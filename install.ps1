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

function Testar-Assinatura($arquivo, $fabricante) {
    $sig = Get-AuthenticodeSignature -FilePath $arquivo
    if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate) {
        throw "Assinatura digital invalida/ausente: $($sig.Status)"
    }
    if ($fabricante) {
        $subject = $sig.SignerCertificate.Subject
        if ($subject -notmatch ('(^|,\s*)O=' + [regex]::Escape($fabricante) + '(,|$)')) {
            throw "Fabricante da assinatura diferente do esperado: $subject"
        }
    }
}

function Instalar-ChromeOficial {
    $url = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    $arquivo = Join-Path $DownloadDir ('bst-chrome-' + [guid]::NewGuid().ToString('N') + '.msi')
    try {
        Write-Host 'Consultando hash publicado pelo Winget...' -ForegroundColor Yellow
        $manifesto = (& winget show --id Google.Chrome --exact --source winget 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel consultar o manifesto do Chrome no Winget.' }
        $hashes = [regex]::Matches($manifesto, '(?im)^\s*(?:Instalador SHA256|Installer SHA256|SHA256)\s*:\s*([a-f0-9]{64})\s*$')
        if ($hashes.Count -ne 1) { throw 'Nao foi possivel identificar um SHA256 unico no manifesto. Instalacao cancelada.' }
        $hashEsperado = $hashes[0].Groups[1].Value
        $urls = [regex]::Matches($manifesto, '(?im)^\s*(?:URL do instalador|Installer URL)\s*:\s*(https://\S+)\s*$')
        if ($urls.Count -ne 1 -or $urls[0].Groups[1].Value -ne $url) {
            throw 'URL do instalador nao confere com a fonte oficial esperada. Instalacao cancelada.'
        }
        Write-Host 'Baixando MSI oficial do Google Chrome...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $arquivo -UseBasicParsing -TimeoutSec 600
        $hashReal = (Get-FileHash -Path $arquivo -Algorithm SHA256).Hash
        if ($hashReal -ine $hashEsperado) { throw 'SHA256 do Chrome nao corresponde ao manifesto. Instalacao cancelada.' }
        Testar-Assinatura $arquivo 'Google LLC'
        Write-Host 'Hash e assinatura do Google verificados.' -ForegroundColor Green
        $proc = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', ('"' + $arquivo + '"'), '/passive', '/norestart') -Wait -PassThru
        if ($proc.ExitCode -notin @(0,3010,1641)) { throw "Instalador MSI retornou codigo $($proc.ExitCode)" }
        if ($proc.ExitCode -in @(3010,1641)) { Write-Host 'Reinicio pode ser necessario.' -ForegroundColor Yellow }
    } finally {
        Remove-Item $arquivo -Force -ErrorAction SilentlyContinue
    }
}

function Instalar-Programa($p) {
    Write-Host "`nPreparando: $($p.nome)" -ForegroundColor Cyan
    if ($p.metodo -eq 'winget') {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'Winget nao encontrado' }
        & winget install --id $p.id_pacote --exact --source winget --accept-source-agreements --accept-package-agreements
        $codigo = $LASTEXITCODE
        if ($codigo -ne 0) {
            if ($p.id_pacote -eq 'Google.Chrome') {
                Write-Host "Winget falhou (codigo $codigo). Tentando instalador oficial verificado..." -ForegroundColor Yellow
                Instalar-ChromeOficial
            } else {
                throw "Winget retornou codigo $codigo"
            }
        }
    } elseif ($p.metodo -eq 'arquivo') {
        $uri = [Uri]$p.url
        if ($uri.Scheme -ne 'https') { throw 'Somente HTTPS e permitido' }
        if ($p.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'SHA256 obrigatorio: 64 caracteres hexadecimais' }
        if ($p.tipo -notin @('exe','msi')) { throw 'Tipo deve ser exe ou msi' }
        $file = Join-Path $DownloadDir ('bst-' + [guid]::NewGuid().ToString('N') + '.' + $p.tipo)
        try {
            Invoke-WebRequest -Uri $p.url -OutFile $file -UseBasicParsing -TimeoutSec 600
            $hash = (Get-FileHash -Path $file -Algorithm SHA256).Hash
            if ($hash -ine $p.sha256) { throw 'Hash SHA256 nao confere. Instalacao cancelada.' }
            Testar-Assinatura $file $p.assinante
            if ($p.tipo -eq 'msi') {
                $proc = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $file + '"'), '/passive', '/norestart') -Wait -PassThru
            } else {
                $proc = Start-Process -FilePath $file -Wait -PassThru
            }
            if ($proc.ExitCode -notin @(0,3010,1641)) { throw "Instalador retornou codigo $($proc.ExitCode)" }
            if ($proc.ExitCode -in @(3010,1641)) { Write-Host 'Reinicio pode ser necessario.' -ForegroundColor Yellow }
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
    for ($i = 0; $i -lt $programas.Count; $i++) { Write-Host ('[{0}] {1}' -f ($i + 1), $programas[$i].nome) }
    Write-Host '[R] Recarregar catalogo'
    Write-Host '[0] Sair'
    $opcao = (Read-Host 'Escolha (ex.: 1,2,3)').Trim()
    if ($opcao -eq '0') { break }
    if ($opcao -match '^[rR]$') {
        try { $programas = @(Ler-Catalogo) } catch { Write-Host $_ -ForegroundColor Red; Read-Host 'ENTER para continuar' }
        continue
    }
    $selecoes = @($opcao -split ',' | ForEach-Object { $_.Trim() })
    $invalidas = @($selecoes | Where-Object {
        if ($_ -notmatch '^\d{1,6}$') { return $true }
        $numero = [int]$_
        return ($numero -lt 1 -or $numero -gt $programas.Count)
    })
    if ($selecoes.Count -eq 0 -or $invalidas.Count -gt 0) {
        Write-Host 'Opcao invalida.' -ForegroundColor Yellow
        Read-Host 'ENTER para continuar'
        continue
    }
    foreach ($n in ($selecoes | Select-Object -Unique)) {
        try { Instalar-Programa $programas[([int]$n) - 1] }
        catch { Write-Host "Falha: $($_.Exception.Message)" -ForegroundColor Red }
    }
    Read-Host 'ENTER para voltar ao menu'
}
