#!/bin/bash
# Testes automatizados do envctl (README, seção 9.2). Rodar como root na VM:
#   sudo bash tests/test_envctl.sh            # todos os testes
#   sudo bash tests/test_envctl.sh B1 B3      # só os escolhidos
# O caminho do motor pode ser trocado com ENVCTL=/caminho/envctl.
# Todo ambiente criado aqui é removido ao final, mesmo se o teste falhar.

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

# Remove um ambiente de teste. Usa o próprio envctl; enquanto o remove não
# existir (etapas 1 a 3), faz a limpeza manualmente pelo cgroup.
cleanup_env() {
    local id=$1 cg=$CG_ENVS/$1 i
    "$ENVCTL" remove "$id" >/dev/null 2>&1
    case $? in 0|2) return ;; esac
    if [[ -d $cg ]]; then
        echo 1 > "$cg/cgroup.kill" 2>/dev/null
        for (( i = 0; i < 50; i++ )); do
            [[ -z $(cat "$cg/cgroup.procs" 2>/dev/null) ]] && break
            sleep 0.1
        done
        rmdir "$cg" 2>/dev/null
    fi
    rm -rf -- "${ENVS_DIR:?}/$id"
}

USED_IDS=()
# fresh <id>: garante que o id está livre (sobras de execuções anteriores) e o
# registra para limpeza no final.
fresh() {
    cleanup_env "$1"
    USED_IDS+=("$1")
}

cleanup_all() {
    local id
    for id in "${USED_IDS[@]}"; do cleanup_env "$id"; done
}
trap cleanup_all EXIT

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
    [B13]="argumentos inválidos"
    [B14]="id duplicado"
    [B15]="não trava o chamador"
)
ALL=(B1 B2 B3 B13 B14 B15)

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
    if (( T_OK )); then
        echo "PASS $t"
        PASSED+=("$t")
    else
        echo "FAIL $t"
        FAILED+=("$t")
    fi
done

echo
echo "Resumo: ${#PASSED[@]} PASS, ${#FAILED[@]} FAIL (de ${#TESTS[@]})"
(( ${#FAILED[@]} == 0 )) || echo "Falharam: ${FAILED[*]}"
[[ ${#FAILED[@]} -eq 0 ]]
