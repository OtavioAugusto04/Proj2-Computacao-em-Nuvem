#!/bin/bash
# Testes automatizados do envctl (README, seção 9.2). Rodar como root na VM:
#   sudo bash tests/test_envctl.sh            # todos os testes
#   sudo bash tests/test_envctl.sh B1 B3      # só os escolhidos
# O caminho do motor pode ser trocado com ENVCTL=/caminho/envctl.
# Cada teste tem seus ids; ao fim de cada um, os ambientes dele são apagados
# com "envctl remove", mesmo se ele falhar. No fim, confere que nada sobrou.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ENVCTL=${ENVCTL:-$HERE/../envctl}
ENVS_DIR=/var/lib/envs
CG_ENVS=/sys/fs/cgroup/envs
LIMITS=(--cpu 50 --mem 128 --io 10)   # limites folgados para testes que não medem recurso

if [[ $EUID -ne 0 ]]; then
    echo "rode como root: sudo bash $0" >&2
    exit 1
fi
if [[ ! -x $ENVCTL ]]; then
    echo "envctl não encontrado ou sem permissão de execução: $ENVCTL" >&2
    exit 1
fi

# ---------------------------------------------------------------- helpers

# run <args...>: chama o envctl guardando stdout em OUT e o código de saída em RC.
# A captura por $(...) só termina quando TODOS os donos do pipe o fecham, igual
# ao execFile do Node: se o processo em background herdasse o stdout, travaria aqui.
run() {
    OUT=$("$ENVCTL" "$@")
    RC=$?
}

# jget <campo>: valor de um campo do JSON em OUT (strings sem aspas, null como null).
jget() {
    python3 -c '
import json, sys
v = json.loads(sys.argv[1])[sys.argv[2]]
print(v if isinstance(v, str) else json.dumps(v))' "$OUT" "$1" 2>/dev/null
}

# is_json <texto>: verdadeiro se o texto é JSON válido.
is_json() {
    python3 -c 'import json, sys; json.loads(sys.argv[1])' "$1" 2>/dev/null
}

# is_error_json: OUT é exatamente {"error": "<string>"}.
is_error_json() {
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
sys.exit(0 if list(d) == ["error"] and isinstance(d["error"], str) else 1)' "$OUT" 2>/dev/null
}

fail() {
    echo "    falhou: $*"
    T_OK=0
}

# expect <descrição> <obtido> <esperado>
expect() {
    [[ $2 == "$3" ]] || fail "$1: esperado '$3', obtido '$2'"
}

# wait_done <id> <segundos>: espera o ambiente sair de "running".
wait_done() {
    local i
    for (( i = 0; i < $2 * 10; i++ )); do
        run status "$1"
        [[ $(jget status) != running ]] && return 0
        sleep 0.1
    done
    return 1
}

now_ms() {
    echo $(( $(date +%s%N) / 1000000 ))
}

# Remove um ambiente de teste pelo próprio envctl. Exit 2 (não existe) é
# normal: o teste pode ter falhado antes de criar, ou já ter removido.
cleanup_env() {
    "$ENVCTL" remove "$1" >/dev/null
    case $? in
        0|2) ;;
        *) echo "    aviso: envctl remove $1 falhou" ;;
    esac
}

USED_IDS=()
# fresh <id>: garante que o id está livre (sobras de execuções anteriores) e o
# registra para limpeza no fim do teste.
fresh() {
    cleanup_env "$1"
    USED_IDS+=("$1")
}

cleanup_all() {
    local id
    for id in "${USED_IDS[@]}"; do cleanup_env "$id"; done
    USED_IDS=()
}
trap cleanup_all EXIT

# tree_pids <pid>: o pid e todos os seus descendentes.
tree_pids() {
    local p
    echo "$1"
    for p in $(ps -o pid= --ppid "$1"); do tree_pids "$p"; done
}

# still_alive <pids...>: imprime os que ainda existem.
still_alive() {
    local p
    for p in "$@"; do [[ -e /proc/$p ]] && echo "$p"; done
}

