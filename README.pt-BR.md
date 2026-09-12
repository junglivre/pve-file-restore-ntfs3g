# Proxmox VE File Restore: fallback com NTFS-3G

Permite acesso confiável e somente leitura pelo File Restore a volumes NTFS quando o driver in-kernel `ntfs3` não consegue montá-los. A imagem de restore também inclui um plugin do `ntfs-3g` para reparse points do Windows Server Data Deduplication (`0x80000013`, inclusive o formato `0x0103`).

English documentation: [README.md](README.md).

> [!WARNING]
> Esta é uma compilação customizada e não oficial. Ela altera os pacotes de File Restore, não o kernel em execução no host. Teste no seu ambiente e preserve os pacotes de rollback. O plugin de deduplicação é um componente GPL-2 de terceiro, sem suporte oficial da Proxmox.

## Alvo testado

Os assets desta release foram compilados e testados com PVE Manager `9.2.11`, Debian 13 (Trixie) `amd64`, `proxmox-backup-file-restore 4.2.5-1` e `proxmox-backup-restore-image 1.0.0`.

O teste funcional usou a API de File Restore do PVE para navegar uma partição NTFS de aproximadamente 4 TB em um backup PBS, sem desligar a VM de origem.

## O que é alterado

1. Após falharem os mounts feitos por drivers in-kernel, `proxmox-backup-file-restore` chama `ntfs-3g -o ro`.
2. A imagem de restore passa a incluir FUSE, `ntfs-3g`, `libfuse3` e `libntfs-3g`.
3. A imagem inclui `ntfs-plugin-80000013.so` no caminho de carregamento automático do `ntfs-3g`.

O fallback é somente leitura: não modifica discos de VMs nem o conteúdo do backup.

## Instalação

Baixe os dois `.deb` e `SHA256SUMS` da release GitHub correspondente, valide e instale-os juntos:

```bash
sha256sum -c SHA256SUMS
apt-get install ./proxmox-backup-file-restore_4.2.5-1+ntfs3g1_amd64.deb \
  ./proxmox-backup-restore-image_1.0.0+ntfs3g1_amd64.deb
```

Não é necessário reiniciar o host ou desligar VMs. Uma nova sessão de File Restore já utilizará a imagem atualizada.

Antes de instalar, guarde os pacotes oficiais para rollback:

```bash
mkdir -p rollback && cd rollback
apt-get download proxmox-backup-file-restore=4.2.5-1 \
  proxmox-backup-restore-image=1.0.0
```

Para reverter:

```bash
apt-get install ./proxmox-backup-file-restore_4.2.5-1_amd64.deb \
  ./proxmox-backup-restore-image_1.0.0_amd64.deb
```

## Compilação própria

O builder usa Docker com Debian 13 descartável; ele não instala dependências de build no nó PVE. São necessários Docker, internet, cerca de 35 GB livres e algumas horas de CPU.

```bash
./scripts/build.sh
```

Os pacotes e os checksums ficam em `dist/`. As versões são fixadas em [`scripts/versions.sh`](scripts/versions.sh).

## Manutenção

Esta compilação é específica para as versões listadas. Atualizações futuras da Proxmox podem substituí-la. Recompile contra as novas versões, revise o diff e reteste o File Restore antes de atualizar em produção.
