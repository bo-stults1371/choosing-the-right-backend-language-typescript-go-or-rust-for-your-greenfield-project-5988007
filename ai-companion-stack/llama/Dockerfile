# syntax=docker/dockerfile:1
ARG CUDA_VERSION=12.4.1
ARG UBUNTU_VERSION=22.04

FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS build
ARG LLAMA_CPP_REF=master
ARG CMAKE_EXTRA_ARGS=""
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates libssl-dev \
 && apt-get clean
WORKDIR /src
# init+fetch works for a branch, a tag or a commit SHA.
RUN git init -q llama.cpp \
 && git -C llama.cpp remote add origin https://github.com/ggml-org/llama.cpp \
 && git -C llama.cpp fetch -q --depth 1 origin "${LLAMA_CPP_REF}" \
 && git -C llama.cpp checkout -q FETCH_HEAD \
 && git -C llama.cpp rev-parse HEAD > /src/llama.cpp.rev
# Web UI is not embedded: SillyTavern is the frontend.
RUN cmake llama.cpp -B llama.cpp/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF -DGGML_CUDA=ON \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF \
      ${CMAKE_EXTRA_ARGS} \
 && cmake --build llama.cpp/build --config Release -j"$(nproc)" --target llama-server

FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      curl ca-certificates libgomp1 openssl \
 && apt-get clean \
 && find /var/lib/apt/lists -type f -delete
COPY --from=build /src/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server
COPY --from=build /src/llama.cpp.rev /etc/llama.cpp.rev
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENV LD_LIBRARY_PATH=/usr/local/nvidia/lib64:/usr/local/nvidia/lib:${LD_LIBRARY_PATH}
VOLUME /models
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=5s --start-period=60m --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