# is_removed_json <id>: OUT é exatamente {"id": <id>, "removed": true}.
is_removed_json() {
    python3 -c '
import json, sys
sys.exit(0 if json.loads(sys.argv[1]) == {"id": int(sys.argv[2]), "removed": True} else 1)' "$OUT" "$1" 2>/dev/null
}

# list_summary: "id:status:exit_code ..." de cada item do array em OUT, na ordem.
list_summary() {
    python3 -c '
import json, sys
print(" ".join("%s:%s:%s" % (e["id"], e["status"], json.dumps(e["exit_code"])) for e in json.loads(sys.argv[1])))' "$OUT" 2>/dev/null
}

# ---------------------------------------------------------------- testes

test_B1() {
    fresh 101
    run create 101 "${LIMITS[@]}" --cmd "echo ola"
    expect "código de saída do create" "$RC" 0
    is_json "$OUT" || fail "create não devolveu JSON válido: $OUT"
    expect "id" "$(jget id)" 101
    wait_done 101 5 || fail "não terminou em 5 s"
    expect "status" "$(jget status)" finished
    expect "exit_code" "$(jget exit_code)" 0
    grep -qx ola "$ENVS_DIR/101/output.log" || fail "output.log não contém 'ola'"
}

test_B2() {
    fresh 102
    run create 102 "${LIMITS[@]}" --cmd "exit 3"
    expect "código de saída do create" "$RC" 0
    wait_done 102 5 || fail "não terminou em 5 s"
    expect "status" "$(jget status)" error
    expect "exit_code" "$(jget exit_code)" 3
}

test_B3() {
    fresh 103
    local t0 elapsed size1 size2
    t0=$(now_ms)
    run create 103 "${LIMITS[@]}" --cmd "while true; do date; sleep 1; done"
    elapsed=$(( $(now_ms) - t0 ))
    expect "código de saída do create" "$RC" 0
    (( elapsed < 1000 )) || fail "create demorou ${elapsed} ms"
    expect "status logo após o create" "$(jget status)" running
    expect "exit_code" "$(jget exit_code)" null
    sleep 1.5
    size1=$(stat -c %s "$ENVS_DIR/103/output.log")
    sleep 2.5
    size2=$(stat -c %s "$ENVS_DIR/103/output.log")
    (( size2 > size1 )) || fail "log não cresceu ($size1 -> $size2 bytes)"
    run status 103
    expect "status depois de 4 s" "$(jget status)" running
    echo "    create em ${elapsed} ms; log ${size1} -> ${size2} bytes"
}

test_B4() {
    fresh 104
    fresh 140
    fresh 999999
    local log=$ENVS_DIR/104/output.log pids
    run create 104 "${LIMITS[@]}" --cmd "while true; do date; sleep 1; done"
    expect "código de saída do create" "$RC" 0
    sleep 1.5
    pids=$(tree_pids "$(jget pid)")
    echo "    antes do stop: $(ps -o comm=,pid= -p "$(echo $pids | tr ' ' ,)" | awk '{ printf "%s(%s) ", $1, $2 }')"
    run stop 104
    expect "código de saída do stop" "$RC" 0
    expect "status devolvido pelo stop" "$(jget status)" stopped
    echo "    stop -> $OUT"
    run status 104
    expect "status depois do stop" "$(jget status)" stopped
    [[ -z $(cat "$CG_ENVS/104/cgroup.procs") ]] || fail "cgroup.procs não está vazio"
    [[ -z $(still_alive $pids) ]] || fail "processos ainda vivos: $(still_alive $pids | tr '\n' ' ')"
    expect "última linha do log" "$(tail -n 1 "$log")" "[envctl] ambiente encerrado pelo usuário"
    echo "    log termina com: $(tail -n 1 "$log")"
    # Um segundo stop não muda nada nem repete a linha.
    run stop 104
    expect "segundo stop" "$(jget status)" stopped
    expect "linhas do envctl no log" "$(grep -c '^\[envctl\]' "$log")" 1

    # Ambiente que terminou sozinho: o stop não pode transformá-lo em stopped.
    run create 140 "${LIMITS[@]}" --cmd "echo fim"
    wait_done 140 5 || fail "não terminou em 5 s"
    run stop 140
    expect "código de saída do stop em finished" "$RC" 0
    expect "status depois do stop em finished" "$(jget status)" finished
    expect "exit_code depois do stop em finished" "$(jget exit_code)" 0
    [[ -e $ENVS_DIR/140/stopped ]] && fail "stop criou 'stopped' num ambiente finished"
    grep -q '^\[envctl\]' "$ENVS_DIR/140/output.log" && fail "stop escreveu no log de um ambiente finished"
    echo "    stop em finished -> $OUT"

    run stop 999999
    expect "stop de id inexistente" "$RC" 2
    is_error_json || fail "stop de id inexistente não devolveu {\"error\"}: $OUT"
}

