#!/usr/bin/env bash
assert_command_exists () {
  if ! ( type "$1" &> /dev/null ); then
    echo "Sorry, I need the '$1' command, but couldn't find it installed." >&2
    if [ -n "$2" ]; then
      echo "Try installing it with \`brew install $2\`."
    else
      echo "Try installing it with \` brew install $1\`."
    fi
    exit 1
  fi
}

assert_command_exists stack
assert_command_exists sbt
assert_command_exists scala
assert_command_exists fswatch
assert_command_exists bloop 'scalacenter/bloop/bloop'

haskell_pid=
last_unison_source="$1"

function kill_haskell {
  # echo "debug: kill $haskell_pid"
  kill $haskell_pid 2>/dev/null
  wait $haskell_pid 2>/dev/null
  haskell_pid=
}

function start_haskell {
  # if haskell isn't running, start it!
  if ! kill -0 $haskell_pid > /dev/null 2>&1; then
    stack exec unison "$last_unison_source" &
    haskell_pid=$!
    echo "Launched haskell watcher as pid $haskell_pid."
  fi
}

function start_dispatch {
  fswatch --batch . | "`dirname $0`/execunison.sh" "$1" "$$" &
  dispatch_pid="$!"
}

function wait_dispatch {
  while kill -0 PIDS 2> /dev/null; do sleep 1; done;
}
