#!/usr/bin/env bash
#MISE description="Check the cni-cilium component's release, source and rendered values, without a live cluster"
set -euo pipefail
bats "${MISE_PROJECT_ROOT:?}/components/cni-cilium/tests/values.bats"