test_B5() {
    fresh 105
    fresh 150
    fresh 999999
    local id pid before removed
    run create 105 "${LIMITS[@]}" --cmd "while true; do date; sleep 1; done"
    expect "código de saída do create 105" "$RC" 0
    run create 150 "${LIMITS[@]}" --cmd "echo fim"
    expect "código de saída do create 150" "$RC" 0
    wait_done 150 5 || fail "150 não terminou em 5 s"
    for id in 105 150; do
        run status "$id"
        before=$(jget status)
        pid=$(jget pid)
        run remove "$id"
        removed=$OUT
        expect "código de saída do remove $id" "$RC" 0
        is_removed_json "$id" || fail "remove $id devolveu: $OUT"
        [[ -e $ENVS_DIR/$id ]] && fail "pasta $ENVS_DIR/$id ainda existe"
        [[ -e $CG_ENVS/$id ]] && fail "cgroup $CG_ENVS/$id ainda existe"
        [[ -e /proc/$pid ]] && fail "pid $pid do ambiente $id ainda vivo"
        run status "$id"
        expect "status de $id depois do remove" "$RC" 2
        is_error_json || fail "status depois do remove não devolveu {\"error\"}: $OUT"
        echo "    $id ($before) -> $removed; status -> exit $RC $OUT"
    done
    run remove 999999
    expect "remove de id inexistente" "$RC" 2
    is_error_json || fail "remove de id inexistente não devolveu {\"error\"}: $OUT"
}

# cpu_usage <id>: tempo de CPU (µs) já consumido pelo cgroup do ambiente.
cpu_usage() {
    awk '$1 == "usage_usec" { print $2 }' "$CG_ENVS/$1/cpu.stat"
}

# in_range <valor> <min> <max>: comparação com decimais (o bash só faz inteiros).
in_range() {
    awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v != "" && v >= lo && v <= hi) }'
}

test_B6() {
    fresh 106
    local u1 u2 t1 t2 pct
    run create 106 --cpu 20 --mem 128 --io 10 --cmd "yes > /dev/null"
    expect "código de saída do create" "$RC" 0
    expect "cpu.max" "$(cat "$CG_ENVS/106/cpu.max")" "20000 100000"
    sleep 0.5
    u1=$(cpu_usage 106); t1=$(date +%s%N)
    sleep 3
    u2=$(cpu_usage 106); t2=$(date +%s%N)
    # µs de CPU usados pelo grupo / µs de relógio que passaram
    pct=$(awk -v du=$(( u2 - u1 )) -v dt=$(( (t2 - t1) / 1000 )) \
        'BEGIN { printf "%.1f", 100 * du / dt }')
    in_range "$pct" 15 25 || fail "uso de CPU fora de 15–25%: ${pct}%"
    run status 106
    expect "status" "$(jget status)" running
    echo "    cpu.max: $(cat "$CG_ENVS/106/cpu.max"); uso medido: ${pct}% em $(( (t2 - t1) / 1000000 )) ms"
}

