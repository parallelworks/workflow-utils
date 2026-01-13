#!/bin/bash
#=============================
# Download, install, run Spack
# to install a list of packages.
#
# To make things "easy" assume
# that the Spack install dir
# will be ${PWD}/spack and all
# other preferences and configs
# will also be therein, including
# user configs (.spack), the Spack
# tmp dir and Spack buildcache.
#===============================

#===============================
# PARAMETERS
#===============================

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

export SPACK_VERSION=v1.0.2
export SPACK_ENV_NAME=myspackenv

#===============================
# Make dirs
#===============================

mkdir -p $SPACK_DIR
mkdir -p $SPACK_BUILDCACHE
mkdir -p $TMPDIR
mkdir -p $SPACK_USER_CONFIG_PATH
mkdir -p $SPACK_USER_CACHE_PATH

#===============================
# Get and install Spack, setup
# environment
#===============================

cd $SPACK_DIR
echo Cloning Spack ${SPACK_VERSION}
git clone --recurse-submodules --depth=2 -b ${SPACK_VERSION} https://github.com/spack/spack
cd spack
source share/spack/setup-env.sh
export SPACK_BUILDCACHE_NAME=local-filesystem
spack mirror add --unsigned $SPACK_BUILDCACHE_NAME file://${SPACK_BUILDCACHE}
echo "==============================="
echo Test location of Spack buildcache:
spack mirror list
spack buildcache update-index $SPACK_BUILDCACHE_NAME

#===============================
# Setup Spack environment
#===============================
spack env create $SPACK_ENV_NAME

# Spacktivate alias does not work with isolated envs?
#spacktivate $spack_env_name
spack env activate $SPACK_ENV_NAME
spack compiler find

#===============================
# Add specific packages to environment
#
# This will pull from the buildcache
# if the buildcache already has the packages.
#===============================

#----------------
# Test with a small easy to install package
spack add zlib
#----------------

#----------------
# For a much bigger, more complicated install
# try the following:
# 1) CUDA
# spack add cuda

# 2) NVIDA HPC
# 13GB tar download, then unpacks to an
# additional 
#spack add nvhpc ++mpi

# 3) OpenMPI
# See what MPI NVHPC pulls up on its own.
# installing OpenMPI separately resulted in
# errors running mpif90.
#spack add openmpi

# This seems to work...
#spack add openmpi +pmi +internal-pmix +cuda
#
# But this might be better:
# spack add openmpi +pmi +internal-pmix +cuda %nvhpc ^cuda
#----------------

spack concretize
spack install

#===============================
# Optionally - push installed packages
# to the buildcache
#===============================
spack --env $SPACK_ENV_NAME buildcache push --unsigned $SPACK_BUILDCACHE_NAME
spack buildcache update-index $SPACK_BUILDCACHE_NAME
