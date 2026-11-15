#!/usr/bin/env bash
# Base image contract test.
#
# Builds a small s6-overlay v2 style downstream image (0644 legacy scripts,
# /etc/services.d, /etc/cont-finish.d, FILE__ secrets, UMASK, CMD) on top of
# the given base image and asserts the behaviour downstream images rely on.
#
# usage: test-base-contract.sh <base-image>
set -euo pipefail

base="${1:?base image is required}"
tag="local/base-contract-fixture:test"
container="base-contract-$$"
work="$(mktemp -d)"
failures=0

cleanup() {
    docker rm -f "${container}" >/dev/null 2>&1 || true
    rm -rf "${work}"
}
trap cleanup EXIT

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "${expected}" = "${actual}" ]; then
        echo "ok   - ${name}"
    else
        echo "FAIL - ${name}"
        echo "       expected: ${expected}"
        echo "       actual:   ${actual}"
        failures=$((failures + 1))
    fi
}

check_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grep -Fq -- "${needle}" <<<"${haystack}"; then
        echo "ok   - ${name}"
    else
        echo "FAIL - ${name}"
        echo "       missing: ${needle}"
        failures=$((failures + 1))
    fi
}

check_absent() {
    local name="$1" needle="$2" haystack="$3"
    if grep -Fq -- "${needle}" <<<"${haystack}"; then
        echo "FAIL - ${name}"
        echo "       unexpected: $(grep -F -- "${needle}" <<<"${haystack}" | head -n 3)"
        failures=$((failures + 1))
    else
        echo "ok   - ${name}"
    fi
}

service_pid() {
    docker exec "${container}" s6-svstat /var/run/s6/services/svc |
        sed -n 's/^up (pid \([0-9][0-9]*\).*/\1/p'
}

wait_for() {
    local description="$1"
    shift
    for _ in $(seq 1 30); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "FAIL - timed out waiting for ${description}"
    docker logs "${container}" 2>&1 || true
    failures=$((failures + 1))
    return 1
}

# --- fixture: a v2 style downstream image, scripts deliberately 0644 ---------
root="${work}/root"
mkdir -p "${root}/etc/cont-init.d" "${root}/etc/cont-finish.d" \
    "${root}/etc/services.d/svc" "${root}/etc/services.d/exl"

cat >"${root}/etc/cont-init.d/20-fixture" <<'EOF'
#!/usr/bin/with-contenv bash
{
    echo "FOO=[${FOO}]"
    echo "MULTI=[${MULTI}]"
    echo "SECRET=[${SECRET}]"
    echo "id=$(id -u):$(id -g)"
    echo "tools=$(command -v s6-setuidgid s6-svc s6-svstat execlineb printcontenv with-contenv | wc -l)"
} >/tmp/init.out
EOF

cat >"${root}/etc/cont-init.d/30-fail" <<'EOF'
#!/usr/bin/with-contenv bash
exit 3
EOF

cat >"${root}/etc/cont-init.d/40-after" <<'EOF'
#!/bin/sh
touch /tmp/after-fail
EOF

cat >"${root}/etc/services.d/svc/run" <<'EOF'
#!/usr/bin/with-contenv bash
{
    echo "FOO=[${FOO}]"
    echo "SECRET=[${SECRET}]"
    echo "umask=$(umask)"
} >/tmp/svc.out
exec s6-setuidgid abc sleep 100000
EOF

cat >"${root}/etc/services.d/svc/finish" <<'EOF'
#!/bin/sh
echo "finish" >>/tmp/svc.finish
EOF

cat >"${root}/etc/services.d/exl/run" <<'EOF'
#!/usr/bin/execlineb -P
with-contenv
foreground { sh -c "echo FOO=[$FOO] > /tmp/exl.out" }
s6-setuidgid abc
sleep 200000
EOF

cat >"${root}/etc/cont-finish.d/10-fin" <<'EOF'
#!/usr/bin/with-contenv bash
echo "[fixture] cont-finish ran FOO=[${FOO}]"
EOF

find "${root}" -type f -exec chmod 0644 {} +
printf 's3cr3t value' >"${work}/secret.txt"
chmod 0644 "${work}/secret.txt"
# shellcheck disable=SC2016 # ${BASE} is expanded by docker build, not by this shell
printf 'ARG BASE\nFROM ${BASE}\nCOPY root/ /\n' >"${work}/Dockerfile"

docker build -q --build-arg BASE="${base}" -t "${tag}" "${work}" >/dev/null

