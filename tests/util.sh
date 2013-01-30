#!/bin/bash


N=1
ret=0

AGENT_PORT="${AGENT_PORT:-6085}"
VARNISH_PORT="${VARNISH_PORT:-80}"
TMPDIR="${TMPDIR:-$(mktemp -d)}"
SRCDIR="${SRCDIR:-"."}"
ORIGPWD="${ORIGPWD:-"."}"
VARNISH_PID="${TMPDIR}/varnish.pid"

inc() {
	N=$(( ${N} + 1 ))
}

fail() {
	echo -en "${INDENT}Failed ${N}:"
	echo " $*"
	if [ "x$KNOWN_FAIL" = "x1" ]; then
		echo "Known failure. Ignoring."
	else
		ret=$(( ${ret} + 1 ))
	fi
}

pass() {
	echo -en "${INDENT}Passed ${N} "
	echo "$*"
}

cleanup() {
    echo Stopping varnishd and the agent
    [ -z "$varnishpid" ] || kill "$varnishpid" || true
    [ -z "$agentpid" ] || kill "$agentpid" || true
    echo Cleaning up
    rm -rf ${TMPDIR}
}

init_misc() {
	trap 'cleanup' EXIT
	mkdir -p ${TMPDIR}/vcl
}

start_varnish() {
	head -c 16 /dev/urandom > "$TMPDIR/secret"
	printf "${INDENT}Starting varnishd\n\n"
	varnishd -f "${SRCDIR}/data/boot.vcl" \
	    -P "$VARNISH_PID" \
	    -n "$TMPDIR" \
	    -p auto_restart=off \
	    -a 127.0.0.1:0 \
	    -T 127.0.0.1:0 \
	    -s malloc,50m \
	    -S "$TMPDIR/secret"
	varnishpid="$(cat "$VARNISH_PID")"
	VARNISH_PORT=$(varnishadm -n "$TMPDIR" debug.listen_address | cut -d\  -f 2)
	sleep 1
	export VARNISH_PORT AGENT_PORT
	export N_ARG="-n ${TMPDIR}"
}

start_agent() {
	printf "Starting agent:\n\n"
	AGENT_PORT=$(( 1024 + ( $RANDOM % 48000 ) ))
	echo -e "\tAgent port: $AGENT_PORT"
	$ORIGPWD/../src/varnish-agent ${N_ARG} -p ${TMPDIR}/vcl/ -P ${TMPDIR}/agent.pid -c "$AGENT_PORT"
	agentpid=$(cat ${TMPDIR}/agent.pid)
	echo "Agent started($agentpid)"
	export agentpid
}

init_all() {
	init_misc
	start_varnish
	start_agent
}

test_it() {
	FOO=$(lwp-request -m $1 http://localhost:$AGENT_PORT/$2 <<<"$3")
	if [ "x$?" = "x0" ]; then pass; else fail "$*: $FOO"; fi
	inc
	if [ "x$FOO" = "x$4" ]; then pass; else fail "$*: $FOO"; fi
	inc
}

test_it_no_content() {
	FOO=$(lwp-request -m $1 http://localhost:${AGENT_PORT}/$2 </dev/null)
	if [ "x$?" = "x0" ]; then pass; else fail "$*: $FOO"; fi
	inc
	if [ "x$FOO" = "x$4" ]; then pass; else fail "$*: $FOO"; fi
	inc
}

test_it_fail() {
	FOO=$(lwp-request -m $1 http://localhost:${AGENT_PORT}/$2 <<<"$3")
	if [ "x$?" != "x0" ]; then pass; else fail "$*: $FOO"; fi
	inc
	if [ "x$FOO" = "x$4" ]; then pass; else fail "$*: $FOO"; fi
	inc
}

test_it_long() {
	FOO=$(lwp-request -m $1 http://localhost:${AGENT_PORT}/$2 <<<"$3")
	if [ "x$?" = "x0" ]; then pass; else fail "$*: $FOO"; fi
	inc
	if echo $FOO | grep -q "$4";then pass; else fail "$*: $FOO"; fi
	inc
}

test_it_long_content_fail() {
	FOO=$(lwp-request -m $1 http://localhost:${AGENT_PORT}/$2 <<<"$3")
	if [ "x$?" = "x0" ]; then pass; else fail "$*: $FOO"; fi
	inc
	if echo $FOO | grep -q "$4"; then fail "$*: $FOO"; else pass; fi
	inc
}

is_running() {
	if [ "x$NOSTATUS" = "x1" ]; then
		return
	fi
	test_it GET status "" "Child in state running"
}

test_json() {
	NAME="${TMPDIR}/jsontest$N.json"
	lwp-request -m GET http://localhost:${AGENT_PORT}/$1 > $NAME
	if [ "x$?" = "x0" ]; then pass; else fail "json failed: $1 failed"; fi
	inc
	FOO=$(jsonlint -v $NAME)
	if [ "x$?" = "x0" ]; then
	    pass
	else
	    fail "json failed: $1 failed: $FOO"
	    cat "$NAME"
	fi
	inc

}
