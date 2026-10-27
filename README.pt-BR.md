# Proxmox VE File Restore: fallback com NTFS-3G

Acesso confiável e somente leitura do Proxmox File Restore a volumes NTFS
que o driver in-kernel `ntfs3` não consegue tratar — incluindo volumes com
Windows Server Data Deduplication (reparse point `0x80000013`, formato
`0x0103`), por meio de um plugin do `ntfs-3g`.

Documentação em inglês: [README.md](README.md).

> [!WARNING]
> Compilação customizada e não oficial. Altera os pacotes de File Restore,
> não o kernel em execução no host. Teste no seu ambiente antes de produção.
> O plugin de dedup é um componente GPL-2.0-only de terceiro, sem suporte
> oficial da Proxmox.

## O que muda

1. O `proxmox-backup-file-restore` cai para `ntfs-3g -o ro` depois que todos
   os mounts in-kernel falham, e **remonta com `ntfs-3g` sempre que o
   `ntfs3` monta um volume com dedup** (detectado por
   `System Volume Information/Dedup`): o `ntfs3` não lê reparse points de
   dedup, então arquivos deduplicados viriam com conteúdo errado. Volumes
   sem dedup continuam no `ntfs3`, mais rápido.
2. O `proxmox-backup-restore-image` ativa FUSE no kernel de restore e
   inclui `ntfs-3g`, `libfuse3` e o plugin de dedup
   `ntfs-plugin-80000013.so` no initramfs do File Restore.
3. O meta-pacote `pve-file-restore-ntfs3g` depende dos pacotes virtuais
   `proxmox-backup-file-restore-ntfs3g` e
   `proxmox-backup-restore-image-ntfs3g`, que só os builds com patch
   fornecem — um pacote oficial nunca satisfaz essa dependência.

Todo o acesso NTFS acontece somente leitura, dentro da microVM de restore;
o kernel do host e os backups nunca são tocados.

## Instalação

As releases ficam no GitHub: pre-release = `testing`, release = `stable`
(veja [docs/releases.md](docs/releases.md)).

- **Cluster / standalone:** veja [docs/standalone.md](docs/standalone.md) —
  um único comando instala em todos os nodes:

  ```bash
  ./scripts/cluster-install.sh --hold
  ```

  O `--hold` é essencial: sem repositório nem pin, um `apt upgrade` troca
  os pacotes com patch pelos oficiais.
- **Clientes MasterMind:** os pacotes também estão no repositório APT
  público da MasterMind (`https://apt.mastermindti.cloud/debian`), que
  espelha estas releases — instale por lá, não pelo script acima.

## Verificação

```bash
pve-file-restore-ntfs3g-check          # saída legível, ✔/✘
pve-file-restore-ntfs3g-check --json   # saída para máquina
```

## Versionamento

Os pacotes são versionados `<versão upstream exata>+ntfs3g<N>` e sempre
construídos a partir do commit de release do upstream
(`bump version to <versão>`, registrado no
[`upstream.lock`](upstream.lock)) — nunca da ponta do `master`. Ordenação
Debian: `4.2.8-1 < 4.2.8-1+ntfs3g1 < 4.2.8-2`. Veja
[CHANGELOG.md](CHANGELOG.md).

## Voltar aos pacotes oficiais

```bash
apt-mark unhold proxmox-backup-file-restore proxmox-backup-restore-image
apt-get install --allow-downgrades \
  proxmox-backup-file-restore=<versão oficial> \
  proxmox-backup-restore-image=<versão oficial>
```

## Compilar você mesmo

Requisitos: Docker, internet, ~35 GB livres e algumas horas de CPU para o
componente restore-image (kernel customizado + ZFS tools).

```bash
./scripts/build.sh --component all        # ou: file-restore | restore-image |
                                          #     dedup-plugin | meta
```

Os pacotes e o `SHA256SUMS` ficam em `dist/`. O build fixa tudo pelo
`upstream.lock` (commits exatos + hashes dos patches), usa um container
`debian:13` fixado por digest e é exatamente o que o CI executa
([docs/automation.md](docs/automation.md)).

## Automação

Um watch diário no GitHub Actions percebe versões novas da Proxmox, confere
se os patches ainda aplicam e abre um PR de bump; o merge publica uma
pre-release automaticamente. A promoção para `stable` é manual e exige
aprovação. Detalhes: [docs/automation.md](docs/automation.md).

## Upstream e licenças

- O fallback segue a série de patches do upstream:
  [pbs-devel](https://lore.proxmox.com/pbs-devel/20260514152510.2273112-1-c.ebner@proxmox.com/T/);
  issue original: [Bugzilla #7544](https://bugzilla.proxmox.com/show_bug.cgi?id=7544).
- Plugin de dedup: [smx-smx/ntfs-3g-dedup-plugin](https://github.com/smx-smx/ntfs-3g-dedup-plugin),
  GPL-2.0-only, com patch para FUSE 3.

Veja [LICENSES.md](LICENSES.md). Os pacotes Proxmox e Debian mantêm suas
licenças originais. Não há endosso da Proxmox Server Solutions GmbH, da
Tuxera ou do autor do plugin.
