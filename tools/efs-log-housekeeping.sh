#!/usr/bin/env bash
# =============================================================================
# efs-log-housekeeping.sh — EFS 上の「タスクごとのログディレクトリ」を、
#                           使用中のタスクのものを消さずに片付ける
#
#   EFS（NFS）では、別のホスト・別のタスクが「開いているファイル」を消すと、
#   開いている側は次の書き込みで java.io.IOException: Stale file handle になる。
#   ローカルディスクの感覚で「古いログを日数で消す」バッチを動かすと、長く動いている
#   タスクのログを消してしまう。本スクリプトは削除の前に ECS に生きているタスクを
#   問い合わせ、そのタスクのディレクトリには触らない。
#
#   対象の形（-b で「タスクごとのディレクトリが並ぶ親」を指定する）:
#     <base>/<タスクID 32 桁>/...             LOG_ID_MODE=taskid のとき
#     <base>/<YYYYMMDDhhmmss-xxxxxxxx>/...    起動時刻＋乱数のとき（持ち主は .owner で判定）
#     <base>/<任意>/.owner                    entrypoint が書く持ち主ファイル（TaskARN=...）
#
#   残す条件（どれか 1 つでも当てはまれば消さない）:
#     1. 持ち主のタスクが ECS で RUNNING（または停止処理中・停止直後）
#     2. 中のファイルが --min-age-hours 以内に更新されている
#     3. .nfsXXXX がある（同じホストで使用中のファイルが消された跡 = まだ誰かが開いている）
#     4. シンボリックリンク（current 等）、およびリンクが指しているディレクトリ
#     5. 保存期間内（持ち主が分かる: --keep-days、分からない: --unknown-keep-days）
#
#   実行環境: EFS をマウントした EC2（RHEL 9 系の bash）＋ AWS CLI v2。
#   規約: aws login --remote 済みを確認し、ECS の参照権限が無ければスイッチバックを促す
#         （-A で自動スイッチバック）。DRY_RUN（-N）なら何も消さない。
# =============================================================================
set -euo pipefail

ELH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELH_SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ELH_VERSION="1.0.0"

if [[ ! -f "${ELH_SCRIPT_DIR}/common.sh" ]]; then
  echo "[ERROR] common.sh が見つかりません: ${ELH_SCRIPT_DIR}/common.sh" >&2
  exit 1
fi
# shellcheck source=tools/common.sh
source "${ELH_SCRIPT_DIR}/common.sh"

readonly ELH_EX_USAGE=2        # 引数の誤り
readonly ELH_EX_PARTIAL=3      # 一部のディレクトリを消せなかった
readonly ELH_EX_UNSAFE=4       # 安全に判定できない（RUNNING が 0 件・クラスターが無い 等）
readonly ELH_EX_NOAUTH=10      # 未認証（aws login --remote が必要）
readonly ELH_EX_NOPERM=11      # ECS の参照権限なし（スイッチバックが必要）
readonly ELH_EX_SWITCHBACK=12  # スイッチバックの失敗

# 変数名は ELH_ で始める（スイッチバック用シェルを source するため、よくある名前は避ける）
ELH_BASES=()
ELH_CLUSTERS=()
ELH_KEEP_DAYS=30
ELH_UNKNOWN_KEEP_DAYS=90
ELH_MIN_AGE_HOURS=24
ELH_ALLOW_NO_RUNNING=false
ELH_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
ELH_AUTO_SWITCH_BACK=false
ELH_SWITCH_BACK_SCRIPT="${SWITCH_BACK_SCRIPT:-}"
ELH_REPORT=""
DRY_RUN="${DRY_RUN:-false}"
ASSUME_YES="${ASSUME_YES:-false}"

ELH_TMP=""
ELH_IN_SWITCH_BACK=0
ELH_SB_PATH=""
ELH_LAST_ERROR=""
ELH_CALLER_ARN=""
ELH_AWS_ARGS=()

