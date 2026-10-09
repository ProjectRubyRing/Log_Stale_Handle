#!/usr/bin/env bash
# =============================================================================
# estale-diag.sh — コンテナの中で「Stale file handle（ESTALE）」の状態を調べる
#
#   ECS Exec でフロント／バックのコンテナに入って実行する（root で実行するのが確実）。
#     bash estale-diag.sh                     既定: NFS マウントを自動検出し、Java が開いているファイルを全部調べる
#     bash estale-diag.sh --probe             書き込みテスト（一時ファイルを作って消す）も行う
#     bash estale-diag.sh -m /mnt/logs -l /webapp/webapp9mf02/logs -p 123
#
#   調べること
#     1. NFS マウント（EFS）の根元が生きているか          … Stale ならこのタスクでは直らない（入れ替えが必要）
#     2. ログ用シンボリックリンクの行き先が引けるか
#     3. Java が開いているファイルの状態                    … STALE / REPLACED / MISSING / SILLY / OK
#     4. .nfsXXXX（使用中に削除されたファイル）の有無
#     5. マウントの統計（再接続の回数、サーバがエラーを返した回数）
#
#   何も変更しない（--probe のときだけ一時ファイルを 1 つ作って消す）。
#   bash 4 以上・coreutils・findutils だけで動く（ps / pgrep / lsof / jq は使わない）。
#
#   終了コード: 0 = 異常なし / 1 = ファイル単位の異常（Java が Stale などを掴んでいる）
#               2 = マウントの根元が Stale・応答なし / 3 = 引数の誤り
# =============================================================================
set -u
export LC_ALL=C          # エラーメッセージ（Stale file handle 等）を英語に固定して判定する

VERSION="1.0.0"
TIMEOUT_SEC=5
PROBE=0
QUIET=0
declare -a MOUNTS=() LINKS=() PIDS=()

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'
オプション:
  -m, --mount DIR     調べるマウントポイント（複数可）。省略時は NFS マウントを自動検出
  -l, --link PATH     調べるシンボリックリンク（複数可）。省略時は /webapp/*/logs・/webapp/*/pdf・
                      /opt/jboss-eap/standalone/log と、/webapp 配下で NFS を指すリンクを自動検出
  -p, --pid PID       調べるプロセス（複数可）。省略時は実行ファイルが java のプロセスを全部
      --probe         書き込みテストを行う（リンク先・マウントに一時ファイルを作って消す）
  -t, --timeout SEC   1 回の確認の待ち時間（既定 5 秒。応答しない NFS で固まらないため）
  -q, --quiet         詳細を省き、判定だけ表示する
  -h, --help          このヘルプ
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -m|--mount)   [ $# -ge 2 ] || { echo "ERROR: $1 に値がありません" >&2; exit 3; }; MOUNTS+=("${2%/}"); shift 2 ;;
        -l|--link)    [ $# -ge 2 ] || { echo "ERROR: $1 に値がありません" >&2; exit 3; }; LINKS+=("${2%/}"); shift 2 ;;
        -p|--pid)     [ $# -ge 2 ] || { echo "ERROR: $1 に値がありません" >&2; exit 3; }; PIDS+=("$2"); shift 2 ;;
        --probe)      PROBE=1; shift ;;
        -t|--timeout) [ $# -ge 2 ] || { echo "ERROR: $1 に値がありません" >&2; exit 3; }; TIMEOUT_SEC="$2"; shift 2 ;;
        -q|--quiet)   QUIET=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "ERROR: 不明な引数: $1（-h でヘルプ）" >&2; exit 3 ;;
    esac
done
case "${TIMEOUT_SEC}" in ''|*[!0-9]*) echo "ERROR: --timeout は秒数（整数）で指定してください" >&2; exit 3 ;; esac
for _p in "${PIDS[@]+"${PIDS[@]}"}"; do
    case "${_p}" in ''|*[!0-9]*) echo "ERROR: --pid は数字で指定してください: ${_p}" >&2; exit 3 ;; esac
done

# ---------------------------------------------------------------- 表示
say()  { [ "${QUIET}" -eq 1 ] || printf '%s\n' "$*"; }
sect() { [ "${QUIET}" -eq 1 ] || printf '\n== %s\n' "$*"; }

declare -a VERDICTS=()
SEV=0                                   # 0 = 異常なし / 1 = ファイル単位 / 2 = マウント単位
verdict() {                             # verdict <重さ 0-2> <文>
    VERDICTS+=("$2")
    [ "$1" -gt "${SEV}" ] && SEV="$1"
    return 0
}

