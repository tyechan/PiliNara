#!/usr/bin/env bash
# Preserve the fork versionName/versionCode in pubspec.yaml.
# Do NOT use git rev-list --count (that yields ~6057 and breaks our YYYYMMDDNN scheme).
set -euo pipefail

line=$(grep -E '^version:' pubspec.yaml | head -n1 | tr -d '\r')
rest=${line#version:}
rest=${rest#"${rest%%[![:space:]]*}"}
versionName=${rest%%+*}
versionCode=${rest#*+}

if [[ -z "$versionName" || -z "$versionCode" || "$versionName" == "$rest" ]]; then
  echo "failed to parse version from pubspec.yaml: $line" >&2
  exit 1
fi

commitHash=$(git rev-parse HEAD)
shortHash=${commitHash:0:7}
buildTime=$(date +%s)

cat > pili_release.json <<EOF
{"pili.name":"${versionName}","pili.code":${versionCode},"pili.hash":"${commitHash}","pili.time":${buildTime}}
EOF

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "version=${versionName}+${shortHash}"
    echo "version_code=${versionCode}"
    echo "version_name=${versionName}"
    echo "commit_hash=${shortHash}"
  } >> "$GITHUB_ENV"
fi

echo "pili_release.json: name=$versionName code=$versionCode hash=$commitHash"
