#!/bin/sh
# =============================================================================
# app-log-dir.sh — アプリログ（Log4j2）の書き先を「タスクごとのディレクトリ」にする
#
#   いまの構成: /webapp/webapp9mf02/logs -> /mnt/logs/<コンポーネント>/logs/<サービス>   ← 全タスク共有
#   変えたあと: /webapp/webapp9mf02/logs -> /opt/jboss-eap/standalone/tmp/app-log-target  （ビルド時）
#               tmp/app-log-target       -> /mnt/logs/<コンポーネント>/logs/<サービス>/app/<APP_LOG_ID>（起動時）
#
#   JBoss のログ（standalone/log -> tmp/jboss-log-target -> mid/<LOG_ID>）と同じ二段リンクの考え方。
#   アプリの log4j2.xml は /webapp/webapp9mf02/logs/... のまま変えなくてよい。
#   1 つのファイルを書くのが 1 タスク（1 つの NFS クライアント）だけになるので、
#   他タスクのロールオーバ・削除で Stale file handle になることがなくなる。
#
#   使い方（efs-entrypoint.sh の中、JBoss を exec する前）:
#       . /usr/local/bin/app-log-dir.sh
#       setup_app_log_dir || die "アプリログのディレクトリを用意できません"
#
#   環境変数
#     EFS_LOG_DIR           必須。/mnt/logs/<Component_name>/logs/<Service_Name>（イメージに焼き込み済み）
#     APP_LOG_SUBDIR        既定 app（EFS_LOG_DIR の下に作る親ディレクトリ名）
#     APP_LOG_LINK_TARGET   既定 /opt/jboss-eap/standalone/tmp/app-log-target（タスクローカルの書き込み可能領域）
#     APP_LOG_ID            指定があればそれを使う。無ければ LOG_ID（JBoss ログと同じ名前）→ タスク ID → 起動時刻-乱数
#     LOG_ID_MODE           taskid のとき、LOG_ID が無ければ ECS タスク ID を使う
#   結果: APP_LOG_ID / APP_LOG_DIR を export する。ディレクトリには持ち主ファイル .owner を書く
#         （片付けバッチ efs-log-housekeeping.sh が「動いているタスクのものか」を判定するのに使う）
# =============================================================================

_alog_say() { echo "[app-log-dir] $*"; }

# ECS メタデータエンドポイント v4 から TaskARN を取る（取れなければ空）
_alog_task_arn() {
    [ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    curl -s --max-time 2 "${ECS_CONTAINER_METADATA_URI_V4}/task" 2>/dev/null \
        | sed -n 's/.*"TaskARN"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

_alog_rand8() {
    _r="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8)"
    [ "${#_r}" -eq 8 ] || _r="$(printf '%08x' "$$")"
    printf '%s' "${_r}"
}

setup_app_log_dir() {
    if [ -z "${EFS_LOG_DIR:-}" ]; then
        _alog_say "ERROR: EFS_LOG_DIR が未設定です"
        return 1
    fi
    _base="${EFS_LOG_DIR}/${APP_LOG_SUBDIR:-app}"
    _link="${APP_LOG_LINK_TARGET:-/opt/jboss-eap/standalone/tmp/app-log-target}"
    _arn="$(_alog_task_arn)"

    _id="${APP_LOG_ID:-${LOG_ID:-}}"
    if [ -z "${_id}" ]; then
        if [ "${LOG_ID_MODE:-timestamp}" = "taskid" ] && [ -n "${_arn}" ]; then
            _id="${_arn##*/}"
        else
            _id="$(date +%Y%m%d%H%M%S)-$(_alog_rand8)"
        fi
    fi

    # 既存なら再利用（同じタスクの中でコンテナだけ再起動したとき）。EFS 上では mkdir -p だけを使い、
    # 既存のディレクトリを消したり作り直したりは絶対にしない（他タスクの FD を Stale にするため）。
    if ! mkdir -p "${_base}/${_id}"; then
        _alog_say "ERROR: ${_base}/${_id} を作れません（EFS のマウント・アクセスポイントの uid/gid・umask を確認）"
        return 1
    fi
    if [ ! -f "${_base}/${_id}/.owner" ]; then
        {
            echo "TaskARN=${_arn:-unknown}"
            echo "Container=${Component_name:-unknown}"
            echo "StartedAt=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            echo "Host=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)"
        } > "${_base}/${_id}/.owner" || _alog_say "WARN: .owner を書けません（片付けでは持ち主不明として長めに残る）"
    fi

    _parent="$(dirname "${_link}")"
    if [ ! -d "${_parent}" ]; then
        _alog_say "ERROR: ${_parent} がありません（タスク定義で standalone/tmp に書き込み可能ボリュームを当てる）"
        return 1
    fi
    # -n: 既存のリンクがディレクトリを指していても、その中にリンクを作らない
    if ! ln -sfn "${_base}/${_id}" "${_link}"; then
        _alog_say "ERROR: ${_link} を張れません"
        return 1
    fi

    APP_LOG_ID="${_id}"
    APP_LOG_DIR="${_base}/${_id}"
    export APP_LOG_ID APP_LOG_DIR
    _alog_say "app logs -> ${APP_LOG_DIR} (link ${_link})"
    return 0
}
