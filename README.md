# Log_Stale_Handle — ECS × EFS × Log4j2「Stale file handle」の解説・検証・道具

ECS タスクのフロント／バックコンテナ（UBI 9.8・OpenJDK 21・JBoss EAP 8.1）が、シンボリックリンク
（`/webapp/webapp9mf02/logs → /mnt/logs/front/inter-api/logs`）経由で EFS にログを書いていて、
Log4j2 が `java.io.IOException: Stale file handle` を出した件の調査一式。

## 成果物

| ファイル | 内容 |
|---|---|
| `ECS_EFS_StaleFileHandle_完全解説.xlsx` | 解説（Meiryo UI・モノトーン、16 シート＋表紙） |
| `ECS_EFS_StaleFileHandle_完全解説.md` | 同じ本文の Markdown 版 |
| `tools/estale-diag.sh` | コンテナの中で Stale の状態を調べる（根元・リンク・Java の FD・.nfs・再接続） |
| `tools/efs-log-housekeeping.sh` | EFS 上のタスクごとのログディレクトリを「止まったタスクのものだけ」片付ける |
| `impl/` | 恒久対策の部品（アプリログのタスク別ディレクトリ化、Log4j2 設定例、Terraform のアラーム） |
| `lab/` | Docker で NFS サーバ＋クライアント 2 台を立てて再現する検証（結果は `lab/results/`） |
| `tests/` | ツールのテスト（偽の aws コマンド）と Excel の実機確認スクリプト |

## 結論（要約）

- **Stale file handle は「握っているファイルの引換券の品物が、EFS の上でもう無い」**。別のタスク・ホスト・作業者がファイルやディレクトリを消した・作り直したときに出る。
- **仮説「デプロイ後に EFS のマウントを外して付け直した」はそのままでは成り立たない**。ECS は動いているタスクのボリュームを付け外ししないし、付け直しても Stale にならない（検証 S5）。
- **いちばん可能性が高いのは、複数タスクが同じログファイルに書き、Log4j2 のロールオーバ（改名→gz 圧縮→削除）が他タスクのファイルを消すこと**（検証 S6 で同じ例外を再現）。
- **根本対策は「1 ファイル 1 書き手」**。アプリログのリンク先をタスクごとのディレクトリにする（検証 S7 で Stale 0・欠損 0）。片付けは止まったタスクのものだけ。

## 作り直し・再実行

```bash
# 資料（Excel と Markdown）を作る（本文は build/content.py の 1 か所）
python -X utf8 build/build_docs.py

# 再現実験（約 12 分。Docker の --privileged が必要。指定したケースだけ流すこともできる）
bash lab/run_lab.sh            # 全ケース
bash lab/run_lab.sh S6 S7      # 指定ケースだけ（ほかの結果は残る）

# ツールのテスト（UBI 9.8 コンテナ）
MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -m "$PWD"):/work:ro" \
  registry.access.redhat.com/ubi9/ubi:9.8 bash /work/tests/run_tests.sh /work

# shellcheck
MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -m "$PWD"):/w" -w /w koalaman/shellcheck:stable \
  -x tools/estale-diag.sh tools/efs-log-housekeeping.sh impl/app-log-dir.sh lab/run_lab.sh lab/server/nfsd-entry.sh

# Excel を実物の Excel（COM）で開いて確認し、PDF と画面の画像を作る（Windows）
powershell -NoProfile -ExecutionPolicy Bypass -File tests/tools/verify_excel_com.ps1 \
  -Path ECS_EFS_StaleFileHandle_完全解説.xlsx -OutDir tests/out -Capture "00_表紙,05_動作イメージ"
```

## 注意

- 検証のサーバは Linux の knfsd で、EFS そのものではない。knfsd（NFSv4.1）は開いているファイルを消されても実体を残すのでエラーにならない（行は消える）が、EFS と NFSv3 は Stale を返す。詳しくは解説の 04・14 章。
- AWS 公式によると、`readonlyRootFilesystem=true` のコンテナでは ECS Exec が非対応。入れない場合の調べ方は解説の 07-3。
- 以前の資料 `Log4j_EFS_Rolling/Log4j2_EFS_ローリングアップデート_FD競合_完全解説.md` の 5.5（別タスクの削除で .nfs になる）は誤り。別タスク（別の NFS クライアント）が消した場合は .nfs にならず、相手は Stale になる（解説 01 章で訂正）。
