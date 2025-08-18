ARG VERSION=latest
ARG TARGETARCH 

# Dockerfile for s6-overlay
FROM alpine:${VERSION} AS rootfs-stage

# Re-declare TARGETARCH in this stage and set as environment variable
ARG TARGETARCH
ENV TARGETARCH=${TARGETARCH}

WORKDIR /downloads
# install packages
RUN \
 apk add --no-cache \
	bash \
	wget \
	ca-certificates \
	xz

COPY install.sh  /downloads

RUN set -ex \
	&& chmod +x install.sh \
	&& bash install.sh

# Runtime stage
ARG VERSION=latest
FROM alpine:${VERSION}
COPY --from=rootfs-stage /downloads/s6-overlay/  /
COPY patch/ /tmp/patch
LABEL maintainer="NG6"

# environment variables
ENV PS1="$(whoami)@$(hostname):$(pwd)\\$ " \
HOME="/root" \
TERM="xterm"

RUN \
 echo "**** install build packages ****" && \
 apk add --no-cache --virtual=build-dependencies \
	patch \
	tar && \
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
 mv /usr/bin/with-contenv /usr/bin/with-contenvb && \
 patch -u /etc/s6/init/init-stage2 -i /tmp/patch/etc/s6/init/init-stage2.patch && \
 echo "**** cleanup ****" && \
 apk del --purge \
	build-dependencies && \
 rm -rf \
	/tmp/*

# add local files
COPY root/ /

ENTRYPOINT ["/init"]