# alloc_cmd <MB>: comando python que aloca e preenche <MB> megabytes. Precisa
# escrever na memória (b"x" * n): só reservar não conta para o cgroup.
alloc_cmd() {
    printf "python3 -c 'import sys; b = b\"x\" * (int(sys.argv[1]) << 20); print(\"alocou\", sys.argv[1], \"MB\")' %s" "$1"
}

test_B7() {
    fresh 107
    fresh 117
    local log=$ENVS_DIR/107/output.log oom
    # Excesso: 200 MB num limite de 64 MB.
    run create 107 --cpu 50 --mem 64 --io 10 --cmd "$(alloc_cmd 200)"
    expect "código de saída do create" "$RC" 0
    expect "memory.max" "$(cat "$CG_ENVS/107/memory.max")" 67108864
    expect "memory.swap.max" "$(cat "$CG_ENVS/107/memory.swap.max")" 0
    wait_done 107 15 || fail "não terminou em 15 s"
    expect "status com 200 MB" "$(jget status)" error
    oom=$(awk '$1 == "oom_kill" { print $2 }' "$CG_ENVS/107/memory.events")
    (( ${oom:-0} >= 1 )) || fail "memory.events sem oom_kill: $(tr '\n' ' ' < "$CG_ENVS/107/memory.events")"
    grep -qxF "[envctl] processo encerrado por exceder o limite de memória (64 MB)" "$log" \
        || fail "output.log sem a mensagem de OOM do envctl"
    grep -q alocou "$log" && fail "conseguiu alocar 200 MB com limite de 64 MB"
    echo "    200 MB: status $(jget status), exit_code $(jget exit_code), oom_kill $oom"
    sed 's/^/    | /' "$log"

    # Controle positivo: 20 MB cabem em 64 MB, então o limite não pode atrapalhar.
    run create 117 --cpu 50 --mem 64 --io 10 --cmd "$(alloc_cmd 20)"
    expect "código de saída do create" "$RC" 0
    wait_done 117 15 || fail "não terminou em 15 s"
    expect "status com 20 MB" "$(jget status)" finished
    expect "exit_code com 20 MB" "$(jget exit_code)" 0
    grep -qx "alocou 20 MB" "$ENVS_DIR/117/output.log" || fail "output.log sem 'alocou 20 MB'"
    echo "    20 MB: status $(jget status), exit_code $(jget exit_code)"
}

test_B8() {
    fresh 108
    local dst=$ENVS_DIR/108/dd.bin log=$ENVS_DIR/108/output.log line rate
    run create 108 --cpu 50 --mem 128 --io 5 \
        --cmd "dd if=/dev/zero of=$dst bs=1M count=25 oflag=direct"
    expect "código de saída do create" "$RC" 0
    # O destino precisa estar no disco limitado pelo io.max, não em memória.
    [[ $(findmnt -no FSTYPE -T "$ENVS_DIR/108") == tmpfs ]] && fail "destino do dd está em tmpfs"
    echo "    destino: $(findmnt -no TARGET,SOURCE,FSTYPE -T "$ENVS_DIR/108")"
    echo "    io.max: $(cat "$CG_ENVS/108/io.max")"
    wait_done 108 20 || fail "não terminou em 20 s"
    expect "status" "$(jget status)" finished
    line=$(grep copied "$log")
    echo "    dd: $line"
    rate=$(sed -nE 's#.*, ([0-9.]+) MB/s$#\1#p' <<<"$line")
    in_range "$rate" 3 7 || fail "taxa do dd fora de 3–7 MB/s: ${rate:-não encontrada}"
    rm -f -- "$dst"
    [[ -e $dst ]] && fail "não conseguiu apagar $dst"
}

# Montagens da VM, uma por linha. Usado para provar que o /proc montado pelo
# --mount-proc ficou só dentro do namespace de mount do ambiente.
mounts() {
    findmnt -rn -o TARGET,SOURCE,FSTYPE
}

