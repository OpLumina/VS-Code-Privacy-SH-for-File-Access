FROM codercom/code-server:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      inotify-tools \
      diffutils \
      rsync \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/vsmask-entrypoint
RUN chmod +x /usr/local/bin/vsmask-entrypoint

USER coder

EXPOSE 8080

VOLUME ["/persist"]

ENTRYPOINT ["/usr/local/bin/vsmask-entrypoint"]
