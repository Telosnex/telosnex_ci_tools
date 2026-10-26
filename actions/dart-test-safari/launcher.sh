#!/bin/bash
# Launch package:test's Safari manager URL without opening its temporary local
# redirect file. Modern Safari asks the user to confirm local files, which
# prevents unattended `dart test -p safari` runs.
set -euo pipefail

if [[ ${#} -ne 1 ]]; then
  echo "Usage: $0 package-test-redirect.html" >&2
  exit 64
fi

redirect_path=$1
if [[ ! -f "$redirect_path" ]]; then
  echo "Safari test redirect does not exist: $redirect_path" >&2
  exit 66
fi

redirect_html=$(<"$redirect_path")
prefix='<script>location = "'
suffix='"</script>'
if [[ "$redirect_html" != "$prefix"*"$suffix" ]]; then
  echo "Unexpected package:test Safari redirect contents." >&2
  exit 65
fi

test_url=${redirect_html#"$prefix"}
test_url=${test_url%"$suffix"}
case "$test_url" in
  http://localhost:* | http://127.0.0.1:* | http://\[::1\]:*) ;;
  *)
    echo "Refusing to open a non-loopback Safari test URL: $test_url" >&2
    exit 65
    ;;
esac

# Launch Services can send an HTTP URL to Safari directly. Safari's executable
# cannot, which is why package:test creates the local redirect in the first
# place.
/usr/bin/open -a Safari "$test_url"

cleaned_up=false
cleanup() {
  if [[ "$cleaned_up" == true ]]; then
    return
  fi
  cleaned_up=true

  # Close only the package:test manager tab opened above. Failure is harmless:
  # Safari may already be closed, or macOS may deny Automation permission.
  /usr/bin/osascript - "$test_url" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set testURL to item 1 of argv
  tell application "Safari"
    repeat with windowIndex from (count of windows) to 1 by -1
      set safariWindow to window windowIndex
      repeat with tabIndex from (count of tabs of safariWindow) to 1 by -1
        set safariTab to tab tabIndex of safariWindow
        try
          if (URL of safariTab) starts with testURL then close safariTab
        end try
      end repeat
    end repeat
  end tell
end run
APPLESCRIPT
}

trap 'cleanup; exit 0' HUP INT TERM
trap cleanup EXIT

# package:test treats this executable as the browser process and terminates it
# after the suite. Stay alive for that lifetime rather than letting `open` exit
# immediately and making the runner report that Safari exited before connecting.
while true; do
  sleep 1
done