# 応答しない NFS（hard マウント）で固まらないよう、確認はすべて timeout -s KILL を付ける。
# NFS の待ちは SIGKILL で中断できる（TASK_KILLABLE）。
tcheck() { timeout -s KILL "${TIMEOUT_SEC}" "$@"; }

# エラーメッセージを短い分類にする
classify() {
    case "$1" in
        *"Stale file handle"*|*"Stale NFS file handle"*) echo "STALE" ;;
        *"No such file or directory"*)                   echo "ENOENT" ;;
        *"Permission denied"*)                           echo "EACCES" ;;
        *"Read-only file system"*)                       echo "EROFS" ;;
        *"Input/output error"*)                          echo "EIO" ;;
        *"Transport endpoint"*|*"timed out"*)            echo "TRANSPORT" ;;
        *) echo "ERROR" ;;
    esac
}

# mountinfo のマウントポイント表記（\040 など）を戻す
unescape() { printf '%b' "$1"; }

# ---------------------------------------------------------------- 1. 環境
sect "環境"
say "estale-diag ${VERSION}  $(date '+%Y-%m-%d %H:%M:%S %z')"
say "host=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo '?')  kernel=$(uname -r)  uid=$(id -u)"
if [ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ]; then
    say "ECS メタデータ: ${ECS_CONTAINER_METADATA_URI_V4}（タスク ID は ARN の末尾）"
    if command -v curl >/dev/null 2>&1; then
        _arn="$(curl -s --max-time 2 "${ECS_CONTAINER_METADATA_URI_V4}/task" 2>/dev/null \
                | sed -n 's/.*"TaskARN"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        [ -n "${_arn}" ] && say "TaskARN=${_arn}"
    fi
fi
[ "$(id -u)" -eq 0 ] || say "注意: root ではないため、他ユーザーのプロセスの FD は読めないことがある"

# ---------------------------------------------------------------- 2. NFS マウント
declare -A M_SRC=() M_TYPE=() M_OPTS=()
while IFS= read -r line; do
    # 形式: ID 親ID major:minor root マウントポイント オプション [任意項目...] - 種類 ソース スーパーブロックのオプション
    left="${line%% - *}"; right="${line#* - }"
    read -r -a lf <<< "${left}"
    read -r -a rf <<< "${right}"
    [ "${#lf[@]}" -ge 5 ] && [ "${#rf[@]}" -ge 2 ] || continue
    mp="$(unescape "${lf[4]}")"
    fstype="${rf[0]}"; src="${rf[1]}"; sopts="${rf[2]:-}"
    case "${fstype}" in nfs|nfs4) ;; *) continue ;; esac
    M_SRC["${mp}"]="${src}"; M_TYPE["${mp}"]="${fstype}"; M_OPTS["${mp}"]="${sopts}"
done < /proc/self/mountinfo

if [ "${#MOUNTS[@]}" -eq 0 ]; then
    for mp in "${!M_SRC[@]}"; do MOUNTS+=("${mp}"); done
fi

sect "NFS マウント（EFS）"
if [ "${#MOUNTS[@]}" -eq 0 ]; then
    say "NFS マウントが見つからない（このコンテナは EFS をマウントしていない）"
fi

# mountstats から 1 マウントぶんの要点を取り出す
mountstats_of() {
    # xprt: tcp <送信元ポート> <bind回数> <connect回数> ...（connect が 2 以上なら再接続があった）
    # 操作ごとの行: OP: <回数> <送信回数> <タイムアウト> <送信byte> <受信byte> <待ち> <RTT> <実行時間> [<エラー回数>]
    awk -v key=" mounted on $1 with fstype nfs" '
        /^device / { inblk = (index($0, key) > 0); next }
        !inblk { next }
        $1 == "age:"  { printf "age=%ss ", $2 }
        $1 == "xprt:" && $2 == "tcp" { printf "tcp接続回数=%s ", $5 }
        $1 == "xprt:" && $2 == "udp" { printf "udp " }
        /^[[:space:]]+[A-Z_]+:/ && NF >= 10 {
            op = $1; sub(":", "", op)
            if ($10 + 0 > 0) errs = errs sprintf("%s=%s ", op, $10)
        }
        END { if (errs != "") printf "| サーバが返したエラー(op=回数): %s", errs }
    ' /proc/self/mountstats 2>/dev/null
}

