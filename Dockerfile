ARG VERSION=latest
ARG TARGETARCH
ARG TARGETVARIANT
ARG S6_OVERLAY_VERSION=3.2.3.0

# Dockerfile for s6-overlay v3 on the official Alpine image
FROM alpine:${VERSION} AS rootfs-stage

ARG TARGETARCH
ARG TARGETVARIANT
ARG S6_OVERLAY_VERSION
ENV TARGETARCH=${TARGETARCH} \
	TARGETVARIANT=${TARGETVARIANT} \
	S6_OVERLAY_VERSION=${S6_OVERLAY_VERSION}

WORKDIR /downloads

# install packages
RUN \
 apk add --no-cache \
	bash \
	wget \
	ca-certificates \
	tar \
	xz

COPY install.sh /downloads

RUN set -ex \
	&& chmod +x install.sh \
	&& bash install.sh

# Runtime stage
ARG VERSION=latest
FROM alpine:${VERSION}
COPY --from=rootfs-stage /downloads/s6-overlay/ /
LABEL maintainer="NG6"

# environment variables
ENV PS1="$(whoami)@$(hostname):$(pwd)\\$ " \
	HOME="/root" \
	TERM="xterm" \
	S6_CMD_WAIT_FOR_SERVICES_MAXTIME="0" \
	S6_STAGE2_HOOK="/docker-mods" \
	S6_VERBOSITY=1

RUN \
 echo "**** install runtime packages ****" && \
 apk add --no-cache \
	bash \
	curl \
	wget \
	ca-certificates \
	coreutils \
	procps \
	shadow \
	tzdata && \
 echo "**** create abc user and make our folders ****" && \
 groupmod -g 1000 users && \
 useradd -u 911 -U -d /config -s /bin/false abc && \
 usermod -G users abc && \
 mkdir -p \
	/app \
	/config \
	/defaults && \
 echo "**** cleanup ****" && \
 rm -rf \
	/tmp/*

# add local files
COPY root/ /

ENTRYPOINT ["/init"]
