#!/bin/sh
# 検証用 NFS サーバの起動スクリプト（コンテナの PID 1）
#   /export を NFSv4 の疑似ルート（fsid=0）として公開する。
#     NFSv4.1: <サーバ>:/            → /export
#     NFSv3  : <サーバ>:/export      → /export
#   EXPORT_FSID を変えて再起動すると「サーバ側でエクスポートが付け替わった」状態を作れる（S9）。
set -eu

EXPORT_FSID="${EXPORT_FSID:-0}"
mkdir -p /export
mountpoint -q /proc/fs/nfsd || mount -t nfsd nfsd /proc/fs/nfsd

# fsid=0 は NFSv4 の疑似ルート。v3 で fsid を変える検証のときは v4 用に別の疑似ルートは作らない。
echo "/export *(rw,sync,no_subtree_check,no_root_squash,insecure,fsid=${EXPORT_FSID})" > /etc/exports

# NFSv4 の猶予期間（grace period・既定 90 秒）を 10 秒に縮める。サーバ起動直後は新しい OPEN が
# 待たされるため（検証の時間を読めなくなる）。リース時間も最小の 10 秒にする。nfsd を動かす前に書く。
echo 10 > /proc/fs/nfsd/nfsv4leasetime 2>/dev/null || true
echo 10 > /proc/fs/nfsd/nfsv4gracetime 2>/dev/null || true

rpcbind -w
exportfs -ra
# 8 スレッド。v3 / v4.0 / v4.1 を有効にする
rpc.nfsd -V 3 -V 4 -V 4.1 8
rpc.mountd -V 3
exportfs -v

stop() {
    echo "[nfsd] stopping"
    rpc.nfsd 0 || true
    exportfs -ua || true
    exit 0
}
trap stop TERM INT

echo "[nfsd] READY fsid=${EXPORT_FSID} lease=$(cat /proc/fs/nfsd/nfsv4leasetime 2>/dev/null) grace=$(cat /proc/fs/nfsd/nfsv4gracetime 2>/dev/null)"
# sleep をバックグラウンドにして wait すると TERM をすぐ受け取れる
while :; do
    sleep 3600 &
    wait $! || true
done
