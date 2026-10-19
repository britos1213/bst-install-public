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

function Preparar-BST {
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '       BST INSTALL - PREPARACAO' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host "[1/3] PowerShell $($PSVersionTable.PSVersion)"
    Write-Host '[2/3] Verificando acesso ao catalogo...'
    try {
        $null = Invoke-WebRequest -Uri $CatalogUrl -Method Head -UseBasicParsing -TimeoutSec 15
        Write-Host 'Catalogo acessivel.' -ForegroundColor Green
    } catch {
        Write-Host 'Nao foi possivel verificar a conexao. O carregamento sera tentado.' -ForegroundColor Yellow
    }
    Write-Host '[3/3] Verificando Winget...'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host 'Winget encontrado. Atualizando fontes...' -ForegroundColor Cyan
        try {
            & winget source update
            if ($LASTEXITCODE -ne 0) { Write-Host 'Fontes nao atualizadas; continuando.' -ForegroundColor Yellow }
        } catch { Write-Host 'Falha ao atualizar fontes; continuando.' -ForegroundColor Yellow }
    } else {
        Write-Host 'Winget ausente. Alternativas oficiais serao usadas quando disponiveis.' -ForegroundColor Yellow
    }
    Write-Host 'Preparacao finalizada.' -ForegroundColor Green
}

