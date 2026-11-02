#!/usr/bin/env bash
# Fork versionName can follow upstream (2.6.1.1-1018b). That is not valid
# Dart semver, so pubspec.yaml stays x.y.z+<versionCode> (currently 2.6.1+…).
# The name and code that ship in the APK, About page, and logs are the
# defaultValues in lib/build_config.dart. Do NOT use git rev-list --count.
set -euo pipefail

versionName=$(sed -n "s/.*defaultValue: '\\([^']*\\)'.*/\\1/p" lib/build_config.dart | head -1)
versionCode=$(sed -n "s/.*defaultValue: \\([0-9][0-9]*\\).*/\\1/p" lib/build_config.dart | head -1)

line=$(grep -E '^version:' pubspec.yaml | head -n1 | tr -d '\r')
rest=${line#version:}
rest=${rest#"${rest%%[![:space:]]*}"}
pubCode=${rest#*+}

if [[ -z "$versionName" || -z "$versionCode" || "$versionName" == "N/A" ]]; then
  echo "failed to parse fork version from lib/build_config.dart" >&2
  exit 1
fi
if (( ${#versionName} > 16 )); then
  echo "versionName longer than 16 characters: $versionName" >&2
  exit 1
fi
if [[ "$pubCode" != "$versionCode" ]]; then
  echo "pubspec build number ($pubCode) != build_config versionCode ($versionCode)" >&2
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
