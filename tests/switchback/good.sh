# テスト用: 正常なスイッチバック（偽 aws のロールを ops へ切り替える）
export FAKE_AWS_ROLE=ops
echo "[test-switchback] good: FAKE_AWS_ROLE=ops"
return 0 2>/dev/null || true
