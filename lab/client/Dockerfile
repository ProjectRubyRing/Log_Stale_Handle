# 検証用クライアント（ECS タスクのフロントコンテナの代わり）
#   UBI 9.8 + Red Hat build of OpenJDK 21 + Log4j2。
#   ユーザーの構成と同じく /webapp/webapp9mf02/logs -> /mnt/logs/front/inter-api/logs のリンクをイメージに焼く。
#   NFS のマウントはコンテナの中で行う（ECS ではホスト側＝Fargate の監督コンテナや ECS エージェントが行い、
#   コンテナにはバインドマウントで見せる。NFS クライアントがカーネルにある点は同じ）。
#   docker build -f lab/client/Dockerfile lab
FROM registry.access.redhat.com/ubi9/ubi:9.8
ARG LOG4J_VERSION=2.26.1
RUN dnf install -y --setopt=install_weak_deps=0 java-21-openjdk-devel procps-ng lsof gzip findutils python3 \
 && dnf clean all && rm -rf /var/cache/dnf
RUN mkdir -p /opt/lab/lib /opt/lab/classes /opt/lab/conf /opt/lab/src \
 && for a in log4j-api log4j-core; do \
      curl -fsSL -o "/opt/lab/lib/${a}-${LOG4J_VERSION}.jar" \
        "https://repo1.maven.org/maven2/org/apache/logging/log4j/${a}/${LOG4J_VERSION}/${a}-${LOG4J_VERSION}.jar"; \
    done
COPY app/StaleLab.java /opt/lab/src/
COPY app/log4j2-shared.xml app/log4j2-pertask.xml /opt/lab/conf/
RUN javac -encoding UTF-8 -cp '/opt/lab/lib/*' -d /opt/lab/classes /opt/lab/src/StaleLab.java
RUN mkdir -p /webapp/webapp9mf02 /mnt/logs \
 && ln -s /mnt/logs/front/inter-api/logs /webapp/webapp9mf02/logs
ENV LOG4J_VERSION=${LOG4J_VERSION}
WORKDIR /opt/lab
CMD ["sleep", "infinity"]