function Atualizar-ProgramasBST($programas) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'Atualizacao via Winget indisponivel neste computador.' -ForegroundColor Yellow
        Write-Host 'As instalacoes alternativas continuam disponiveis no menu.'
        return
    }
    Write-Host 'Verificando atualizacoes dos programas do catalogo...' -ForegroundColor Cyan
    Write-Host 'Office e Java ficam fora da atualizacao automatica para preservar versoes.' -ForegroundColor Yellow
    foreach ($p in $programas) {
        if ($p.metodo -ne 'winget' -or $p.id_pacote -match '^(EclipseAdoptium\.|Microsoft\.)') { continue }
        Write-Host "`nVerificando: $($p.nome)" -ForegroundColor Cyan
        try {
            & winget upgrade --id $p.id_pacote --exact --source winget --accept-source-agreements
            $codigo = $LASTEXITCODE
            if ($codigo -ne 0) { Write-Host "Consulta retornou codigo $codigo." -ForegroundColor Yellow; continue }
            $confirma = (Read-Host "Atualizar $($p.nome) se houver atualizacao? (S/N)").Trim()
            if ($confirma -match '^[sS]$') {
                & winget upgrade --id $p.id_pacote --exact --source winget --accept-source-agreements --accept-package-agreements
                if ($LASTEXITCODE -ne 0) { Write-Host "Atualizacao retornou codigo $LASTEXITCODE." -ForegroundColor Yellow }
            }
        } catch { Write-Host "Falha ao consultar $($p.nome): $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}


# Limpeza segura: somente Appx de usuario atual, lista explicita, nunca drivers/componentes essenciais.
function Limpeza-WindowsBST {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host ' BST INSTALL - LIMPEZA DO WINDOWS' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        Write-Host 'Appx nao disponivel neste Windows.' -ForegroundColor Yellow
        return
    }
    $versao = [Environment]::OSVersion.Version
    if ($versao.Major -ne 10) {
        Write-Host 'Esta funcao foi preparada para Windows 10 e 11.' -ForegroundColor Yellow
        return
    }
    # Identificadores exatos; evitar curingas que alcancem apps essenciais.
    $permitidos = @(
        @{ Nome='Xbox Game Bar'; Pacote='Microsoft.XboxGamingOverlay'; Categoria='Xbox e Game Bar' },
        @{ Nome='Xbox Identity Provider'; Pacote='Microsoft.XboxIdentityProvider'; Categoria='Xbox e Game Bar' },
        @{ Nome='Xbox TCUI'; Pacote='Microsoft.Xbox.TCUI'; Categoria='Xbox e Game Bar' },
        @{ Nome='Xbox Game Speech Window'; Pacote='Microsoft.XboxGameCallableUI'; Categoria='Xbox e Game Bar' },
        @{ Nome='Xbox app'; Pacote='Microsoft.GamingApp'; Categoria='Xbox e Game Bar' },
        @{ Nome='Xbox Console Companion'; Pacote='Microsoft.XboxApp'; Categoria='Xbox e Game Bar' },
        @{ Nome='Microsoft Solitaire Collection'; Pacote='Microsoft.MicrosoftSolitaireCollection'; Categoria='Jogos' },
        @{ Nome='Clipchamp'; Pacote='Clipchamp.Clipchamp'; Categoria='Clipchamp' },
        @{ Nome='Microsoft News'; Pacote='Microsoft.BingNews'; Categoria='Noticias' },
        @{ Nome='Microsoft Tips'; Pacote='Microsoft.Getstarted'; Categoria='Promocionais' },
        @{ Nome='Microsoft People'; Pacote='Microsoft.People'; Categoria='Promocionais' },
        @{ Nome='Microsoft 3D Viewer'; Pacote='Microsoft.Microsoft3DViewer'; Categoria='Promocionais' },
        @{ Nome='Microsoft Mixed Reality Portal'; Pacote='Microsoft.MixedReality.Portal'; Categoria='Promocionais' }
    )
    # Somente instalacoes do usuario corrente, sem -AllUsers e sem alterar a imagem do Windows.
    $instalados = @(Get-AppxPackage -ErrorAction Stop)
    $achados = @()
    foreach ($item in $permitidos) {
        $pacotes = @($instalados | Where-Object { $_.Name -eq $item.Pacote -and -not $_.IsFramework -and -not $_.NonRemovable })
        foreach ($pacote in $pacotes) {
            $achados += [pscustomobject]@{
                Nome=$item.Nome; Categoria=$item.Categoria; Pacote=$pacote.Name
                Versao=[string]$pacote.Version; PackageFullName=$pacote.PackageFullName
                PackageFamilyName=$pacote.PackageFamilyName; InstallLocation=$pacote.InstallLocation
            }
        }
    }
    $pasta = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BST-Relatorios'
    if (-not $pasta -or $pasta -eq 'BST-Relatorios') { $pasta = Join-Path $env:TEMP 'BST-Relatorios' }
    New-Item -Path $pasta -ItemType Directory -Force | Out-Null
    $data = Get-Date -Format 'yyyyMMdd-HHmmss'
    $relatorio = Join-Path $pasta "BST-Limpeza-Inventario-$data.csv"
    $log = Join-Path $pasta "BST-Limpeza-Resultado-$data.csv"
    $todos = @($instalados | Select-Object Name, Version, PackageFullName, PackageFamilyName, InstallLocation)
    # Inventario de todos os apps do usuario como referencia para eventual reinstalacao.
    $todos | Export-Csv -Path $relatorio -NoTypeInformation -Encoding UTF8
    Write-Host "`nInventario salvo em: $relatorio" -ForegroundColor Green
    Write-Host 'O inventario NAO e backup dos aplicativos ou dos dados.' -ForegroundColor Yellow
    if ($achados.Count -eq 0) {
        Write-Host 'Nenhum aplicativo opcional da lista foi encontrado para o usuario atual.' -ForegroundColor Green
        return
    }
    Write-Host "`nAplicativos opcionais encontrados:" -ForegroundColor Cyan
    for ($i=0; $i -lt $achados.Count; $i++) {
        Write-Host ('[{0}] {1} | {2} | v{3}' -f ($i+1),$achados[$i].Nome,$achados[$i].Categoria,$achados[$i].Versao)
    }
    Write-Host 'Nao remove OneDrive, Microsoft Store, Defender, Edge, drivers ou dependencias do Windows.' -ForegroundColor Yellow
    Write-Host 'A remocao afeta somente o usuario atual. Apps podem voltar em atualizacoes.' -ForegroundColor Yellow
    $escolha = (Read-Host 'Numeros para remover (ex.: 1,3) ou 0 para cancelar').Trim()
    if ($escolha -eq '0' -or -not $escolha) { Write-Host 'Nenhum aplicativo removido.'; return }
    $numeros = @($escolha -split ',' | ForEach-Object { $_.Trim() })
    $invalidos = @($numeros | Where-Object { $_ -notmatch '^\d{1,3}$' -or [int]$_ -lt 1 -or [int]$_ -gt $achados.Count })
    if ($invalidos.Count -gt 0) { Write-Host 'Selecao invalida; nenhuma remocao realizada.' -ForegroundColor Yellow; return }
    $selecionados = @($numeros | Select-Object -Unique | ForEach-Object { $achados[([int]$_)-1] })
    Write-Host "`nConfirme cada remocao individualmente." -ForegroundColor Yellow
    $resultados = @()
    foreach ($item in $selecionados) {
        $confirmar = (Read-Host "Remover $($item.Nome) [$($item.Pacote)] do usuario atual? Digite REMOVER").Trim()
        if ($confirmar -cne 'REMOVER') {
            $resultados += [pscustomobject]@{Data=(Get-Date); Nome=$item.Nome; Pacote=$item.Pacote; Resultado='Ignorado'; Detalhe='Sem confirmacao'}
            continue
        }
        try {
            # Verifica novamente se e um dos pacotes explicitamente permitidos.
            if (@($permitidos | Where-Object { $_.Pacote -eq $item.Pacote }).Count -eq 0) { throw 'Pacote nao autorizado' }
            Remove-AppxPackage -Package $item.PackageFullName -ErrorAction Stop
            Write-Host "Removido: $($item.Nome)" -ForegroundColor Green
            $resultados += [pscustomobject]@{Data=(Get-Date); Nome=$item.Nome; Pacote=$item.Pacote; Resultado='Removido'; Detalhe='Usuario atual'}
        } catch {
            Write-Host "Falha ao remover $($item.Nome): $($_.Exception.Message)" -ForegroundColor Red
            $resultados += [pscustomobject]@{Data=(Get-Date); Nome=$item.Nome; Pacote=$item.Pacote; Resultado='Falha'; Detalhe=$_.Exception.Message}
        }
    }
    if ($resultados.Count -gt 0) {
        $resultados | Export-Csv -Path $log -NoTypeInformation -Encoding UTF8
        Write-Host "Relatorio de resultados: $log" -ForegroundColor Cyan
    }
    Write-Host 'Limpeza concluida. Reinicie o computador se necessario.' -ForegroundColor Green
}


# BST: relatorios e limpeza adicional conservadora.
function Obter-PastaRelatoriosBST {
    $base = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
    $pasta = Join-Path $base 'BST-Relatorios'
    New-Item -ItemType Directory -Path $pasta -Force | Out-Null
    return $pasta
}

function Analisar-InicializacaoBST {
    Write-Host "`nBST - Analise de inicializacao (somente leitura)" -ForegroundColor Cyan
    $itens = @()
    foreach ($escopo in @(
        @{ Nome='Usuario'; Caminho='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' },
        @{ Nome='Maquina'; Caminho='HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' },
        @{ Nome='Maquina32'; Caminho='HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }
    )) {
        if (Test-Path $escopo.Caminho) {
            $propriedades = Get-ItemProperty -Path $escopo.Caminho -ErrorAction SilentlyContinue
            if ($null -ne $propriedades) {
                foreach ($prop in $propriedades.PSObject.Properties) {
                    if ($prop.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') {
                        $itens += [pscustomobject]@{ Origem=$escopo.Nome; Nome=$prop.Name; Comando=[string]$prop.Value }
                    }
                }
            }
        }
    }
    foreach ($pasta in @(
        [pscustomobject]@{ Origem='Inicializacao usuario'; Caminho=[Environment]::GetFolderPath('Startup') },
        [pscustomobject]@{ Origem='Inicializacao comum'; Caminho=[Environment]::GetFolderPath('CommonStartup') }
    )) {
        if ($pasta.Caminho -and (Test-Path -LiteralPath $pasta.Caminho)) {
            foreach ($arq in @(Get-ChildItem -LiteralPath $pasta.Caminho -File -ErrorAction SilentlyContinue)) {
                $itens += [pscustomobject]@{ Origem=$pasta.Origem; Nome=$arq.Name; Comando=$arq.FullName }
            }
        }
    }
    $destino = Join-Path (Obter-PastaRelatoriosBST) ('BST-Inicializacao-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    if ($itens.Count -gt 0) { $itens | Export-Csv -LiteralPath $destino -NoTypeInformation -Encoding UTF8; $itens | Format-Table -AutoSize -Wrap }
    else { 'Nenhuma entrada encontrada nas fontes verificadas.' | Set-Content -LiteralPath $destino -Encoding UTF8 }
    Write-Host "Relatorio: $destino" -ForegroundColor Green
    Write-Host 'Nenhum programa de inicializacao foi desativado.' -ForegroundColor Yellow
}

function Analisar-ArmazenamentoBST {
    Write-Host "`nBST - Armazenamento (somente leitura)" -ForegroundColor Cyan
    $discos = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Unidade=$_.DeviceID; TotalGB=[math]::Round($_.Size/1GB,2); LivreGB=[math]::Round($_.FreeSpace/1GB,2); LivrePercentual= if ($_.Size -gt 0) {[math]::Round(100*$_.FreeSpace/$_.Size,1)} else {0} }
    })
    $discos | Format-Table -AutoSize
    $destino = Join-Path (Obter-PastaRelatoriosBST) ('BST-Armazenamento-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    $discos | Export-Csv -LiteralPath $destino -NoTypeInformation -Encoding UTF8
    Write-Host "Relatorio: $destino" -ForegroundColor Green
}

function Limpar-TemporariosBST {
    Write-Host "`nBST - Arquivos temporarios do usuario" -ForegroundColor Cyan
    Write-Host 'Somente arquivos soltos na pasta TEMP do usuario, com mais de 7 dias.' -ForegroundColor Yellow
    Write-Host 'Nao limpa Downloads, Documentos, cache de navegadores, Windows Update ou pastas do sistema.' -ForegroundColor Yellow
    $pastaTemp = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
    $pastaPerfil = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    if (-not $pastaTemp.StartsWith($pastaPerfil + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'TEMP nao esta dentro do perfil do usuario. Limpeza cancelada.'
    }
    if (-not (Test-Path -LiteralPath $pastaTemp -PathType Container)) { throw 'Pasta TEMP nao encontrada.' }
    $limite = (Get-Date).AddDays(-7)
    $arquivos = @(Get-ChildItem -LiteralPath $pastaTemp -File -Force -ErrorAction Stop | Where-Object { $_.LastWriteTime -lt $limite -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
    $total = [long]0
    foreach ($arquivo in $arquivos) { $total += $arquivo.Length }
    Write-Host ('Encontrados: {0} arquivos; tamanho aproximado: {1:N2} MB' -f $arquivos.Count, ($total/1MB))
    $destino = Join-Path (Obter-PastaRelatoriosBST) ('BST-Temporarios-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    if ($arquivos.Count -gt 0) {
        $arquivos | Select-Object FullName,Length,LastWriteTime | Export-Csv -LiteralPath $destino -NoTypeInformation -Encoding UTF8
    } else { 'Nenhum arquivo elegivel.' | Set-Content -LiteralPath $destino -Encoding UTF8 }
    Write-Host "Inventario: $destino" -ForegroundColor Green
    if ($arquivos.Count -eq 0) { return }
    $confirma = (Read-Host 'Para excluir esses arquivos temporarios, digite LIMPAR (ou Enter para cancelar)').Trim()
    if ($confirma -cne 'LIMPAR') { Write-Host 'Limpeza cancelada.'; return }
    $resultados = @()
    foreach ($arquivo in $arquivos) {
        try {
            # Revalidar idade e caminho antes de excluir. Arquivos em uso geram falha e sao preservados.
            $atual = Get-Item -LiteralPath $arquivo.FullName -Force -ErrorAction Stop
            if ($atual.PSIsContainer -or $atual.LastWriteTime -ge $limite -or ($atual.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            if ([System.IO.Path]::GetDirectoryName($atual.FullName).TrimEnd('\') -ine $pastaTemp) { continue }
            Remove-Item -LiteralPath $atual.FullName -Force -ErrorAction Stop
            $resultados += [pscustomobject]@{ Arquivo=$atual.FullName; Resultado='Excluido'; Detalhe='' }
        } catch {
            $resultados += [pscustomobject]@{ Arquivo=$arquivo.FullName; Resultado='Ignorado/Falha'; Detalhe=$_.Exception.Message }
        }
    }
    $log = Join-Path (Obter-PastaRelatoriosBST) ('BST-Temporarios-Resultado-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    $resultados | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
    Write-Host ('Excluidos: {0}. Nao excluidos: {1}.' -f @($resultados | Where-Object Resultado -eq 'Excluido').Count, @($resultados | Where-Object Resultado -ne 'Excluido').Count) -ForegroundColor Green
    Write-Host "Log: $log"
}


# Varredura abrangente somente leitura: Appx (usuario atual) e programas Win32 registrados.
# Nao executa UninstallString, Win32_Product, winget uninstall nem Remove-AppxPackage.
function Varredura-ProgramasBST {
    Write-Host "`nBST - VARREDURA COMPLETA DE PROGRAMAS (SOMENTE ANALISE)" -ForegroundColor Cyan
    Write-Host 'Nenhum programa sera removido nesta etapa.' -ForegroundColor Yellow
    $registros = New-Object 'System.Collections.Generic.List[object]'
    $appxOpcionais = @{
        'Microsoft.XboxGamingOverlay'='Xbox e Game Bar'
        'Microsoft.XboxIdentityProvider'='Xbox e Game Bar'
        'Microsoft.Xbox.TCUI'='Xbox e Game Bar'
        'Microsoft.GamingApp'='Xbox e Game Bar'
        'Microsoft.XboxApp'='Xbox e Game Bar'
        'Microsoft.MicrosoftSolitaireCollection'='Jogos'
        'Clipchamp.Clipchamp'='Editor de video opcional'
        'Microsoft.BingNews'='Noticias'
        'Microsoft.Getstarted'='Dicas'
        'Microsoft.People'='Contatos'
        'Microsoft.Microsoft3DViewer'='Visualizador 3D'
        'Microsoft.MixedReality.Portal'='Realidade mista'
        'Microsoft.BingWeather'='Clima'
        'Microsoft.WindowsMaps'='Mapas'
        'Microsoft.ZuneMusic'='Reprodutor multimidia'
        'Microsoft.ZuneVideo'='Reprodutor multimidia'
        'Microsoft.YourPhone'='Vincular ao celular'
        'Microsoft.WindowsFeedbackHub'='Central de comentarios'
    }
    try {
        foreach ($a in @(Get-AppxPackage -ErrorAction Stop)) {
            $grupo='Preservar / componente ou nao classificado'
            $motivo='Nao remover automaticamente; verificar funcao e dependencias.'
            if ($appxOpcionais.ContainsKey([string]$a.Name) -and -not $a.IsFramework -and -not $a.NonRemovable) {
                $grupo='Candidato opcional (avaliar uso)'
                $motivo=$appxOpcionais[[string]$a.Name]
            }
            $registros.Add([pscustomobject]@{
                Origem='Microsoft Store / Appx'; Nome=[string]$a.Name; Versao=[string]$a.Version
                Fabricante=''; Categoria=$grupo; Motivo=$motivo
                Identificador=[string]$a.PackageFullName; Escopo='Usuario atual'
            })
        }
    } catch { Write-Host "Nao foi possivel consultar Appx: $($_.Exception.Message)" -ForegroundColor Yellow }

    $locais = @(
        @{Caminho='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Escopo='Maquina (64 bits)'},
        @{Caminho='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Escopo='Maquina (32 bits)'},
        @{Caminho='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Escopo='Usuario atual'}
    )
    foreach ($local in $locais) {
        foreach ($a in @(Get-ItemProperty -Path $local.Caminho -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace([string]$a.DisplayName)) { continue }
            $nome=[string]$a.DisplayName
            $fabricante=[string]$a.Publisher
            $categoria='Revisao manual'
            $motivo='Verificar se o cliente utiliza; nao desinstalar sem avaliar.'
            if ($a.SystemComponent -eq 1 -or $nome -match '(?i)Microsoft Visual C\+\+|\.NET (Runtime|Desktop Runtime|Host|SDK)|Windows (Update|Driver)|WebView2|Intel\(R\)|Realtek|NVIDIA|AMD (Chipset|Software)|Dell (Command|SupportAssist)|HP (System|Hotkey)|Lenovo (System|Vantage)') {
                $categoria='Preservar / dependencias ou drivers'
                $motivo='Possivel dependencia, driver ou componente de suporte.'
            } elseif ($nome -match '(?i)solitaire|xbox|game bar|clipchamp|trial|free trial|toolbar|coupon|shopping assistant') {
                $categoria='Candidato opcional (avaliar uso)'
                $motivo='Pode ser dispensavel; confirmar necessidade com o cliente.'
            } elseif ($nome -match '(?i)OneDrive|Office|Microsoft 365|AnyDesk|TeamViewer|Java|JRE|JDK|VPN|Antivirus|Security|Backup') {
                $categoria='Revisao cuidadosa'
                $motivo='Pode conter dados, acesso remoto, licencas ou dependencias.'
            }
            $registros.Add([pscustomobject]@{
                Origem='Programa Win32'; Nome=$nome; Versao=[string]$a.DisplayVersion
                Fabricante=$fabricante; Categoria=$categoria; Motivo=$motivo
                Identificador=[string]$a.PSChildName; Escopo=$local.Escopo
            })
        }
    }
    $itens=@($registros | Sort-Object Origem, Nome, Versao, Escopo -Unique)
    $arquivo=Join-Path (Obter-PastaRelatoriosBST) ('BST-Varredura-Completa-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    if ($itens.Count -gt 0) {
        $itens | Export-Csv -LiteralPath $arquivo -NoTypeInformation -Encoding UTF8
        $candidatos=@($itens | Where-Object { $_.Categoria -eq 'Candidato opcional (avaliar uso)' })
        $revisao=@($itens | Where-Object { $_.Categoria -in @('Revisao manual','Revisao cuidadosa') })
        Write-Host "`nTotal de entradas inventariadas: $($itens.Count)" -ForegroundColor Green
        Write-Host "Candidatos opcionais: $($candidatos.Count) | Para revisao: $($revisao.Count)"
        if ($candidatos.Count -gt 0) {
            Write-Host "`nCANDIDATOS A AVALIAR:" -ForegroundColor Cyan
            $candidatos | Select-Object Origem, Nome, Versao, Motivo | Format-Table -AutoSize -Wrap
        }
        Write-Host "`nRelatorio completo: $arquivo" -ForegroundColor Green
        Write-Host 'Abra o CSV para revisar todos os programas e suas classificacoes.'
    } else {
        Write-Host 'Nenhuma entrada retornada pelas fontes consultadas.' -ForegroundColor Yellow
    }
    Write-Host 'Nenhuma remocao foi realizada. Para Appx permitidos, use a opcao [1] com confirmacao individual.' -ForegroundColor Yellow
    Write-Host 'A lista nao mede uso real ou importancia do programa para o cliente.' -ForegroundColor Yellow
}

function Menu-LimpezaBST {
    while ($true) {
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host ' BST - LIMPEZA E OTIMIZACAO WINDOWS' -ForegroundColor Cyan
        Write-Host '========================================' -ForegroundColor Cyan
        Write-Host '[1] Analisar/remover aplicativos opcionais (confirmacao individual)'
        Write-Host '[2] Analisar/limpar TEMP do usuario (arquivos antigos)'
        Write-Host '[3] Relatorio de programas de inicializacao (sem alterar)'
        Write-Host '[4] Relatorio de espaco em disco'
        Write-Host '[5] Varredura completa de aplicativos (Appx + programas Win32; sem remover)'
        Write-Host '[0] Voltar ao menu principal'
        $op = (Read-Host 'Escolha').Trim()
        if ($op -eq '0') { return }
        try {
            switch ($op) {
                '1' { Limpeza-WindowsBST }
                '2' { Limpar-TemporariosBST }
                '3' { Analisar-InicializacaoBST }
                '4' { Analisar-ArmazenamentoBST }
                '5' { Varredura-ProgramasBST }
                default { Write-Host 'Opcao invalida.' -ForegroundColor Yellow }
            }
        } catch { Write-Host "Falha: $($_.Exception.Message)" -ForegroundColor Red }
        Read-Host 'ENTER para continuar'
    }
}

Preparar-BST
try { $programas = @(Ler-Catalogo) } catch { Write-Host $_ -ForegroundColor Red; Read-Host 'ENTER para sair'; exit 1 }
while ($true) {
    Clear-Host
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '       BST INSTALL - PROGRAMAS' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    for ($i = 0; $i -lt $programas.Count; $i++) { Write-Host ('[{0}] {1}' -f ($i + 1), $programas[$i].nome) }
    Write-Host '[A] Verificar/atualizar programas instalados'
    Write-Host '[L] Limpeza e otimizacao do Windows'
    Write-Host '[R] Recarregar catalogo'
    Write-Host '[0] Sair'
    $opcao = (Read-Host 'Escolha (ex.: 1,2,3)').Trim()
    if ($opcao -eq '0') { break }
    if ($opcao -match '^[aA]$') {
        Atualizar-ProgramasBST $programas
        Read-Host 'ENTER para voltar ao menu'
        continue
    }
    if ($opcao -match '^[lL]$') {
        Menu-LimpezaBST
        continue
    }
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