usage() {
  cat <<EOF
使い方:
  ${ELH_SCRIPT_NAME} -b <親ディレクトリ> [-b ...] -c <クラスター> [-c ...] [オプション]

EFS 上のタスクごとのログディレクトリのうち、持ち主のタスクが動いていないもので、
保存期間を過ぎたものだけを削除します。既定では確認してから削除します（-N で表示のみ）。

必須:
  -b, --base <DIR>            タスクごとのディレクトリが並ぶ親（複数可）
                              例: /mnt/efs/logs-root/interapi-front/logs/interapi/mid
  -c, --cluster <名前>        生きているタスクを問い合わせる ECS クラスター（複数可）

保存期間:
  -k, --keep-days <日>        持ち主が分かるディレクトリの保存日数（既定 ${ELH_KEEP_DAYS}）
      --unknown-keep-days <日>
                              持ち主が分からないディレクトリの保存日数（既定 ${ELH_UNKNOWN_KEEP_DAYS}）
      --min-age-hours <時間>  この時間内に更新されたファイルがあれば必ず残す（既定 ${ELH_MIN_AGE_HOURS}）
      --allow-no-running      RUNNING のタスクが 0 件でも続ける（既定は安全のため中止）

AWS:
  -r, --region <リージョン>   既定 ${ELH_REGION}
  -p, --profile <名前>        AWS_PROFILE として使う
  -A, --auto-switch-back      ECS を参照できない権限のとき、スイッチバック用シェルを source して続ける
  -S, --switch-back-script <パス>
                              スイッチバック用シェル（環境変数 SWITCH_BACK_SCRIPT でも可）

その他:
  -y, --yes                   確認せずに削除する（cron 等）
  -N, --dry-run               何も消さずに判定だけ表示する
      --report <FILE>         判定の一覧を TSV で書き出す
  -v, --verbose               詳細（AWS CLI の呼び出し）を表示
  -h, --help                  このヘルプ
      --version               版数

終了コード:
  0 正常 / 2 引数の誤り / 3 一部を消せなかった / 4 安全に判定できない
  10 未認証（aws login --remote が必要） / 11 ECS の参照権限なし / 12 スイッチバックの失敗

例:
  # まず判定だけ見る
  ./${ELH_SCRIPT_NAME} -N -c prod-cluster -b /mnt/efs/logs-root/interapi-front/logs/interapi/mid
  # cron で毎日（30 日より古い、止まったタスクのものだけ消す）
  ./${ELH_SCRIPT_NAME} -y -c prod-cluster -b /mnt/efs/logs-root/interapi-front/logs/interapi/mid \\
      -b /mnt/efs/logs-root/interapi-front/logs/interapi/app
EOF
}

elh_need_value() {
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    die "オプション $1 には値が必要です（--help を参照）" "$ELH_EX_USAGE"
  fi
}
elh_need_int() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "オプション $1 は 0 以上の整数で指定してください: $2" "$ELH_EX_USAGE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--base)               elh_need_value "$@"; ELH_BASES+=("${2%/}"); shift 2 ;;
    -c|--cluster)            elh_need_value "$@"; ELH_CLUSTERS+=("$2"); shift 2 ;;
    -k|--keep-days)          elh_need_value "$@"; elh_need_int "$1" "$2"; ELH_KEEP_DAYS="$2"; shift 2 ;;
    --unknown-keep-days)     elh_need_value "$@"; elh_need_int "$1" "$2"; ELH_UNKNOWN_KEEP_DAYS="$2"; shift 2 ;;
    --min-age-hours)         elh_need_value "$@"; elh_need_int "$1" "$2"; ELH_MIN_AGE_HOURS="$2"; shift 2 ;;
    --allow-no-running)      ELH_ALLOW_NO_RUNNING=true; shift ;;
    -r|--region)             elh_need_value "$@"; ELH_REGION="$2"; shift 2 ;;
    -p|--profile)            elh_need_value "$@"; export AWS_PROFILE="$2"; shift 2 ;;
    -A|--auto-switch-back)   ELH_AUTO_SWITCH_BACK=true; shift ;;
    -S|--switch-back-script) elh_need_value "$@"; ELH_SWITCH_BACK_SCRIPT="$2"; shift 2 ;;
    -y|--yes)                ASSUME_YES=true; shift ;;
    -N|--dry-run)            DRY_RUN=true; shift ;;
    --report)                elh_need_value "$@"; ELH_REPORT="$2"; shift 2 ;;
    -v|--verbose)            DEBUG=true; shift ;;
    -h|--help)               usage; exit 0 ;;
    --version)               echo "${ELH_SCRIPT_NAME} ${ELH_VERSION}"; exit 0 ;;
    *) die "不明な引数です: $1（--help を参照）" "$ELH_EX_USAGE" ;;
  esac
