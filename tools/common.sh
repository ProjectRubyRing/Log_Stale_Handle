#!/usr/bin/env bash
#
# common.sh - 複数のスクリプトで共有するユーティリティ関数群
#
# 使い方:
#   このファイルを source して各関数を利用する。
#     source "$(dirname "$0")/common.sh"
#
#   DRY_RUN=true を設定すると run() は実コマンドを実行せず表示のみ行う。
#
# 注意: このファイル自体は単体実行を想定していない（source 専用）。
#
# 由来: CodeCommit_Git_branch_local_Create プロジェクトの common.sh を基にした
#       ECS_Exec_Access_Support / CloudWatchLogs_Simple_Search / CloudWatchLogs_Excel_Export 版を流用し、
#       AWS CLI のエラー分類（認証切れ / 権限不足 / 接続不可）などを追加したもの。
#       ログ / die / run / confirm / require_command / aws_is_authenticated の
#       インタフェースは元と互換。

# 既に読み込み済みなら何もしない（多重 source 対策）
#   マーカー変数が環境に漏れていても、関数が未定義の新しいシェルでは必ず
#   定義し直すよう「変数あり かつ 関数定義済み」を読み込み済みの条件とする。
if [[ -n "${COMMON_SH_LOADED:-}" ]] && declare -F require_command >/dev/null 2>&1; then
  # shellcheck disable=SC2317  # source 時は return、誤って実行された時は exit
  return 0 2>/dev/null || exit 0
fi
COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# 色定義（端末が対応している場合のみ色を付ける）
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET="$(printf '\033[0m')"
  C_RED="$(printf '\033[31m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_BLUE="$(printf '\033[34m')"
  C_BOLD="$(printf '\033[1m')"
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD=""
fi

# ---------------------------------------------------------------------------
# ログ関数
# ---------------------------------------------------------------------------
log_info()    { printf '%s[INFO]%s  %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
log_success() { printf '%s[OK]%s    %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()    { printf '%s[WARN]%s  %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error()   { printf '%s[ERROR]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }

# DEBUG=true のときだけ標準エラーへ出力する
log_debug() {
  [[ "${DEBUG:-false}" == "true" ]] || return 0
  printf '%s[DEBUG]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

# 見出し（セクション区切り）
log_section() {
  printf '\n%s========== %s ==========%s\n' "$C_BOLD" "$*" "$C_RESET"
}

# エラーメッセージを出して終了する
# usage: die "メッセージ" [終了コード]
die() {
  local msg="$1"
  local code="${2:-1}"
  log_error "$msg"
  exit "$code"
}

# ---------------------------------------------------------------------------
# コマンド実行ヘルパー
#   DRY_RUN=true のときは実行内容を表示するだけで実行しない。
#   それ以外のときは表示してから実行する。
#
# usage: run aws logs describe-log-groups ...
# ---------------------------------------------------------------------------
run() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf '%s[DRY-RUN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
    return 0
  fi
  printf '%s[RUN]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
  "$@"
}

# ---------------------------------------------------------------------------
# 確認プロンプト
#   ASSUME_YES=true（--yes 相当）のときは確認せず yes とみなす。
#   DRY_RUN=true のときも確認をスキップする（破壊的操作は実行されないため）。
#   対話は常に端末（/dev/tty）から読む。端末が無い（cron 等）ときは no とみなす。
#
# usage: if confirm "上書きしますか?"; then ... ; fi
# 戻り値: yes -> 0, no -> 1
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-続行しますか?}"

  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    return 0
  fi
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run のため確認をスキップ)"
    return 0
  fi
  if ! (: </dev/tty) 2>/dev/null; then
    log_warn "端末が無いため確認できません（-y/--yes で自動承認できます）"
    return 1
  fi

  local reply=""
  read -r -p "$prompt [y/N]: " reply </dev/tty || reply=""
  case "$reply" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 必須コマンドの存在確認
# usage: require_command aws
# ---------------------------------------------------------------------------
require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "コマンドが見つかりません: $cmd"
}

