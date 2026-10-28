# Projeto 2 — Ambiente de Execução de Programas via Web

**Computação em Nuvem — Escola Politécnica, PUC Campinas (2026)**
Professor: Antonio Forster · **Entrega: 31/10**

Plataforma web que permite criar ambientes isolados de execução (namespaces), limitar seus recursos (cgroups: CPU, memória e IO), executar comandos ou scripts dentro deles, acompanhar o output e gerenciar o ciclo de vida de vários ambientes ao mesmo tempo.

> **Este README é o documento de trabalho do grupo.** Ele define a arquitetura, a divisão das tarefas e os **contratos** entre as partes. Se cada um seguir os contratos, as três partes são desenvolvidas em paralelo e só se encontram na integração. Leia o documento inteiro antes de começar, não só a sua seção.

---

## Sumário

1. [O que o professor pede](#1-o-que-o-professor-pede)
2. [Arquitetura](#2-arquitetura)
3. [Divisão do trabalho](#3-divisão-do-trabalho)
4. [Estrutura do repositório](#4-estrutura-do-repositório)
5. [Contratos entre as partes (LEIA ANTES DE CODAR)](#5-contratos-entre-as-partes)
6. [Parte A — Infraestrutura](#6-parte-a--infraestrutura)
7. [Parte B — Motor de execução](#7-parte-b--motor-de-execução)
8. [Parte C — Aplicação web](#8-parte-c--aplicação-web)
9. [Testes (obrigatório para cada parte)](#9-testes)
10. [Integração e teste de ponta a ponta](#10-integração-e-teste-de-ponta-a-ponta)
11. [Fluxo de Git e commits](#11-fluxo-de-git-e-commits)
12. [Cronograma](#12-cronograma)
13. [Preparação para a avaliação](#13-preparação-para-a-avaliação)

---

## 1. O que o professor pede

### Funcionalidades

O usuário, pela web, deve conseguir:

| # | Requisito | Onde é atendido |
|---|---|---|
| F1 | Criar um novo ambiente de execução (via namespace) | Motor (`envctl create`) + App |
| F2 | Definir os recursos alocados: CPU, memória e IO | Motor (cgroups) + App (formulário) |
| F3 | Definir o que executar: programa, programas ou script | App (formulário) + Motor |
| F4 | Enviar scripts via formulário e mantê-los armazenados para reuso | App (upload + MySQL) |
| F5 | Output direcionado a arquivo e visualizado quando desejado | Motor (log em arquivo) + App (tela de log) |
| F6 | Suportar programas que não terminam (serviços) | Motor (execução em background, desacoplada da requisição) |
| F7 | Listar ambientes e ver status: em execução / terminado / erro | Motor (`status`/`list`) + App |
| F8 | Vários ambientes simultâneos, cada um com seus cgroups/namespaces | Motor (um cgroup por ambiente) |
| F9 | Terminar e remover ambientes | Motor (`stop`/`remove`) + App |

### Requisitos de infraestrutura

| # | Requisito | Onde é atendido |
|---|---|---|
| I1 | Uma VM com pelo menos 1 core e 4096 MB | Vagrantfile |
| I2 | Interface web; sugestão de Apache como webserver | Apache como proxy reverso para Node/Express |
| I3 | Tudo criado e gerenciado via Vagrant (VirtualBox) | Vagrantfile |
| I4 | Armazenamento permanente de dados; sugestão MySQL | MySQL na mesma VM |
| I5 | Código no GitHub, acessível pela rede da PUC | Este repositório |
| I6 | Toda a carga a partir do Vagrantfile; todo provisionamento (inclusive `git clone`) no provision | `provision/provision.sh` |

### Critérios de avaliação

- Funcionamento da solução
- Aderência à arquitetura solicitada
- Setups dos componentes
- **Qualquer integrante pode ser questionado sobre qualquer parte** — veja a [seção 13](#13-preparação-para-a-avaliação).

---

## 2. Arquitetura

```
┌──────────────────────────── Host (Windows + VirtualBox) ────────────────────────────┐
│                                                                                     │
│   Browser ──► localhost:8080 ──(port forward)──┐                                    │
│                                                ▼                                    │
│   ┌──────────────────────── VM ubuntu/jammy64 (1 CPU, 4096 MB) ─────────────────┐   │
│   │                                                                             │   │
│   │   Apache :80  ──(mod_proxy)──►  Node/Express :3000  ──►  MySQL :3306        │   │
│   │                                       │                  (banco "envs")     │   │
│   │                                       │ sudo envctl ...                     │   │
│   │                                       ▼                                     │   │
│   │                          /usr/local/bin/envctl (root)                       │   │
│   │                                       │                                     │   │
│   │            ┌──────────────────────────┼──────────────────────────┐          │   │
│   │            ▼                          ▼                          ▼          │   │
│   │   cgroup envs/1              cgroup envs/2              cgroup envs/N       │   │
│   │   cpu/mem/io limits          cpu/mem/io limits          cpu/mem/io limits   │   │
│   │   ns: pid,mnt,uts,ipc        ns: pid,mnt,uts,ipc        ns: pid,mnt,uts,ipc │   │
│   │   output.log                 output.log                 output.log          │   │
│   └─────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Fluxo de uma requisição "criar ambiente"

1. Usuário preenche o formulário (CPU %, memória MB, IO MB/s, comando ou script salvo).
2. Apache recebe em `:80` e repassa para o Express em `127.0.0.1:3000`.
3. Express valida os dados e insere uma linha em `environments` (status `creating`), obtendo o `id`.
4. Express chama `sudo /usr/local/bin/envctl create <id> ...` via `execFile`.
5. `envctl` cria o cgroup, aplica os limites, inicia o programa dentro de novos namespaces em background, grava o PID e **retorna imediatamente** um JSON.
6. Express atualiza a linha no banco com PID e status e responde ao browser.
7. O programa continua rodando independente da requisição; o output vai para `/var/lib/envs/<id>/output.log`.

### Decisões técnicas (e o porquê)

| Decisão | Motivo |
|---|---|
| Box `ubuntu/jammy64` (22.04), **não** `focal64` | Jammy usa **cgroups v2** (hierarquia unificada) por padrão. Focal usa modo híbrido v1, onde `cpu.max`, `memory.max`, `io.max` e `cgroup.kill` não funcionam como descrito aqui. |
| Apache só como proxy reverso | Atende a sugestão do professor e deixa a lógica no Node, que o grupo domina. |
| Motor isolado num script (`envctl`) | Só ele roda como root. A aplicação web roda como usuário comum e só pode chamar esse único binário via sudoers. Menor superfície de risco e partes desacopladas. |
| cgroups manipulados direto em `/sys/fs/cgroup` | Mostra o mecanismo de verdade na avaliação, sem esconder atrás de `systemd-run` ou Docker. |
| `unshare` para namespaces | Ferramenta padrão do util-linux, já instalada; cria namespaces PID, mount, UTS e IPC. |
| Status consultado ao vivo no motor | O processo pode terminar sozinho a qualquer momento; o banco é cache, o motor é a fonte da verdade. |

---

## 3. Divisão do trabalho

| | **A — Infraestrutura** | **B — Motor de execução** | **C — Aplicação web** |
|---|---|---|---|
| **Responsável** | João Victor | Otávio Augusto | Vinicius Felippe |
| **Pasta no repo** | `Vagrantfile`, `provision/` | `engine/` | `app/` |
| **Entrega** | VM sobe do zero com tudo instalado e configurado | Script `envctl` que cria/consulta/encerra ambientes | API Express + interface web |
| **Dificuldade** | Menor (base do Lab 2) | Maior (conceitos novos) | Média (mais volume de código) |
| **Depende de** | Nada (usa contratos) | Nada (testa direto na VM) | Nada (usa o mock do `envctl`) |
| **Vai defender** | Vagrant, provision, Apache proxy, sudoers, systemd | Namespaces, cgroups, processos em background, status | Rotas, persistência, upload, chamada ao motor |

> Como cada parte vive numa pasta própria, **não existe conflito de merge** entre as partes. O único ponto de encontro são os contratos da seção 5.

---

## 4. Estrutura do repositório

```
projeto2/
├── README.md                      ← este arquivo
├── Vagrantfile                    ← A
├── provision/                     ← A
│   ├── provision.sh               ← script principal chamado pelo Vagrantfile
│   ├── apache/envs.conf           ← vhost com proxy reverso
│   ├── mysql/schema.sql           ← criação do banco e tabelas (contrato 5.3)
│   ├── systemd/envweb.service     ← serviço do Node
│   └── sudoers/envctl             ← libera só o envctl para o usuário envweb
├── engine/                        ← B
│   ├── envctl                     ← o motor (bash)
│   └── tests/test_envctl.sh       ← testes automatizados do motor
└── app/                           ← C
    ├── package.json
    ├── .env.example
    ├── src/
    │   ├── server.js
    │   ├── db.js
    │   ├── envctl.js              ← único arquivo que chama o motor
    │   └── routes/
    │       ├── environments.js
    │       └── scripts.js
    ├── public/                    ← HTML/CSS/JS da interface
    ├── mock/envctl                ← mock do motor (contrato 5.6)
    └── tests/                     ← testes das rotas
```

---

## 5. Contratos entre as partes

> **Regra de ouro:** nada nesta seção muda sem que as pessoas afetadas concordem **antes**. Se mudar, atualiza-se este README e o mock no mesmo commit.

### 5.1 Caminhos e usuários fixos

| Item | Valor | Dono |
|---|---|---|
| Diretório do código na VM | `/opt/projeto2` (clonado do GitHub) | A |
| Binário do motor | `/usr/local/bin/envctl` (cópia de `engine/envctl`, `root:root`, `755`) | A instala, B escreve |
| Usuário que roda o Node | `envweb` (sem login, sem senha) | A |
| Dados dos ambientes | `/var/lib/envs/<id>/` (`root:root`) | B |
| Scripts enviados | `/var/lib/envs/scripts/<script_id>.sh` (`envweb:envweb`, `750`) | A cria a pasta, C grava, B lê |
| Raiz dos cgroups | `/sys/fs/cgroup/envs/` | B |
| Porta do Node | `3000`, escutando só em `127.0.0.1` | C |
| Porta do Apache | `80` na VM → `8080` no host | A |

### 5.2 Permissão sudo

Arquivo `/etc/sudoers.d/envctl`:

```
envweb ALL=(root) NOPASSWD: /usr/local/bin/envctl
```

O usuário `envweb` pode rodar **somente** o `envctl` como root, sem senha. Nada mais.

### 5.3 Banco de dados

Banco `envs`, usuário `envweb` com senha definida no provision e lida pela app via `.env`.

```sql
CREATE TABLE scripts (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(100)  NOT NULL,
  filename    VARCHAR(255)  NOT NULL,
  description VARCHAR(255)  NULL,
  created_at  TIMESTAMP     DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE environments (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(100)  NOT NULL,
  cpu_percent INT           NOT NULL,
  memory_mb   INT           NOT NULL,
  io_mbps     INT           NOT NULL,
  mode        ENUM('cmd','script') NOT NULL,
  command     TEXT          NULL,
  script_id   INT           NULL,
  pid         INT           NULL,
  status      ENUM('creating','running','finished','error','stopped') NOT NULL DEFAULT 'creating',
  exit_code   INT           NULL,
  created_at  TIMESTAMP     DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (script_id) REFERENCES scripts(id)
);
```

O **conteúdo** do script fica no disco (`/var/lib/envs/scripts/`), o banco guarda os metadados.

### 5.4 Interface do `envctl`

| Comando | Saída (stdout) |
|---|---|
| `envctl create <id> --cpu <1-100> --mem <MB> --io <MB/s> --cmd "<comando>"` | JSON |
| `envctl create <id> --cpu <1-100> --mem <MB> --io <MB/s> --script <caminho>` | JSON |
| `envctl status <id>` | JSON |
| `envctl list` | JSON (array) |
| `envctl logs <id> [--tail <N>]` | **texto puro** |
| `envctl stop <id>` | JSON |
| `envctl remove <id>` | JSON |

**Unidades e limites aceitos:**

| Parâmetro | Unidade | Faixa válida |
|---|---|---|
| `--cpu` | % de um core | 1 a 100 |
| `--mem` | MB | 32 a 2048 |
| `--io` | MB/s (leitura e escrita) | 1 a 500 |
| `<id>` | inteiro positivo | vem do auto-increment do banco |

`--cmd` e `--script` são mutuamente exclusivos; exatamente um deles é obrigatório.

### 5.5 Formato das respostas

**Sucesso (`create`, `status`, `stop`):**

```json
{"id": 12, "pid": 4821, "status": "running", "exit_code": null}
```

**`list`:**

```json
[
  {"id": 12, "pid": 4821, "status": "running",  "exit_code": null},
  {"id": 13, "pid": 4900, "status": "finished", "exit_code": 0}
]
```

**`remove`:**

```json
{"id": 12, "removed": true}
```

**Valores de `status`:**

| Status | Significado |
|---|---|
| `running` | Ainda há processos vivos no cgroup |
| `finished` | Terminou sozinho com código 0 |
| `error` | Terminou com código ≠ 0, foi morto pelo kernel (ex.: estouro de memória) ou falhou ao iniciar |
| `stopped` | Encerrado pelo usuário via `stop` |

**Erro:** stdout traz `{"error": "mensagem legível"}` e o processo sai com:

| Código de saída | Significado | Sugestão de HTTP na app |
|---|---|---|
| 0 | OK | 200 / 201 |
| 1 | Argumento inválido | 400 |
| 2 | Ambiente não existe | 404 |
| 3 | Ambiente já existe | 409 |
| 4 | Falha interna (cgroup, permissão, disco) | 500 |

### 5.6 Mock do motor (para a Parte C desenvolver sem depender da B)

Arquivo `app/mock/envctl`:

```bash
#!/bin/bash
case "$1" in
  create) echo "{\"id\": $2, \"pid\": $RANDOM, \"status\": \"running\", \"exit_code\": null}" ;;
  status) echo "{\"id\": $2, \"pid\": 1234, \"status\": \"running\", \"exit_code\": null}" ;;
  list)   echo '[{"id": 1, "pid": 1234, "status": "running", "exit_code": null}, {"id": 2, "pid": 1300, "status": "finished", "exit_code": 0}]' ;;
  logs)   printf "linha 1 do output\nlinha 2 do output\n" ;;
  stop)   echo "{\"id\": $2, \"pid\": null, \"status\": \"stopped\", \"exit_code\": null}" ;;
  remove) echo "{\"id\": $2, \"removed\": true}" ;;
  *)      echo '{"error": "comando invalido"}'; exit 1 ;;
esac
```

A app lê o caminho do motor de uma variável de ambiente (`ENVCTL_PATH`), então trocar mock por motor real é só mudar o `.env`.

---

## 6. Parte A — Infraestrutura

**Objetivo:** `vagrant up` numa máquina limpa resulta numa VM com a aplicação acessível em `http://localhost:8080`, sem nenhum passo manual.

### 6.1 Vagrantfile

- Box `ubuntu/jammy64`.
- `vb.cpus = 1`, `vb.memory = 4096`, `vb.gui = false`.
- `config.vm.boot_timeout = 600`.
- `forwarded_port guest: 80, host: 8080`.
- Hostname `projeto2`.
- Provision via `provision/provision.sh`. **Atenção:** o professor exige `git clone` no provision. Então o Vagrantfile pode trazer só o `provision.sh` (inline ou via `/vagrant`), mas o código da app e do motor tem que vir do GitHub.

### 6.2 `provision.sh` — ordem recomendada

1. `set -e` no topo (o provision já roda como root, não usar `sudo`).
2. `apt-get update` e instalar: `apache2`, `mysql-server`, `git`, `curl`, `util-linux`, `python3`.
3. Instalar Node.js 20 (repositório NodeSource).
4. Criar usuário `envweb`: `useradd --system --no-create-home --shell /usr/sbin/nologin envweb`.
5. `git clone` do repositório em `/opt/projeto2` (se já existir, `git pull` para o provision ser reexecutável).
6. MySQL: criar banco `envs`, usuário `envweb` com senha, aplicar `provision/mysql/schema.sql`.
7. App: `npm ci --omit=dev` em `/opt/projeto2/app`; gerar `/opt/projeto2/app/.env` com credenciais e `ENVCTL_PATH=/usr/local/bin/envctl`.
8. Motor: `install -o root -g root -m 755 /opt/projeto2/engine/envctl /usr/local/bin/envctl`.
9. Pastas: `mkdir -p /var/lib/envs/scripts`, dono `envweb:envweb` em `scripts/`.
10. Sudoers: copiar `provision/sudoers/envctl` para `/etc/sudoers.d/envctl`, `chmod 440`, **validar com `visudo -cf`** (sudoers inválido quebra o sudo da VM inteira).
11. Apache: `a2enmod proxy proxy_http`, habilitar `envs.conf`, desabilitar `000-default`, `systemctl reload apache2`.
12. systemd: copiar `envweb.service`, `systemctl daemon-reload`, `systemctl enable --now envweb`.

### 6.3 Vhost do Apache (`provision/apache/envs.conf`)

```apache
<VirtualHost *:80>
    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:3000/
    ProxyPassReverse / http://127.0.0.1:3000/
    ErrorLog  ${APACHE_LOG_DIR}/envs_error.log
    CustomLog ${APACHE_LOG_DIR}/envs_access.log combined
</VirtualHost>
```

### 6.4 Serviço systemd (`provision/systemd/envweb.service`)

```ini
[Unit]
Description=Projeto 2 - Aplicacao web
After=network.target mysql.service

[Service]
User=envweb
WorkingDirectory=/opt/projeto2/app
EnvironmentFile=/opt/projeto2/app/.env
ExecStart=/usr/bin/node src/server.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

### 6.5 Como desenvolver sem esperar as outras partes

- Enquanto `engine/envctl` e `app/` não existem, crie versões vazias (um `envctl` que é o mock e um `server.js` que responde "ok" em `/`). Assim você valida o provision inteiro desde o primeiro dia.
- Quando B e C fizerem push, o provision passa a trazer o código real automaticamente.

### 6.6 Pegadinhas conhecidas (vindas do Lab 2)

- `sudo` dentro do provision descarta variáveis como `DEBIAN_FRONTEND`. Rode tudo direto como root.
- Sudoers com erro de sintaxe trava o sudo da VM. Sempre `visudo -cf` antes de copiar.
- O provision precisa ser **idempotente** (`vagrant provision` duas vezes não pode quebrar): use `CREATE ... IF NOT EXISTS`, `mkdir -p`, `id envweb || useradd ...`.

---

## 7. Parte B — Motor de execução

**Objetivo:** o script `engine/envctl` implementa exatamente o contrato da seção 5.4/5.5.

### 7.1 Conceitos que você precisa dominar

| Conceito | O que isola / limita | Como aparece no projeto |
|---|---|---|
| Namespace PID | Árvore de processos própria; o programa vê a si mesmo como PID 1 | `unshare --pid --fork --mount-proc` |
| Namespace mount | `/proc` próprio, montagens não vazam para o host | `--mount-proc` (implica `--mount`) |
| Namespace UTS | Hostname próprio | `--uts` + `hostname env-<id>` |
| Namespace IPC | Filas/semáforos/memória compartilhada próprios | `--ipc` |
| cgroup `cpu.max` | Fração de CPU por período | `"<quota> <período>"` |
| cgroup `memory.max` | Teto de memória; acima disso o kernel mata (OOM) | bytes |
| cgroup `io.max` | Taxa de leitura/escrita em disco | `"<maj:min> rbps=<B/s> wbps=<B/s>"` |
| `cgroup.kill` | Mata todos os processos do cgroup de uma vez | `echo 1 > cgroup.kill` |

### 7.2 Layout em disco de um ambiente

```
/var/lib/envs/<id>/
├── output.log     ← stdout + stderr do programa
├── pid            ← PID do processo principal (visto pelo host)
├── exit_code      ← só existe depois que o programa termina
├── stopped        ← só existe se o usuário chamou stop
└── command        ← o que foi executado (para auditoria/depuração)

/sys/fs/cgroup/envs/<id>/
├── cpu.max
├── memory.max
├── memory.swap.max
├── io.max
├── cgroup.procs
└── cgroup.kill
```

### 7.3 Passo a passo do `create`

1. **Validar argumentos** (faixas da seção 5.4). Inválido → `{"error": ...}`, exit 1.
2. Se `/var/lib/envs/<id>` já existe → exit 3.
3. **Habilitar controladores** no pai (idempotente):
   ```bash
   echo "+cpu +memory +io" > /sys/fs/cgroup/cgroup.subtree_control
   mkdir -p /sys/fs/cgroup/envs
   echo "+cpu +memory +io" > /sys/fs/cgroup/envs/cgroup.subtree_control
   ```
   Sem isso, os arquivos `cpu.max`, `memory.max` e `io.max` **nem aparecem** no cgroup filho.
4. **Criar o cgroup** `/sys/fs/cgroup/envs/<id>` e gravar os limites:
   - CPU: período de 100000 µs, quota = `cpu% × 1000`. Ex.: 50% → `echo "50000 100000" > cpu.max`.
   - Memória: `MB × 1048576` em `memory.max`, e `0` em `memory.swap.max` (senão o processo "foge" do limite usando swap).
   - IO: descobrir o disco raiz dinamicamente e gravar `"<maj:min> rbps=<X> wbps=<X>"`, com X = `MB/s × 1048576`.
     ```bash
     PARENT=$(lsblk -ndo PKNAME "$(findmnt -no SOURCE /)")
     DEV=$(lsblk -ndo MAJ:MIN "/dev/$PARENT" | tr -d ' ')
     ```
     O `io.max` precisa do disco inteiro (ex.: `sda` → `8:0`), não da partição (`sda1`).
5. **Iniciar o programa desacoplado**, entrando no cgroup **antes** de executar o comando:
   - O processo intermediário escreve o próprio PID (`$$`) em `cgroup.procs`; a partir daí tudo que ele criar herda os limites.
   - Em seguida executa `unshare --pid --fork --mount-proc --uts --ipc` rodando o comando (`bash -c "<cmd>"` ou `bash <script>`).
   - Quando o `unshare` retorna, grava o código de saída em `exit_code`.
   - Tudo isso com `setsid` + `nohup`, redirecionando stdout/stderr para `output.log` e stdin de `/dev/null`.
6. Gravar `pid` e `command`, imprimir o JSON e **sair imediatamente**.

> ⚠️ **A pegadinha mais importante da parte B:** se o processo em background herdar o stdout/stderr do `envctl`, o `execFile` do Node fica esperando o pipe fechar e a requisição HTTP trava até o programa terminar (ou para sempre, no caso de um serviço). O processo em background **precisa** ter stdin, stdout e stderr redirecionados para arquivos/`/dev/null` e estar numa nova sessão (`setsid`).

### 7.4 Lógica do `status`

Avaliar nesta ordem:

1. Pasta não existe → exit 2.
2. Arquivo `stopped` existe → `stopped`.
3. `cgroup.procs` não está vazio → `running`.
4. `exit_code` existe e é `0` → `finished`.
5. `exit_code` existe e é ≠ 0 → `error`.
6. Nenhum processo e nenhum `exit_code` (o kernel matou tudo, ex.: OOM) → `error`.

Para diferenciar OOM, o arquivo `memory.events` do cgroup mostra o contador `oom_kill`. Bom ponto para mencionar na avaliação.

### 7.5 `stop`, `remove`, `logs`, `list`

- **stop:** criar o arquivo `stopped` e `echo 1 > cgroup.kill`. Funciona mesmo para programas que nunca terminam e mata filhos, netos etc.
- **remove:** se estiver rodando, fazer o `stop`; esperar `cgroup.procs` esvaziar; `rmdir` no cgroup (só funciona vazio; é `rmdir`, não `rm -rf`); `rm -rf /var/lib/envs/<id>`.
- **logs:** `cat` ou `tail -n N` do `output.log`. Texto puro, sem JSON.
- **list:** percorrer `/var/lib/envs/*/` (ignorando `scripts/`) e montar o array com a mesma lógica do `status`.

### 7.6 Como desenvolver sem esperar as outras partes

- Suba qualquer VM `ubuntu/jammy64` (até um Vagrantfile mínimo seu) e desenvolva o `envctl` direto nela via `vagrant ssh` + `sudo`.
- Você não precisa de Apache, Node nem MySQL para testar o motor: o contrato é a linha de comando.

---

## 8. Parte C — Aplicação web

**Objetivo:** API REST + interface web que cobre todos os requisitos F1–F9, falando com o motor **apenas** pelo contrato da seção 5.

### 8.1 Configuração (`.env.example`)

```
PORT=3000
HOST=127.0.0.1
DB_HOST=localhost
DB_USER=envweb
DB_PASS=troque_no_provision
DB_NAME=envs
ENVCTL_PATH=/usr/local/bin/envctl
SCRIPTS_DIR=/var/lib/envs/scripts
```

Em desenvolvimento local: `ENVCTL_PATH=./mock/envctl` e `SCRIPTS_DIR=./tmp/scripts`.

### 8.2 Rotas da API

| Método | Rota | Função | Respostas |
|---|---|---|---|
| GET | `/api/scripts` | Lista scripts salvos | 200 |
| POST | `/api/scripts` | Upload (multipart: `name`, `description`, `file`) | 201, 400 |
| GET | `/api/scripts/:id` | Metadados + conteúdo do script | 200, 404 |
| DELETE | `/api/scripts/:id` | Remove (bloquear se algum ambiente usa) | 204, 404, 409 |
| GET | `/api/environments` | Lista com **status atualizado** via `envctl list` | 200 |
| POST | `/api/environments` | Cria (`name`, `cpu_percent`, `memory_mb`, `io_mbps`, `mode`, `command` ou `script_id`) | 201, 400 |
| GET | `/api/environments/:id` | Detalhes + status atual | 200, 404 |
| GET | `/api/environments/:id/logs?tail=N` | Output (texto) | 200, 404 |
| POST | `/api/environments/:id/stop` | Encerra | 200, 404 |
| DELETE | `/api/environments/:id` | Remove ambiente e linha do banco | 204, 404 |

### 8.3 Regras importantes

- **Um único arquivo (`src/envctl.js`) chama o motor.** O resto da app chama funções desse módulo (`create()`, `status()`, ...). Se o contrato mudar, só esse arquivo muda.
- **Sempre `execFile`, nunca `exec`:**
  ```js
  execFile('sudo', [process.env.ENVCTL_PATH, 'status', String(id)], { timeout: 10000 }, cb)
  ```
  Em desenvolvimento com o mock, chamar o mock direto (sem `sudo`).
- **Traduzir o código de saída do motor em HTTP** usando a tabela da seção 5.5.
- **Validar no backend** as mesmas faixas da seção 5.4, antes de chamar o motor. Validação só no HTML não conta.
- **Criação em duas etapas:** insere no banco (`creating`) → chama `envctl create` → atualiza com `pid` e `status`. Se o motor falhar, marca como `error`.
- **Upload:** usar `multer`, limite de tamanho (ex.: 1 MB), salvar como `<script_id>.sh` em `SCRIPTS_DIR`. Nunca usar o nome de arquivo enviado pelo usuário como caminho.
- **Ao listar,** sincronizar o banco com o resultado de `envctl list` (o processo pode ter terminado desde a última consulta).

### 8.4 Interface web (`public/`)

HTML + JS simples é suficiente. Telas mínimas:

1. **Ambientes:** tabela com nome, recursos, status (com cor), botões *Ver output*, *Terminar*, *Remover*. Atualização automática a cada poucos segundos.
2. **Novo ambiente:** formulário com CPU, memória, IO e escolha entre *comando* ou *script salvo*.
3. **Scripts:** lista dos salvos + formulário de upload.
4. **Output:** exibe o log com atualização automática enquanto o status for `running` (atende o caso do serviço que nunca termina).

### 8.5 Como desenvolver sem esperar as outras partes

- Rode MySQL local (ou Docker) e aplique `provision/mysql/schema.sql`.
- Aponte `ENVCTL_PATH` para `app/mock/envctl`.
- Todas as telas e rotas podem ser feitas e testadas com o mock.

---

## 9. Testes

> **Nenhuma parte está "pronta" sem testes passando.** Cada um entrega sua parte com os testes abaixo executados e o resultado colado no Pull Request. Isso evita que a integração de sexta vire uma caça a bugs que já podiam ter sido achados na quinta — e o professor vai testar exatamente essas coisas na avaliação.

### 9.1 Testes da Parte A (Infraestrutura)

Executar a partir de uma VM **destruída**:

```bash
vagrant destroy -f && vagrant up
```

| # | Teste | Comando | Esperado |
|---|---|---|---|
| A1 | VM sobe sem erro | `vagrant up` | Termina sem nenhum passo vermelho |
| A2 | Recursos da VM | `nproc` / `free -m` | 1 CPU / ~4096 MB |
| A3 | cgroups v2 | `stat -fc %T /sys/fs/cgroup` | `cgroup2fs` |
| A4 | Código clonado | `git -C /opt/projeto2 log -1` | Último commit do GitHub |
| A5 | Banco | `mysql -u envweb -p envs -e "SHOW TABLES"` | `scripts`, `environments` |
| A6 | Serviço Node | `systemctl is-active envweb` | `active` |
| A7 | Apache proxy | `curl -I http://localhost` (dentro da VM) | 200 |
| A8 | Acesso pelo host | abrir `http://localhost:8080` | Interface carrega |
| A9 | Sudoers | `sudo -u envweb sudo -n /usr/local/bin/envctl list` | JSON, sem pedir senha |
| A10 | Sudoers restrito | `sudo -u envweb sudo -n ls /root` | **Negado** |
| A11 | Idempotência | `vagrant provision` | Roda de novo sem erro |

### 9.2 Testes da Parte B (Motor)

Automatizar em `engine/tests/test_envctl.sh` (rodar como root na VM).

| # | Cenário | Como | Esperado |
|---|---|---|---|
| B1 | Comando que termina | `create 101 ... --cmd "echo ola"` e depois `status 101` | `finished`, `exit_code: 0`, log contém `ola` |
| B2 | Comando com erro | `--cmd "exit 3"` | `error`, `exit_code: 3` |
| B3 | Serviço que não termina | `--cmd "while true; do date; sleep 1; done"` | `running`; log cresce; `create` retorna na hora |
| B4 | Stop | `stop` no B3 | `stopped`; nenhum processo restante em `cgroup.procs` |
| B5 | Remove | `remove` no B3 | Pasta e cgroup apagados; `status` → exit 2 |
| B6 | Limite de CPU | `--cpu 20 --cmd "yes > /dev/null"` e `top` | Processo em ~20% de CPU |
| B7 | Limite de memória | `--mem 64 --cmd "python3 -c \"a = ' ' * 200 * 1024 * 1024\""` | `error`; `memory.events` mostra `oom_kill 1` |
| B8 | Limite de IO | `--io 5 --cmd "dd if=/dev/zero of=/tmp/t bs=1M count=50 oflag=direct"` | Taxa ~5 MB/s no log do `dd` |
| B9 | Namespace PID | `--cmd "ps aux"` | Log mostra o comando como PID 1, sem processos do host |
| B10 | Namespace UTS | `--cmd "hostname"` | Hostname do ambiente, não `projeto2` |
| B11 | Script | `--script /var/lib/envs/scripts/teste.sh` | Executa o conteúdo do script |
| B12 | Simultâneos | criar 3 ambientes ao mesmo tempo | `list` mostra os 3, cada um com seu status |
| B13 | Argumentos inválidos | `--cpu 0`, `--cpu 150`, sem `--cmd`/`--script`, ambos | exit 1 com JSON de erro |
| B14 | ID duplicado | `create` com ID existente | exit 3 |
| B15 | Não trava o chamador | `time envctl create ... --cmd "sleep 300"` | Retorna em menos de 1 s |

### 9.3 Testes da Parte C (Aplicação web)

Testar as rotas com `curl` (ou automatizar com `jest` + `supertest`) primeiro contra o **mock**, depois contra o motor real.

| # | Rota / cenário | Esperado |
|---|---|---|
| C1 | `POST /api/environments` com dados válidos (modo `cmd`) | 201, linha criada no banco com `pid` |
| C2 | `POST /api/environments` com `cpu_percent: 0` ou `150` | 400, motor **não** é chamado |
| C3 | `POST /api/environments` com `command` e `script_id` juntos | 400 |
| C4 | `POST /api/environments` modo `script` com `script_id` inexistente | 400 ou 404 |
| C5 | `GET /api/environments` | 200, status vindo do `envctl list` |
| C6 | `GET /api/environments/999` | 404 |
| C7 | `GET /api/environments/:id/logs` | 200, texto do output |
| C8 | `POST /api/environments/:id/stop` | 200, status `stopped` |
| C9 | `DELETE /api/environments/:id` | 204, some da lista |
| C10 | `POST /api/scripts` com arquivo | 201, arquivo em `SCRIPTS_DIR`, linha no banco |
| C11 | `POST /api/scripts` sem arquivo / arquivo grande demais | 400 / 413 |
| C12 | `DELETE /api/scripts/:id` usado por um ambiente | 409 |
| C13 | Motor retorna exit 4 (simular no mock) | 500 com mensagem, app não cai |
| C14 | Nome de arquivo malicioso no upload (`../../etc/x`) | Salvo como `<id>.sh`, nada fora de `SCRIPTS_DIR` |
| C15 | Interface: todas as telas funcionam no navegador | Criar, listar, ver log, parar, remover, enviar script |

---

## 10. Integração e teste de ponta a ponta

Feito pelos três juntos, **na sexta**, a partir de `vagrant destroy -f && vagrant up`, usando só o navegador em `http://localhost:8080`. Cada linha corresponde a um requisito do professor:

| # | Roteiro | Requisito |
|---|---|---|
| E1 | Enviar um script pelo formulário; ele aparece na lista de scripts | F4 |
| E2 | Criar ambiente com CPU 50%, 256 MB, 10 MB/s usando o script | F1, F2, F3 |
| E3 | Criar ambiente com comando `while true; do date; sleep 1; done` | F3, F6 |
| E4 | Criar ambiente com comando `exit 1` | F7 |
| E5 | Lista mostra os três com status `finished`/`running`/`error` corretos | F7, F8 |
| E6 | Abrir o output do E3; o log continua crescendo | F5, F6 |
| E7 | Terminar o E3; status vira `stopped` | F9 |
| E8 | Remover os ambientes; somem da lista | F9 |
| E9 | Reiniciar a VM (`vagrant reload`); scripts salvos continuam lá | F4, I4 |
| E10 | Dentro da VM, `cat /sys/fs/cgroup/envs/<id>/cpu.max` de um ambiente ativo bate com o pedido | F2 |

Só considerar o projeto pronto quando **E1 a E10 passarem a partir de uma VM destruída**.

---

## 11. Fluxo de Git e commits

- `main` sempre funcional. Cada um trabalha numa branch: `infra`, `engine`, `app`.
- Merge na `main` via Pull Request, com o resultado dos testes da seção 9 na descrição.
- **Commits pequenos e frequentes**, com mensagem descritiva (`engine: aplica memory.max e memory.swap.max`). O professor avalia o histórico e pergunta sobre os commits de cada um.
- Mudança de contrato (seção 5): um commit só para isso, alterando README + mock juntos, revisado pelas pessoas afetadas.
- Nada de commit depois do prazo: a avaliação usa o último commit dentro da data.
- Se o professor pedir checksum na entrega: compactar o projeto e gerar `sha256sum projeto2.zip`.

---

## 12. Cronograma

| Dia | A — Infraestrutura | B — Motor | C — Aplicação web |
|---|---|---|---|
| **Qua 28/10** | Criar repositório, dar acesso, subir este README e a estrutura de pastas | Ler seção 7, subir VM jammy de testes | Ler seção 8, criar projeto Express e o mock |
| **Qui 29/10** | Vagrantfile + provision completos com placeholders; testes A1–A11 | `create`, `status`, `logs`; testes B1–B3, B9–B11, B15 | Rotas de ambientes e scripts contra o mock; testes C1–C14 |
| **Sex 30/10** | Integração: provision com o código real | `stop`, `remove`, `list`, limites; testes B4–B8, B12–B14 | Interface web; teste C15 com motor real |
| **Sex 30/10 (noite)** | **Todos:** roteiro E1–E10 a partir de VM destruída | | |
| **Sáb 31/10** | Correções finais, último commit, entrega | | |

---

## 13. Preparação para a avaliação

O professor pode perguntar **qualquer coisa a qualquer integrante**. Antes da entrega, cada um explica sua parte aos outros dois e todos devem saber responder:

**Infraestrutura**
- Por que `jammy64` e não `focal64`?
- Como o código chega à VM? (resposta: `git clone` no provision)
- O que o Apache faz aqui e por que o Node escuta só em `127.0.0.1`?
- Por que o Node não roda como root e como ele consegue executar o motor?

**Motor**
- Qual a diferença entre namespace e cgroup?
- Quais namespaces usamos e o que cada um isola?
- Como o limite de CPU é calculado em `cpu.max`?
- O que acontece quando um processo passa do `memory.max`? Como detectamos isso?
- Como um programa que nunca termina não trava a requisição HTTP?
- Como o `stop` mata também os processos filhos?

**Aplicação web**
- Por que `execFile` e não `exec`?
- Onde ficam os scripts e onde ficam os metadados?
- Por que o status é consultado no motor em vez de confiar no banco?
- Como a app trata um erro do motor?

**Conceitos gerais**
- Como esse projeto se relaciona com containers (Docker) e com computação em nuvem? (Docker usa exatamente namespaces + cgroups por baixo; aqui fizemos a mesma coisa "na mão".)
