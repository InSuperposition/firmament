#!/usr/bin/env bash
#MISE description="Check the cilium component's release, source and rendered values, without a live cluster"
set -euo pipefail
bats "${MISE_PROJECT_ROOT:?}/packages/cilium/tests/values.bats"
