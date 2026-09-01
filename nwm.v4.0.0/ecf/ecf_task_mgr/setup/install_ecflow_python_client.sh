#!/usr/bin/env bash
#
# \brief
# Builds and installs the ecflow Python client library from source.
#
# \desc
# Targets Ubuntu/Debian. For Rocky Linux 8, try swapping apt commands for dnf equivalents.
# Note nuances of static vs dynamic libs when building with Boost. ecflow has its own var ENABLE_STATIC_BOOST_LIBS.
# The default ecflow version is 5.15.2 to match that of ``nwm.v4.0.0/ecflow-server/Dockerfile.ecflow-server``
#
# \usage
# ./install_ecflow_python_client.sh [ECFLOW_VERSION] (default: 5.15.2) [INSTALL_PREFIX] (default: $VIRTUAL_ENV if active, otherwise /usr/local)
#
#
set -euo pipefail

ECFLOW_VERSION="${1:-5.15.2}"
BOOST_VERSION="${BOOST_VERSION:-1.84.0}"
if [[ -n "${2:-}" ]]; then
    INSTALL_PREFIX="$2"
elif [[ -n "${VIRTUAL_ENV:-}" ]]; then
    INSTALL_PREFIX="${VIRTUAL_ENV}"
else
    INSTALL_PREFIX="/usr/local"
fi
JOBS="${JOBS:-$(nproc)}"
BUILD_DIR="/tmp/installing_ecflow_python_client"

set -x

echo "=== Installing ecflow Python client v${ECFLOW_VERSION} ==="

# Clean any previous build attempt
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "--- Installing system dependencies ---"
# Determine the python3-dev package matching the active python3 interpreter
PYTHON3_DEV_PKG="python$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')-dev"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    wget \
    libssl-dev \
    "${PYTHON3_DEV_PKG}" \
    python3-pip \
    zlib1g-dev \
    libbz2-dev \
    libicu-dev

echo "--- Building Boost ${BOOST_VERSION} from source (with -fPIC) ---"
BOOST_VERS_UNDER="${BOOST_VERSION//./_}"
PYTHON3_EXE="$(which python3)"
PYTHON3_VERSION="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PYTHON3_INCLUDE="$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')"
PYTHON3_LIB="$(python3 -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))')"

cd "${BUILD_DIR}"
wget -q "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_VERS_UNDER}.tar.gz"
tar xf "boost_${BOOST_VERS_UNDER}.tar.gz"
cd "boost_${BOOST_VERS_UNDER}"

# Write user-config.jam so b2 can find the correct Python headers
cat > user-config.jam <<EOF
using python : ${PYTHON3_VERSION} : ${PYTHON3_EXE} : ${PYTHON3_INCLUDE} : ${PYTHON3_LIB} ;
EOF

./bootstrap.sh --with-python="${PYTHON3_EXE}" --prefix="${BUILD_DIR}/boost_install" \
    --with-libraries=filesystem,program_options,date_time,python,system
./b2 -j"${JOBS}" cxxflags=-fPIC link=static --user-config=user-config.jam install
cd "${BUILD_DIR}"

echo "--- Installing pybind11 ---"
pip3 install --quiet "pybind11>=2.10.3"

# Expose pybind11 cmake dir so find_package(pybind11) works
PYBIND11_CMAKE_DIR="$(python3 -c 'import pybind11; print(pybind11.get_cmake_dir())')"

echo "--- Cloning ecflow v${ECFLOW_VERSION} ---"
cd "${BUILD_DIR}"

git clone --depth 1 --branch "${ECFLOW_VERSION}" \
    https://github.com/ecmwf/ecflow.git

# ecbuild is ECMWF's cmake framework (required by ecflow)
git clone --depth 1 https://github.com/ecmwf/ecbuild.git

mkdir -p ecflow/build
cd ecflow/build
cmake .. \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MODULE_PATH="${BUILD_DIR}/ecbuild/cmake" \
    -DCMAKE_PREFIX_PATH="${PYBIND11_CMAKE_DIR}" \
    -DENABLE_PYTHON=ON \
    -DENABLE_SERVER=OFF \
    -DENABLE_UI=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_DOCS=OFF \
    -DENABLE_SSL=ON \
    -DBOOST_ROOT="${BUILD_DIR}/boost_install" \
    -DBoost_NO_SYSTEM_PATHS=ON \
    -DPython3_EXECUTABLE="$(which python3)"
make -j"${JOBS}"
sudo make install

echo "--- Verifying installation ---"
python3 -c "import ecflow; print(f'ecflow {ecflow.__version__} installed successfully')"

echo "--- Cleaning up build directory ---"
rm -rf "${BUILD_DIR}"

echo "=== Done installing ecflow Python client v${ECFLOW_VERSION} ==="
