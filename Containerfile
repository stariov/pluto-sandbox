FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git \
	python3 jq bind9-dnsutils unzip zip less procps file \
	&& rm -rf /var/lib/apt/lists/*

ARG HOST_UID
ARG HOST_GID
RUN groupadd -g "${HOST_GID}" pluto && \
	useradd -m -k /dev/null -s /bin/bash -u ${HOST_UID} -g ${HOST_GID} pluto

USER pluto
ENV HOME=/home/pluto
WORKDIR /home/pluto