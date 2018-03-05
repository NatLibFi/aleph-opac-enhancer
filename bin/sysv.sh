#!/bin/bash
#
# Copyright 2008-2010, 2018 University Of Helsinki (The National Library Of Finland)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

source "${BASH_SOURCE%/*}/../../conf/conf.sh"

NAME="OPAC enhancer"
DESC="Aleph OPAC enhancer"

test -d $DIR || exit 0
test -f $DAEMON || exit 0

set -e

case "$1" in
  start)
    printf "%s" "Starting $DESC: "
    if test -f $PIDFILE; then
      echo "Error: PID file $PIDFILE already exists. Use restart instead."
    else
      cd $DIR
      $DAEMON --config=$CONFIG --pidfile=$PIDFILE --workdir=$DIR --daemon
      echo "$NAME."
    fi
    ;;
  stop)
    printf "%s" "Stopping $DESC: "
    cd $DIR
    if test -f $PIDFILE; then
      kill `cat $PIDFILE`
      rm -f $PIDFILE
      echo "$NAME."
    else
      echo "No PID $PIDFILE"
    fi
    ;;
  restart|force-reload)
    printf "%s" "Restarting $DESC: "
    cd $DIR
    if test -f $PIDFILE; then
      kill `cat $PIDFILE`
      rm -f $PIDFILE
    fi
    sleep 1
    cd $DIR
    $DAEMON --config=$CONFIG --pidfile=$PIDFILE --workdir=$DIR --daemon
    echo "$NAME."
    ;;
  *)
    N=/etc/init.d/$NAME
    echo "Usage: $N {start|stop|restart|force-reload}" >&2
    exit 1
    ;;
esac

exit 0
