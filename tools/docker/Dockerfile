FROM debian:13
RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-utils bc bison build-essential ca-certificates curl device-tree-compiler \
    file fdisk flex gdisk git gnupg gpgv jq kmod libelf-dev libssl-dev libgnutls28-dev uuid-dev \
    cmake pkg-config libusb-1.0-0-dev autoconf automake libtool \
    patch python3 python3-venv python3-dev python3-yaml rsync shellcheck swig u-boot-tools xz-utils zip \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/schema && /opt/schema/bin/pip install --no-cache-dir dtschema==2025.8 yamllint==1.37.1 PyYAML==6.0.2 setuptools==80.9.0 pyelftools==0.32
# ARM64 runners build natively; keep the cross compiler only for amd64 local validation.
RUN if [ "$(dpkg --print-architecture)" != arm64 ]; then \
        apt-get update && apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu && rm -rf /var/lib/apt/lists/*; \
    fi
ENV PATH="/opt/schema/bin:${PATH}"
RUN git config --system --add safe.directory /work
WORKDIR /work
