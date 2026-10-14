#!/usr/bin/env bash
# Finds what TUFF test and fixture builds leave on this Mac, and removes it.
#
#   Scripts/dev_cleanup.sh            list leftovers
#   Scripts/dev_cleanup.sh --check    list them and exit 1 if there are any
#   Scripts/dev_cleanup.sh --remove   remove them
#
# Add --builds to include this checkout's .build and dist folders.
#
# A leftover is anything named for a bundle id other than the shipped app's
# (com.rexmhall09.TUFF.<something>), a scoped data root's preferences
# (TUFF.local.*), a Background API login item other than the shipped one, or
# a TUFF process running from somewhere other than /Applications/TUFF.app.
# The shipped app's data, models, chats and settings are never touched.

set -u

mode=list
builds=false
for argument in "$@"; do
  case "$argument" in
    --check) mode=check ;;
    --remove) mode=remove ;;
    --builds) builds=true ;;
    *) echo "usage: $0 [--check | --remove] [--builds]" >&2; exit 2 ;;
  esac
done

production_id="com.rexmhall09.TUFF"
production_label="$production_id.server"
library="$HOME/Library"
repository="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
found=0

report() {
  found=$((found + 1))
  echo "$1"
}

# Files and folders named for a non-production bundle id. The shipped app's
# own names (com.rexmhall09.TUFF, .plist, .binarycookies, .savedState) stay.
for folder in Caches HTTPStorages Preferences "Saved Application State" WebKit LaunchAgents Containers; do
  [[ -d "$library/$folder" ]] || continue
  for path in "$library/$folder/$production_id."*; do
    [[ -e "$path" ]] || continue
    case "$(basename "$path")" in
      "$production_id.plist" | "$production_id.binarycookies" | "$production_id.savedState") continue ;;
    esac
    report "file      $path"
    if [[ "$mode" == remove ]]; then
      if [[ "$folder" == Preferences ]]; then
        domain="$(basename "$path" .plist)"
        defaults delete "$domain" >/dev/null 2>&1
      fi
      rm -rf -- "$path"
    fi
  done
done

# Preferences written by builds run with TUFF_APPLICATION_SUPPORT_ROOT.
for path in "$library/Preferences/TUFF.local."*.plist; do
  [[ -e "$path" ]] || continue
  report "file      $path"
  if [[ "$mode" == remove ]]; then
    defaults delete "$(basename "$path" .plist)" >/dev/null 2>&1
    rm -f -- "$path"
  fi
done

# Background API login items registered by fixture builds. Their apps are
# usually gone, so they fail at every login.
uid="$(id -u)"
while read -r label; do
  [[ -n "$label" && "$label" != "$production_label" ]] || continue
  report "login     $label"
  if [[ "$mode" == remove ]]; then
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1
  fi
done < <(launchctl list | awk -v id="$production_id." 'index($3, id) == 1 { print $3 }')

# TUFF processes that aren't the installed app. Listed, never killed: one may
# be a run someone is watching. launchd starts the server with a bare name,
# so the executable's real path comes from lsof.
while read -r pid; do
  [[ -n "$pid" ]] || continue
  executable="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }')"
  case "$executable" in
    /Applications/TUFF.app/*) continue ;;
  esac
  report "process   $pid ${executable:-unknown path}"
done < <(pgrep -x 'TUFF|TUFFServer|TUFFCLI|TUFFDecodeService|TUFFCommand|tuff')

if [[ "$builds" == true ]]; then
  for path in "$repository/.build" "$repository/dist"; do
    [[ -e "$path" ]] || continue
    report "build     $path"
    if [[ "$mode" == remove ]]; then rm -rf -- "$path"; fi
  done
fi

if [[ "$found" -eq 0 ]]; then
  echo "No TUFF development leftovers."
elif [[ "$mode" == remove ]]; then
  echo "Removed $found. Processes, if any were listed, are still running."
elif [[ "$mode" == check ]]; then
  exit 1
fi
