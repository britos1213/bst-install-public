# BST Install - base editavel

## Publicacao
1. No repositorio PUBLICO `britos1213/bst-install-public`, adicione `install.ps1` e `programas.json` na raiz (`main`). Nao publique credenciais, ativadores ou pacotes privados.
2. Em cada PC, baixe o script para inspecionar e execute como administrador:

```powershell
Invoke-WebRequest 'https://raw.githubusercontent.com/britos1213/bst-install-public/main/install.ps1' -OutFile "$env:TEMP\bst-install.ps1"
notepad "$env:TEMP\bst-install.ps1"
& "$env:TEMP\bst-install.ps1"
```

Se a politica de execucao impedir, use uma sessao administrativa com politica de execucao apropriada aprovada pela empresa.

## Adicionar programa
Edite `programas.json` no GitHub. Adicione um item a `programas` e salve (commit). Ao iniciar ou pressionar R, o menu le o catalogo atualizado.

- Winget: `{ "nome":"7-Zip", "ativo":true, "metodo":"winget", "id_pacote":"7zip.7zip" }`
- Arquivo proprio: hospede EXE/MSI HTTPS em local acessivel sem login, de preferencia GitHub Releases, e cadastre `nome`, `ativo`, `metodo:"arquivo"`, `tipo:"exe"` ou `"msi"`, `url` e `sha256` real. Exige assinatura Authenticode valida.
- Para obter SHA256 do arquivo original: `Get-FileHash 'C:\caminho\programa.msi' -Algorithm SHA256`.
- Arquivos privados no repo `bstinstall` nao sao acessiveis por PCs sem autenticacao. Nao use URL de pagina GitHub como URL de download.
- O Office esta desativado ate cadastrar um instalador oficial e licenciado; o ZIP antigo com OInstall nao e utilizado.
- O script bloqueia hash incorreto; nao desative validacao de integridade do Winget.
- O GitHub Pages e DNS personalizado sao configuracoes posteriores e independentes da base.

## Seguranca
Qualquer alteracao em script publico passa a ser recebida por clientes. Restrinja permissoes de escrita e revise commits. Para distribuicao profissional, fixe uma versao do script e valide seu hash antes de executar.
