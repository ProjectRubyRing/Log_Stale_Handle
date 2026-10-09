#!/usr/bin/env bash
#
# run_tests.sh — tools/ と impl/ のテスト（AWS なし。偽 aws コマンドで実行する）
#
# RHEL 9.8 相当の UBI9 コンテナで実行する（Windows の Git Bash から）:
#   MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -m "$PWD"):/work:ro" \
#     registry.access.redhat.com/ubi9/ubi:9.8 bash /work/tests/run_tests.sh /work
#
# 対象
#   efs-log-housekeeping.sh … 判定（残す／消す）、dry-run、削除、認証・権限・スイッチバック、引数
#   estale-diag.sh          … NFS が無い環境での動作と引数の検証（NFS 上の判定は lab/run_lab.sh で確認）
#   app-log-dir.sh          … タスクごとのディレクトリ・.owner・リンク・再利用・メタデータ無し
set -uo pipefail

SRC="${1:-/work}"
WORK="${TMPDIR:-/tmp}/elh_test"
rm -rf "$WORK"
mkdir -p "$WORK/logs" "$WORK/cwd"
cp -r "$SRC" "$WORK/proj"
chmod +x "$WORK/proj/tests/fake_aws/aws" "$WORK/proj/tools/"*.sh

export FAKE_AWS_DIR="$WORK/fake"
export PATH="$WORK/proj/tests/fake_aws:$PATH"
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION FAKE_AWS_ROLE SWITCH_BACK_SCRIPT

HK="$WORK/proj/tools/efs-log-housekeeping.sh"
DIAG="$WORK/proj/tools/estale-diag.sh"
ALD="$WORK/proj/impl/app-log-dir.sh"
SB="$WORK/proj/tests/switchback"
PASS=0
FAIL=0

result() {
  if [[ "$1" == "ok" ]]; then
    PASS=$((PASS + 1)); printf 'PASS  %-36s %s\n' "$2" "$3"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-36s %s\n' "$2" "$3"
    if [[ -n "${4:-}" && -f "$4" ]]; then sed 's/^/      | /' "$4" | tail -25; fi
  fi
}

# run_case <名前> <期待する終了コード> <ログに含まれるべき正規表現（空なら確認しない）> <コマンド...>
run_case() {
  local name="$1" want="$2" pat="$3" log="$WORK/logs/$1.log" rc
  shift 3
  (cd "$WORK/cwd" && "$@") >"$log" 2>&1 </dev/null
  rc=$?
  if [[ "$rc" != "$want" ]]; then
    result ng "$name" "rc=$rc（期待 $want）" "$log"
  elif [[ -n "$pat" ]] && ! grep -qE -- "$pat" "$log"; then
    result ng "$name" "rc=$rc ログに /$pat/ が無い" "$log"
  else
    result ok "$name" "rc=$rc"
  fi
}

assert() {
  local name="$1" log="$WORK/logs/assert_$1.log"
  shift
  if "$@" >"$log" 2>&1; then result ok "$name" ""; else result ng "$name" "" "$log"; fi
}

echo "===== 環境 ====="
cat /etc/redhat-release 2>/dev/null
bash --version | head -n 1
echo

# ---------------------------------------------------------------------------
# 片付けの対象ツリー
# ---------------------------------------------------------------------------
RUN1=0123456789abcdef0123456789abcdef      # RUNNING
RUN2=11111111111111111111111111111111      # RUNNING（.owner で持ち主を示す）
DRAIN=22222222222222222222222222222222     # desired=STOPPED（停止処理中・停止直後）
OLD=33333333333333333333333333333333       # 停止済み・100 日前 → 消す
NEW=44444444444444444444444444444444       # 停止済み・10 日前  → 保存期間内
NFS=55555555555555555555555555555555       # 停止済み・古いが .nfs あり → 残す
HOT=66666666666666666666666666666666       # 停止済み・古いが 1 時間前に更新したファイルあり → 残す
LNK=77777777777777777777777777777777       # 停止済み・古いが current2 が指す → 残す
ARN="arn:aws:ecs:ap-northeast-1:123456789012:task/prod"

