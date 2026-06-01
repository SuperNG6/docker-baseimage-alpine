#!/usr/bin/env bash
set -euo pipefail

container="${1:?container name is required}"
image="${2:?image name is required}"
rpc_url="${3:-http://127.0.0.1:16800/jsonrpc}"
web_url="${4:-http://127.0.0.1:18080/}"
secret="${5:-smoketoken}"

wait_for_container() {
    local last_error="container is not running"
    for i in {1..30}; do
        if docker ps --filter "name=${container}" --filter "status=running" --format '{{.Names}}' |
            grep -qx "${container}"; then
            return 0
        fi
        last_error="$(docker ps -a --filter "name=${container}" --format '{{.Status}}' || true)"
        if [ $((i % 5)) -eq 0 ]; then
            echo "Waiting for ${container} to run (${i}/30): ${last_error:-not created}"
            docker logs --tail 80 "${container}" || true
        fi
        sleep 1
    done
    echo "container did not reach running state: ${last_error}" >&2
    docker logs "${container}" || true
    return 1
}

legacy_service_dir() {
    local service="$1"
    docker exec "${container}" sh -c '
        service="$1"
        for dir in "/run/service/${service}" "/run/s6/legacy-services/${service}"; do
            if [ -d "${dir}" ]; then
                echo "${dir}"
                exit 0
            fi
        done
        exit 1
    ' sh "${service}"
}

wait_for_legacy_service_up() {
    local service="$1"
    local service_dir=""
    local last_error="s6 has not exposed ${service} yet"
    local service_err="/tmp/docker-aria2-${service}-service.err"
    local svwait_err="/tmp/docker-aria2-${service}-svwait.err"

    for i in {1..30}; do
        service_dir="$(legacy_service_dir "${service}" 2>"${service_err}" || true)"
        if [ -n "${service_dir}" ] &&
            docker exec "${container}" s6-svwait -u -t 1000 "${service_dir}" >/dev/null 2>"${svwait_err}"; then
            echo "${service_dir}"
            return 0
        fi

        if [ -n "${service_dir}" ]; then
            last_error="$(docker exec "${container}" s6-svstat "${service_dir}" 2>&1 || true)"
        else
            last_error="$(cat "${service_err}" 2>/dev/null || echo waiting)"
        fi

        if [ $((i % 5)) -eq 0 ]; then
            echo "Waiting for s6 legacy service ${service} (${i}/30): ${last_error}" >&2
            docker logs --tail 80 "${container}" >&2 || true
        fi
        sleep 1
    done

    echo "s6 legacy service ${service} did not become up: ${last_error}" >&2
    docker logs "${container}" || true
    return 1
}

rpc() {
    local token="$1"
    curl -sS --max-time 3 "${rpc_url}" \
        -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":\"smoke\",\"method\":\"aria2.getVersion\",\"params\":[\"token:${token}\"]}"
}

wait_for_rpc_ready() {
    local last_error="RPC has not been probed yet"
    for i in {1..30}; do
        response="$(rpc "${secret}" 2>/tmp/docker-aria2-rpc-curl.err || true)"
        if printf '%s' "${response}" | jq -e '.result.version' >/dev/null 2>/tmp/docker-aria2-rpc-json.err; then
            return 0
        fi
        curl_error="$(cat /tmp/docker-aria2-rpc-curl.err 2>/dev/null || true)"
        json_error="$(cat /tmp/docker-aria2-rpc-json.err 2>/dev/null || true)"
        last_error="${curl_error:-${json_error:-empty response}}"
        if [ $((i % 5)) -eq 0 ]; then
            echo "Waiting for aria2 JSON-RPC (${i}/30): ${last_error}"
            docker logs --tail 80 "${container}" || true
        fi
        sleep 1
    done
    echo "aria2 JSON-RPC did not become ready: ${last_error}" >&2
    docker logs "${container}" || true
    return 1
}

assert_container_environment() {
    echo "Checking base cont-init environment and docker-aria2 config side effects ..."
    test "$(docker exec "${container}" id -u abc)" = "1001"
    test "$(docker exec "${container}" id -g abc)" = "1001"
    test "$(docker exec "${container}" cat /run/s6/container_environment/PUID)" = "1001"
    test "$(docker exec "${container}" cat /run/s6/container_environment/PGID)" = "1001"
    test "$(docker exec "${container}" cat /run/s6/container_environment/SECRET)" = "${secret}"
    test "$(docker exec "${container}" cat /run/s6/container_environment/PORT)" = "6800"
    test "$(docker exec "${container}" cat /run/s6/container_environment/WEBUI)" = "true"
    test "$(docker exec "${container}" cat /run/s6/container_environment/WEBUI_PORT)" = "8080"

    test "$(docker exec "${container}" stat -c '%u:%g' /config)" = "1001:1001"
    test "$(docker exec "${container}" stat -c '%u:%g' /downloads)" = "1001:1001"
    test "$(docker exec "${container}" stat -c '%u:%g' /www)" = "1001:1001"

    docker exec "${container}" test -f /config/aria2.conf
    docker exec "${container}" test -f /config/aria2.session
    docker exec "${container}" test -f /config/dht.dat
    docker exec "${container}" test -f /config/logs/move.log
    docker exec "${container}" grep -qx 'rpc-listen-port=6800' /config/aria2.conf
    docker exec "${container}" grep -qx 'dht-listen-port=32516' /config/aria2.conf
    docker exec "${container}" grep -qx 'listen-port=32516' /config/aria2.conf
    docker exec "${container}" grep -qx 'on-download-complete=/aria2/scripts/completed.sh' /config/aria2.conf
}

