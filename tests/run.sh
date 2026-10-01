#!/usr/bin/env bash
# tests/run.sh — build the image locally and run the render tests in it.
#
#   tests/run.sh                # render matrix + backward-compat diff vs main
#   BASE_REF=v2.0 tests/run.sh  # compare against another git ref
#
# Nothing here enrolls a router, contacts a controller, or touches a running
# container: the tests run in a throwaway container from a local image tag.

set -eo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-aer-local:test}"
BASE_REF="${BASE_REF:-main}"

docker build -q -t "${IMAGE}" . >/dev/null
echo "Built ${IMAGE}"

OLD="tests/.old-entrypoint.sh"
git show "${BASE_REF}:docker-entrypoint.sh" > "${OLD}"
trap 'rm -f "${OLD}"' EXIT

run_in_image() {
    docker run --rm -v "${PWD}:/w" -e AER_LIB=/w/aer-lib.sh --entrypoint bash "${IMAGE}" "$@"
}

rc=0
echo
echo "########## Render matrix ##########"
run_in_image /w/tests/render-tests.sh || rc=1
echo
echo "########## Backward compatibility vs ${BASE_REF} ##########"
run_in_image /w/tests/compat-diff.sh "/w/${OLD}" /tmp/compat || rc=1
exit "${rc}"