for mp in "${MOUNTS[@]+"${MOUNTS[@]}"}"; do
    src="${M_SRC[${mp}]:-?}"
    opts="${M_OPTS[${mp}]:-}"
    if [ "${src}" = "?" ]; then
        say "[${mp}] NFS マウントではない（または存在しない）"
        verdict 1 "${mp} は NFS マウントとして見つからない（-m の指定、タスク定義の mountPoints を確認）"
        continue
    fi
    vers="$(printf '%s' "${opts}" | tr ',' '\n' | sed -n 's/^vers=//p')"
    mode="$(printf '%s' "${opts}" | tr ',' '\n' | grep -E '^(hard|soft)$' || true)"
    timeo="$(printf '%s' "${opts}" | tr ',' '\n' | sed -n 's/^timeo=//p')"
    say "[${mp}] source=${src} type=${M_TYPE[${mp}]} vers=${vers:-?} ${mode:-?} timeo=${timeo:-?}"
    case "${src}" in 127.0.0.1:*) say "    TLS（efs-proxy / stunnel）経由のマウント。ポートごとに別の NFS クライアントとして扱われる" ;; esac
    ms="$(mountstats_of "${mp}")"
    [ -n "${ms}" ] && say "    統計: ${ms}"
    out="$(tcheck stat -c '%i' "${mp}" 2>&1)"; rc=$?
    if [ "${rc}" -eq 137 ]; then
        say "    根元: 応答なし（${TIMEOUT_SEC} 秒で打ち切り）"
        verdict 2 "${mp} が応答しない: EFS への通信の問題（SG・マウントターゲット・efs-proxy）。Stale とは別の現象"
    elif [ "${rc}" -ne 0 ]; then
        k="$(classify "${out}")"
        say "    根元: ${k}  (${out})"
        if [ "${k}" = "STALE" ]; then
            verdict 2 "${mp} の根元が Stale: EFS 側で rootDirectory／アクセスポイントのルート（またはその上）が削除・作り直しされた。このタスクでは直らない → タスクを入れ替える"
        else
            verdict 2 "${mp} の根元が ${k}: ${out}"
        fi
    else
        say "    根元: OK (inode=${out})"
    fi
done

is_on_nfs() {               # パスが調べている NFS マウントの配下なら 0
    local p="$1" mp
    for mp in "${MOUNTS[@]+"${MOUNTS[@]}"}"; do
        case "${p}" in "${mp}"|"${mp}"/*) return 0 ;; esac
    done
    return 1
}

# ---------------------------------------------------------------- 3. シンボリックリンク
if [ "${#LINKS[@]}" -eq 0 ]; then
    for p in /webapp/*/logs /webapp/*/pdf /opt/jboss-eap/standalone/log; do
        [ -L "${p}" ] && LINKS+=("${p}")
    done
    if [ -d /webapp ]; then
        while IFS= read -r p; do
            t="$(readlink "${p}" 2>/dev/null || true)"
            if is_on_nfs "${t}"; then
                dup=0
                for q in "${LINKS[@]+"${LINKS[@]}"}"; do [ "${q}" = "${p}" ] && dup=1; done
                [ "${dup}" -eq 0 ] && LINKS+=("${p}")
            fi
        done < <(find /webapp -maxdepth 3 -type l 2>/dev/null)
    fi
fi

sect "シンボリックリンク"
[ "${#LINKS[@]}" -eq 0 ] && say "対象のリンクなし"
declare -a PROBE_DIRS=()
for l in "${LINKS[@]+"${LINKS[@]}"}"; do
    if [ ! -L "${l}" ]; then
        say "[${l}] リンクではない（実ディレクトリ・不存在）"
        continue
    fi
    t1="$(readlink "${l}")"
    out="$(tcheck readlink -f "${l}" 2>&1)"; rc=$?
    final="${out}"
    st="$(tcheck stat -L -c '%i' "${l}" 2>&1)"; src=$?
    if [ "${src}" -eq 0 ]; then
        say "[${l}] -> ${t1}  （最終: ${final}）  OK inode=${st}"
        PROBE_DIRS+=("${l}")
    elif [ "${src}" -eq 137 ]; then
        say "[${l}] -> ${t1}  応答なし"
        verdict 2 "${l} の行き先が応答しない（EFS への通信）"
    else
        k="$(classify "${st}")"
        say "[${l}] -> ${t1}  ${k}  (${st})"
        case "${k}" in
            STALE)  verdict 2 "${l} の行き先が Stale: リンク先（EFS 上）の上位ディレクトリが作り直された可能性" ;;
            ENOENT) verdict 1 "${l} の行き先が無い: EFS 側のディレクトリが未作成・削除済み、または上位が Stale（マウント欄を確認）" ;;
            *)      verdict 1 "${l} の行き先を引けない: ${st}" ;;
        esac
    fi
done

# ---------------------------------------------------------------- 4. Java プロセスの FD
if [ "${#PIDS[@]}" -eq 0 ]; then
    for d in /proc/[0-9]*; do
        exe="$(readlink "${d}/exe" 2>/dev/null || true)"
        case "${exe}" in */java) PIDS+=("${d#/proc/}") ;; esac
    done
