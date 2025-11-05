#!/bin/bash
#=====================
# Environment setup for
# a self contained Spack
# install created with
# spack_setup.sh
#=====================

export SPACK_DIR=${PWD}/spack
export SPACK_BUILDCACHE=${SPACK_DIR}/spack_buildcache

# Default is normally ~/.spack, but for portability
# with mounted disks, this is nice to specify.
export SPACK_USER_CONFIG_PATH=${SPACK_DIR}/.spack
export SPACK_USER_CACHE_PATH=${SPACK_DIR}/spack_user_cache
export SPACK_DISABLE_LOCAL_CONFIG=true

# Default is /tmp, but this is restricted on some 
# systems so reset to something explicit in the
# spack root working dir. Also helps with debugging
# and tracing install errors.
export TMPDIR=${SPACK_DIR}/tmp

source ${SPACK_DIR}/spack/share/spack/setup-env.sh

