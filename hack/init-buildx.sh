#!/usr/bin/env bash

# Copyright 2020 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if [ "$DEBUG" = true ]; then
  set -x
fi

set -o errexit
set -o nounset
set -o pipefail

export DOCKER_CLI_EXPERIMENTAL=enabled

if ! docker buildx -h >/dev/null 2>&1; then
  echo "buildx not available. Docker 19.03 or higher is required with experimental features enabled"
  exit 1
fi

if ! current_builder="$(docker buildx inspect)"; then
  echo "ERROR: docker buildx inspect failed: exit code $?" >&2
  exit 1
fi

# Ensure qemu is in binfmt_misc
# Docker desktop already has these in versions recent enough to have buildx
# We only need to do this setup on linux hosts
# Any error is treated as a warning if the buildx driver is "remote"
if [ "$(uname)" == 'Linux' ]; then
  # NOTE: this is pinned to a digest for a reason!
  # Note2 (@rikatz) - Removing the pin, as apparently it's breaking new alpine builds
  # docker run --rm --privileged multiarch/qemu-user-static@sha256:28ebe2e48220ae8fd5d04bb2c847293b24d7fbfad84f0b970246e0a4efd48ad6 --reset -p yes
  if ! docker run --rm --privileged multiarch/qemu-user-static --reset -p yes; then
    if grep -q "^Driver: *remote$" <<<"${current_builder}"; then
      echo "WARNING: binfmt_misc setup failed, cross-platform builds may not work" >&2
    else
      echo "ERROR: binfmt_misc setup failed, cross-platform builds will not work" >&2
      exit 1
    fi
  fi
fi

# We can skip setup if the current builder has sufficient platforms (specified
# as arguments) AND if it isn't the docker driver, which doesn't work
if [ "$#" -gt 0 ] && ! grep -q "^Driver: *docker$" <<<"${current_builder}"; then
  ok=1
  for platform in "$@"; do
    if ! { grep '^Platforms:' <<<"${current_builder}" | grep -q "$platform"; }; then
      ok=0
      break
    fi
  done
  if [ "$ok" -eq 1 ]; then
    exit 0
  fi
fi

# Ensure we use a builder that can leverage it (the default on linux will not)
docker buildx rm ingress-nginx || true
docker buildx create --use --name=ingress-nginx $(for platform in "$@"; do echo "--platform=$platform"; done)