fi

sect "Java プロセスが開いているファイル（NFS 上のもの）"
[ "${#PIDS[@]}" -eq 0 ] && say "Java プロセスが見つからない"
N_STALE=0; N_REPL=0; N_MISS=0; N_SILLY=0; N_OK=0
for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
    [ -d "/proc/${pid}" ] || { say "[pid ${pid}] プロセスが無い"; continue; }
    cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | cut -c1-160)"
    kind="java"
    case "${cmd}" in *jboss-modules.jar*) kind="JBoss EAP" ;; esac
    say "[pid ${pid}] ${kind}: ${cmd}..."
    if ! ls "/proc/${pid}/fd" >/dev/null 2>&1; then
        say "    FD を読めない（権限不足。root で実行する）"
        verdict 1 "pid ${pid} の FD を読めない（root で実行し直す）"
        continue
    fi
    for fd in /proc/"${pid}"/fd/*; do
        tgt="$(readlink "${fd}" 2>/dev/null || true)"
        [ -n "${tgt}" ] || continue
        path="${tgt% (deleted)}"
        is_on_nfs "${path}" || continue
        n="${fd##*/}"
        name="${path##*/}"
        # (1) FD が指す実体を確かめる。stat だけだと NFS の属性キャッシュ（数秒〜1 分）の古い答えが
        #     返ることがあるので、読み取りで開き直す（NFS は開くたびにサーバへ確認する＝close-to-open）。
        #     NFSv4.1 / v3 はファイルハンドルで確かめるので、改名されただけのファイルは OK になる。
        out="$(tcheck stat -L -c '%i' "${fd}" 2>&1)"; rc=$?
        if [ "${rc}" -eq 0 ]; then
            ino_fd="${out}"
            # shellcheck disable=SC2016  # $1 は子の sh で展開させる
            out="$(tcheck sh -c ': < "$1"' sh "${fd}" 2>&1)"; rc=$?
        fi
        if [ "${rc}" -ne 0 ]; then
            k="$(classify "${out}")"
            [ "${rc}" -eq 137 ] && k="応答なし"
            case "${k}" in
                STALE)
                    say "    fd ${n}: STALE   ${path}（サーバ上で実体が消えている。EFS では書き込みも失敗する）"
                    N_STALE=$((N_STALE + 1)) ;;
                ENOENT)
                    say "    fd ${n}: MISSING ${path}（サーバ上にその名前が無い。名前の無い実体へ書いている）"
                    N_MISS=$((N_MISS + 1)) ;;
                *)
                    say "    fd ${n}: ${k}  ${path}  (${out})"
                    verdict 1 "pid ${pid} fd ${n} (${path}) を確認できない: ${out}" ;;
            esac
            continue
        fi
        case "${name}" in
            .nfs*) say "    fd ${n}: SILLY   ${path}（同じクライアントで使用中に削除された。閉じると中身ごと消える）"
                   N_SILLY=$((N_SILLY + 1)); continue ;;
        esac
        # (2) 名前の側も一度開いてから inode を比べる（名前のキャッシュの古い答えを避ける）。
        #     NFSv3 はディレクトリの属性キャッシュ（acdirmin 既定 30 秒）が切れるまで、他のクライアントの
        #     改名に気づかないことがある（REPLACED の見逃し。v4.1 は名前で開き直すので気づく）。
        # shellcheck disable=SC2016
        tcheck sh -c ': < "$1"' sh "${path}" >/dev/null 2>&1 || true
        ino_path="$(tcheck stat -c '%i' "${path}" 2>/dev/null || true)"
        if [ -z "${ino_path}" ]; then
            say "    fd ${n}: MISSING ${path}（その名前のファイルは無い。改名・削除済みの実体へ書いている）"
            N_MISS=$((N_MISS + 1))
        elif [ "${ino_path}" != "${ino_fd}" ]; then
            say "    fd ${n}: REPLACED ${path}（名前は別の実体 inode=${ino_path} を指す。FD は古い inode=${ino_fd}）"
            N_REPL=$((N_REPL + 1))
        else
            [ "${QUIET}" -eq 1 ] || say "    fd ${n}: OK      ${path} (inode=${ino_fd})"
            N_OK=$((N_OK + 1))
        fi
    done
