#!/bin/sh
. ./test-lib.sh

t_plan 9 "promote worker to a mold"

t_begin "setup and startup" && {
	rtmpfiles curl_out curl_err r_rot
	unicorn_setup
	unicorn_spawn t0006.ru -c $unicorn_config
	unicorn_wait_start
}

t_begin "ensure server is responsive" && {
	test xtrue = x$(curl -sSf http://$listen/ 2> $curl_err)
}

t_begin "send promote signal (USR2)" && {
	kill -USR2 $unicorn_pid
}

t_begin "ensure server is still responsive" && {
	test xtrue = x$(curl -sSf http://$listen/ 2> $curl_err)
}

t_begin "wait for worker to be promoted" && {
	nr=10
	re="worker=.* pid=.* promoted to a mold"
	while ! grep "$re" < $r_err >/dev/null && test $nr -ge 0
	do
		sleep 1
		nr=$(( $nr - 1 ))
	done
}

t_begin "ensure no errors from curl" && {
	test ! -s $curl_err
}

t_begin "stderr is clean" && check_stderr

t_begin "stop server" && {
	kill $unicorn_pid
}

t_begin "current server stderr is clean" && check_stderr

t_done
