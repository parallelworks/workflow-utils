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

spack_version=v1.0.2
spack_env_name=myspackenv

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
git clone --recurse-submodules --depth=2 -b ${spack_version} https://github.com/spack/spack
export $SPACK_ROOT=$SPACK_DIR/spack
cd spack
source share/spack/setup-env.sh
spack mirror add local_filesystem file://${SPACK_BUILDCACHE}
echo "==============================="
echo Test location of Spack buildcache:
spack mirror list

#===============================
# Setup Spack environment
#===============================
spack env create $spack_env_name

# Spacktivate alias does not work with isolated envs?
#spacktivate $spack_env_name
spack env activate $spack_env_name
spack compiler find

#===============================
# Add specific packages to environment
#
# This will pull from the buildcache
# if the buildcache already has the packages.
#===============================
spack add cuda

# 13GB tar download, then unpacks to an
# additional 
spack add nvhpc
spack concretize
spack install

#===============================
# Optionally - push installed packages
# to the buildcache
#===============================

