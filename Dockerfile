FROM ubuntu

ARG AS_VERSION=latest
ARG DEBIAN_FRONTEND=noninteractive

EXPOSE 8089 8080 8081 8082 8090 8091 8888

COPY thirdparty/mc-RELEASE.2021-06-08T01-29-37Z  /mc
COPY thirdparty/mysql-connector-java-8.0.25.jar  /mysql-connector-java.jar
COPY entrypoint.sh                               /entrypoint.sh
COPY restore.sh                                  /restore.sh
COPY backup.sh                                   /backup.sh

RUN apt-get update && \
    apt-get install -y openjdk-8-jre wget curl unzip lsb-release gnupg sudo sendmail && \
    wget https://dev.mysql.com/get/mysql-apt-config_0.8.12-1_all.deb && \
    DEBIAN_FRONTEND=noninteractive dpkg -i mysql-apt-config_0.8.12-1_all.deb && \
    apt-get update && \
    apt-get install -y mysql-client && \
    useradd -m -d /home/archivesspace archivesspace && \
    usermod -aG sudo archivesspace && \
    echo 'archivesspace ALL=(root) NOPASSWD: /etc/init.d/sendmail start' >> /etc/sudoers && \
    chown -R archivesspace:archivesspace /home/archivesspace && \
    chown archivesspace:archivesspace /entrypoint.sh && \
    chown archivesspace:archivesspace /restore.sh && \
    chown archivesspace:archivesspace /backup.sh && \
    chmod +x /entrypoint.sh && \
    chmod +x /restore.sh && \
    chmod +x /backup.sh && \
    rm -f /etc/localtime && \
    ln -s /usr/share/zoneinfo/Etc/UTC /etc/localtime

WORKDIR /home/archivesspace

USER archivesspace

RUN echo "Download version: ${AS_VERSION}" && \
    if [ "${AS_VERSION}" != "latest" ]; then AS_VERSION="tags/$AS_VERSION"; fi && \
    API_RESP=`curl --silent "https://api.github.com/repos/archivesspace/archivesspace/releases/${AS_VERSION}"` && \
    echo "${API_RESP}" && \
    echo "${API_RESP}" | grep "browser_download_url" | cut -d: -f2- | xargs wget -nv && \
    if [ -f archivesspace*.zip ]; then unzip archivesspace*.zip > /dev/null 2>&1; rm archivesspace*.zip; fi

RUN mv /mysql-connector-java.jar /home/archivesspace/archivesspace/lib && \
    cd ~

RUN mkdir minio && \
    mv /mc /home/archivesspace/minio/ && \
    chmod +x /home/archivesspace/minio/mc

ENV PATH="/home/archivesspace/minio:${PATH}"

HEALTHCHECK --interval=1m --timeout=30s --start-period=15m --retries=5 \
        CMD curl -f http://localhost:8089/ || exit 1

ENTRYPOINT /entrypoint.sh
