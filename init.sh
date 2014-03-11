#!/bin/bash

case "$1" in
	start)
		start-stop-daemon --start --startas /root/.rbenv/shims/ruby /opt/script/rulemanager.rb --oknodo -p /var/run/rulemanager.pid
	;;
	stop)
		kill -9 `cat /var/run/rulemanager.pid`
esac

