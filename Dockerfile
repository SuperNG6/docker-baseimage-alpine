ARG VERSION=latest
ARG TARGETARCH
ARG TARGETVARIANT
ARG S6_OVERLAY_VERSION=3.2.3.2

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
	S6_CMD_ARG0="/command/with-contenv" \
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
 echo "**** link s6 tools into /bin for s6-overlay v2 style absolute paths ****" && \
 for tool in /command/*; do \
	[ -e "/bin/${tool##*/}" ] || [ -L "/bin/${tool##*/}" ] || ln -s "${tool}" "/bin/${tool##*/}"; \
 done && \
 echo "**** cleanup ****" && \
 rm -rf \
	/tmp/*

# Register the compatibility oneshot before overlay processes legacy scripts.
# Leave the upstream stage-2 hook available to downstream images.
RUN set -eu; \
    sources=/package/admin/s6-overlay/etc/s6-rc/sources; \
    test -f "$sources/fix-attrs/type"; \
    mkdir -p "$sources/fix-attrs/dependencies.d" "$sources/base-legacy-compat"; \
    touch "$sources/fix-attrs/dependencies.d/base-legacy-compat"; \
    echo oneshot > "$sources/base-legacy-compat/type"; \
    echo /usr/libexec/superng6/legacy-compat > "$sources/base-legacy-compat/up"; \
    mkdir -p /usr/libexec/superng6/compat-bin /etc/s6-overlay/scripts; \
    ln -s /usr/libexec/superng6/legacy-compat /etc/s6-overlay/scripts/legacy-compat; \
    ln -s /usr/bin/with-contenv /usr/libexec/superng6/compat-bin/with-contenv; \
    mv /init /usr/libexec/superng6/overlay-init

COPY root/ /

ENTRYPOINT ["/init"]