# --- service mode ------------------------------------------------------------
docker run -d --name "${container}" \
    -e PUID=1500 -e PGID=1600 -e UMASK=002 \
    -e FOO=bar -e "MULTI=a b  c" \
    -e FILE__SECRET=/secret.txt \
    -v "${work}/secret.txt:/secret.txt:ro" \
    "${tag}" >/dev/null

wait_for "legacy service svc" docker exec "${container}" test -f /tmp/svc.out
wait_for "legacy service exl" docker exec "${container}" test -f /tmp/exl.out

init_out="$(docker exec "${container}" cat /tmp/init.out)"
svc_out="$(docker exec "${container}" cat /tmp/svc.out)"

check "abc uid follows PUID" "1500" "$(docker exec "${container}" id -u abc)"
check "abc gid follows PGID" "1600" "$(docker exec "${container}" id -g abc)"
check "/config owned by abc" "1500:1600" "$(docker exec "${container}" stat -c '%u:%g' /config)"
check_contains "0644 cont-init script runs with container env" "FOO=[bar]" "${init_out}"
check_contains "env values keep inner whitespace" "MULTI=[a b  c]" "${init_out}"
check_contains "FILE__ secret visible to cont-init" "SECRET=[s3cr3t value]" "${init_out}"
check_contains "cont-init runs as root" "id=0:0" "${init_out}"
check_contains "s6 tools are on PATH in cont-init" "tools=6" "${init_out}"
check "cont-init continues after a failing script" "yes" \
    "$(docker exec "${container}" sh -c 'test -f /tmp/after-fail && echo yes || echo no')"
check_contains "0644 service run script gets container env" "FOO=[bar]" "${svc_out}"
check_contains "FILE__ secret visible to services" "SECRET=[s3cr3t value]" "${svc_out}"
check_contains "UMASK applies to services" "umask=0002" "${svc_out}"
check "execlineb service gets container env" "FOO=[bar]" "$(docker exec "${container}" cat /tmp/exl.out)"
check "services drop privileges with s6-setuidgid" "2" \
    "$(docker exec "${container}" sh -c 'ps -eo user,args | grep -c "^abc  *sleep [12]00000"')"
check "s6 tools are on PATH for docker exec" "/usr/bin/s6-svc" \
    "$(docker exec "${container}" sh -c 'command -v s6-svc')"
check "v2 absolute path /bin/execlineb works" "execline-ok" \
    "$(docker exec "${container}" /bin/execlineb -Pc 's6-echo execline-ok' 2>&1)"
check_contains "v2 absolute path /bin/s6-svstat works" "up (pid" \
    "$(docker exec "${container}" /bin/s6-svstat /var/run/s6/services/svc 2>&1)"
check "docker exec with-contenv sees container env" "bar|s3cr3t value" \
    "$(docker exec "${container}" with-contenv sh -c 'echo "${FOO}|${SECRET}"')"

old_pid="$(service_pid 2>&1 || true)"
if [[ "${old_pid}" =~ ^[0-9]+$ ]]; then
    echo "ok   - v2 service path /var/run/s6/services/<name> works"
    docker exec "${container}" s6-svc -r /var/run/s6/services/svc
    restarted() { new_pid="$(service_pid)" && [ -n "${new_pid}" ] && [ "${new_pid}" != "${old_pid}" ]; }
    if wait_for "service restart through the v2 path" restarted; then
        echo "ok   - s6-svc -r through the v2 path restarts the service"
    fi
    if wait_for "service finish script" docker exec "${container}" test -f /tmp/svc.finish; then
        echo "ok   - 0644 service finish script runs"
    fi
else
    check "v2 service path /var/run/s6/services/<name> works" "a service pid" "${old_pid}"
fi

docker stop "${container}" >/dev/null
logs="$(docker logs "${container}" 2>&1)"
check "container stops cleanly" "0" "$(docker inspect "${container}" --format '{{.State.ExitCode}}')"
check_contains "0644 cont-finish script runs with container env" "[fixture] cont-finish ran FOO=[bar]" "${logs}"
check_absent "no permission errors in logs" "Permission denied" "${logs}"
check_absent "no fatal errors in logs" "fatal" "${logs}"
docker rm "${container}" >/dev/null

# --- CMD mode ----------------------------------------------------------------
set +e
cmd_out="$(docker run --rm -e FOO=bar "${tag}" sh -c 'echo "cmd FOO=[${FOO}]"; exit 7' 2>&1)"
cmd_rc=$?
set -e
check_contains "CMD receives the container env" "cmd FOO=[bar]" "${cmd_out}"
check "container exits with the CMD exit code" "7" "${cmd_rc}"

if [ "${failures}" -gt 0 ]; then
    echo "${failures} base contract check(s) failed" >&2
    exit 1
fi
echo "All base contract checks passed for ${base}."
