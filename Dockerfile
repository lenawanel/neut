FROM debian:bookworm

WORKDIR /app/

ENV LANG C.utf8
ENV LC_ALL C.utf8

RUN apt-get update && \
  apt-get install --no-install-recommends -y \
  curl \
  gcc \
  git \
  gnupg \
  libc6-dev \
  libffi-dev \
  libgmp-dev \
  lsb-release \
  make \
  netbase \
  software-properties-common \
  tar \
  wget \
  xxd \
  xz-utils \
  zlib1g-dev \
  zstd && \
  rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://get.haskellstack.org/ | sh

RUN wget --progress=dot:giga https://apt.llvm.org/llvm.sh && \
  chmod +x llvm.sh && \
  ./llvm.sh 14 && \
  apt-get install --no-install-recommends -y \
  libclang-rt-14-dev && \
  ln -s /usr/bin/clang-14 /usr/bin/clang

RUN wget -qO - 'https://proget.makedeb.org/debian-feeds/prebuilt-mpr.pub' | gpg --dearmor | tee /usr/share/keyrings/prebuilt-mpr-archive-keyring.gpg 1> /dev/null && \
  echo "deb [arch=all,$(dpkg --print-architecture) signed-by=/usr/share/keyrings/prebuilt-mpr-archive-keyring.gpg] https://proget.makedeb.org prebuilt-mpr $(lsb_release -cs)" | tee /etc/apt/sources.list.d/prebuilt-mpr.list && \
  apt-get update && \
  apt-get install --no-install-recommends -y just && \
  rm -rf /var/lib/apt/lists/*

COPY build/package.template.yaml /app/build/package.template.yaml

RUN cp /app/build/package.template.yaml /app/package.yaml

COPY stack.yaml /app/

RUN stack build --only-dependencies
