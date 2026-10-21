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


# Remocao em lote estritamente limitada a seis Appx opcionais do usuario atual.
# Nao altera provisionamento, outros usuarios, drivers ou componentes do sistema.
function Remover-OpcionaisEmLoteBST {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host ' BST - LIMPEZA EM LOTE (6 APPS)' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan

    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) -or
        -not (Get-Command Remove-AppxPackage -ErrorAction SilentlyContinue)) {
        Write-Host 'Comandos Appx indisponiveis neste computador.' -ForegroundColor Yellow
        return
    }
    if ([Environment]::OSVersion.Version.Major -ne 10) {
        Write-Host 'Recurso destinado a Windows 10 e 11.' -ForegroundColor Yellow
        return
    }

    $alvos = @(
        [pscustomobject]@{ Nome='Microsoft People'; Id='Microsoft.People' },
        [pscustomobject]@{ Nome='Central de Comentarios'; Id='Microsoft.WindowsFeedbackHub' },
        [pscustomobject]@{ Nome='Mapas'; Id='Microsoft.WindowsMaps' },
        [pscustomobject]@{ Nome='Xbox TCUI'; Id='Microsoft.Xbox.TCUI' },
        [pscustomobject]@{ Nome='Xbox App'; Id='Microsoft.XboxApp' },
        [pscustomobject]@{ Nome='Xbox Identity Provider'; Id='Microsoft.XboxIdentityProvider' }
    )
    $pasta = Obter-PastaRelatoriosBST
    $marca = Get-Date -Format 'yyyyMMdd-HHmmss'
    $inventario = Join-Path $pasta "BST-Lote-Inventario-$marca.csv"
    $resultado = Join-Path $pasta "BST-Lote-Resultado-$marca.csv"
    $depois = Join-Path $pasta "BST-Lote-Apos-$marca.csv"

    $instalados = @(Get-AppxPackage -ErrorAction Stop)
    $instalados | Select-Object Name,Version,PackageFullName,PackageFamilyName,InstallLocation |
        Export-Csv -Path $inventario -NoTypeInformation -Encoding UTF8
    Write-Host "Inventario ANTES: $inventario" -ForegroundColor Green
    Write-Host 'CSV e apenas inventario; nao e backup dos aplicativos nem dos dados.' -ForegroundColor Yellow

    $encontrados = @()
    foreach ($alvo in $alvos) {
        foreach ($app in @($instalados | Where-Object {
            $_.Name -ceq $alvo.Id -and -not $_.IsFramework -and -not $_.NonRemovable
        })) {
            $encontrados += [pscustomobject]@{
                Nome=$alvo.Nome; Id=$alvo.Id; Versao=[string]$app.Version;
                PackageFullName=$app.PackageFullName
            }
        }
    }
    if ($encontrados.Count -eq 0) {
        Write-Host 'Nenhum dos seis aplicativos opcionais esta instalado para o usuario atual.' -ForegroundColor Green
        return
    }

    Write-Host "`nAplicativos encontrados para remocao:" -ForegroundColor Cyan
    for ($i=0; $i -lt $encontrados.Count; $i++) {
        Write-Host ('[{0}] {1} | {2} | v{3}' -f ($i+1),$encontrados[$i].Nome,$encontrados[$i].Id,$encontrados[$i].Versao)
    }
    Write-Host "`nApenas o usuario atual sera afetado. Apps podem voltar apos atualizacoes." -ForegroundColor Yellow
    Write-Host 'Store, OneDrive, Defender, Edge, drivers e dependencias ficam intactos.' -ForegroundColor Yellow
    Write-Host 'Feche os aplicativos listados antes de continuar.' -ForegroundColor Yellow
    $confirmacao = (Read-Host 'Para remover TODOS os listados digite REMOVER LOTE (ou 0 para cancelar)').Trim()
    if ($confirmacao -cne 'REMOVER LOTE') {
        Write-Host 'Operacao cancelada. Nenhum aplicativo removido.' -ForegroundColor Yellow
        [pscustomobject]@{Data=(Get-Date).ToString('s');Nome='Lote';Pacote='';Resultado='Cancelado';Detalhe='Usuario nao confirmou'} |
            Export-Csv -Path $resultado -NoTypeInformation -Encoding UTF8
        Write-Host "Relatorio: $resultado" -ForegroundColor Cyan
        return
    }

    $registros = @()
    foreach ($app in $encontrados) {
        try {
            # Confere novamente o identificador EXATO contra a lista fechada.
            if (-not @($alvos | Where-Object { $_.Id -ceq $app.Id }).Count) { throw 'Pacote fora da lista permitida' }
            $atual = @(Get-AppxPackage -Name $app.Id -ErrorAction Stop | Where-Object {
                $_.PackageFullName -ceq $app.PackageFullName -and -not $_.IsFramework -and -not $_.NonRemovable
            })
            if ($atual.Count -eq 0) { throw 'Pacote nao encontrado na verificacao final' }
            Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
            $status = 'Removido'; $detalhe = 'Usuario atual'
            Write-Host "Removido: $($app.Nome)" -ForegroundColor Green
        } catch {
            $status = 'Falha'; $detalhe = $_.Exception.Message
            Write-Host "Falha em $($app.Nome): $detalhe" -ForegroundColor Red
        }
        $registros += [pscustomobject]@{
            Data=(Get-Date).ToString('s');Nome=$app.Nome;Pacote=$app.Id;
            Versao=$app.Versao;Resultado=$status;Detalhe=$detalhe
        }
    }
    $registros | Export-Csv -Path $resultado -NoTypeInformation -Encoding UTF8
    @(Get-AppxPackage -ErrorAction Stop) |
        Select-Object Name,Version,PackageFullName,PackageFamilyName,InstallLocation |
        Export-Csv -Path $depois -NoTypeInformation -Encoding UTF8
    Write-Host "`nResultado: $resultado" -ForegroundColor Cyan
    Write-Host "Inventario APOS: $depois" -ForegroundColor Cyan
    Write-Host 'Se necessario, reinicie o Windows. Nenhum componente essencial foi selecionado.' -ForegroundColor Yellow
}