# ---------------------------------------------------------------------------
# パスを絶対パスへ解決する（ファイル自体は存在しなくてよい。親ディレクトリは必須）
#   source の相対パス解決は「実行時の CWD」基準になるため、source する前に
#   絶対パスにしておく。
# usage: abs="$(resolve_abs_path "./switch_back.sh")" || die ...
# ---------------------------------------------------------------------------
resolve_abs_path() {
  local p="$1" dir base
  [[ -n "$p" ]] || return 1
  dir="$(dirname -- "$p")"
  base="$(basename -- "$p")"
  [[ -d "$dir" ]] || return 1
  printf '%s/%s' "$(cd -- "$dir" && pwd)" "$base"
}

# ---------------------------------------------------------------------------
# 資格情報らしき文字列を伏字にする（AWS CLI のエラー表示に含まれ得るため）
# usage: printf '%s' "$err" | mask_secrets
# ---------------------------------------------------------------------------
mask_secrets() {
  sed -E \
    -e 's/\b((AKIA|ASIA)[0-9A-Z]{4})[0-9A-Z]{12}\b/\1************/g' \
    -e 's/([Ss]ession[_ ]?[Tt]oken[^A-Za-z0-9]{1,3})[A-Za-z0-9/+=]{16,}/\1********/g'
}

# ---------------------------------------------------------------------------
# AWS の認証が済んでいるか（aws login --remote 済みか）を確認する。
#   sts get-caller-identity が成功すれば「認証済み」とみなす。
#
# usage: aws_is_authenticated [aws共通引数...]
#        例: aws_is_authenticated --region ap-northeast-1
# 戻り値: 認証済み -> 0, 未認証 -> 1
# ---------------------------------------------------------------------------
aws_is_authenticated() {
  aws "$@" sts get-caller-identity >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# AWS CLI のエラー出力を分類する（標準出力へ分類名を出す）
#   access_denied : 権限不足（スイッチバック等で権限を切り替える必要がある）
#   auth          : 未認証 / 認証の期限切れ（aws login --remote が必要）
#   network       : AWS へ到達できない（ネットワーク / プロキシ / リージョン）
#   throttle      : API の呼び出し回数制限
#   not_found     : 対象が存在しない
#   other         : 上記以外
#
# usage: case "$(aws_classify_error "$err")" in access_denied) ... ;; esac
# ---------------------------------------------------------------------------
aws_classify_error() {
  local msg="$1"
  if grep -qiE 'AccessDenied|not authorized to perform|UnauthorizedOperation|is not authorized|explicit deny' <<<"$msg"; then
    printf 'access_denied'
  elif grep -qiE 'Unable to locate credentials|ExpiredToken|token (has|is) expired|session (has )?expired|InvalidClientTokenId|UnrecognizedClient|security token included in the request is (invalid|expired)|aws login|reauthenticate|Unable to load credentials|SignatureDoesNotMatch|Error when retrieving (token|credentials)' <<<"$msg"; then
    printf 'auth'
  elif grep -qiE 'Could not connect to the endpoint|Connect timeout|Read timeout|Connection was closed|Name or service not known|Temporary failure in name resolution|SSL validation failed|ProxyConnectionError|Max retries exceeded|Network is unreachable|EndpointConnectionError|Connection refused' <<<"$msg"; then
    printf 'network'
  elif grep -qiE 'Throttl|Rate exceeded|TooManyRequests' <<<"$msg"; then
    printf 'throttle'
  elif grep -qiE 'ResourceNotFound|does not exist' <<<"$msg"; then
    printf 'not_found'
  else
    printf 'other'
  fi
}

# ---------------------------------------------------------------------------
# AWS CLI のエラー出力からエラーコード（AccessDeniedException 等）を取り出す。
#   取り出せないときは分類名を返す。
# usage: code="$(aws_error_code "$err")"
# ---------------------------------------------------------------------------
aws_error_code() {
  local msg="$1" code
  code="$(sed -n 's/.*An error occurred (\([A-Za-z0-9_.]*\)).*/\1/p' <<<"$msg" | head -n 1)"
  if [[ -z "$code" ]]; then
    code="$(aws_classify_error "$msg")"
  fi
  printf '%s' "$code"
}

# ---------------------------------------------------------------------------
# AWS CLI のエラー出力から、表示用の 1 行（最初の空でない行）を取り出す。
# usage: log_error "詳細: $(aws_error_line "$err")"
# ---------------------------------------------------------------------------
aws_error_line() {
  printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | head -n 1 | cut -c1-400
}
