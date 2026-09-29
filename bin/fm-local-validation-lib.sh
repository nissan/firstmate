#!/usr/bin/env bash
# Canonical repository policy for Firstmate's local-only routine validation.
#
# This file is the single owner of the repository allowlist. Callers may omit
# hosted-check waiting only when fm_local_validation_repo_identity accepts the
# exact forge identity. The policy currently covers the repositories migrated
# together to exact-head local no-mistakes validation: nissan/firstmate and
# nissan/Work on github.com.
#
# fm_local_validation_repo_identity <provider> <host> <owner/repo>
# fm_local_validation_repo_remote_url <git-remote-url>

fm_local_validation_repo_identity() {
  local provider=$1 host=$2 path=$3 identity
  identity=$(printf '%s:%s/%s' "$provider" "$host" "$path" | tr '[:upper:]' '[:lower:]')
  case "$identity" in
    github:github.com/nissan/firstmate|github:github.com/nissan/work) return 0 ;;
    *) return 1 ;;
  esac
}

fm_local_validation_repo_remote_url() {
  local url=$1 path
  case "$url" in
    https://github.com/*|http://github.com/*|git://github.com/*)
      path=${url#*://github.com/}
      ;;
    git@github.com:*)
      path=${url#git@github.com:}
      ;;
    ssh://git@github.com/*)
      path=${url#ssh://git@github.com/}
      ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  fm_local_validation_repo_identity github github.com "$path"
}
