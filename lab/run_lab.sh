#!/usr/bin/env bash
# =============================================================================
# lab/run_lab.sh — 「Stale file handle」の再現実験（Docker だけで動く）
#
#   EFS の代わりに Linux カーネルの NFS サーバ（knfsd）を 1 台、ECS タスクの代わりに
#   UBI 9.8 + OpenJDK 21 + Log4j2 のコンテナを 2 台（タスク A・タスク B）立てて、
#   「何をすると ESTALE になるか／ならないか」を 1 つずつ確かめる。
#
#   使い方:  bash lab/run_lab.sh            全ケース
#            bash lab/run_lab.sh S1 S6      指定ケースだけ
#            KEEP=1 bash lab/run_lab.sh     終わってもコンテナを残す（手で触る用）
#
#   必要: Docker（--privileged が使えること。Docker Desktop の WSL2 カーネルで確認済み）
#   出力: lab/results/<ケース>.txt（実行記録）と lab/results/summary.tsv（判定の一覧）
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
RES="${HERE}/results"
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
export MSYS_NO_PATHCONV=1

NET=estale-net; VOL=estale-export
SRV=estale-nfsd; A=estale-a; B=estale-b
SRV_IP=172.30.0.10; A_IP=172.30.0.11; B_IP=172.30.0.12
OPT41="vers=4.1,addr=${SRV_IP},hard,timeo=600,retrans=2,noresvport"
OPT3="vers=3,proto=tcp,addr=${SRV_IP},mountaddr=${SRV_IP},mountproto=tcp,mountvers=3,nolock,hard,timeo=600,retrans=2"
JAVA_CP="/opt/lab/classes:/opt/lab/lib/*"
LOGDIR=/mnt/logs/front/inter-api/logs          # コンテナの中の EFS 実体（リンク先）
LINK=/webapp/webapp9mf02/logs                  # アプリが書くパス（シンボリックリンク）

mkdir -p "${RES}"
SUMMARY="${RES}/summary.tsv"
CUR=""                                         # 実行中のケースの記録ファイル

log()  { printf '%s\n' "$*" | tee -a "${CUR}"; }
step() { printf '\n$ %s\n' "$*" | tee -a "${CUR}"; }
# コンテナの中でコマンドを実行し、記録する
on() { local c="$1"; shift; step "[${c#estale-}] $*"; docker exec "${c}" bash -c "$*" 2>&1 | tee -a "${CUR}" || true; }
quiet_on() { local c="$1"; shift; docker exec "${c}" bash -c "$*" 2>&1 || true; }

# summary.tsv に 1 行: ケース / NFS / 条件 / 期待 / 観測 / 判定
record() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "${SUMMARY}"
    log ">>> 判定 [$6] 期待: $4 / 観測: $5"
}

begin() {
    CUR="${RES}/$1.txt"
    : > "${CUR}"
    log "# $1  $2"
    log "# $(date '+%Y-%m-%d %H:%M:%S %z')"
}

# ------------------------------------------------------------------ 基盤
build_images() {
    docker build -q -t estale-nfsd:local "$(native "${HERE}/server")" >/dev/null
    docker build -q -t estale-client:local -f "$(native "${HERE}/client/Dockerfile")" "$(native "${HERE}")" >/dev/null
}

# knfsd のスレッドが動いたままコンテナを強制削除すると、カーネルの後始末が数分固まることがある。
# 先に rpc.nfsd 0 で止めてから消す。
server_down() {
    docker exec "${SRV}" sh -c 'rpc.nfsd 0; exportfs -ua' >/dev/null 2>&1 || true
    docker stop -t 20 "${SRV}" >/dev/null 2>&1 || true
    docker rm -f "${SRV}" >/dev/null 2>&1 || true
}

# クライアントはアンマウントしてから消す（マウントを残したまま消すと後始末が遅れる）
clients_down() {
    local c
    for c in "${A}" "${B}"; do
        docker exec "${c}" sh -c 'umount -f -l /mnt/logs' >/dev/null 2>&1 || true
        docker rm -f "${c}" >/dev/null 2>&1 || true
    done
}

