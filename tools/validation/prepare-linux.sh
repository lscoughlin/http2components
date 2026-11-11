#!/bin/sh
# Prepare the pinned mORMot2 Linux static objects for a native Linux build.
set -eu

mormot_root=${1:?usage: prepare-linux.sh MORMOT_ROOT}
checksum_file="$mormot_root/static/dev.sha256"
archive_name=mormot2static.tgz
archive_url="https://synopse.info/files/$archive_name"
expected=$(awk -v name="$archive_name" '$2 == "*" name { print $1 }' "$checksum_file")

case "$expected" in
  ""|*[!0-9a-fA-F]*) echo "No valid $archive_name checksum in $checksum_file" >&2; exit 1 ;;
esac
if [ "${#expected}" -ne 64 ]; then
  echo "Invalid SHA-256 for $archive_name in $checksum_file" >&2
  exit 1
fi

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM
curl --fail --location --silent --show-error "$archive_url" -o "$temp_dir/$archive_name"
printf '%s  %s\n' "$expected" "$temp_dir/$archive_name" | sha256sum --check --status || {
  echo "mORMot2 static archive checksum mismatch" >&2
  exit 1
}
tar -xzf "$temp_dir/$archive_name" -C "$mormot_root/static"

# These are the Linux x86_64 objects used by the pinned HTTP/2 dependencies.
for object in \
  x86_64-linux/libdeflatepas.a \
  x86_64-linux/quickjs.o \
  x86_64-linux/sha512-x64sse4.o \
  x86_64-linux/crc32c64.o
do
  if [ ! -s "$mormot_root/static/$object" ]; then
    echo "Required mORMot2 Linux static object is missing: $object" >&2
    exit 1
  fi
done
echo "Prepared mORMot2 static objects from checksum-pinned $archive_name"