# Limpeza assistida: sem remocao automatica de Prefetch nem de cache do Windows Update.
function Obter-ArquivosTemporariosBST($pasta, $tipo) {
    if (-not (Test-Path -LiteralPath $pasta -PathType Container)) { return @() }
    $limite = (Get-Date).AddDays(-7)
    $base = [IO.Path]::GetFullPath($pasta).TrimEnd('\') + '\'
    $arquivos = @(Get-ChildItem -LiteralPath $pasta -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            $_.LastWriteTime -lt $limite -and
            ($tipo -ne 'miniaturas' -or $_.Name -like 'thumbcache_*.db')
        })
    return $arquivos
}

function Limpar-CategoriaBST($nome, $pasta, $tipo, [bool]$somenteAnalise=$false) {
    Write-Host "`n$nome" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $pasta -PathType Container)) {
        Write-Host 'Pasta nao encontrada.'; return
    }
    $arquivos = @(Obter-ArquivosTemporariosBST $pasta $tipo)
    $bytes = [long]0
    foreach ($a in $arquivos) { $bytes += $a.Length }
    Write-Host ('Pasta: {0}' -f $pasta)
    Write-Host ('Arquivos antigos elegiveis: {0} | Espaco estimado: {1:N2} MB' -f $arquivos.Count,($bytes/1MB))
    if ($somenteAnalise -or $arquivos.Count -eq 0) { return }
    $inventario = Join-Path (Obter-PastaRelatoriosBST) ('BST-Limpeza-Inventario-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.csv')
    $arquivos | Select-Object FullName,Length,LastWriteTime | Export-Csv -LiteralPath $inventario -NoTypeInformation -Encoding UTF8
    Write-Host "Inventario (nao e backup): $inventario"
    $confirmar = (Read-Host 'Digite LIMPAR para excluir somente esses arquivos (0 cancela)').Trim()
    if ($confirmar -cne 'LIMPAR') { Write-Host 'Cancelado.'; return }
    $resultados = @()
    $base = [IO.Path]::GetFullPath($pasta).TrimEnd('\') + '\'
    foreach ($item in $arquivos) {
        $resultado='Ignorado'; $detalhe=''
        try {
            $atual = Get-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            if ($atual.PSIsContainer -or $atual.LastWriteTime -ge (Get-Date).AddDays(-7) -or
                ($atual.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                -not $atual.FullName.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or
                ($tipo -eq 'miniaturas' -and $atual.Name -notlike 'thumbcache_*.db')) { throw 'Arquivo nao elegivel' }
            Remove-Item -LiteralPath $atual.FullName -Force -ErrorAction Stop
            $resultado='Excluido'
        } catch { $detalhe=$_.Exception.Message }
        $resultados += [pscustomobject]@{ Categoria=$nome; Arquivo=$item.FullName; Resultado=$resultado; Detalhe=$detalhe }
    }
    $log = Join-Path (Obter-PastaRelatoriosBST) ('BST-Limpeza-Resultado-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.csv')
    $resultados | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
    Write-Host ('Excluidos: {0} / {1} | Relatorio: {2}' -f @($resultados | Where-Object Resultado -eq 'Excluido').Count,$resultados.Count,$log) -ForegroundColor Green
}

function Limpeza-AvancadaBST {
    $tempUsuario = [IO.Path]::GetFullPath($env:TEMP)
    $tempWindows = Join-Path $env:windir 'Temp'
    $cacheMiniaturas = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    $wer = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'
    $prefetch = Join-Path $env:windir 'Prefetch'
    $update = Join-Path $env:windir 'SoftwareDistribution\Download'
    while ($true) {
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host ' BST - LIMPEZA AVANCADA WINDOWS' -ForegroundColor Cyan
        Write-Host '========================================' -ForegroundColor Cyan
        Write-Host '[1] Limpar %TEMP% do usuario (mais de 7 dias)'
        Write-Host '[2] Limpar C:\Windows\Temp (mais de 7 dias; requer permissao)'
        Write-Host '[3] Analisar Prefetch (nao exclui)'
        Write-Host '[4] Limpar cache antigo de miniaturas'
        Write-Host '[5] Limpar relatorios antigos de erros'
        Write-Host '[6] Cache do Windows Update: analisar e abrir Limpeza de Disco'
        Write-Host '[7] Esvaziar Lixeira (confirmacao especifica)'
        Write-Host '[8] Limpeza segura assistida (categorias 1,2,4,5)'
        Write-Host '[9] Relatorio de espaco recuperavel (sem excluir)'
        Write-Host '[0] Voltar'
        $opcao = (Read-Host 'Escolha').Trim().ToUpperInvariant()
        switch ($opcao) {
            '1' { Limpar-CategoriaBST 'TEMP do usuario' $tempUsuario 'geral' }
            '2' { Limpar-CategoriaBST 'TEMP do Windows' $tempWindows 'geral' }
            '3' {
                Write-Host 'Prefetch ajuda na inicializacao. Nenhum arquivo sera removido.' -ForegroundColor Yellow
                Limpar-CategoriaBST 'Prefetch (somente analise)' $prefetch 'geral' $true
            }
            '4' { Limpar-CategoriaBST 'Cache de miniaturas' $cacheMiniaturas 'miniaturas' }
            '5' { Limpar-CategoriaBST 'Relatorios de falhas (WER)' $wer 'geral' }
            '6' {
                Limpar-CategoriaBST 'Cache Windows Update (somente analise)' $update 'geral' $true
                Write-Host 'Nao apagaremos SoftwareDistribution manualmente.' -ForegroundColor Yellow
                if ((Read-Host 'Abrir a Limpeza de Disco do Windows? (S/N)').Trim() -match '^[Ss]$') {
                    Start-Process cleanmgr.exe -ArgumentList ('/d {0}' -f $env:SystemDrive) -ErrorAction SilentlyContinue
                }
            }
            '7' {
                Write-Host 'Esvaziar a Lixeira pode apagar arquivos recuperaveis. Nao ha backup.' -ForegroundColor Yellow
                if ((Read-Host 'Digite ESVAZIAR LIXEIRA para confirmar').Trim() -ceq 'ESVAZIAR LIXEIRA') {
                    try { Clear-RecycleBin -Force -ErrorAction Stop; Write-Host 'Lixeira esvaziada.' -ForegroundColor Green }
                    catch { Write-Host "Nao foi possivel esvaziar: $($_.Exception.Message)" -ForegroundColor Yellow }
                } else { Write-Host 'Cancelado.' }
            }
            '8' {
                Write-Host 'Cada categoria solicitara sua propria confirmacao.' -ForegroundColor Yellow
                Limpar-CategoriaBST 'TEMP do usuario' $tempUsuario 'geral'
                Limpar-CategoriaBST 'TEMP do Windows' $tempWindows 'geral'
                Limpar-CategoriaBST 'Cache de miniaturas' $cacheMiniaturas 'miniaturas'
                Limpar-CategoriaBST 'Relatorios de falhas (WER)' $wer 'geral'
            }
            '9' {
                $linhas = @()
                foreach ($c in @(
                    @{Nome='TEMP usuario';Pasta=$tempUsuario;Tipo='geral'},
                    @{Nome='TEMP Windows';Pasta=$tempWindows;Tipo='geral'},
                    @{Nome='Prefetch (analise apenas)';Pasta=$prefetch;Tipo='geral'},
                    @{Nome='Miniaturas';Pasta=$cacheMiniaturas;Tipo='miniaturas'},
                    @{Nome='WER';Pasta=$wer;Tipo='geral'},
                    @{Nome='Windows Update (analise apenas)';Pasta=$update;Tipo='geral'}
                )) {
                    $itens = @(Obter-ArquivosTemporariosBST $c.Pasta $c.Tipo)
                    $soma=[long]0; foreach($f in $itens){$soma += $f.Length}
                    $linhas += [pscustomobject]@{Categoria=$c.Nome;Pasta=$c.Pasta;Arquivos=$itens.Count;MB=[math]::Round($soma/1MB,2)}
                }
                $log = Join-Path (Obter-PastaRelatoriosBST) ('BST-Espaco-Recuperavel-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
                $linhas | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
                $linhas | Format-Table -AutoSize | Out-Host
                Write-Host "Relatorio: $log"
            }
            '0' { return }
            default { Write-Host 'Opcao invalida.' -ForegroundColor Yellow }
        }
    }
}

# Desinstalacao individual limitada a aplicativos opcionais Appx do usuario atual.
function Desinstalar-IndividualBST {
    Write-Host "`nBST - DESINSTALAR UM APLICATIVO OPCIONAL" -ForegroundColor Cyan
    $nomes = @(
        'Microsoft.People','Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps',
        'Microsoft.Xbox.TCUI','Microsoft.XboxApp','Microsoft.XboxIdentityProvider',
        'Microsoft.XboxGamingOverlay','Microsoft.GamingApp','Microsoft.MicrosoftSolitaireCollection',
        'Clipchamp.Clipchamp','Microsoft.BingNews','Microsoft.Getstarted',
        'Microsoft.Microsoft3DViewer','Microsoft.MixedReality.Portal',
        'Microsoft.BingWeather','Microsoft.549981C3F5F10','Microsoft.WindowsCamera'
    )
    $apps = @(Get-AppxPackage -ErrorAction Stop | Where-Object {
        $_.Name -in $nomes -and -not $_.IsFramework -and -not $_.NonRemovable
    } | Sort-Object Name)
    if ($apps.Count -eq 0) { Write-Host 'Nenhum aplicativo opcional encontrado.'; return }
    $rotulos = @{
        'Microsoft.BingWeather' = 'Clima'
        'Microsoft.549981C3F5F10' = 'Cortana'
        'Microsoft.WindowsCamera' = 'Camera do Windows'
    }
    for ($i=0; $i -lt $apps.Count; $i++) {
        $nome = $apps[$i].Name
        $rotulo = if ($rotulos.ContainsKey($nome)) { $rotulos[$nome] } else { $nome }
        Write-Host ('[{0}] {1} | {2} | v{3}' -f ($i+1),$rotulo,$nome,$apps[$i].Version)
    }
    $entrada = (Read-Host 'Numero do UNICO aplicativo para remover (0 cancela)').Trim()
    if ($entrada -eq '0' -or -not $entrada) { Write-Host 'Cancelado.'; return }
    if ($entrada -notmatch '^\d+$' -or [int]$entrada -lt 1 -or [int]$entrada -gt $apps.Count) {
        Write-Host 'Numero invalido.' -ForegroundColor Yellow; return
    }
    $app = $apps[[int]$entrada-1]
    Write-Host "Selecionado: $($app.Name)" -ForegroundColor Yellow
    if ($app.Name -eq 'Microsoft.WindowsCamera') {
        Write-Host 'ATENCAO: o aplicativo Camera sera removido; a webcam e seu driver permanecem, mas fotos/videos pelo app Camera deixarao de funcionar ate reinstalar.' -ForegroundColor Yellow
    }
    Write-Host 'Somente o usuario atual sera afetado. O inventario NAO e backup.' -ForegroundColor Yellow
    $confirma = (Read-Host 'Digite REMOVER para confirmar a desinstalacao').Trim()
    if ($confirma -cne 'REMOVER') { Write-Host 'Cancelado.'; return }
    $status='Falha'; $detalhe=''
    try {
        $atual = @(Get-AppxPackage -Name $app.Name -ErrorAction Stop | Where-Object { $_.PackageFullName -eq $app.PackageFullName })
        if ($atual.Count -ne 1 -or $app.Name -notin $nomes) { throw 'Pacote nao encontrado ou nao autorizado' }
        Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
        $restante = @(Get-AppxPackage -Name $app.Name -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -eq $app.PackageFullName })
        if ($restante.Count -gt 0) { throw 'O pacote ainda aparece instalado apos a tentativa' }
        $status='Removido'; Write-Host "Removido: $($app.Name)" -ForegroundColor Green
    } catch { $detalhe=$_.Exception.Message; Write-Host "Falha: $detalhe" -ForegroundColor Red }
    $log = Join-Path (Obter-PastaRelatoriosBST) ('BST-Desinstalacao-Individual-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    [pscustomobject]@{ Data=Get-Date; Usuario=$env:USERNAME; Aplicativo=$app.Name; Versao=[string]$app.Version; Resultado=$status; Detalhe=$detalhe } |
        Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
    Write-Host "Relatorio: $log"
}


# BST Windows Basico: lista explicita de aplicativos opcionais; sem remocao de componentes de sistema.
function Windows-BasicoBST {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host ' BST - WINDOWS BASICO (APPs OPCIONAIS)' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host 'Remove SOMENTE aplicativos opcionais desta lista, para o usuario atual.' -ForegroundColor Yellow
    Write-Host 'Nao remove programas Win32, drivers, Defender, Store, Edge, WebView2 ou Windows Update.'
    Write-Host 'Alguns aplicativos podem voltar em atualizacoes; reinstalacao depende da disponibilidade na Store.'
    $nomes = @(
        'Microsoft.People','Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps',
        'Microsoft.Xbox.TCUI','Microsoft.XboxApp','Microsoft.XboxIdentityProvider',
        'Microsoft.XboxGamingOverlay','Microsoft.GamingApp','Microsoft.MicrosoftSolitaireCollection',
        'Clipchamp.Clipchamp','Microsoft.BingNews','Microsoft.Getstarted',
        'Microsoft.Microsoft3DViewer','Microsoft.MixedReality.Portal',
        'Microsoft.BingWeather','Microsoft.549981C3F5F10',
        'Microsoft.YourPhone','Microsoft.WindowsSoundRecorder','Microsoft.MicrosoftOfficeHub',
        'Microsoft.WindowsAlarms','Microsoft.ZuneMusic','Microsoft.ZuneVideo',
        'Microsoft.SkypeApp','Microsoft.Todos','Microsoft.WindowsFeedbackHub',
        'microsoft.windowscommunicationsapps','Microsoft.Copilot','Microsoft.549981C3F5F10',
        'MicrosoftCorporationII.MicrosoftFamily','7EE7776C.LinkedInforWindows'
    ) | Select-Object -Unique
    # Camera e Fotos sao opcionais, mas ficam fora da selecao em lote por precaucao.
    $apps = @(Get-AppxPackage -ErrorAction Stop | Where-Object {
        $_.Name -in $nomes -and -not $_.IsFramework -and -not $_.NonRemovable
    } | Sort-Object Name)
    if ($apps.Count -eq 0) { Write-Host 'Nenhum aplicativo opcional desta lista encontrado.'; return }
    Write-Host "`nAplicativos encontrados:" -ForegroundColor Cyan
    for ($i=0; $i -lt $apps.Count; $i++) {
        Write-Host ('[{0}] {1} | {2}' -f ($i+1),$apps[$i].Name,$apps[$i].Version)
    }
    $pasta = Obter-PastaRelatoriosBST
    $selo = Get-Date -Format 'yyyyMMdd-HHmmss'
    $inventario = Join-Path $pasta ("BST-Windows-Basico-Inventario-$selo.csv")
    $apps | Select-Object Name,Version,PackageFullName | Export-Csv -LiteralPath $inventario -NoTypeInformation -Encoding UTF8
    Write-Host "Inventario (NAO e backup): $inventario" -ForegroundColor Yellow
    Write-Host "`nDigite os numeros dos aplicativos que deseja REMOVER (ex.: 1,3,5)." -ForegroundColor Yellow
    Write-Host 'ENTER ou 0 cancela. Os aplicativos nao selecionados serao preservados.'
    $entrada = (Read-Host 'Remover').Trim()
    if (-not $entrada -or $entrada -eq '0') { Write-Host 'Cancelado. Nada removido.'; return }
    $selecionados = @()
    foreach ($valor in @($entrada -split ',' | ForEach-Object { $_.Trim() })) {
        if ($valor -notmatch '^\d+$') { Write-Host 'Selecao invalida. Nada removido.' -ForegroundColor Red; return }
        $numero = [int]$valor
        if ($numero -lt 1 -or $numero -gt $apps.Count -or $numero -in $selecionados) {
            Write-Host 'Numero invalido ou repetido. Nada removido.' -ForegroundColor Red; return
        }
        $selecionados += $numero
    }
    $remover = @($selecionados | ForEach-Object { $apps[$_ - 1] })
    if ($remover.Count -eq 0) { Write-Host 'Nada selecionado para remocao.'; return }
    Write-Host "`nSERAO REMOVIDOS SOMENTE ESTES $($remover.Count) APLICATIVOS:" -ForegroundColor Yellow
    $remover | Select-Object Name,Version | Format-Table -AutoSize | Out-Host
    Write-Host 'Todos os demais serao preservados. Email/Calendario podem compartilhar um unico pacote.' -ForegroundColor Yellow
    Write-Host 'Aviso: apps Xbox podem ser necessarios para jogos; Telefone, Gravador, Musica e Videos podem ser usados pelo cliente.' -ForegroundColor Yellow
    $confirmacao = (Read-Host 'Para confirmar digite WINDOWS BASICO REMOVER').Trim()
    if ($confirmacao -cne 'WINDOWS BASICO REMOVER') { Write-Host 'Cancelado. Nada removido.'; return }
    $resultado = @()
    foreach ($app in $remover) {
        $status='Falha'; $detalhe=''
        try {
            $atual = @(Get-AppxPackage -Name $app.Name -ErrorAction Stop | Where-Object { $_.PackageFullName -eq $app.PackageFullName })
            if ($atual.Count -ne 1 -or $app.Name -notin $nomes) { throw 'Pacote nao autorizado ou nao encontrado' }
            Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
            $restante = @(Get-AppxPackage -Name $app.Name -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -eq $app.PackageFullName })
            if ($restante.Count -gt 0) { throw 'Pacote ainda aparece instalado' }
            $status='Removido'
        } catch { $detalhe=$_.Exception.Message }
        Write-Host ("{0}: {1}" -f $status,$app.Name)
        $resultado += [pscustomobject]@{ Usuario=$env:USERNAME; Nome=$app.Name; Versao=[string]$app.Version; Resultado=$status; Detalhe=$detalhe }
    }
    $arquivo = Join-Path $pasta ("BST-Windows-Basico-Resultado-$selo.csv")
    $resultado | Export-Csv -LiteralPath $arquivo -NoTypeInformation -Encoding UTF8
    Write-Host "Resultado: $arquivo" -ForegroundColor Cyan

    # Auditoria apos remocao: consulta novamente o usuario atual, sem modificar pacotes.
    Write-Host "`nBST - VERIFICACAO APOS REMOCAO" -ForegroundColor Cyan
    $auditoria = @()
    foreach ($app in $apps) {
        $situacao = 'Nao verificado'; $detalheAuditoria = ''
        try {
            $restantes = @(Get-AppxPackage -Name $app.Name -ErrorAction Stop | Where-Object {
                $_.PackageFullName -eq $app.PackageFullName
            })
            if ($app.PackageFullName -in @($remover | ForEach-Object { $_.PackageFullName })) {
                if ($restantes.Count -eq 0) { $situacao = 'Removido confirmado' }
                else { $situacao = 'Permanece instalado' }
            } else {
                if ($restantes.Count -gt 0) { $situacao = 'Preservado' }
                else { $situacao = 'Preservado - nao encontrado apos' }
            }
        } catch {
            $situacao = 'Verificacao falhou'
            $detalheAuditoria = $_.Exception.Message
        }
        $auditoria += [pscustomobject]@{
            Usuario=$env:USERNAME; Nome=$app.Name; Versao=[string]$app.Version
            Situacao=$situacao; Detalhe=$detalheAuditoria
        }
    }
    $confirmados = @($auditoria | Where-Object Situacao -eq 'Removido confirmado').Count
    $pendentes = @($auditoria | Where-Object Situacao -eq 'Permanece instalado').Count
    $preservados = @($auditoria | Where-Object Situacao -eq 'Preservado').Count
    $falhasAuditoria = @($auditoria | Where-Object Situacao -eq 'Verificacao falhou').Count
    $auditoria | Format-Table Nome,Situacao -AutoSize | Out-Host
    Write-Host ("Confirmados removidos: {0} | Permanecem: {1} | Preservados: {2} | Falhas na verificacao: {3}" -f $confirmados,$pendentes,$preservados,$falhasAuditoria)
    $arquivoAuditoria = Join-Path $pasta ("BST-Windows-Basico-Auditoria-$selo.csv")
    $auditoria | Export-Csv -LiteralPath $arquivoAuditoria -NoTypeInformation -Encoding UTF8
    Write-Host "Auditoria CSV: $arquivoAuditoria" -ForegroundColor Cyan

    # Relatorio informativo de componentes integrados; nunca tentar remove-los.
    $protegidos = @('Microsoft.XboxGameCallableUI','Microsoft.Windows.PeopleExperienceHost')
    $componentes = @()
    foreach ($nomeProtegido in $protegidos) {
        try {
            $encontrados = @(Get-AppxPackage -Name $nomeProtegido -ErrorAction Stop)
            foreach ($item in $encontrados) {
                $componentes += [pscustomobject]@{Nome=$item.Name; Versao=[string]$item.Version; Acao='Preservado - componente integrado'}
            }
        } catch { Write-Host ("Nao foi possivel consultar componente: {0}" -f $nomeProtegido) -ForegroundColor Yellow }
    }
    $arquivoProtegidos = Join-Path $pasta ("BST-Windows-Basico-Protegidos-$selo.csv")
    if ($componentes.Count -gt 0) {
        $componentes | Export-Csv -LiteralPath $arquivoProtegidos -NoTypeInformation -Encoding UTF8
        Write-Host "Componentes integrados preservados: $arquivoProtegidos" -ForegroundColor Cyan
    }
    Write-Host 'A auditoria cobre apenas os aplicativos selecionados e o usuario atual; nao verifica provisionamento de novos usuarios.' -ForegroundColor Yellow
    Write-Host 'Reinicie somente se necessario. Aplicativos opcionais podem ser reinstalados pela Microsoft Store, se disponiveis.' -ForegroundColor Yellow
}

function Limpar-AtalhosResiduaisBST {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host ' BST - ATALHOS RESIDUAIS DO MENU INICIAR' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host 'Analisa somente atalhos .lnk do Menu Iniciar do usuario atual.'
    Write-Host 'Nao altera apps, blocos fixados, registro ou atalhos de outros usuarios.'
    $raiz = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    if (-not (Test-Path -LiteralPath $raiz)) { Write-Host 'Pasta do Menu Iniciar nao encontrada.' -ForegroundColor Yellow; return }
    # Apenas nomes opcionais conhecidos sao candidatos. Um destino ausente sozinho
    # nao prova que um atalho esta quebrado (ex.: acessibilidade e apps UWP).
    $nomesOpcionais = '(?i)linkedin|microsoft to do|(^|\W)to do(\W|$)|copilot|clima|cortana|skype|xbox|mapas|noticias|clipchamp|solitaire'
    $nomesProtegidos = '(?i)narrator|narrador|on.screen keyboard|teclado virtual|acessibilidade|accessibility|calculadora|calculator|explorador|file explorer|powershell|prompt de comando|command prompt|windows security|seguranca do windows|microsoft store|edge|defender'
    $atalhos = @(Get-ChildItem -LiteralPath $raiz -Filter '*.lnk' -File -Recurse -Force -ErrorAction SilentlyContinue)
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { Write-Host 'Nao foi possivel ler os destinos dos atalhos.' -ForegroundColor Red; return }
    $candidatos = @()
    $ignorados = 0
    foreach ($item in $atalhos) {
        if ($item.BaseName -match $nomesProtegidos) { $ignorados++; continue }
        if ($item.BaseName -notmatch $nomesOpcionais) { continue }
        try {
            $atalho = $shell.CreateShortcut($item.FullName)
            $destino = [string]$atalho.TargetPath
            $destinoExpandido = [Environment]::ExpandEnvironmentVariables($destino)
            $tipo = 'Nao determinado'
            if ([string]::IsNullOrWhiteSpace($destino)) {
                $tipo = 'Destino especial ou vazio - verificar manualmente'
            } elseif (Test-Path -LiteralPath $destinoExpandido) {
                $tipo = 'Destino encontrado - aplicativo pode estar instalado'
            } elseif ($destino -match '^(?i:shell:|ms-|https?:|\\)' -or $destino -match '^\w+\.exe$') {
                $tipo = 'Destino especial ou relativo - verificar manualmente'
            } else {
                $tipo = 'Destino nao localizado - verificar manualmente'
            }
            $candidatos += [pscustomobject]@{
                Nome=$item.BaseName; Caminho=$item.FullName; Destino=$destino;
                Classificacao=$tipo; Motivo='Nome de aplicativo opcional'
            }
        } catch { Write-Host "Ignorado (nao foi possivel analisar): $($item.Name)" -ForegroundColor Yellow }
    }
    Write-Host "Atalhos protegidos ignorados: $ignorados" -ForegroundColor Cyan
    Write-Host 'Destinos ausentes nao sao automaticamente considerados atalhos quebrados.' -ForegroundColor Yellow
    $pastaRel = Obter-PastaRelatoriosBST
    $selo = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $inventario = Join-Path $pastaRel "BST-Atalhos-Inventario-$selo.csv"
    if ($candidatos.Count -eq 0) {
        Write-Host 'Nenhum atalho candidato encontrado. Blocos fixados e sugestoes do Windows nao sao arquivos .lnk.' -ForegroundColor Yellow
        return
    }
    $candidatos | Export-Csv -LiteralPath $inventario -NoTypeInformation -Encoding UTF8
    for ($i=0; $i -lt $candidatos.Count; $i++) {
        Write-Host ('[{0}] {1} | {2}' -f ($i+1),$candidatos[$i].Nome,$candidatos[$i].Classificacao)
    }
    Write-Host "Inventario (nao e backup): $inventario" -ForegroundColor Cyan
    Write-Host 'Atalhos de apps ainda instalados podem aparecer. Nenhum atalho sera movido sem selecao e confirmacao.' -ForegroundColor Yellow
    $entrada = (Read-Host 'Numeros para RETIRAR do menu (ex.: 1,3; ENTER ou 0 cancela)').Trim()
    if (-not $entrada -or $entrada -eq '0') { Write-Host 'Cancelado. Nenhuma alteracao.'; return }
    $partes = @($entrada -split ',' | ForEach-Object { $_.Trim() })
    $indices = @()
    foreach ($parte in $partes) {
        if ($parte -notmatch '^\d+$' -or [int]$parte -lt 1 -or [int]$parte -gt $candidatos.Count) {
            Write-Host 'Selecao invalida. Nada alterado.' -ForegroundColor Red; return
        }
        $indices += [int]$parte
    }
    $selecionados = @($indices | Sort-Object -Unique | ForEach-Object { $candidatos[$_-1] })
    $selecionados | Format-Table Nome,Caminho -AutoSize | Out-Host
    Write-Host 'Os atalhos serao MOVIDOS para backup, nao apagados. Apps nao serao desinstalados.' -ForegroundColor Yellow
    if ((Read-Host 'Digite MOVER ATALHOS para confirmar') -cne 'MOVER ATALHOS') { Write-Host 'Cancelado.'; return }
    $backup = Join-Path $pastaRel "BST-Atalhos-Backup-$selo"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $resultado = @()
    foreach ($item in $selecionados) {
        $estado = 'Movido para backup'; $detalhe = ''
        try {
            $relativo = $item.Caminho.Substring($raiz.Length).TrimStart('\')
            $destino = Join-Path $backup $relativo
            $diretorio = Split-Path -Parent $destino
            New-Item -ItemType Directory -Path $diretorio -Force | Out-Null
            if (Test-Path -LiteralPath $destino) { throw 'Destino de backup ja existe.' }
            Move-Item -LiteralPath $item.Caminho -Destination $destino -ErrorAction Stop
        } catch { $estado = 'Falha'; $detalhe = $_.Exception.Message; $destino = '' }
        Write-Host "$estado`: $($item.Nome)" -ForegroundColor $(if ($estado -eq 'Falha') {'Yellow'} else {'Green'})
        $resultado += [pscustomobject]@{Nome=$item.Nome; Origem=$item.Caminho; Backup=$destino; Estado=$estado; Detalhe=$detalhe}
    }
    $relatorio = Join-Path $pastaRel "BST-Atalhos-Resultado-$selo.csv"
    $resultado | Export-Csv -LiteralPath $relatorio -NoTypeInformation -Encoding UTF8
    Write-Host "Backup dos atalhos: $backup" -ForegroundColor Cyan
    Write-Host "Relatorio: $relatorio" -ForegroundColor Cyan
    Write-Host 'Para restaurar, mova o arquivo .lnk do backup para sua pasta original indicada no CSV.' -ForegroundColor Yellow
}

function Diagnosticar-BlocosFixadosBST {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host ' BST - DIAGNOSTICO DE BLOCOS FIXADOS' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host 'Somente leitura. Nao desafixa blocos nem remove aplicativos.'
    if (-not [Environment]::Is64BitProcess) {
        Write-Host 'Execute no Windows PowerShell de 64 bits para usar Export-StartLayout.' -ForegroundColor Yellow
        return
    }
    if (-not (Get-Command Export-StartLayout -ErrorAction SilentlyContinue)) {
        Write-Host 'Export-StartLayout nao esta disponivel neste Windows.' -ForegroundColor Yellow
        return
    }
    $pasta = Obter-PastaRelatoriosBST
    $selo = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $xmlPath = Join-Path $pasta "BST-MenuIniciar-Layout-$selo.xml"
    $csvPath = Join-Path $pasta "BST-BlocosFixados-Diagnostico-$selo.csv"
    try {
        Export-StartLayout -Path $xmlPath -ErrorAction Stop
        [xml]$layout = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
    } catch {
        Write-Host "Nao foi possivel exportar ou ler o layout: $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }
    $pacotes = @(Get-AppxPackage -ErrorAction SilentlyContinue)
    $appsIniciar = @()
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $appsIniciar = @(Get-StartApps -ErrorAction SilentlyContinue)
    }
    $itens = @($layout.SelectNodes('//*[local-name()="Tile" or local-name()="DesktopApplicationTile"]'))
    $resultado = @()
    foreach ($item in $itens) {
        $aumid = [string]$item.GetAttribute('AppUserModelID')
        $link = [string]$item.GetAttribute('DesktopApplicationLinkPath')
        $id = if ($aumid) { $aumid } else { $link }
        if (-not $id) { continue }
        $nome = $id
        $registro = @($appsIniciar | Where-Object { $_.AppID -eq $aumid } | Select-Object -First 1)
        if ($registro.Count -gt 0) { $nome = [string]$registro[0].Name }
        $situacao = 'Verificar manualmente'
        if ($aumid) {
            $familia = ($aumid -split '!')[0]
            $pacote = @($pacotes | Where-Object { $_.PackageFamilyName -eq $familia } | Select-Object -First 1)
            if ($pacote.Count -gt 0) {
                $situacao = 'Pacote instalado para usuario atual'
            } elseif ($aumid -match '^(?i:Microsoft\.Windows\.|Microsoft\.WindowsStore_|windows\.|Microsoft\.AutoGenerated\.)') {
                $situacao = 'Componente do Windows ou identificador especial - preservar'
            } else {
                $situacao = 'Possivel bloco residual - confirmar visualmente'
            }
        } elseif ($link) {
            $caminho = [Environment]::ExpandEnvironmentVariables($link)
            if (Test-Path -LiteralPath $caminho) {
                $situacao = 'Atalho encontrado - preservar ate verificar'
            } else {
                $situacao = 'Atalho nao localizado - verificar manualmente'
            }
        }
        $resultado += [pscustomobject]@{
            Nome = $nome; Identificador = $id; Situacao = $situacao
        }
    }
    if ($resultado.Count -eq 0) {
        Write-Host 'Nenhum bloco encontrado no layout exportado.' -ForegroundColor Yellow
    } else {
        $resultado | Format-Table Nome, Situacao -AutoSize | Out-Host
        $resultado | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Relatorio CSV: $csvPath" -ForegroundColor Cyan
    }
    Write-Host "Layout exportado: $xmlPath" -ForegroundColor Cyan
    Write-Host 'A ausencia de pacote no usuario atual nao prova desinstalacao em todos os usuarios.' -ForegroundColor Yellow
    Write-Host 'Para retirar um bloco, clique nele com o botao direito no Iniciar e escolha Desafixar de Iniciar.' -ForegroundColor Yellow
}

function Remover-AppsSolicitadosBST {
    Write-Host "`n BST - APPS OPCIONAIS: USUARIO E PROVISIONAMENTO" -ForegroundColor Cyan
    Write-Host 'Analise separada: usuario atual, provisionado para novos usuarios e blocos fixados.'
    Write-Host 'Nao remove Office desktop, dados pessoais, Store, Edge, Defender ou componentes Xbox integrados.' -ForegroundColor Yellow
    $grupos = @(
        @{Nome='Office Hub (NAO Word/Excel)'; Pacotes=@('Microsoft.MicrosoftOfficeHub')},
        @{Nome='Email e Calendario'; Pacotes=@('microsoft.windowscommunicationsapps')},
        @{Nome='LinkedIn'; Pacotes=@('7EE7776C.LinkedInforWindows')},
        @{Nome='Microsoft To Do'; Pacotes=@('Microsoft.Todos')},
        @{Nome='Solitaire'; Pacotes=@('Microsoft.MicrosoftSolitaireCollection')},
        @{Nome='Clima'; Pacotes=@('Microsoft.BingWeather')},
        @{Nome='Cortana'; Pacotes=@('Microsoft.549981C3F5F10')},
        @{Nome='Xbox - apps opcionais'; Pacotes=@('Microsoft.XboxApp','Microsoft.Xbox.TCUI','Microsoft.XboxIdentityProvider','Microsoft.XboxGamingOverlay','Microsoft.GamingApp')}
    )
    try { $instalados = @(Get-AppxPackage -ErrorAction Stop) }
    catch { Write-Host "Falha ao consultar Appx: $_" -ForegroundColor Red; return }
    $provisionados = @()
    try { $provisionados = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) }
    catch { Write-Host 'Nao foi possivel consultar provisionamento (execute como administrador). Nenhuma remocao de provisionamento sera oferecida.' -ForegroundColor Yellow }
    $opcoes = @()
    for ($i=0; $i -lt $grupos.Count; $i++) {
        $g = $grupos[$i]
        $appx = @($instalados | Where-Object { $_.Name -in $g.Pacotes -and -not $_.NonRemovable -and -not $_.IsFramework })
        $prov = @($provisionados | Where-Object { $_.DisplayName -in $g.Pacotes })
        $opcoes += [pscustomobject]@{Numero=$i+1; Nome=$g.Nome; Usuario=$appx; Provisionados=$prov}
        Write-Host ('[{0}] {1} | usuario: {2} | provisionado: {3}' -f ($i+1),$g.Nome,$appx.Count,$prov.Count)
    }
    Write-Host 'Nao altera pacotes instalados em outros usuarios; remover provisionamento afeta NOVOS perfis.' -ForegroundColor Yellow
    Write-Host 'Blocos fixados nao sao alterados; utilize a opcao [9] para diagnosticar.'
    $entrada = (Read-Host 'Numeros para selecionar (ex.: 1,3,5; ENTER cancela)').Trim()
    if (-not $entrada -or $entrada -eq '0') { Write-Host 'Cancelado.'; return }
    $nums = @()
    foreach ($parte in ($entrada -split ',')) {
        $parte = $parte.Trim()
        if ($parte -notmatch '^[1-8]$' -or [int]$parte -in $nums) { Write-Host 'Selecao invalida. Nada removido.' -ForegroundColor Red; return }
        $nums += [int]$parte
    }
    $selecionados = @($opcoes | Where-Object { $_.Numero -in $nums })
    $alvosUsuario = @($selecionados | ForEach-Object { $_.Usuario })
    $alvosProv = @($selecionados | ForEach-Object { $_.Provisionados })
    if (-not $alvosUsuario.Count -and -not $alvosProv.Count) { Write-Host 'Nenhum pacote correspondente encontrado. Nada removido.' -ForegroundColor Yellow; return }
    Write-Host "`nPacotes encontrados para o usuario atual:" -ForegroundColor Cyan
    if ($alvosUsuario.Count) { $alvosUsuario | Select-Object Name,PackageFullName | Format-Table -AutoSize | Out-Host } else { Write-Host 'Nenhum' }
    Write-Host "`nPacotes provisionados para novos usuarios:" -ForegroundColor Cyan
    if ($alvosProv.Count) { $alvosProv | Select-Object DisplayName,PackageName | Format-Table -AutoSize | Out-Host } else { Write-Host 'Nenhum' }
    Write-Host "`n[1] Remover SOMENTE do usuario atual"
    Write-Host '[2] Remover SOMENTE provisionamento para novos usuarios (administrador)'
    Write-Host '[3] Ambos os procedimentos'
    Write-Host '[0] Cancelar'
    $modo = (Read-Host 'Escolha o escopo').Trim()
    if ($modo -notin @('1','2','3')) { Write-Host 'Cancelado.'; return }
    if ($modo -in @('2','3')) {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $admin -or -not $alvosProv.Count) { Write-Host 'Sem permissao administrativa ou sem pacotes provisionados selecionados. Cancelado.' -ForegroundColor Yellow; return }
    }
    if ($modo -eq '1' -and -not $alvosUsuario.Count) { Write-Host 'Nao ha pacotes para remover do usuario atual.'; return }
    Write-Host 'ATENCAO: remover provisionamento nao desinstala aplicativos de outros usuarios nem desafixa blocos.' -ForegroundColor Yellow
    if ((Read-Host 'Digite CONFIRMAR REMOCAO para executar') -cne 'CONFIRMAR REMOCAO') { Write-Host 'Cancelado.'; return }
    $resultado = @()
    if ($modo -in @('1','3')) {
        foreach ($app in $alvosUsuario) {
            $status='Removido'; $detalhe=''
            try { Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop }
            catch { $status='Falha'; $detalhe=$_.Exception.Message }
            $resultado += [pscustomobject]@{Data=Get-Date;Escopo='Usuario atual';Nome=$app.Name;Pacote=$app.PackageFullName;Resultado=$status;Detalhe=$detalhe}
            Write-Host "$status - $($app.Name)"
        }
    }
    if ($modo -in @('2','3')) {
        foreach ($app in $alvosProv) {
            $status='Removido'; $detalhe=''
            try { Remove-AppxProvisionedPackage -Online -PackageName $app.PackageName -ErrorAction Stop | Out-Null }
            catch { $status='Falha'; $detalhe=$_.Exception.Message }
            $resultado += [pscustomobject]@{Data=Get-Date;Escopo='Provisionamento novos usuarios';Nome=$app.DisplayName;Pacote=$app.PackageName;Resultado=$status;Detalhe=$detalhe}
            Write-Host "$status - $($app.DisplayName)"
        }
    }
    $pasta = Obter-PastaRelatoriosBST
    $relatorio = Join-Path $pasta ('BST-Remocao-Apps-Provisionamento-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.csv')
    $resultado | Export-Csv -LiteralPath $relatorio -NoTypeInformation -Encoding UTF8
    Write-Host "Relatorio CSV: $relatorio" -ForegroundColor Cyan
    Write-Host 'Blocos fixados residuais: diagnostique pela opcao [9] e desafixe manualmente.' -ForegroundColor Yellow
}