make_tree() {
  local b="$WORK/efs/mid"
  rm -rf "$WORK/efs"
  mkdir -p "$b"
  mk() { mkdir -p "$b/$1"; echo log > "$b/$1/server.log"; touch -d "$2" "$b/$1/server.log" "$b/$1"; }
  mk "$RUN1" "100 days ago"
  mk 20260101000000-abcd1234 "100 days ago"
  printf 'TaskARN=%s/%s\nContainer=interapi-front\n' "$ARN" "$RUN2" > "$b/20260101000000-abcd1234/.owner"
  touch -d "100 days ago" "$b/20260101000000-abcd1234/.owner" "$b/20260101000000-abcd1234"
  mk "$DRAIN" "100 days ago"
  mk "$OLD" "100 days ago"
  mk "$NEW" "10 days ago"
  mk "$NFS" "100 days ago"; echo x > "$b/$NFS/.nfs0000000000abcdef00000001"; touch -d "100 days ago" "$b/$NFS/.nfs0000000000abcdef00000001" "$b/$NFS"
  mk "$HOT" "100 days ago"; echo x > "$b/$HOT/app.log"; touch -d "1 hour ago" "$b/$HOT/app.log"
  mk "$LNK" "100 days ago"; ln -s "$LNK" "$b/current2"
  mk 20250101000000-zzzz0000 "200 days ago"          # 持ち主不明・200 日 → 消す
  mk 20260801000000-yyyy1111 "60 days ago"           # 持ち主不明・60 日  → 残す（不明は 90 日）
  mk 20260102000000-unkn0001 "60 days ago"            # .owner の TaskARN=unknown → 不明扱い（90 日）→ 残す
  printf 'TaskARN=unknown\n' > "$b/20260102000000-unkn0001/.owner"
  touch -d "60 days ago" "$b/20260102000000-unkn0001/.owner" "$b/20260102000000-unkn0001"
  ln -s 20260801000000-yyyy1111 "$b/current"
  mkdir -p "$FAKE_AWS_DIR/tasks"
  printf '%s/%s\n%s/%s\n' "$ARN" "$RUN1" "$ARN" "$RUN2" > "$FAKE_AWS_DIR/tasks/prod_RUNNING.txt"
  printf '%s/%s\n' "$ARN" "$DRAIN" > "$FAKE_AWS_DIR/tasks/prod_STOPPED.txt"
  : > "$FAKE_AWS_DIR/tasks/empty_RUNNING.txt"
}

HK_ARGS=(-c prod -b "$WORK/efs/mid")

echo "===== efs-log-housekeeping.sh: 引数 ====="
make_tree
run_case hk_help             0 "使い方"                     bash "$HK" --help
run_case hk_no_base          2 "-b/--base"                  bash "$HK" -c prod
run_case hk_no_cluster       2 "-c/--cluster"               bash "$HK" -b "$WORK/efs/mid"
run_case hk_bad_days         2 "整数"                       bash "$HK" "${HK_ARGS[@]}" -k abc
run_case hk_unknown_lt_keep  2 "unknown-keep-days"          bash "$HK" "${HK_ARGS[@]}" -k 30 --unknown-keep-days 10
run_case hk_no_dir           2 "親ディレクトリがありません" bash "$HK" -c prod -b "$WORK/nope"

echo "===== efs-log-housekeeping.sh: 判定（dry-run） ====="
make_tree
run_case hk_dryrun 0 "判定: 残す 9 / 消す 2" bash "$HK" "${HK_ARGS[@]}" -N --report "$WORK/report.tsv"
L="$WORK/logs/hk_dryrun.log"
assert dry_keep_running   grep -qE "KEEP .*/$RUN1 .*使用中のタスク（prod/RUNNING）" "$L"
assert dry_keep_owner     grep -qE "KEEP .*/20260101000000-abcd1234 .*owner=$RUN2 .*使用中" "$L"
assert dry_keep_draining  grep -qE "KEEP .*/$DRAIN .*prod/STOPPED" "$L"
assert dry_delete_old     grep -qE "DELETE .*/$OLD .*停止済みタスク・30 日超" "$L"
assert dry_keep_new       grep -qE "KEEP .*/$NEW .*保存期間内" "$L"
assert dry_keep_nfs       grep -qE "KEEP .*/$NFS .*\.nfs ファイルあり" "$L"
assert dry_keep_hot       grep -qE "KEEP .*/$HOT .*24 時間以内に更新あり" "$L"
assert dry_keep_linked    grep -qE "KEEP .*/$LNK .*シンボリックリンクが指している" "$L"
assert dry_delete_unknown grep -qE "DELETE .*/20250101000000-zzzz0000 .*持ち主不明・90 日超" "$L"
assert dry_keep_unknown60 grep -qE "KEEP .*/20260801000000-yyyy1111 .*シンボリックリンクが指している|KEEP .*/20260801000000-yyyy1111 .*保存期間内" "$L"
assert dry_unknown_owner  grep -qE "KEEP .*/20260102000000-unkn0001 .*owner=- .*保存期間内" "$L"
assert dry_nothing_gone   test -d "$WORK/efs/mid/$OLD" -a -d "$WORK/efs/mid/20250101000000-zzzz0000"
assert dry_report_tsv     bash -c "head -1 '$WORK/report.tsv' | grep -q '判定' && [ \$(wc -l < '$WORK/report.tsv') -eq 12 ]"

