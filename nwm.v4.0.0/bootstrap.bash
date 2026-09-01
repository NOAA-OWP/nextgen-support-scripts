#!/usr/bin/env bash
#
# SCRIPT NAME: bootstrap.bash
# USAGE: This script is used as the user bootrap when configurating and build the 
#        operational testbed Early Access cluster using Parallel Works cluster tool.
#        When configurating a cluster, paste the content of this entire file to the 
#        "User Bootstrap" textbox under the "Advanced Settings" section.
#

set -euo pipefail

# install dnf-plugins-core
sudo dnf -y install dnf-plugins-core >/dev/null 2>&1 || true
sudo dnf config-manager --set-disabled cuda-rhel8-x86_64 || true
sudo dnf clean all && sudo dnf makecache
 
#sudo dnf install -y docker-compose-plugin
sudo dnf install -y yum-utils
sudo dnf install -y gdb
sudo dnf install -y epel-release
## NGEN FOSS dependencies ##
sudo dnf install -y gcc-toolset-10 bzip2-devel zlib-devel libcurl libasan6
sudo dnf install -y gcc-toolset-10-libasan-devel bzip2-devel zlib-devel libcurl-devel
sudo dnf install -y udunits2
sudo dnf install -y udunits2-devel
sudo dnf install -y qt5-qtsvg-devel

sudo dnf install -y git cmake boost169-static openssl-devel python3.11-devel libicu-devel
 
sudo dnf install -y hdf5 hdf5-devel netcdf netcdf-devel netcdf-fortran netcdf-fortran-devel netcdf-fortran-static perl-Switch
sudo dnf install -y boost-regex boost-filesystem boost-devel boost-test log4cxx log4cxx-devel libpq libpq-devel patch

# E.g. 1.91.0
BOOST_VERS_DOT=1.90.0
# e.g. 1_91_0
BOOST_VERS_UNDER=1_90_0
# Build boost (from: https://www.boost.org/doc/user-guide/getting-started.html#from-source)
sudo dnf -y install wget findutils
sudo wget https://archives.boost.io/release/${BOOST_VERS_DOT}/source/boost_${BOOST_VERS_UNDER}.tar.gz && \
    sudo tar xf boost_${BOOST_VERS_UNDER}.tar.gz && \
    cd boost_${BOOST_VERS_UNDER} && \
    sudo ./bootstrap.sh --with-python=/usr/bin/python3.11 \
    --prefix=/opt/boost/${BOOST_VERS_DOT} && \
    sudo ./b2 cxxflags=-fPIC && \
    sudo ./b2 install

sudo git clone --branch 5.15.2 https://github.com/ecmwf/ecflow.git /src/ecflow
sudo git clone --branch 3.14.2 https://github.com/ecmwf/ecbuild.git /src/ecbuild
## See docs for build options, e.g. custom compiler, Ninja, UI disabling, etc.
## DENABLE_UI=OFF is needed here since we don't have Qt installed, not building the UI.
cd /src/ecflow
sudo cmake -B build -S . \
    -DCMAKE_INSTALL_PREFIX=/opt/ecflow \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SERVER=OFF \
    -DENABLE_UI=ON \
    -DENABLE_HTTP=ON \
    -DENABLE_PYTHON=ON \
    -DENABLE_TESTS=ON  \
    -DPython3_EXECUTABLE=/usr/bin/python3.11 \
    -DBOOST_ROOT=/opt/boost/${BOOST_VERS_DOT}
sudo cmake --build build -j 4
sudo cmake --build build --target install

cd -
sudo rm -rf /src

# make bin visible for new shells (optional but convenient)
echo 'export PATH="/opt/ecflow/bin:$PATH"' | sudo tee /etc/profile.d/ecflow.sh >/dev/null
sudo chmod +x /etc/profile.d/ecflow.sh

# install openmpi
sudo dnf -y install openmpi \
 && sudo dnf clean all \
 && sudo rm -rf /var/cache/dnf

# make bin visible for new shells (optional but convenient)
echo 'export PATH="/usr/lib64/openmpi/bin:$PATH"' | sudo tee /etc/profile.d/openmpi.sh >/dev/null
sudo chmod +x /etc/profile.d/openmpi.sh

# ensure libs are cached
echo "/usr/lib64/openmpi/lib" | sudo tee /etc/ld.so.conf.d/openmpi.conf >/dev/null
sudo ldconfig

# install Docker
if ! command -v docker >/dev/null 2>&1; then
    if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
        sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# enable Docker on boot
sudo systemctl enable --now docker
sudo systemctl start docker

# if contrib isn't mounted, move the shared user directories out of the way before the mount
if [ -z "`mount | grep '/contrib'`" ]; then
  mkdir /tmp/tmpcontribbkp
  sudo mv /contrib/* /tmp/tmpcontribbkp
fi
 
if [ -f /tmp/grant-sudo.cron ]; then
  echo "cron file already exists"
else
  echo "* * * * * flock -n /tmp/grant_sudo.lock /hydrofabric-efs/scripts/grant-sudo.sh" > /tmp/grant-sudo.cron
  crontab /tmp/grant-sudo.cron
fi

# set sudo users, dnf packages, and python packages
ADD_USERS=(
  "ngen-pw-user"
  "miguel.pena"
  "Zhengtao.Cui"
)
PY_PIP_PKGS="Flask gunicorn"

# run script with environment variables
#ADD_USERS="${ADD_USERS[*]}" \
#PY_PIP_PKGS="$PY_PIP_PKGS" \
#
# install gh cli
if ! command -v gh >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo | sudo tee /etc/yum.repos.d/github-cli.repo
    sudo dnf -y install gh
fi

# install mountpoint-s3
if ! command -v mount-s3 >/dev/null 2>&1; then
    sudo dnf -y install https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.rpm
fi

# install python packages
if [ -n "${PY_PIP_PKGS:-}" ]; then
    sudo dnf -y install python3-pip
    sudo python3 -m pip install --upgrade pip
    sudo python3 -m pip install ${PY_PIP_PKGS}
fi

# ensure a sudoers drop-in exists that grants passwordless sudo to all users in the wheel group
if [ ! -f /etc/sudoers.d/99-wheel-nopw ]; then
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/99-wheel-nopw >/dev/null
    sudo chmod 440 /etc/sudoers.d/99-wheel-nopw
fi

# add users to docker and wheel groups
if [ -n "${ADD_USERS:-}" ]; then
    if getent group docker >/dev/null 2>&1; then
        for u in ${ADD_USERS}; do
            id -u "$u" >/dev/null 2>&1 && sudo usermod -aG docker "$u" || echo "warn: user $u not found"
        done
    else
        echo "warn: docker group not found; skipping docker memberships"
    fi
    for u in ${ADD_USERS}; do
        id -u "$u" >/dev/null 2>&1 && sudo usermod -aG wheel "$u" || echo "warn: user $u not found"
    done
fi