done
export DRY_RUN ASSUME_YES

[[ ${#ELH_BASES[@]} -gt 0 ]] || die "-b/--base を 1 つ以上指定してください（--help を参照）" "$ELH_EX_USAGE"
[[ ${#ELH_CLUSTERS[@]} -gt 0 ]] || die "-c/--cluster を 1 つ以上指定してください（生きているタスクの問い合わせに必須）" "$ELH_EX_USAGE"
if (( ELH_UNKNOWN_KEEP_DAYS < ELH_KEEP_DAYS )); then
  die "--unknown-keep-days（${ELH_UNKNOWN_KEEP_DAYS}）は --keep-days（${ELH_KEEP_DAYS}）以上にしてください" "$ELH_EX_USAGE"
fi
ELH_AWS_ARGS=(--region "$ELH_REGION")

# ---------------------------------------------------------------------------
# 後始末
# ---------------------------------------------------------------------------
# shellcheck disable=SC2317  # trap から呼ばれる
elh_on_exit() {
  local rc=$?
  if [[ "$ELH_IN_SWITCH_BACK" == "1" ]]; then
    log_error "スイッチバック用シェルの実行中に処理が終了しました: ${ELH_SB_PATH}"
    log_error "  source で呼び出すシェルは、exit ではなく return で終了する必要があります。"
    rc=$ELH_EX_SWITCHBACK
  fi
  [[ -n "$ELH_TMP" && -d "$ELH_TMP" ]] && rm -rf -- "$ELH_TMP"
  exit "$rc"
}
elh_install_traps() {
  trap elh_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
elh_install_traps
ELH_TMP="$(mktemp -d)"

# ---------------------------------------------------------------------------
# AWS: 認証・権限・スイッチバック
# ---------------------------------------------------------------------------
elh_check_auth() {
  local out
  log_debug "aws ${ELH_AWS_ARGS[*]} sts get-caller-identity"
  if out="$(aws "${ELH_AWS_ARGS[@]}" sts get-caller-identity --query 'Arn' --output text 2>"$ELH_TMP/sts.err")"; then
    ELH_CALLER_ARN="$out"
    return 0
  fi
  ELH_LAST_ERROR="$(mask_secrets <"$ELH_TMP/sts.err")"
  return 1
}

# 戻り値: 0 = 参照できる / 1 = 権限なし / 2 = 権限以外のエラー
elh_probe_ecs_permission() {
  local err
  ELH_LAST_ERROR=""
  log_debug "aws ${ELH_AWS_ARGS[*]} ecs list-tasks --cluster ${ELH_CLUSTERS[0]} --max-results 1 --no-paginate"
  if ! err="$(aws "${ELH_AWS_ARGS[@]}" ecs list-tasks --cluster "${ELH_CLUSTERS[0]}" \
      --max-results 1 --no-paginate --output json 2>&1 >/dev/null)"; then
    ELH_LAST_ERROR="$(mask_secrets <<<"$err")"
    case "$(aws_classify_error "$ELH_LAST_ERROR")" in
      access_denied) return 1 ;;
      *) return 2 ;;
    esac
  fi
  return 0
}

elh_switch_back_prepare() {
  if [[ -z "$ELH_SWITCH_BACK_SCRIPT" ]]; then
    log_error "自動スイッチバックには、スイッチバック用シェルの場所の指定が必要です。"
    log_error "  -S/--switch-back-script <パス> または 環境変数 SWITCH_BACK_SCRIPT で指定してください。"
    exit "$ELH_EX_SWITCHBACK"
  fi
  ELH_SB_PATH="$(resolve_abs_path "$ELH_SWITCH_BACK_SCRIPT")" ||
    die "スイッチバック用シェルの配置ディレクトリが存在しません: $ELH_SWITCH_BACK_SCRIPT" "$ELH_EX_SWITCHBACK"
  [[ -f "$ELH_SB_PATH" ]] || die "スイッチバック用シェルが見つかりません: $ELH_SB_PATH" "$ELH_EX_SWITCHBACK"
  [[ -r "$ELH_SB_PATH" ]] || die "スイッチバック用シェルを読み取れません: $ELH_SB_PATH" "$ELH_EX_SWITCHBACK"
  ELH_SB_SAVED_SET="$(set +o)"
  ELH_SB_SAVED_SHOPT="$(shopt -p || true)"
  ELH_SB_SAVED_PWD="$PWD"
  ELH_SB_SAVED_IFS="$IFS"
  declare -f >"$ELH_TMP/functions.bash"
  log_info "スイッチバック用シェルを source します: $ELH_SB_PATH"
  set +e +u +o pipefail
}

elh_switch_back_restore() {
  # shellcheck source=/dev/null
  source "$ELH_TMP/functions.bash"
  eval "$ELH_SB_SAVED_SHOPT"
  eval "$ELH_SB_SAVED_SET"
  IFS="$ELH_SB_SAVED_IFS"
  cd -- "$ELH_SB_SAVED_PWD" 2>/dev/null || true
  elh_install_traps
}

# ---------------------------------------------------------------------------
# 判定に使う小道具
# ---------------------------------------------------------------------------
# ディレクトリの持ち主（タスク ID）を返す。分からなければ空
elh_owner_of() {
  local d="$1" arn base
  if [[ -f "$d/.owner" ]]; then
    arn="$(sed -n 's/^TaskARN=//p' "$d/.owner" | head -n 1)"
    # TaskARN=unknown（ローカル実行など）は持ち主不明として扱う
    if [[ "$arn" =~ ^arn:aws[a-z-]*:ecs:[^:]*:[0-9]*:task/ ]]; then
      printf '%s' "${arn##*/}"
      return 0
    fi
  fi
  base="${d##*/}"
  if [[ "$base" =~ ^[0-9a-f]{32}$ ]]; then
    printf '%s' "$base"
  fi
}

# ディレクトリの中でいちばん新しい更新時刻（エポック秒）
elh_newest_mtime() {
  { find "$1" -xdev -printf '%T@\n' 2>/dev/null || true; } | sort -n | tail -n 1 | cut -d. -f1
}

elh_has_nfs_files() {
  [[ -n "$(find "$1" -xdev -name '.nfs*' -print -quit 2>/dev/null)" ]]
}

elh_fmt_time() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"; }

# ===========================================================================
# 事前チェック 1: コマンドと対象ディレクトリ
# ===========================================================================
log_section "事前チェック: コマンドと対象ディレクトリ"
require_command aws
require_command find
for b in "${ELH_BASES[@]}"; do
  [[ -d "$b" ]] || die "親ディレクトリがありません: $b（EFS のマウントとパスを確認してください）" "$ELH_EX_USAGE"
  fstype="$(stat -f -c '%T' "$b" 2>/dev/null || echo '?')"
  if [[ "$fstype" != "nfs" ]]; then
    log_warn "NFS（EFS）ではありません（${fstype}）: $b"
  fi
  log_info "対象: $b （${fstype}）"
done
log_info "保存期間: 持ち主が分かる ${ELH_KEEP_DAYS} 日 / 分からない ${ELH_UNKNOWN_KEEP_DAYS} 日 / 更新から ${ELH_MIN_AGE_HOURS} 時間以内は必ず残す"
[[ "$DRY_RUN" == "true" ]] && log_info "dry-run: 何も削除しません"

# ===========================================================================
# 事前チェック 2: AWS 認証（aws login --remote 済みか）
# ===========================================================================
log_section "事前チェック: AWS 認証状態"
if ! elh_check_auth; then
  if [[ "$(aws_classify_error "$ELH_LAST_ERROR")" == "network" ]]; then
    log_error "AWS（STS）へ接続できませんでした。ネットワーク / プロキシ / リージョン（${ELH_REGION}）を確認してください。"
    log_error "詳細: $(aws_error_line "$ELH_LAST_ERROR")"
    die "AWS へ接続できないため中止しました" "$ELH_EX_NOAUTH"
  fi
  log_error "AWS が未認証です（aws login --remote が済んでいないか、期限切れです）。"
  log_error "先に次のコマンドで認証してから再実行してください:"
  log_error "    aws login --remote${AWS_PROFILE:+ --profile ${AWS_PROFILE}}"
  [[ -n "$ELH_LAST_ERROR" ]] && log_error "詳細: $(aws_error_line "$ELH_LAST_ERROR")"
  die "未認証のため中止しました" "$ELH_EX_NOAUTH"
fi
log_success "AWS 認証済み: ${ELH_CALLER_ARN}"

# ===========================================================================
# 事前チェック 3: ECS の参照権限（スイッチバック制御）
# ===========================================================================
log_section "事前チェック: ECS 参照権限（スイッチバック制御）"
elh_perm_rc=0
elh_probe_ecs_permission || elh_perm_rc=$?
case "$elh_perm_rc" in
  0) log_success "ECS の参照権限を確認しました（ecs:ListTasks）" ;;
  1)
    log_warn "現在の権限では ECS を参照できません（AccessDenied）。CodeCommit 用の権限のままの可能性があります。"
    log_warn "  詳細: $(aws_error_line "$ELH_LAST_ERROR")"
    if [[ "$ELH_AUTO_SWITCH_BACK" != "true" ]]; then
      log_error "ECS を参照できる権限へスイッチバックしてから再実行してください:"
      if [[ -n "$ELH_SWITCH_BACK_SCRIPT" ]]; then
        log_error "    source \"${ELH_SWITCH_BACK_SCRIPT}\""
      else
        log_error "    （別チーム提供のスイッチバック用シェルを source。場所は -S または SWITCH_BACK_SCRIPT で指定）"
      fi
      log_error "または -A（--auto-switch-back）で自動スイッチバックしてから続けます。"
      die "ECS の参照権限が無いため中止しました" "$ELH_EX_NOPERM"
    fi
    elh_switch_back_prepare
    # ↓ source は関数の中ではなくトップレベルで行う（関数の中だと、相手の declare / typeset が
    #   ローカル変数になって消える）。効果はこのプロセスの中だけ。
    ELH_IN_SWITCH_BACK=1
    # shellcheck source=/dev/null
    source "$ELH_SB_PATH"
    ELH_SB_RC=$?
    ELH_IN_SWITCH_BACK=0
    elh_switch_back_restore
    [[ "$ELH_SB_RC" -ne 0 ]] && log_warn "スイッチバック用シェルが終了コード ${ELH_SB_RC} を返しました（権限を確認し直します）"
    elh_check_auth || die "スイッチバック後に認証が無効です: $(aws_error_line "$ELH_LAST_ERROR")" "$ELH_EX_SWITCHBACK"
    elh_perm_rc=0
    elh_probe_ecs_permission || elh_perm_rc=$?
    [[ "$elh_perm_rc" -eq 0 ]] || die "スイッチバック後も ECS を参照できません: $(aws_error_line "$ELH_LAST_ERROR")" "$ELH_EX_SWITCHBACK"
    log_success "スイッチバックしました: ${ELH_CALLER_ARN}"
    ;;
  *)
    log_error "ECS の参照に失敗しました（権限以外）: $(aws_error_line "$ELH_LAST_ERROR")"
    die "クラスター名・リージョン（${ELH_REGION}）・ネットワークを確認してください" "$ELH_EX_UNSAFE"
    ;;
esac

# ===========================================================================
# ステップ 1: 生きているタスクを集める（RUNNING と、停止処理中・停止直後）
#   list-tasks --desired-status STOPPED には、停止を指示されたがまだ書いているタスク
#   （ドレイン中）と、止まってから約 1 時間以内のタスクが含まれる。これらも残す。
# ===========================================================================
log_section "ステップ 1: ECS に生きているタスクを問い合わせる"
declare -A ELH_ACTIVE=()
for cl in "${ELH_CLUSTERS[@]}"; do
  for st in RUNNING STOPPED; do
    log_debug "aws ${ELH_AWS_ARGS[*]} ecs list-tasks --cluster $cl --desired-status $st"
    if ! out="$(aws "${ELH_AWS_ARGS[@]}" ecs list-tasks --cluster "$cl" --desired-status "$st" \
        --query 'taskArns' --output text 2>"$ELH_TMP/lt.err")"; then
      die "タスク一覧を取得できません（$cl / $st）: $(aws_error_line "$(mask_secrets <"$ELH_TMP/lt.err")")" "$ELH_EX_UNSAFE"
    fi
    n=0
    for arn in $out; do
      [[ "$arn" == "None" ]] && continue
      ELH_ACTIVE["${arn##*/}"]="$cl/$st"
      n=$((n + 1))
    done
    log_info "  $cl: desired=$st … ${n} 件"
    if [[ "$st" == "RUNNING" && "$n" -eq 0 && "$ELH_ALLOW_NO_RUNNING" != "true" ]]; then
      die "クラスター $cl に RUNNING のタスクが 0 件です。クラスター名の誤りで全部を古いと判定する事故を防ぐため中止します（意図どおりなら --allow-no-running）" "$ELH_EX_UNSAFE"
    fi
  done
done
log_success "残すタスク: ${#ELH_ACTIVE[@]} 件"

# ===========================================================================
# ステップ 2: 判定
# ===========================================================================
log_section "ステップ 2: ディレクトリごとの判定"
now="$(date +%s)"
keep_s=$((ELH_KEEP_DAYS * 86400))
unknown_s=$((ELH_UNKNOWN_KEEP_DAYS * 86400))
minage_s=$((ELH_MIN_AGE_HOURS * 3600))
DEL=()
n_keep=0
[[ -n "$ELH_REPORT" ]] && printf '判定\tディレクトリ\t持ち主\t最終更新\t理由\n' >"$ELH_REPORT"

elh_emit() {   # 判定 ディレクトリ 持ち主 最終更新 理由
  printf '  %-6s %s  owner=%s  newest=%s  %s\n' "$1" "$2" "${3:--}" "$4" "$5"
  [[ -n "$ELH_REPORT" ]] && printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "$4" "$5" >>"$ELH_REPORT"
  return 0
}

for b in "${ELH_BASES[@]}"; do
  # シンボリックリンク（current 等）が指す先は残す
  declare -A ELH_LINKED=()
  while IFS= read -r l; do
    t="$(readlink -f "$l" 2>/dev/null || true)"
    [[ -n "$t" ]] && ELH_LINKED["$t"]=1
  done < <(find "$b" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)

  while IFS= read -r d; do
    owner="$(elh_owner_of "$d")"
    newest="$(elh_newest_mtime "$d")"
    [[ -n "$newest" ]] || newest="$now"
    age=$((now - newest))
    when="$(elh_fmt_time "$newest")"
    real="$(readlink -f "$d")"
    decision=KEEP
    if [[ -n "$owner" && -n "${ELH_ACTIVE[$owner]:-}" ]]; then
      reason="使用中のタスク（${ELH_ACTIVE[$owner]}）"
    elif [[ -n "${ELH_LINKED[$real]:-}" ]]; then
      reason="シンボリックリンクが指している"
    elif elh_has_nfs_files "$d"; then
      reason=".nfs ファイルあり（まだ開いているプロセスがある）"
    elif (( age < minage_s )); then
      reason="${ELH_MIN_AGE_HOURS} 時間以内に更新あり"
    elif [[ -n "$owner" ]] && (( age >= keep_s )); then
      decision=DELETE; reason="停止済みタスク・${ELH_KEEP_DAYS} 日超"
    elif [[ -z "$owner" ]] && (( age >= unknown_s )); then
      decision=DELETE; reason="持ち主不明・${ELH_UNKNOWN_KEEP_DAYS} 日超"
    else
      reason="保存期間内"
    fi
    elh_emit "$decision" "$d" "$owner" "$when" "$reason"
    if [[ "$decision" == "DELETE" ]]; then
      DEL+=("$d")
    else
      n_keep=$((n_keep + 1))
    fi
  done < <(find "$b" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  unset ELH_LINKED
done
log_info "判定: 残す ${n_keep} / 消す ${#DEL[@]}"

# ===========================================================================
# ステップ 3: 削除
# ===========================================================================
log_section "ステップ 3: 削除"
if [[ ${#DEL[@]} -eq 0 ]]; then
  log_success "消すものはありません"
  exit 0
fi
if ! confirm "${#DEL[@]} 個のディレクトリを削除しますか?"; then
  log_warn "中止しました（何も削除していません）"
  exit 0
fi
failed=0
for d in "${DEL[@]}"; do
  # 判定から削除までの間に使われ始めていないか、直前にもう一度確かめる
  newest="$(elh_newest_mtime "$d")"
  if [[ -n "$newest" ]] && (( now - newest < minage_s )) || elh_has_nfs_files "$d"; then
    log_warn "直前の再確認で使用中の跡があったため残します: $d"
    continue
  fi
  if run rm -rf -- "$d"; then
    [[ "$DRY_RUN" == "true" ]] || log_success "削除: $d"
  else
    log_error "削除に失敗: $d"
    failed=$((failed + 1))
  fi
done
if (( failed > 0 )); then
  die "${failed} 個のディレクトリを削除できませんでした（権限・.nfs ファイル・EFS の状態を確認してください）" "$ELH_EX_PARTIAL"
fi
log_success "完了"
