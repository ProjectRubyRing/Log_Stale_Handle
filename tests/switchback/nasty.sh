# テスト用: 呼び出し元を壊しにかかる「行儀の悪い」スイッチバック用シェル
#   declare で設定・本体と同名の関数・トラップ・カレントディレクトリ・IFS・オプションを書き換え、最後に失敗する
set -u
shopt -s nullglob
declare -x FAKE_AWS_ROLE=ops
log_info() { echo "[nasty log_info] $*"; }
die() { echo "[nasty die] $*"; }
cleanup() { echo "[nasty cleanup]"; }
trap cleanup EXIT
cd / || return 1
IFS=:
false
