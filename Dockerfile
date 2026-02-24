###############################################################################
# Stage 1: Builder
###############################################################################
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install APT build dependencies
RUN apt-get update && apt-get --no-install-recommends -y install \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    cmake \
    duktape-dev \
    git \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libconfig-dev \
    libcurl4-openssl-dev \
    libglib2.0-dev \
    libgirepository1.0-dev \
    libjansson-dev \
    liblua5.3-dev \
    libmicrohttpd-dev \
    libnanomsg-dev \
    libogg-dev \
    libopus-dev \
    libpcap-dev \
    librabbitmq-dev \
    libsofia-sip-ua-dev \
    libssl-dev \
    libtool \
    meson \
    ninja-build \
    pkg-config \
    python3 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/build

# ---- libnice (master) ----
RUN git clone --depth 1 https://github.com/libnice/libnice.git && \
    cd libnice && \
    meson setup -Dprefix=/usr/local -Dlibdir=lib -Dc_args="-O2 -Wno-cast-align" \
      -Dexamples=disabled \
      -Dgtk_doc=disabled \
      -Dgstreamer=disabled \
      -Dgupnp=disabled \
      -Dtests=disabled \
      build && \
    ninja -C build && \
    ninja -C build install

# ---- libsrtp v2.7.0 ----
RUN git clone --depth 1 --branch v2.7.0 https://github.com/cisco/libsrtp.git && \
    cd libsrtp && \
    ./configure --prefix=/usr/local CFLAGS="-O2" \
      --disable-dependency-tracking \
      --disable-pcap \
      --enable-openssl && \
    make -j$(nproc) shared_library && \
    make install

# ---- usrsctp (master) — required for data channels ----
RUN git clone --depth 1 https://github.com/sctplab/usrsctp.git && \
    cd usrsctp && \
    ./bootstrap && \
    ./configure --prefix=/usr/local CFLAGS="-O2" \
      --disable-dependency-tracking \
      --disable-debug \
      --disable-inet \
      --disable-inet6 \
      --disable-programs \
      --disable-static \
      --enable-shared && \
    make -j$(nproc) && \
    make install

# ---- libwebsockets v4.3-stable ----
RUN git clone --depth 1 --branch v4.3-stable https://github.com/warmcat/libwebsockets.git && \
    cd libwebsockets && \
    mkdir build && cd build && \
    cmake -DCMAKE_INSTALL_PREFIX:PATH=/usr/local -DCMAKE_BUILD_TYPE=RELEASE -DCMAKE_C_FLAGS="-O2" \
      -DLWS_ROLE_RAW_FILE=OFF \
      -DLWS_WITH_HTTP2=OFF \
      -DLWS_WITHOUT_EXTENSIONS=OFF \
      -DLWS_WITHOUT_TESTAPPS=ON \
      -DLWS_WITHOUT_TEST_CLIENT=ON \
      -DLWS_WITHOUT_TEST_PING=ON \
      -DLWS_WITHOUT_TEST_SERVER=ON \
      -DLWS_WITH_STATIC=OFF \
      .. && \
    make -j$(nproc) && \
    make install

# Ensure linker can find /usr/local libs during Janus build
RUN ldconfig

# ---- Build Janus Gateway ----
COPY . /tmp/build/janus-gateway
WORKDIR /tmp/build/janus-gateway

RUN ./autogen.sh && \
    ./configure --prefix=/usr/local \
      --disable-dependency-tracking \
      --disable-docs \
      --enable-post-processing \
      --enable-plugin-lua \
      --enable-plugin-duktape \
      --enable-json-logger \
      CFLAGS="-O2" && \
    make -j$(nproc) && \
    make install


###############################################################################
# Stage 2: Runtime
###############################################################################
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install only runtime libraries (no -dev packages)
RUN apt-get update && apt-get --no-install-recommends -y install \
    ca-certificates \
    curl \
    libavcodec60 \
    libavformat60 \
    libavutil58 \
    libconfig9 \
    libcurl4t64 \
    libduktape207 \
    libglib2.0-0t64 \
    libgirepository-1.0-1 \
    libjansson4 \
    liblua5.3-0 \
    libmicrohttpd12t64 \
    libnanomsg5 \
    libogg0 \
    libopus0 \
    libpcap0.8t64 \
    librabbitmq4 \
    libsofia-sip-ua0 \
    libssl3t64 \
  && rm -rf /var/lib/apt/lists/*

# Copy Janus binaries and data
COPY --from=builder /usr/local/bin/janus* /usr/local/bin/
COPY --from=builder /usr/local/lib/janus/ /usr/local/lib/janus/
COPY --from=builder /usr/local/etc/janus/ /usr/local/etc/janus/
COPY --from=builder /usr/local/share/janus/ /usr/local/share/janus/

# Copy from-source shared libraries (libnice, libsrtp, usrsctp, libwebsockets)
COPY --from=builder /usr/local/lib/*.so* /usr/local/lib/
COPY --from=builder /usr/local/lib/pkgconfig/ /usr/local/lib/pkgconfig/

# Refresh shared library cache
RUN ldconfig

ENTRYPOINT ["/usr/local/bin/janus"]
