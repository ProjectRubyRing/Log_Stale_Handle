# 検証用 NFS サーバ（Linux カーネル NFS サーバ = knfsd）
#   EFS の代わりに使う。EFS と同じく NFSv4.1 で公開し、比較用に NFSv3 も公開する。
#   docker run --privileged が必要（コンテナのネットワーク名前空間の中で knfsd を動かすため）。
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends nfs-kernel-server procps \
 && rm -rf /var/lib/apt/lists/*
COPY nfsd-entry.sh /usr/local/bin/nfsd-entry.sh
RUN sed -i 's/\r$//' /usr/local/bin/nfsd-entry.sh && chmod 755 /usr/local/bin/nfsd-entry.sh
ENTRYPOINT ["/usr/local/bin/nfsd-entry.sh"]