test_B9() {
    fresh 109
    local before after log=$ENVS_DIR/109/output.log
    before=$(mounts)
    run create 109 "${LIMITS[@]}" --cmd "ps -eo pid,comm"
    expect "código de saída do create" "$RC" 0
    wait_done 109 5 || fail "não terminou em 5 s"
    expect "status" "$(jget status)" finished
    sed 's/^/    | /' "$log"
    awk '$1 == 1' "$log" | grep -q . || fail "log não mostra nenhum processo com PID 1"
    grep -wE 'systemd|sshd|cron|agetty' "$log" && fail "log mostra processos do host"
    after=$(mounts)
    [[ $before == "$after" ]] || fail "findmnt da VM mudou: $(diff <(echo "$before") <(echo "$after"))"
}

test_B10() {
    fresh 110
    local orig
    orig=$(hostname)
    run create 110 "${LIMITS[@]}" --cmd "hostname"
    expect "código de saída do create" "$RC" 0
    wait_done 110 5 || fail "não terminou em 5 s"
    expect "status" "$(jget status)" finished
    grep -qx env-110 "$ENVS_DIR/110/output.log" \
        || fail "log não contém env-110: $(cat "$ENVS_DIR/110/output.log")"
    expect "hostname da VM depois do teste" "$(hostname)" "$orig"
    echo "    dentro: $(cat "$ENVS_DIR/110/output.log"); VM: $(hostname)"
}

test_B11() {
    fresh 111
    local tmp
    tmp=$(mktemp /tmp/envctl-B11-XXXXXX.sh)
    printf '%s\n' 'echo "linha conhecida do B11"' 'exit 5' > "$tmp"
    run create 111 "${LIMITS[@]}" --script "$tmp"
    expect "código de saída do create" "$RC" 0
    wait_done 111 5 || fail "não terminou em 5 s"
    expect "status" "$(jget status)" error
    expect "exit_code" "$(jget exit_code)" 5
    grep -qx "linha conhecida do B11" "$ENVS_DIR/111/output.log" \
        || fail "log não contém a linha do script"
    rm -f -- "$tmp"
    [[ -f $ENVS_DIR/111/script.sh ]] || fail "cópia $ENVS_DIR/111/script.sh não existe"
    echo "    command: $(tr '\n' ' ' < "$ENVS_DIR/111/command")"
}

# Ids 98, 99 e 100 de propósito: em ordem de texto "100" viria antes de "98",
# então o teste também prova que o list ordena como número.
test_B12() {
    local id tmp
    local -a pids=()
    for id in 98 99 100; do fresh "$id"; done
    tmp=$(mktemp -d)
    # Os três create disparados juntos, cada um com limites diferentes.
    "$ENVCTL" create 98  --cpu 10 --mem 64  --io 5  --cmd "echo fim" > "$tmp/98" & pids+=($!)
    "$ENVCTL" create 99  --cpu 30 --mem 128 --io 10 --cmd "exit 7" > "$tmp/99" & pids+=($!)
    "$ENVCTL" create 100 --cpu 60 --mem 256 --io 20 --cmd "while true; do sleep 1; done" > "$tmp/100" & pids+=($!)
    for id in "${pids[@]}"; do wait "$id" || fail "um dos create saiu com erro"; done
    for id in 98 99 100; do echo "    create $id -> $(cat "$tmp/$id")"; done
    rm -rf -- "$tmp"

    wait_done 98 5 || fail "98 não terminou em 5 s"
    wait_done 99 5 || fail "99 não terminou em 5 s"
    run list
    expect "código de saída do list" "$RC" 0
    expect "list (id:status:exit_code)" "$(list_summary)" "98:finished:0 99:error:7 100:running:null"
    echo "    list -> $OUT"
    expect "cpu.max de 98"  "$(cat "$CG_ENVS/98/cpu.max")"  "10000 100000"
    expect "cpu.max de 99"  "$(cat "$CG_ENVS/99/cpu.max")"  "30000 100000"
    expect "cpu.max de 100" "$(cat "$CG_ENVS/100/cpu.max")" "60000 100000"
    echo "    cpu.max: 98=$(cat "$CG_ENVS/98/cpu.max") 99=$(cat "$CG_ENVS/99/cpu.max") 100=$(cat "$CG_ENVS/100/cpu.max")"

    for id in 98 99 100; do
        run remove "$id"
        is_removed_json "$id" || fail "remove $id devolveu: $OUT"
    done
    run list
    expect "list depois de remover os 3" "$OUT" "[]"
    echo "    list depois do remove -> $OUT"
}