server_up() {      # server_up [fsid]
    server_down
    docker run -d --name "${SRV}" --hostname nfsd --privileged --network "${NET}" --ip "${SRV_IP}" \
        -e EXPORT_FSID="${1:-0}" -v "${VOL}:/export" estale-nfsd:local >/dev/null
    for _ in $(seq 1 30); do
        if docker logs "${SRV}" 2>&1 | grep -q 'READY'; then
            sleep 12          # NFSv4 の猶予期間（10 秒に縮めてある）が明けるのを待つ
            return 0
        fi
        sleep 1
    done
    echo "NFS サーバが起動しない" >&2; docker logs "${SRV}" >&2; return 1
}

infra_up() {
    clients_down
    server_down
    # 前回の残り（コンテナの削除直後はネットワークがまだ外れていないことがある）は作り直さずに使う
    docker network inspect "${NET}" >/dev/null 2>&1         || docker network create --subnet 172.30.0.0/24 "${NET}" >/dev/null
    docker volume inspect "${VOL}" >/dev/null 2>&1 || docker volume create "${VOL}" >/dev/null
    server_up 0
}

infra_down() {
    [ "${KEEP:-0}" = 1 ] && return 0
    clients_down
    server_down
    docker network rm "${NET}" >/dev/null 2>&1 || true
    docker volume rm "${VOL}" >/dev/null 2>&1 || true
}

# ケースごとにタスク A・B を作り直す（前のケースの FD やキャッシュを持ち越さない）
clients_up() {
    clients_down
    docker run -d --name "${A}" --hostname task-a --privileged --network "${NET}" --ip "${A_IP}" \
        -v "$(native "${ROOT}/tools"):/opt/tools:ro" -v "$(native "${ROOT}/impl"):/opt/impl:ro" estale-client:local >/dev/null
    docker run -d --name "${B}" --hostname task-b --privileged --network "${NET}" --ip "${B_IP}" \
        -v "$(native "${ROOT}/tools"):/opt/tools:ro" -v "$(native "${ROOT}/impl"):/opt/impl:ro" estale-client:local >/dev/null
    # サーバ側をまっさらにする
    docker exec "${SRV}" sh -c 'rm -rf /export/* /export/.[!.]* 2>/dev/null; mkdir -p /export/logs-root/front/inter-api/logs'
}

# mnt <コンテナ> <4.1|3> <サーバ側のパス>
#   4.1: "/" = EFS のルート、"/logs-root" = rootDirectory（アクセスポイントのルート）に相当
#   3  : "/export" と "/export/logs-root"
mnt() {
    local c="$1" v="$2" p="$3" o t
    if [ "${v}" = "3" ]; then o="${OPT3}"; t=nfs; else o="${OPT41}"; t=nfs4; fi
    docker exec "${c}" bash -c "umount -l /mnt/logs 2>/dev/null; mount -i -t ${t} -o ${o} ${SRV_IP}:${p} /mnt/logs"
}

# Java を裏で動かす。出力はコンテナの /tmp/<名前>.out
java_raw() {      # java_raw <コンテナ> <タスク名> <間隔ms> <秒> <出力名>
    docker exec -d -e TASK_NAME="$2" -e INTERVAL_MS="$3" -e DURATION_SEC="$4" "$1" \
        bash -c "java -cp '${JAVA_CP}' StaleLab raw ${LINK}/app.log > /tmp/$5.out 2>&1"
}
java_log4j() {    # java_log4j <コンテナ> <タスク名> <間隔ms> <秒> <出力名> <設定（/ で始まれば絶対パス）> [APP_LOG_ID]
    local conf="$6"
    case "${conf}" in /*) ;; *) conf="/opt/lab/conf/${conf}" ;; esac
    docker exec -d -e TASK_NAME="$2" -e INTERVAL_MS="$3" -e DURATION_SEC="$4" -e APP_LOG_ID="${7:-}" "$1" \
        bash -c "java -Dlog4j2.configurationFile=${conf} -cp '${JAVA_CP}' StaleLab log4j > /tmp/$5.out 2>&1"
}
wait_java() {     # Java が終わるまで待つ
    local c
    for c in "$@"; do
        for _ in $(seq 1 120); do
            docker exec "${c}" bash -c 'for p in /proc/[0-9]*; do case "$(readlink $p/exe 2>/dev/null)" in */java) exit 1;; esac; done; exit 0' \
                && break
            sleep 1
        done
    done
}
# Java がファイルを開いたのを確かめてから次へ進む（開く前に消すと検証にならない）
wait_line() {     # wait_line <コンテナ> <ファイル> <文字列>
    for _ in $(seq 1 60); do
        docker exec "$1" grep -q "$3" "$2" 2>/dev/null && return 0
        sleep 1
    done
    log "!!! $1: $2 に '$3' が出ない（60 秒）"; return 1
}
wait_file() {     # wait_file <コンテナ> <パス>
    for _ in $(seq 1 60); do
        docker exec "$1" test -e "$2" 2>/dev/null && return 0
        sleep 1
    done
    log "!!! $1: $2 ができない（60 秒）"; return 1
}

