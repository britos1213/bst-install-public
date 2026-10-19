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

function Testar-ChromeInstalado {
    $caminhos = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome'
    )
    foreach ($caminho in $caminhos) {
        if (Test-Path $caminho) { return $true }
    }
    return ((Test-Path "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") -or
            (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") -or
            (Test-Path "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"))
}

function Instalar-ChromeOficial {
    if (Testar-ChromeInstalado) {
        Write-Host 'Google Chrome ja instalado. Sem Winget, atualizacao automatica nao sera executada.' -ForegroundColor Green
        return
    }
    $url = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    $arquivo = Join-Path $DownloadDir ('bst-chrome-' + [guid]::NewGuid().ToString('N') + '.msi')
    try {
        Write-Host 'Baixando MSI oficial do Google Chrome...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $arquivo -UseBasicParsing -TimeoutSec 600
        # Sem manifesto do Winget nao existe SHA256 publicado para comparar.
        # Exigimos assinatura Authenticode valida do fabricante oficial.
        Testar-Assinatura $arquivo 'Google LLC'
        Write-Host 'Assinatura digital do Google verificada.' -ForegroundColor Green
        $proc = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', ('"' + $arquivo + '"'), '/passive', '/norestart') -Wait -PassThru
        if ($proc.ExitCode -notin @(0,3010,1641)) { throw "Instalador MSI retornou codigo $($proc.ExitCode)" }
        if ($proc.ExitCode -in @(3010,1641)) { Write-Host 'Reinicio pode ser necessario.' -ForegroundColor Yellow }
    } finally {
        Remove-Item $arquivo -Force -ErrorAction SilentlyContinue
    }
}

function Instalar-Java8Oficial {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Instalacao alternativa do Java 8 disponivel somente para Windows 64 bits.'
    }
    # A API oficial fornece URL e checksum SHA256 da versao atual do Temurin 8 JRE.
    $api = 'https://api.adoptium.net/v3/assets/latest/8/hotspot?architecture=x64&image_type=jre&os=windows&vendor=eclipse'
    Write-Host 'Consultando API oficial Eclipse Adoptium (Temurin 8 JRE x64)...' -ForegroundColor Cyan
    $releases = @(Invoke-RestMethod -Uri $api -UseBasicParsing -TimeoutSec 45)
    $release = @($releases | Where-Object {
        $_.binary -and $_.binary.package -and $_.binary.package.link -match '^https://' -and
        $_.binary.package.checksum -match '^[a-fA-F0-9]{64}$' -and
        $_.binary.package.name -match '\.msi$'
    } | Select-Object -First 1)
    if ($release.Count -eq 0) { throw 'Nao foi encontrado MSI com SHA256 na API oficial. Instalacao cancelada.' }
    $pacote = $release[0].binary.package
    $uri = [Uri]$pacote.link
    if ($uri.Host -notin @('github.com','api.adoptium.net')) {
        throw "Dominio de download inesperado: $($uri.Host)"
    }
    $arquivo = Join-Path $DownloadDir ('bst-temurin8-' + [guid]::NewGuid().ToString('N') + '.msi')
    try {
        Write-Host 'Baixando Java 8 JRE oficial...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri $pacote.link -OutFile $arquivo -UseBasicParsing -TimeoutSec 900
        $hash = (Get-FileHash -Path $arquivo -Algorithm SHA256).Hash
        if ($hash -ine $pacote.checksum) { throw 'SHA256 do Java nao confere com o publicado pela Adoptium.' }
        $assinatura = Get-AuthenticodeSignature -FilePath $arquivo
        if ($assinatura.Status -ne 'Valid') { throw "Assinatura digital do Java invalida: $($assinatura.Status)" }
        Write-Host 'SHA256 e assinatura digital verificados.' -ForegroundColor Green
        $proc = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $arquivo + '"'), '/passive', '/norestart') -Wait -PassThru
        if ($proc.ExitCode -notin @(0,3010,1641)) { throw "MSI Java retornou codigo $($proc.ExitCode)" }
        if ($proc.ExitCode -in @(3010,1641)) { Write-Host 'Reinicio pode ser necessario.' -ForegroundColor Yellow }
    } finally {
        Remove-Item $arquivo -Force -ErrorAction SilentlyContinue
    }
}