test_LOGS() {
    fresh 116
    fresh 118
    fresh 999999
    local bad
    run create 116 "${LIMITS[@]}" --cmd 'for i in 1 2 3 4 5; do echo "linha $i"; done'
    expect "código de saída do create" "$RC" 0
    wait_done 116 5 || fail "não terminou em 5 s"
    run logs 116 --tail 2
    expect "código de saída do logs --tail 2" "$RC" 0
    expect "logs --tail 2" "$OUT" $'linha 4\nlinha 5'
    echo "    logs --tail 2 -> $(echo "$OUT" | tr '\n' '|')"
    run logs 116
    expect "logs sem --tail" "$OUT" $'linha 1\nlinha 2\nlinha 3\nlinha 4\nlinha 5'
    for bad in 0 abc 10001 -1 ''; do
        run logs 116 --tail "$bad"
        if [[ $RC -ne 1 ]] || ! is_error_json; then
            fail "--tail '$bad': esperado exit 1 + {\"error\"}, obtido exit $RC: $OUT"
        else
            echo "    ok  --tail '$bad' -> $OUT"
        fi
    done
    run logs 116 --tail
    [[ $RC -eq 1 ]] && is_error_json || fail "--tail sem valor: exit $RC: $OUT"
    run logs 999999
    expect "logs de id inexistente" "$RC" 2
    is_error_json || fail "logs de id inexistente não devolveu {\"error\"}: $OUT"
    echo "    logs 999999 -> exit $RC $OUT"
    # Programa que não escreve nada: saída vazia, sem erro.
    run create 118 "${LIMITS[@]}" --cmd "true"
    wait_done 118 5 || fail "118 não terminou em 5 s"
    run logs 118
    expect "código de saída do logs com log vazio" "$RC" 0
    expect "logs com log vazio" "$OUT" ""
}

test_B13() {
    fresh 113
    local -a c
    local desc
    # cada caso: descrição | argumentos depois de "create"
    while IFS='|' read -r desc args; do
        eval "c=($args)"
        run create "${c[@]}"
        if [[ $RC -ne 1 ]] || ! is_error_json; then
            fail "$desc: esperado exit 1 + {\"error\"}, obtido exit $RC: $OUT"
        else
            echo "    ok  $desc -> $OUT"
        fi
    done <<'EOF'
--cpu 0|113 --cpu 0 --mem 128 --io 10 --cmd true
--cpu 150|113 --cpu 150 --mem 128 --io 10 --cmd true
sem --cmd nem --script|113 --cpu 50 --mem 128 --io 10
--cmd e --script juntos|113 --cpu 50 --mem 128 --io 10 --cmd true --script /etc/hostname
--mem 31|113 --cpu 50 --mem 31 --io 10 --cmd true
--mem 2049|113 --cpu 50 --mem 2049 --io 10 --cmd true
--io 0|113 --cpu 50 --mem 128 --io 0 --cmd true
--io 501|113 --cpu 50 --mem 128 --io 501 --cmd true
--cpu não numérico|113 --cpu abc --mem 128 --io 10 --cmd true
--cpu negativo|113 --cpu -5 --mem 128 --io 10 --cmd true
sem --io|113 --cpu 50 --mem 128 --cmd true
--cmd vazio|113 --cpu 50 --mem 128 --io 10 --cmd ''
--script inexistente|113 --cpu 50 --mem 128 --io 10 --script /nao/existe.sh
opção sem valor|113 --cpu 50 --mem 128 --io 10 --cmd
opção repetida|113 --cpu 50 --cpu 60 --mem 128 --io 10 --cmd true
id zero|0 --cpu 50 --mem 128 --io 10 --cmd true
id não numérico|abc --cpu 50 --mem 128 --io 10 --cmd true
id com zero à esquerda|0113 --cpu 50 --mem 128 --io 10 --cmd true
sem id|
opção desconhecida com aspas e \ (JSON precisa escapar)|113 --cpu 50 --mem 128 --io 10 '--x"y\z' 1 --cmd true
EOF
    [[ -e $ENVS_DIR/113 ]] && fail "argumento inválido não pode criar $ENVS_DIR/113"
    [[ -e $CG_ENVS/113 ]] && fail "argumento inválido não pode criar $CG_ENVS/113"
    # Comando inválido no nível do envctl também segue o contrato.
    run frobnicate 113
    [[ $RC -eq 1 ]] && is_error_json || fail "subcomando inválido: exit $RC: $OUT"
}

