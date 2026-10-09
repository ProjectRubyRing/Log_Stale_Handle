# テスト用: source されるのに exit してしまうシェル（呼び出し元ごと終了する）
export FAKE_AWS_ROLE=ops
echo "[test-switchback] exit.sh: exit します"
exit 0