# サーバ上の行を数える（task=X seq=N の重複を除いた件数）。出力: "A=<件数> B=<件数>"
count_lines() {
    docker exec "${SRV}" bash -c '
        find /export/logs-root -type f \( -name "*.gz" -o -name "*.log" \) -print0 \
        | xargs -0 -r -n1 sh -c "case \"\$0\" in *.gz) gzip -dc \"\$0\" 2>/dev/null;; *) cat \"\$0\";; esac" \
        | awk "{ t=\"\"; s=\"\"; for (i=1;i<=NF;i++) { if (\$i ~ /^task=/) t=substr(\$i,6); if (\$i ~ /^seq=/) s=substr(\$i,5) }
                 if (t!=\"\" && s!=\"\" && !((t\":\"s) in seen)) { seen[t\":\"s]=1; n[t]++ } }
               END { printf \"A=%d B=%d\", n[\"A\"], n[\"B\"] }"'
}
summary_of() { quiet_on "$1" "grep -o 'SUMMARY.*' /tmp/$2.out | tail -1"; }
count_in() {      # count_in <コンテナ> <出力名> <文字列> → 出現行数（ファイルが無ければ 0）
    local n
    n="$(quiet_on "$1" "grep -c \"$3\" /tmp/$2.out" | tr -d '[:space:]')"
    [[ "${n}" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "${n}"
}

# ================================================================== ケース
S1() {   # 別クライアントが「開いているファイル」を消す（v4.1 と v3）
    local v
    for v in 4.1 3; do
        clients_up
        local id="S1_v${v/./}"
        begin "${id}" "別タスク（別 NFS クライアント）が、Java が開いているログファイルを削除する（NFSv${v}）"
        local root="/logs-root"; [ "${v}" = 3 ] && root="/export/logs-root"
        mnt "${A}" "${v}" "${root}"; mnt "${B}" "${v}" "${root}"
        on "${A}" "grep ' /mnt/logs ' /proc/mounts; ls -l ${LINK}"
        java_raw "${A}" A 300 22 s1
        wait_line "${A}" /tmp/s1.out opened || true
        sleep 3
        on "${B}" "date '+%H:%M:%S.%3N'; ls -li ${LOGDIR}; rm -v ${LOGDIR}/app.log"
        sleep 4
        # Java が開いたままの状態で診断スクリプトを当てる
        on "${A}" "bash /opt/tools/estale-diag.sh -q; echo exit=\$?"
        wait_java "${A}"
        on "${A}" "cat /tmp/s1.out"
        local s; s="$(summary_of "${A}" s1)"
        local n; n="$(count_in "${A}" s1 'Stale file handle')"
        if ! grep -q "removed '${LOGDIR}/app.log'" "${CUR}"; then
            record "${id}" "v${v}" "別クライアントが開いているファイルを削除" "削除が成功していること" "B の rm が失敗（検証不成立）" "NG"
        elif [ "${v}" = 3 ]; then
            if [ "${n}" -gt 0 ]; then record "${id}" "v3" "別クライアントが開いているファイルを削除" "書き込みが ESTALE（IOException: Stale file handle）" "${s}" "OK"
            else record "${id}" "v3" "別クライアントが開いているファイルを削除" "書き込みが ESTALE" "${s}" "NG"; fi
        else
            if [ "${n}" -eq 0 ]; then record "${id}" "v4.1" "別クライアントが開いているファイルを削除" "knfsd は実体を残すのでエラーにならない（書いた行は消える）" "${s}" "OK"
            else record "${id}" "v4.1" "別クライアントが開いているファイルを削除" "エラーにならない" "${s}" "NG"; fi
        fi
    done
}

S2() {   # 上位のディレクトリを作り直す（ルートではない）
    clients_up
    begin S2 "別クライアントが、ログのディレクトリを削除して作り直す（NFSv4.1）"
    mnt "${A}" 4.1 /logs-root; mnt "${B}" 4.1 /logs-root
    docker exec -d "${A}" bash -c "cd ${LINK} && sleep 6 && { echo '--- ls .（カレントディレクトリ）'; ls -la .; echo rc=\$?; echo '--- ls（パス名で引き直す）'; ls -la ${LINK}/; echo rc=\$?; echo '--- 新しいファイルを作る'; echo hi > ${LINK}/new.txt && echo NEWFILE_OK; } > /tmp/s2.out 2>&1"
    sleep 2
    on "${B}" "stat -c 'before inode=%i' ${LOGDIR}; rm -rf ${LOGDIR} && mkdir -p ${LOGDIR} && stat -c 'after  inode=%i' ${LOGDIR}"
    sleep 6
    on "${A}" "cat /tmp/s2.out"
    local out; out="$(quiet_on "${A}" 'cat /tmp/s2.out')"
    if grep -q "cannot open directory '.': Stale file handle" <<<"${out}" && grep -q NEWFILE_OK <<<"${out}"; then
        record S2 "v4.1" "ログのディレクトリを作り直す" "掴んでいるもの（カレントディレクトリ）は ESTALE、パス名で開き直すものは自動で直る" "cwd=ESTALE / パス名=OK / 新規作成=OK" "OK"
    else
        record S2 "v4.1" "ログのディレクトリを作り直す" "cwd=ESTALE、パス名=OK" "$(tr '\n' ' ' <<<"${out}" | cut -c1-200)" "NG"
    fi
}

S3() {   # マウントの根元（rootDirectory / アクセスポイントのルート）を作り直す
    local v
    for v in 4.1 3; do
        clients_up
        local id="S3_v${v/./}"
        begin "${id}" "別クライアントが、マウントの根元（rootDirectory・アクセスポイントのルート）を削除して作り直す（NFSv${v}）"
        local root="/logs-root" top="/"
        [ "${v}" = 3 ] && { root="/export/logs-root"; top="/export"; }
        mnt "${A}" "${v}" "${root}"; mnt "${B}" "${v}" "${top}"
        java_raw "${A}" A 300 20 s3
        wait_line "${A}" /tmp/s3.out opened || true
        sleep 2
        on "${B}" "stat -c 'before inode=%i' /mnt/logs/logs-root; rm -rf /mnt/logs/logs-root && mkdir -p /mnt/logs/logs-root/front/inter-api/logs && stat -c 'after  inode=%i' /mnt/logs/logs-root"
        sleep 2
        on "${A}" "ls -la /mnt/logs; echo rc=\$?; stat /mnt/logs; echo rc=\$?; mkdir -p /mnt/logs/front/inter-api/logs; echo rc=\$?; touch ${LINK}/probe.txt; echo rc=\$?"
        on "${A}" "bash /opt/tools/estale-diag.sh -q --probe; echo exit=\$?"
        wait_java "${A}"
        on "${A}" "cat /tmp/s3.out"
        step "[a] マウントし直す（ECS ではタスクの入れ替えに相当）"
        mnt "${A}" "${v}" "${root}"
        on "${A}" "ls -la ${LINK}/ && touch ${LINK}/probe.txt && echo REMOUNT_OK"
        local o; o="$(quiet_on "${A}" "ls /mnt/logs 2>&1 >/dev/null; ls ${LINK}/ >/dev/null && echo REMOUNT_OK")"
        local s; s="$(summary_of "${A}" s3)"
        if grep -q REMOUNT_OK <<<"${o}"; then
            record "${id}" "v${v}" "マウントの根元を作り直す" "ls・stat・mkdir が ESTALE、マウントし直すまで直らない" "マウント中は ESTALE / 再マウントで回復 / Java: ${s}" "OK"
        else
            record "${id}" "v${v}" "マウントの根元を作り直す" "再マウントで回復" "${o}" "NG"
        fi
    done
}

S4() {   # 同じクライアントの中で消す（silly rename）
    clients_up
    begin S4 "同じタスク（同じ NFS クライアント）の中で、Java が開いているファイルを削除する（NFSv4.1）"
    mnt "${A}" 4.1 /logs-root
    java_raw "${A}" A 300 14 s4
    wait_line "${A}" /tmp/s4.out opened || true
    sleep 2
    on "${A}" "rm -v ${LINK}/app.log; ls -la ${LINK}/"
    on "${A}" "bash /opt/tools/estale-diag.sh -q; echo exit=\$?"
    wait_java "${A}"
    on "${A}" "cat /tmp/s4.out; echo '--- Java が閉じたあと'; ls -la ${LINK}/"
    local s; s="$(summary_of "${A}" s4)"
    local after; after="$(quiet_on "${A}" "ls -a ${LINK}/ | grep -c '^\.nfs'")"
    if grep -q 'errors=0' <<<"${s}" && [ "${after}" = "0" ]; then
        record S4 "v4.1" "同じクライアントで使用中ファイルを削除" ".nfsXXXX に改名されエラーにならない。閉じると中身ごと消える" "${s} / 閉じた後の .nfs=${after}" "OK"
    else
        record S4 "v4.1" "同じクライアントで使用中ファイルを削除" ".nfs に改名・エラーなし" "${s} / .nfs=${after}" "NG"
    fi
}

S5() {   # 仮説: アプリ起動後にマウントを外して付け直す
    clients_up
    begin S5 "仮説の検証: Java が書いている最中に EFS のマウントを外して付け直す（NFSv4.1）"
    mnt "${A}" 4.1 /logs-root; mnt "${B}" 4.1 /logs-root
    java_raw "${A}" A 300 20 s5
    wait_line "${A}" /tmp/s5.out opened || true
    sleep 2
    on "${A}" "umount /mnt/logs; echo rc=\$?"
    on "${A}" "umount -l /mnt/logs; echo rc=\$?; mount -i -t nfs4 -o ${OPT41} ${SRV_IP}:/logs-root /mnt/logs; echo mount_rc=\$?; grep ' /mnt/logs ' /proc/mounts | cut -c1-60; echo hi > ${LINK}/after-remount.txt && echo NEW_OPEN_OK"
    wait_java "${A}"
    on "${A}" "cat /tmp/s5.out"
    on "${B}" "wc -l ${LOGDIR}/app.log; tail -1 ${LOGDIR}/app.log"
    local s; s="$(summary_of "${A}" s5)"
    local n; n="$(quiet_on "${B}" "wc -l < ${LOGDIR}/app.log" | tr -d '[:space:]')"
    local w; w="$(sed -n 's/.*writes=\([0-9]*\).*/\1/p' <<<"${s}")"
    if grep -q 'errors=0' <<<"${s}" && [ "${n}" = "${w}" ]; then
        record S5 "v4.1" "書き込み中にマウントを外して付け直す（仮説）" "ESTALE にならない（古い FD は外したマウント経由で書き続ける）" "${s} / サーバ上の行数=${n}" "OK"
    else
        record S5 "v4.1" "書き込み中にマウントを外して付け直す（仮説）" "ESTALE にならない" "${s} / サーバ上の行数=${n}" "NG"
    fi
}

S6() {   # いまの構成: 2 タスクが同じ app.log に書き、Log4j2 がロールオーバ（gz 圧縮→元ファイル削除）
    local v
    for v in 3 4.1; do
        clients_up
        local id="S6_v${v/./}"
        begin "${id}" "2 タスクが同じ app.log に書き、Log4j2 が 10 秒ごとにロールオーバ（gz 圧縮→元ファイル削除）する（NFSv${v}）"
        local root="/logs-root"; [ "${v}" = 3 ] && root="/export/logs-root"
        mnt "${A}" "${v}" "${root}"; mnt "${B}" "${v}" "${root}"
        java_log4j "${A}" A 200 45 s6 log4j2-shared.xml
        wait_line "${A}" /tmp/s6.out "log4j start" || true
        sleep 1.3
        java_log4j "${B}" B 200 45 s6 log4j2-shared.xml
        wait_line "${B}" /tmp/s6.out "log4j start" || true
        sleep 25
        on "${A}" "bash /opt/tools/estale-diag.sh -q; echo exit=\$?"
        wait_java "${A}" "${B}"
        on "${A}" "grep -n -m6 -E 'ERROR|Caused by|IOException' /tmp/s6.out; grep -o 'SUMMARY.*' /tmp/s6.out"
        on "${B}" "grep -n -m6 -E 'ERROR|Caused by|IOException' /tmp/s6.out; grep -o 'SUMMARY.*' /tmp/s6.out"
        on "${A}" "ls -la ${LINK}/"
        local na nb ea eb cnt
        na="$(count_in "${A}" s6 'Stale file handle')"; nb="$(count_in "${B}" s6 'Stale file handle')"
        ea="$(summary_of "${A}" s6 | sed -n 's/.*events=\([0-9]*\).*/\1/p')"
        eb="$(summary_of "${B}" s6 | sed -n 's/.*events=\([0-9]*\).*/\1/p')"
        cnt="$(count_lines)"
        log "出力した行: A=${ea} B=${eb} / サーバに残った行: ${cnt}"
        local obs="Stale の出現 A=${na} B=${nb}回 / 出力 A=${ea} B=${eb} / 残った ${cnt}"
        if [ "${v}" = 3 ]; then
            if [ $((na + nb)) -gt 0 ]; then record "${id}" "v3" "2 タスクが同じファイル＋ロールオーバ" "片方に AppenderLoggingException … Caused by: IOException: Stale file handle" "${obs}" "OK"
            else record "${id}" "v3" "2 タスクが同じファイル＋ロールオーバ" "ESTALE が出る" "${obs}" "NG"; fi
        else
            record "${id}" "v4.1" "2 タスクが同じファイル＋ロールオーバ" "knfsd ではエラーが出ないことがあるが、行は欠ける" "${obs}" "OK"
        fi
    done
}

S7() {   # 恒久対策: タスクごとのディレクトリ
    clients_up
    begin S7 "恒久対策の確認: タスクごとのディレクトリ（APP_LOG_ID）に書く。条件は S6 と同じ（NFSv3＝最も厳しいサーバ）"
    mnt "${A}" 3 /export/logs-root; mnt "${B}" 3 /export/logs-root
    java_log4j "${A}" A 200 45 s7 log4j2-pertask.xml task-a-0001
    wait_line "${A}" /tmp/s7.out "log4j start" || true
    sleep 1.3
    java_log4j "${B}" B 200 45 s7 log4j2-pertask.xml task-b-0002
    wait_java "${A}" "${B}"
    on "${A}" "grep -c 'Stale file handle' /tmp/s7.out; grep -o 'SUMMARY.*' /tmp/s7.out"
    on "${B}" "grep -c 'Stale file handle' /tmp/s7.out; grep -o 'SUMMARY.*' /tmp/s7.out"
    on "${A}" "ls -la ${LINK}/ ${LINK}/task-a-0001 ${LINK}/task-b-0002"
    local na nb ea eb cnt
    na="$(count_in "${A}" s7 'Stale file handle')"; nb="$(count_in "${B}" s7 'Stale file handle')"
    ea="$(summary_of "${A}" s7 | sed -n 's/.*events=\([0-9]*\).*/\1/p')"
    eb="$(summary_of "${B}" s7 | sed -n 's/.*events=\([0-9]*\).*/\1/p')"
    cnt="$(count_lines)"
    log "出力した行: A=${ea} B=${eb} / サーバに残った行: ${cnt}"
    if [ $((na + nb)) -eq 0 ] && [ "${cnt}" = "A=${ea} B=${eb}" ]; then
        record S7 "v3" "タスクごとのディレクトリに書く（対策後）" "ESTALE 0 件・欠けた行 0" "Stale A=${na} B=${nb} / 出力 A=${ea} B=${eb} / 残った ${cnt}" "OK"
    else
        record S7 "v3" "タスクごとのディレクトリに書く（対策後）" "ESTALE 0 件・欠けた行 0" "Stale A=${na} B=${nb} / 出力 A=${ea} B=${eb} / 残った ${cnt}" "NG"
    fi
}

S8() {   # 診断スクリプト（tools/estale-diag.sh）の判定が正しいか
    local v
    for v in 3 4.1; do
        clients_up
        local id="S8_v${v/./}"
        begin "${id}" "診断スクリプトの判定: 正常 → 改名して作り直し（REPLACED）→ 改名先も削除（STALE）（NFSv${v}）"
        local root="/logs-root"; [ "${v}" = 3 ] && root="/export/logs-root"
        mnt "${A}" "${v}" "${root}"; mnt "${B}" "${v}" "${root}"
        java_raw "${A}" A 300 70 s8
        wait_line "${A}" /tmp/s8.out opened || true
        sleep 2
        on "${A}" "bash /opt/tools/estale-diag.sh; echo exit=\$?"
        local e1; e1="$(grep -o 'exit=[0-9]' "${CUR}" | tail -1)"
        on "${B}" "mv ${LOGDIR}/app.log ${LOGDIR}/app.1 && touch ${LOGDIR}/app.log && ls -li ${LOGDIR}"
        sleep 1
        on "${A}" "bash /opt/tools/estale-diag.sh -q; echo exit=\$?"
        local e2; e2="$(grep -o 'exit=[0-9]' "${CUR}" | tail -1)"
        local e2b="-"
        if [ "${v}" = 3 ]; then
            step "[a] NFSv3 はディレクトリの属性キャッシュ（acdirmin=30 秒）が切れるまで改名に気づかないことがある。31 秒待ってもう一度"
            sleep 31
            on "${A}" "bash /opt/tools/estale-diag.sh -q; echo exit=\$?"
            e2b="$(grep -o 'exit=[0-9]' "${CUR}" | tail -1)"
        fi
        local r2; r2="$(grep -c 'FD 1 個が古い実体を掴んでいる' "${CUR}" || true)"
        on "${B}" "rm -v ${LOGDIR}/app.1"
        sleep 4
        on "${A}" "bash /opt/tools/estale-diag.sh -q; echo exit=\$?"
        local e3; e3="$(grep -o 'exit=[0-9]' "${CUR}" | tail -1)"
        local s3; s3="$(grep -c 'が Stale: 別タスク' "${CUR}" || true)"
        wait_java "${A}"
        on "${A}" "cat /tmp/s8.out"
        local obs="正常=${e1} / 改名+作り直し 1 秒後=${e2}（31 秒後=${e2b}）REPLACED 表示 ${r2} / 改名先も削除=${e3}（STALE 表示 ${s3}）"
        # v3: 削除後は STALE であること。v4.1（knfsd）: 消されても実体を残すので、STALE か REPLACED のどちらか（終了コード 1）
        local want3="ok"
        if [ "${v}" = 3 ]; then [ "${s3}" -ge 1 ] || want3="ng"; else [ "${e3}" = "exit=1" ] || want3="ng"; fi
        local expect="正常は 0、改名後は REPLACED（1）。削除後は v3 で STALE（1）、knfsd v4.1 は STALE か REPLACED（1）"
        if [ "${e1}" = "exit=0" ] && [ "${r2}" -ge 1 ] && [ "${want3}" = "ok" ]; then
            record "${id}" "v${v}" "診断スクリプトの判定" "${expect}" "${obs}" "OK"
        else
            record "${id}" "v${v}" "診断スクリプトの判定" "${expect}" "${obs}" "NG"
        fi
    done
}

S10() {  # 恒久対策 P7 の確認: impl/log4j2-pertask.xml の Failover（ファイルに書けなくなったら標準出力へ）
    clients_up
    begin S10 "Log4j2 の保険（impl/log4j2-pertask.xml の Failover）: 別クライアントがファイルを消しても、ログは標準出力へ逃げる（NFSv3）"
    mnt "${A}" 3 /export/logs-root; mnt "${B}" 3 /export/logs-root
    java_log4j "${A}" A 200 25 s10 /opt/impl/log4j2-pertask.xml task-a-0001
    wait_line "${A}" /tmp/s10.out "log4j start" || true
    sleep 3
    on "${B}" "ls -la ${LOGDIR}/task-a-0001/; rm -v ${LOGDIR}/task-a-0001/app.log"
    wait_java "${A}"
    on "${A}" "grep -m4 -E 'ERROR|Stale' /tmp/s10.out | cut -c1-200; echo '--- 標準出力へ逃げた行（Failover）'; grep -c 'lab - task=A seq=' /tmp/s10.out; grep 'lab - task=A seq=' /tmp/s10.out | tail -2; grep -o 'SUMMARY.*' /tmp/s10.out"
    local fo ev
    fo="$(quiet_on "${A}" "grep -c 'lab - task=A seq=' /tmp/s10.out" | tr -d '[:space:]')"
    [[ "${fo}" =~ ^[0-9]+$ ]] || fo=0
    ev="$(summary_of "${A}" s10 | sed -n 's/.*events=\([0-9]*\).*/\1/p')"
    if [ "${fo}" -gt 0 ]; then
        record S10 "v3" "Failover の保険（ファイルが消された後）" "ファイルに書けない間のログが標準出力（CloudWatch Logs）に出る" "出力 ${ev} 行のうち ${fo} 行が標準出力へ" "OK"
    else
        record S10 "v3" "Failover の保険（ファイルが消された後）" "ファイルに書けない間のログが標準出力に出る" "標準出力へ ${fo} 行" "NG"
    fi
}

S9() {   # 参考: サーバの再起動（同じ fsid）と、エクスポートの付け替え（fsid 変更）
    clients_up
    begin S9 "参考: NFS サーバの再起動（同じ fsid）と、エクスポートの付け替え（fsid を変える）（NFSv3）"
    mnt "${A}" 3 /export/logs-root
    on "${A}" "echo before > ${LINK}/s9.txt && cat ${LINK}/s9.txt"
    step "[server] 同じ fsid で NFS サーバを作り直す（再起動に相当）"
    server_up 0
    on "${A}" "cat ${LINK}/s9.txt && echo after-restart >> ${LINK}/s9.txt && echo RESTART_OK"
    step "[server] fsid を 0 → 7 に変えて作り直す（エクスポートの付け替え）"
    server_up 7
    on "${A}" "cat ${LINK}/s9.txt; echo rc=\$?; ls /mnt/logs; echo rc=\$?"
    local o1 o2
    o1="$(grep -c RESTART_OK "${CUR}" || true)"
    o2="$(grep -c 'Stale file handle' "${CUR}" || true)"
    step "[server] fsid を 0 に戻す"
    server_up 0
    if [ "${o1}" -ge 1 ] && [ "${o2}" -ge 1 ]; then
        record S9 "v3" "サーバ再起動 / fsid の付け替え" "再起動では ESTALE にならず、付け替えると ESTALE" "再起動=OK / 付け替え=ESTALE" "OK"
    else
        record S9 "v3" "サーバ再起動 / fsid の付け替え" "再起動=OK / 付け替え=ESTALE" "RESTART_OK=${o1} STALE=${o2}" "NG"
    fi
}

# ================================================================== 実行
main() {
    local cases=("$@")
    [ "${#cases[@]}" -eq 0 ] && cases=(S1 S2 S3 S4 S5 S6 S7 S8 S9 S10)
    build_images
    infra_up
    trap infra_down EXIT
    if [ "$#" -gt 0 ] && [ -f "${SUMMARY}" ]; then
        # 指定したケースだけ流し直す: そのケースの行だけ消して、ほかの結果は残す
        local pat
        pat="^($(IFS='|'; echo "$*"))(_v[0-9]+)?"$'\t'
        grep -Ev "${pat}" "${SUMMARY}" > "${SUMMARY}.tmp" || true
        mv "${SUMMARY}.tmp" "${SUMMARY}"
        echo "partial=$* $(date '+%Y-%m-%d %H:%M:%S %z')" >> "${RES}/meta.txt"
        for c in "${cases[@]}"; do "${c}"; done
        echo
        column -t -s $'\t' "${SUMMARY}" 2>/dev/null || cat "${SUMMARY}"
        return 0
    fi
    printf 'ケース\tNFS\t条件\t期待\t観測\t判定\n' > "${SUMMARY}"
    {
        echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "docker=$(docker version --format '{{.Server.Version}}') kernel=$(docker version --format '{{.Server.KernelVersion}}')"
        docker run --rm estale-client:local bash -c 'echo "client=$(cat /etc/redhat-release) java=$(java -version 2>&1 | head -1) log4j=${LOG4J_VERSION}"'
        docker run --rm --entrypoint sh estale-nfsd:local -c 'echo "server=Debian $(cat /etc/debian_version) knfsd（Docker の VM のカーネルに内蔵） nfs-kernel-server=$(dpkg-query -W -f "\${Version}" nfs-kernel-server)"' 
    } > "${RES}/meta.txt"
    local c
    for c in "${cases[@]}"; do
        "${c}"
    done
    echo
    column -t -s $'\t' "${SUMMARY}" 2>/dev/null || cat "${SUMMARY}"
}

main "$@"