test_B14() {
    fresh 114
    run create 114 "${LIMITS[@]}" --cmd "sleep 30"
    expect "primeiro create" "$RC" 0
    local pid1
    pid1=$(jget pid)
    run create 114 "${LIMITS[@]}" --cmd "echo outro"
    expect "código de saída do create duplicado" "$RC" 3
    is_error_json || fail "create duplicado não devolveu {\"error\"}: $OUT"
    echo "    duplicado -> $OUT"
    run status 114
    expect "ambiente original continua rodando" "$(jget status)" running
    expect "pid original preservado" "$(jget pid)" "$pid1"
}

test_B15() {
    fresh 115
    local t0 elapsed
    t0=$(now_ms)
    run create 115 "${LIMITS[@]}" --cmd "sleep 300"
    elapsed=$(( $(now_ms) - t0 ))
    expect "código de saída do create" "$RC" 0
    expect "status" "$(jget status)" running
    (( elapsed < 1000 )) || fail "create demorou ${elapsed} ms (limite 1000 ms)"
    echo "    create retornou em ${elapsed} ms: $OUT"
}

# ---------------------------------------------------------------- execução

declare -A DESC=(
    [B1]="comando que termina"
    [B2]="comando com erro"
    [B3]="serviço que não termina"
    [B4]="stop"
    [B5]="remove"
    [B6]="limite de CPU"
    [B7]="limite de memória (OOM)"
    [B8]="limite de IO"
    [B9]="namespace PID (e /proc sem vazar para a VM)"
    [B10]="namespace UTS"
    [B11]="script (executa a cópia)"
    [B12]="ambientes simultâneos e list"
    [B13]="argumentos inválidos"
    [B14]="id duplicado"
    [B15]="não trava o chamador"
    [LOGS]="logs e --tail"
)
ALL=(B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 B11 B12 B13 B14 B15 LOGS)

TESTS=("$@")
[[ ${#TESTS[@]} -eq 0 ]] && TESTS=("${ALL[@]}")

PASSED=() FAILED=()
for t in "${TESTS[@]}"; do
    if ! declare -F "test_$t" >/dev/null; then
        echo "teste desconhecido: $t" >&2
        FAILED+=("$t")
        continue
    fi
    echo "== $t: ${DESC[$t]}"
    T_OK=1
    "test_$t"
    cleanup_all
    if (( T_OK )); then
        echo "PASS $t"
        PASSED+=("$t")
    else
        echo "FAIL $t"
        FAILED+=("$t")
    fi
done

# Nada pode sobrar: nem pasta de ambiente (nome = id) nem cgroup filho.
LEFT=$(find "$ENVS_DIR" -mindepth 1 -maxdepth 1 -type d -regex '.*/[1-9][0-9]*' 2>/dev/null
       find "$CG_ENVS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
echo "== sobras em $ENVS_DIR e $CG_ENVS: ${LEFT:-nenhuma}"
[[ -z $LEFT ]] || FAILED+=(sobras)

echo
echo "Resumo: ${#PASSED[@]} PASS, ${#FAILED[@]} FAIL (de ${#TESTS[@]})"
(( ${#FAILED[@]} == 0 )) || echo "Falharam: ${FAILED[*]}"
[[ ${#FAILED[@]} -eq 0 ]]