function Otimizacao-EnxutaBST {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host ' BST - WINDOWS ENXUTO (ASSISTIDO)' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host 'Preserva Defender, Firewall, Windows Update, Store, Edge, WebView2 e drivers.'
    Write-Host 'Nao altera servicos, registro, telemetria, tarefas ou politicas de seguranca.'
    Write-Host '[1] Diagnostico: aplicativos opcionais instalados (sem alterar)'
    Write-Host '[2] Desinstalar um aplicativo opcional (confirmacao individual)'
    Write-Host '[3] Limpeza avancada de arquivos temporarios (assistida)'
    Write-Host '[4] Relatorio de programas de inicializacao (sem alterar)'
    Write-Host '[5] Abrir configuracoes de inicializacao do Windows'
    Write-Host '[6] Abrir configuracoes de armazenamento do Windows'
    Write-Host '[7] Windows Basico: remover em lote apps opcionais (com lista e confirmacao)'
    Write-Host '[8] Analisar/retirar atalhos residuais do Menu Iniciar (com backup)'
    Write-Host '[9] Diagnosticar blocos fixados no Menu Iniciar (sem alterar)'
    Write-Host '[10] Apps opcionais: remover do usuario / provisionamento (seletivo)'
    Write-Host '[0] Voltar'
    $opcao = (Read-Host 'Escolha').Trim()
    switch ($opcao) {
        '7' { Windows-BasicoBST }
        '8' { Limpar-AtalhosResiduaisBST }
        '9' { Diagnosticar-BlocosFixadosBST }
        '10' { Remover-AppsSolicitadosBST }
        '1' {
            $permitidos = @(
                'Microsoft.People','Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps',
                'Microsoft.Xbox.TCUI','Microsoft.XboxApp','Microsoft.XboxIdentityProvider',
                'Microsoft.XboxGamingOverlay','Microsoft.GamingApp','Microsoft.MicrosoftSolitaireCollection',
                'Clipchamp.Clipchamp','Microsoft.BingNews','Microsoft.Getstarted',
                'Microsoft.Microsoft3DViewer','Microsoft.MixedReality.Portal',
                'Microsoft.BingWeather','Microsoft.549981C3F5F10','Microsoft.WindowsCamera'
            )
            $instalados = @(Get-AppxPackage -ErrorAction Stop | Where-Object {
                $_.Name -in $permitidos -and -not $_.IsFramework -and -not $_.NonRemovable
            } | Sort-Object Name)
            if ($instalados.Count -eq 0) { Write-Host 'Nenhum aplicativo da lista opcional encontrado.' }
            else {
                $instalados | Select-Object Name, Version | Format-Table -AutoSize
            }
            $relatorio = Join-Path (Obter-PastaRelatoriosBST) ('BST-Windows-Enxuto-Analise-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
            if ($instalados.Count) { $instalados | Select-Object Name,Version,PackageFullName | Export-Csv -LiteralPath $relatorio -NoTypeInformation -Encoding UTF8 }
            else { 'Nenhum aplicativo opcional encontrado.' | Set-Content -LiteralPath $relatorio -Encoding UTF8 }
            Write-Host "Relatorio: $relatorio"
        }
        '2' { Desinstalar-IndividualBST }
        '3' { Limpeza-AvancadaBST }
        '4' { Analisar-InicializacaoBST }
        '5' { Start-Process 'ms-settings:startupapps' }
        '6' { Start-Process 'ms-settings:storagesense' }
        '0' { return }
        default { Write-Host 'Opcao invalida.' -ForegroundColor Yellow }
    }
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
        Write-Host '[6] Remover em lote: People, Comentarios, Mapas e 3 apps Xbox'
        Write-Host '[7] Limpeza avancada de arquivos temporarios (com confirmacao)'
        Write-Host '[8] Desinstalar UM aplicativo opcional (individual)'
        Write-Host '[9] Windows enxuto - otimizacao segura assistida'
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
                '6' { Remover-OpcionaisEmLoteBST }
                '7' { Limpeza-AvancadaBST }
                '8' { Desinstalar-IndividualBST }
                '9' { Otimizacao-EnxutaBST }
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
