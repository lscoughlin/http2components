#!/bin/sh
# Compiler wrapper for the lazbuild build of the package http2tlslib.
# lazbuild adds the argument -B (build all units) to every compiler call.
# The TlsLib bootstrap units are already built in the required order, and -B
# would compile them again in an order that enters the CryptoLib
# ClpMultipliers cycle. The wrapper removes each argument that is exactly -B
# and runs the real compiler with the other arguments, in the same order.
#
# The environment variable LAZBUILD_REAL_COMPILER holds the path of the real
# compiler (for example ppca64). The task packages:check sets it.
if [ -z "${LAZBUILD_REAL_COMPILER:-}" ]; then
  echo "lazbuild-compiler.sh: LAZBUILD_REAL_COMPILER is not set" >&2
  exit 1
fi
_n=$#
while [ "$_n" -gt 0 ]; do
  _a=$1
  shift
  if [ "$_a" != "-B" ]; then set -- "$@" "$_a"; fi
  _n=$((_n - 1))
done
exec "$LAZBUILD_REAL_COMPILER" "$@"
