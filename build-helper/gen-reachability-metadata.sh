#!/bin/sh
# Generate GraalVM reachability metadata at build time so it always tracks the resolved JJWT
# version. Registers every io.jsonwebtoken.* class from the resolved jjwt jars (JJWT loads its
# impl classes reflectively by name and ships no GraalVM metadata), plus two app-specific
# entries: java.util.UUID[] (Hibernate instantiates it for the UUID entity ids) and Credentials
# (parsed via a manual ObjectMapper in CustomAuthenticationFilter, which Spring AOT misses).
# Run from the project root AFTER dependencies are resolved (jjwt jars in the Gradle cache).
set -eu

dir="src/main/resources/META-INF/native-image"
mkdir -p "$dir"

jars=$(find /root/.gradle/caches -name 'jjwt-impl-*.jar' -o -name 'jjwt-jackson-*.jar')
[ -n "$jars" ] || { echo 'ERROR: jjwt jars not found in Gradle cache' >&2; exit 1; }

# shellcheck disable=SC2086  # intentional word-splitting over the jar list
classes=$(for j in $jars; do unzip -Z1 "$j"; done | grep '[.]class$' | grep -vE 'module-info|package-info' | sed 's/[.]class$//; s|/|.|g' | grep '^io[.]jsonwebtoken[.]' | sort -u)
n=$(echo "$classes" | sed '/^$/d' | wc -l)
[ "$n" -ge 50 ] || { echo "ERROR: only $n jjwt classes found (expected many)" >&2; exit 1; }

{
  echo '{'
  echo '  "reflection": ['
  echo '    { "type": "java.util.UUID[]" },'
  echo '    { "type": "com.example.jwt.core.security.helpers.Credentials", "allDeclaredConstructors": true, "allDeclaredMethods": true, "allDeclaredFields": true }'
  echo "$classes" | while read -r c; do
    if [ -n "$c" ]; then
      echo '    ,{ "type": "'"$c"'", "allDeclaredConstructors": true, "allDeclaredMethods": true, "allDeclaredFields": true }'
    fi
  done
  echo '  ]'
  echo '}'
} > "$dir/reachability-metadata.json"

echo "Generated $dir/reachability-metadata.json with $n JJWT classes + UUID[] + Credentials"