assert_process_state() {
    local service_dir="$1"
    echo "Checking s6-supervised aria2 process state ..."
    docker exec "${container}" s6-svstat "${service_dir}" | grep -q '^up'

    pid="$(docker exec "${container}" pidof aria2c)"
    test -n "${pid}"
    proc_uid="$(docker exec "${container}" sh -c 'awk "/^Uid:/ {print \$2}" "/proc/$1/status"' sh "${pid}")"
    proc_gid="$(docker exec "${container}" sh -c 'awk "/^Gid:/ {print \$2}" "/proc/$1/status"' sh "${pid}")"
    test "${proc_uid}" = "1001"
    test "${proc_gid}" = "1001"

    docker exec "${container}" pgrep -x darkhttpd >/dev/null
    docker exec "${container}" pgrep -x crond >/dev/null
}

assert_rpc_and_webui() {
    echo "Checking application readiness after s6 marks aria2 up ..."
    wait_for_rpc_ready
    wrong_response="$(rpc "not-${secret}" || true)"
    printf '%s' "${wrong_response}" | jq -e '.error' >/dev/null
    curl -fsS --max-time 3 "${web_url}" >/dev/null
}

assert_supervision_restart() {
    local service_dir="$1"
    echo "Checking s6 restarts aria2 legacy service after process death ..."
    old_pid="$(docker exec "${container}" pidof aria2c)"
    test -n "${old_pid}"
    docker exec "${container}" kill -TERM "${old_pid}"

    for i in {1..30}; do
        docker exec "${container}" s6-svwait -u -t 1000 "${service_dir}" >/dev/null 2>/tmp/docker-aria2-restart-svwait.err || true
        new_pid="$(docker exec "${container}" pidof aria2c 2>/dev/null || true)"
        if [ -n "${new_pid}" ] && [ "${new_pid}" != "${old_pid}" ]; then
            wait_for_rpc_ready
            return 0
        fi
        if [ $((i % 5)) -eq 0 ]; then
            echo "Waiting for aria2 restart (${i}/30): old=${old_pid} new=${new_pid:-none}"
            docker exec "${container}" s6-svstat "${service_dir}" || true
        fi
        sleep 1
    done

    echo "aria2 was not restarted by s6 supervision" >&2
    docker exec "${container}" s6-svstat "${service_dir}" || true
    docker logs "${container}" || true
    return 1
}

assert_default_secret_warning_is_colored() {
    local warning_container="${container}-default-secret"
    echo "Checking docker-aria2 default SECRET warning keeps ANSI colors under s6 v3 ..."
    docker rm -f "${warning_container}" >/dev/null 2>&1 || true
    docker run -d \
        --name "${warning_container}" \
        -e UT=false \
        -e RUT=false \
        -e WEBUI=false \
        -e PORT=6800 \
        -e WEBUI_PORT=8080 \
        "${image}" >/dev/null

    for i in {1..30}; do
        docker logs "${warning_container}" > /tmp/docker-aria2-default-secret.log 2>&1 || true
        if grep -q 'SECRET=yourtoken' /tmp/docker-aria2-default-secret.log &&
            grep -q $'\033\\[1;31m' /tmp/docker-aria2-default-secret.log &&
            grep -q $'\033\\[1;33m' /tmp/docker-aria2-default-secret.log; then
            docker rm -f "${warning_container}" >/dev/null
            return 0
        fi
        sleep 1
        if [ $((i % 5)) -eq 0 ]; then
            echo "Waiting for colored default SECRET warning (${i}/30)"
            cat /tmp/docker-aria2-default-secret.log
        fi
    done

    echo "default SECRET warning did not include expected ANSI colors" >&2
    cat /tmp/docker-aria2-default-secret.log >&2
    docker rm -f "${warning_container}" >/dev/null 2>&1 || true
    return 1
}

wait_for_container
aria2_service_dir="$(wait_for_legacy_service_up aria2)"
assert_container_environment
assert_process_state "${aria2_service_dir}"
assert_rpc_and_webui
assert_supervision_restart "${aria2_service_dir}"
assert_default_secret_warning_is_colored

echo "docker-aria2 s6 v2-style startup is compatible with the s6 v3 base."