echo "===== efs-log-housekeeping.sh: 削除（-y） ====="
make_tree
run_case hk_delete 0 "完了" bash "$HK" "${HK_ARGS[@]}" -y
assert del_old_gone       test ! -e "$WORK/efs/mid/$OLD"
assert del_unknown_gone   test ! -e "$WORK/efs/mid/20250101000000-zzzz0000"
assert del_running_stays  test -d "$WORK/efs/mid/$RUN1" -a -d "$WORK/efs/mid/20260101000000-abcd1234" -a -d "$WORK/efs/mid/$DRAIN"
assert del_others_stay    test -d "$WORK/efs/mid/$NEW" -a -d "$WORK/efs/mid/$NFS" -a -d "$WORK/efs/mid/$HOT" -a -d "$WORK/efs/mid/$LNK"
assert del_links_stay     test -L "$WORK/efs/mid/current" -a -L "$WORK/efs/mid/current2"
make_tree
run_case hk_no_tty_no_yes 0 "端末が無いため確認できません|中止しました" bash "$HK" "${HK_ARGS[@]}"
assert notty_nothing_gone test -d "$WORK/efs/mid/$OLD"

echo "===== efs-log-housekeeping.sh: 安全装置 ====="
make_tree
run_case hk_no_running   4 "RUNNING のタスクが 0 件"    bash "$HK" -c empty -b "$WORK/efs/mid" -N
run_case hk_allow_empty  0 "判定:"                      bash "$HK" -c empty -b "$WORK/efs/mid" -N --allow-no-running
assert empty_keeps_hot   grep -qE "KEEP .*/$HOT .*24 時間以内" "$WORK/logs/hk_allow_empty.log"
run_case hk_bad_cluster  4 "ClusterNotFound|クラスター名" bash "$HK" -c nosuch -b "$WORK/efs/mid" -N

echo "===== efs-log-housekeeping.sh: 認証・権限・スイッチバック ====="
make_tree
run_case hk_noauth       10 "aws login --remote"        env FAKE_AWS_ROLE=none bash "$HK" "${HK_ARGS[@]}" -N
run_case hk_netdown      10 "接続できません"            env FAKE_AWS_ROLE=netdown bash "$HK" "${HK_ARGS[@]}" -N
run_case hk_noperm       11 "スイッチバックしてから"    env FAKE_AWS_ROLE=codecommit bash "$HK" "${HK_ARGS[@]}" -N
run_case hk_sb_noscript  12 "場所の指定が必要"          env FAKE_AWS_ROLE=codecommit bash "$HK" "${HK_ARGS[@]}" -N -A
run_case hk_sb_good       0 "スイッチバックしました"    env FAKE_AWS_ROLE=codecommit bash "$HK" "${HK_ARGS[@]}" -N -A -S "$SB/good.sh"
run_case hk_sb_env        0 "スイッチバックしました"    env FAKE_AWS_ROLE=codecommit SWITCH_BACK_SCRIPT="$SB/good.sh" bash "$HK" "${HK_ARGS[@]}" -N -A
run_case hk_sb_nasty      0 "判定: 残す 9 / 消す 2"    env FAKE_AWS_ROLE=codecommit bash "$HK" "${HK_ARGS[@]}" -N -A -S "$SB/nasty.sh"
assert nasty_no_cleanup  bash -c "! grep -q 'nasty cleanup' '$WORK/logs/hk_sb_nasty.log'"
run_case hk_sb_exit      12 "exit ではなく return"      env FAKE_AWS_ROLE=codecommit bash "$HK" "${HK_ARGS[@]}" -N -A -S "$SB/exit.sh"

