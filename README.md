# BGBar

App de barra de menus para macOS que mostra, em tempo real, o que está rodando em segundo plano na sua máquina:

- **LaunchAgents do usuário** (`~/Library/LaunchAgents`)
- **Containers Docker** (Docker Desktop ou OrbStack)
- **Processos de desenvolvimento** (bun, node, python etc.)

Para cada item aparecem status, PID, uptime, CPU, memória e portas em escuta. Pelo menu dá para iniciar, parar, reiniciar, encerrar (kill) e ver logs. O app avisa por notificação quando algo cai, permite fixar ou ocultar itens e tem a opção "Abrir ao iniciar sessão".

## Requisitos

- macOS 14 (Sonoma) ou mais recente
- Xcode Command Line Tools com Swift 5.10+ (`xcode-select --install`)
- Docker ou OrbStack (opcional, apenas para a seção de containers)

## Compilar

```sh
scripts/bundle.sh
```

O script roda `swift build -c release`, monta `build/BGBar.app` (Info.plist com `LSUIElement`, então não aparece no Dock), valida o plist com `plutil -lint` e assina ad-hoc com `codesign`. A assinatura é necessária para notificações e para o registro de abertura no login.

Para usar outro diretório de build: `SCRATCH_PATH=/caminho scripts/bundle.sh`.

## Instalar

```sh
scripts/bundle.sh --install          # copia para /Applications (encerra a instância em execução antes)
scripts/bundle.sh --install --open   # instala e abre
```

Ou manualmente: `cp -R build/BGBar.app /Applications/`.

## Abrir ao iniciar sessão

Ative "Abrir ao iniciar sessão" no menu ⋯ do app (usa `SMAppService`). Também dá para gerenciar em Ajustes do Sistema > Geral > Itens de Início. Funciona melhor com o app instalado em `/Applications`.

## O que monitora e como

| Fonte | Coleta |
| --- | --- |
| LaunchAgents | `launchctl print gui/<uid>/<label>` (estado, PID, último código de saída) |
| Docker | `docker ps -a`, `docker inspect` (início do container), `docker stats --no-stream` (CPU/mem) |
| Processos de dev | `ps` (PID, PPID, uptime, CPU, mem, comando) |
| Portas, cwd e logs | `lsof` (portas TCP em `LISTEN`, diretório de trabalho e stdout/stderr redirecionados para arquivo) |

As ações usam as mesmas ferramentas: `launchctl` para agentes, `docker` para containers e sinais `TERM`/`KILL` para processos.

### Filtros de ruído

Na seção de processos de dev entram só runtimes conhecidos (bun, node, deno, python, ruby, tsx, uvicorn, go, cargo etc.). Ficam de fora:

- executáveis dentro de um `.app` (helpers de apps Electron, editores);
- ruído conhecido de ferramentas/IDEs (`/_npx/`, `/.vscode/`, `/.cursor/`, `Code Helper` e afins);
- processos com menos de 30 s de vida (execuções curtas);
- filhos de outro processo já listado: um `bun run dev` que sobe `node vite` vira um item só.

## Fixar e ocultar

Itens fixados ficam no topo, mesmo quando param (aparecem como parados). Itens ocultos somem da lista; há uma opção para mostrá-los de novo. As preferências ficam em `UserDefaults` (domínio `dev.fernandoeeu.bgbar`):

```sh
defaults read dev.fernandoeeu.bgbar
```

## Notificações

Na primeira execução o macOS pede permissão para notificações; autorize para ser avisado quando um agente, container ou processo cair. Se negou, reative em Ajustes do Sistema > Notificações > BGBar.

## Desenvolvimento

```sh
swift build        # build de debug
swift run BGBar    # roda sem bundle (notificações e login item não funcionam fora do .app)
swift test         # testes
```

## Licença

MIT. Veja [LICENSE](LICENSE).