function Testar-FirefoxInstalado {
    $caminhos = @(
        "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    )
    foreach ($caminho in $caminhos) { if (Test-Path $caminho) { return $true } }
    return $false
}

function Instalar-FirefoxOficial {
    if (Testar-FirefoxInstalado) {
        Write-Host 'Firefox ja instalado. Sem Winget, atualizacao automatica nao sera executada.' -ForegroundColor Green
        return
    }
    $url = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=pt-BR'
    if (-not [Environment]::Is64BitOperatingSystem) {
        $url = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win&lang=pt-BR'
    }
    $arquivo = Join-Path $DownloadDir ('bst-firefox-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        Write-Host 'Baixando Firefox pelo endereco oficial da Mozilla...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $arquivo -UseBasicParsing -TimeoutSec 900 -MaximumRedirection 10
        $sig = Get-AuthenticodeSignature -FilePath $arquivo
        if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate) {
            throw "Assinatura digital do Firefox invalida: $($sig.Status)"
        }
        $subject = $sig.SignerCertificate.Subject
        if ($subject -notmatch 'O=Mozilla (Corporation|Foundation)(,|$)') {
            throw "Fabricante do Firefox nao corresponde a Mozilla: $subject"
        }
        Write-Host 'Assinatura digital da Mozilla verificada.' -ForegroundColor Green
        $proc = Start-Process -FilePath $arquivo -Wait -PassThru
        if ($proc.ExitCode -notin @(0,3010,1641)) { throw "Instalador Firefox retornou codigo $($proc.ExitCode)" }
        if ($proc.ExitCode -in @(3010,1641)) { Write-Host 'Reinicio pode ser necessario.' -ForegroundColor Yellow }
    } finally {
        Remove-Item $arquivo -Force -ErrorAction SilentlyContinue
    }
}

function Instalar-Programa($p) {
    Write-Host "`nPreparando: $($p.nome)" -ForegroundColor Cyan
    if ($p.metodo -eq 'winget') {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            if ($p.id_pacote -eq 'Google.Chrome') {
                Write-Host 'Winget nao encontrado. Usando instalador oficial do Google.' -ForegroundColor Yellow
                Instalar-ChromeOficial
                Write-Host "Finalizado: $($p.nome)" -ForegroundColor Green
                return
            }
            if ($p.id_pacote -eq 'Mozilla.Firefox') {
                Write-Host 'Winget nao encontrado. Usando instalador oficial da Mozilla.' -ForegroundColor Yellow
                Instalar-FirefoxOficial
                Write-Host "Finalizado: $($p.nome)" -ForegroundColor Green
                return
            }
            if ($p.id_pacote -eq 'EclipseAdoptium.Temurin.8.JRE') {
                Write-Host 'Winget nao encontrado. Instalando Temurin 8 JRE pelo fornecedor oficial.' -ForegroundColor Yellow
                Instalar-Java8Oficial
                Write-Host "Finalizado: $($p.nome)" -ForegroundColor Green
                return
            }
            throw "Winget nao encontrado para $($p.nome). Instale o App Installer da Microsoft ou configure metodo arquivo com URL, SHA256 e assinante no catalogo."
        }
        & winget install --id $p.id_pacote --exact --source winget --accept-source-agreements --accept-package-agreements
        $codigo = $LASTEXITCODE
        # Winget: APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE (-1978335189).
        # Programa ja instalado sem atualizacao disponivel: nao baixar novamente.
        if ($codigo -eq -1978335189) {
            Write-Host 'Programa ja instalado e sem atualizacao disponivel.' -ForegroundColor Green
            return
        }
        if ($codigo -ne 0) {
            if ($p.id_pacote -eq 'Google.Chrome') {
                Write-Host "Winget falhou (codigo $codigo). Tentando instalador oficial verificado..." -ForegroundColor Yellow
                Instalar-ChromeOficial
            } elseif ($p.id_pacote -eq 'Mozilla.Firefox') {
                Write-Host "Winget falhou (codigo $codigo). Tentando Firefox oficial..." -ForegroundColor Yellow
                Instalar-FirefoxOficial
            } elseif ($p.id_pacote -eq 'EclipseAdoptium.Temurin.8.JRE') {
                Write-Host "Winget falhou (codigo $codigo). Tentando Java oficial..." -ForegroundColor Yellow
                Instalar-Java8Oficial
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