echo "===== estale-diag.sh（NFS なし） ====="
run_case diag_help     0 "オプション"                    bash "$DIAG" -h
run_case diag_badpid   3 "数字で指定"                    bash "$DIAG" -p abc
run_case diag_badarg   3 "不明な引数"                    bash "$DIAG" --nope
run_case diag_no_nfs   0 "NFS マウントが見つからない"    bash "$DIAG"
run_case diag_not_nfs  1 "NFS マウントとして見つからない" bash "$DIAG" -m /tmp

echo "===== app-log-dir.sh ====="
ALD_ROOT="$WORK/ald"
rm -rf "$ALD_ROOT"; mkdir -p "$ALD_ROOT/efs/logs/svc" "$ALD_ROOT/tmp"
# メタデータエンドポイントの代わり
mkdir -p "$ALD_ROOT/meta"
printf '{"Cluster":"prod","TaskARN":"%s/%s","Family":"interapi"}' "$ARN" "$RUN1" > "$ALD_ROOT/meta/task"
(cd "$ALD_ROOT/meta" && exec python3 -m http.server 18080 --bind 127.0.0.1 >/dev/null 2>&1) &
HTTP_PID=$!
for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:18080/task && break; sleep 0.2; done
ALD_ENV=(EFS_LOG_DIR="$ALD_ROOT/efs/logs/svc" APP_LOG_LINK_TARGET="$ALD_ROOT/tmp/app-log-target" Component_name=interapi-front)
run_case ald_taskid 0 "app logs -> .*/app/$RUN1" env "${ALD_ENV[@]}" LOG_ID_MODE=taskid \
  ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:18080 sh -c ". '$ALD'; setup_app_log_dir && echo \"ID=\$APP_LOG_ID DIR=\$APP_LOG_DIR\""
assert ald_dir_made     test -d "$ALD_ROOT/efs/logs/svc/app/$RUN1"
assert ald_owner        grep -q "^TaskARN=$ARN/$RUN1$" "$ALD_ROOT/efs/logs/svc/app/$RUN1/.owner"
assert ald_link         test "$(readlink "$ALD_ROOT/tmp/app-log-target")" = "$ALD_ROOT/efs/logs/svc/app/$RUN1"
echo keep > "$ALD_ROOT/efs/logs/svc/app/$RUN1/app.log"
run_case ald_reuse  0 "app logs -> .*/app/$RUN1" env "${ALD_ENV[@]}" LOG_ID_MODE=taskid \
  ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:18080 sh -c ". '$ALD'; setup_app_log_dir"
assert ald_reuse_kept   grep -q keep "$ALD_ROOT/efs/logs/svc/app/$RUN1/app.log"
run_case ald_logid  0 "app logs -> .*/app/20261009120000-abcdefgh" env "${ALD_ENV[@]}" LOG_ID=20261009120000-abcdefgh \
  ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:18080 sh -c ". '$ALD'; setup_app_log_dir"
assert ald_link_moved   test "$(readlink "$ALD_ROOT/tmp/app-log-target")" = "$ALD_ROOT/efs/logs/svc/app/20261009120000-abcdefgh"
assert ald_link_not_nested test ! -e "$ALD_ROOT/efs/logs/svc/app/$RUN1/app-log-target"
run_case ald_nometa 0 "app logs -> .*/app/[0-9]{14}-[a-z0-9]{8}" env "${ALD_ENV[@]}" sh -c ". '$ALD'; setup_app_log_dir"
assert ald_unknown_owner bash -c "grep -l '^TaskARN=unknown$' '$ALD_ROOT'/efs/logs/svc/app/*/.owner | grep -q ."
run_case ald_no_efs 1 "EFS_LOG_DIR が未設定"         sh -c ". '$ALD'; setup_app_log_dir"
run_case ald_no_tmp 1 "書き込み可能ボリューム"       env EFS_LOG_DIR="$ALD_ROOT/efs/logs/svc" APP_LOG_LINK_TARGET="$ALD_ROOT/none/app-log-target" \
  sh -c ". '$ALD'; setup_app_log_dir"
kill "$HTTP_PID" 2>/dev/null || true

echo
echo "===== 結果: PASS=${PASS} FAIL=${FAIL} ====="
[[ "$FAIL" -eq 0 ]]
