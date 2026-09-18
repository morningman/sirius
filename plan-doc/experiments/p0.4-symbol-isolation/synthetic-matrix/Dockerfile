FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential g++ pkg-config libprotobuf-dev protobuf-compiler libabsl-dev libjemalloc-dev \
    binutils file curl ca-certificates bzip2 patchelf cmake && rm -rf /var/lib/apt/lists/*
# PIC static protobuf 3.21.12 (same 21.x series as Doris's 21.11) for the static-plugin variants
RUN curl -Ls https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protobuf-cpp-3.21.12.tar.gz | tar -xz -C /opt \
 && cd /opt/protobuf-3.21.12 && src=. && [ -f CMakeLists.txt ] || src=cmake \
 && cmake -S $src -B build -DCMAKE_BUILD_TYPE=Release -Dprotobuf_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=/opt/pb21 -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
 && cmake --build build -j$(nproc) && cmake --install build && rm -rf /opt/protobuf-3.21.12
RUN arch=$(uname -m); case "$arch" in aarch64) p=linux-aarch64;; x86_64) p=linux-64;; esac; \
    curl -Ls https://micro.mamba.pm/api/micromamba/$p/latest | tar -xj -C /usr/local/bin/ --strip-components=1 bin/micromamba
ENV MAMBA_ROOT_PREFIX=/opt/conda
RUN micromamba create -y -n sirius -c conda-forge cxx-compiler "libprotobuf>=5" libabseil pkg-config && micromamba clean -a -y
WORKDIR /exp