done
say "集計: STALE=${N_STALE} REPLACED=${N_REPL} MISSING=${N_MISS} SILLY=${N_SILLY} OK=${N_OK}"
[ "${N_STALE}" -gt 0 ] && verdict 1 "Java が掴んでいるファイル ${N_STALE} 個が Stale: 別タスク・別ホストがそのファイル（または親ディレクトリ）を削除した。JBoss の reload かタスク入れ替えで開き直す。根本対策はタスクごとのログパス"
[ "${N_REPL}" -gt 0 ] && verdict 1 "FD ${N_REPL} 個が古い実体を掴んでいる（名前は別ファイル）: 同じパスを複数タスクが使い、他タスクがローテーションした跡。ログが想定と違うファイルに入っている"
[ "${N_MISS}" -gt 0 ] && verdict 1 "FD ${N_MISS} 個が名前の無い実体を掴んでいる: 改名・削除済み。EFS 上で消されていれば次の書き込みで Stale になる"
[ "${N_SILLY}" -gt 0 ] && verdict 1 "FD ${N_SILLY} 個が .nfs ファイル（同じタスク内で使用中に削除）: 容量を使い続け、閉じると中身ごと消える"

# ---------------------------------------------------------------- 5. .nfs ファイル
sect ".nfsXXXX（使用中に削除されたファイルの名残）"
declare -a SCAN=()
for l in "${PROBE_DIRS[@]+"${PROBE_DIRS[@]}"}"; do SCAN+=("$(readlink -f "${l}")"); done
[ "${#SCAN[@]}" -eq 0 ] && SCAN=("${MOUNTS[@]+"${MOUNTS[@]}"}")
found=0
for d in "${SCAN[@]+"${SCAN[@]}"}"; do
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        say "  ${f}"
        found=$((found + 1))
    done < <(tcheck find "${d}" -xdev -maxdepth 4 -name '.nfs*' -printf '%p  size=%s  mtime=%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | head -50)
done
[ "${found}" -eq 0 ] && say "なし"

# ---------------------------------------------------------------- 6. 書き込みテスト
if [ "${PROBE}" -eq 1 ]; then
    sect "書き込みテスト（一時ファイルを作って消す）"
    [ "${#PROBE_DIRS[@]}" -eq 0 ] && PROBE_DIRS=("${MOUNTS[@]+"${MOUNTS[@]}"}")
    for d in "${PROBE_DIRS[@]+"${PROBE_DIRS[@]}"}"; do
        f="${d}/.estale-probe.$$.${RANDOM}"
        # shellcheck disable=SC2016  # $1 は子の sh で展開させる
        out="$(tcheck sh -c 'echo probe > "$1" && rm -f "$1"' sh "${f}" 2>&1)"; rc=$?
        if [ "${rc}" -eq 0 ]; then
            say "[${d}] OK（新しく開く・作る操作はできる）"
        else
            k="$(classify "${out}")"
            [ "${rc}" -eq 137 ] && k="応答なし"
            say "[${d}] ${k}  (${out})"
            verdict 2 "${d} に新しいファイルを作れない（${k}）: ロールオーバや新しいログも書けない"
        fi
    done
fi

# ---------------------------------------------------------------- 判定
printf '\n== 判定\n'
if [ "${#VERDICTS[@]}" -eq 0 ]; then
    echo "異常なし（Stale・応答なしは見つからない）"
else
    for v in "${VERDICTS[@]}"; do echo "- ${v}"; done
fi
case "${SEV}" in
    2) echo "→ 優先対応: このタスクを入れ替える（aws ecs stop-task、またはサービスの force-new-deployment）" ;;
    1) echo "→ 優先対応: 消した側（別タスクのロールオーバ・削除バッチ・手作業）を特定して止め、JBoss の reload かタスク入れ替えで開き直す" ;;
esac
exit "${SEV}"
