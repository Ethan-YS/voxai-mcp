# VoxAI MCP server —— 容器构建。
#
# ⚠️ 这个容器能跑，但**跑不出真实功能**：server 的工具全都读写 VoxAI macOS App
# 沙盒容器里的 IPC 文件，非 macOS 宿主上没有那个 App。容器里 server 会正常启动、
# 完成 MCP 握手、报出完整工具表,而任何工具调用都会明确回复"需要 macOS 宿主 App"
# （见 Sources/voxai-mcp/Compat.swift）。
#
# 存在的意义:让 MCP 目录站点的容器化检查（启动 + initialize）能跑通真实的 server,
# 而不是为了过检查另造一个假的。真要用请在 macOS 14+ 上装 VoxAI:
# https://voxai.ethanflow.com

# 6.0 镜像不够用:依赖链里的 swift-system 1.7.4 要求 Swift tools 6.1+
FROM swift:6.2-jammy AS build
WORKDIR /build

# 先只拷贝清单,让依赖解析层可缓存
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources ./Sources
RUN swift build -c release --static-swift-stdlib

FROM ubuntu:22.04
# 静态链接的是 Swift stdlib;Foundation 在 Linux 上仍动态依赖 libcurl(网络)
# 与 libxml2,runtime 镜像里必须有,否则启动即 libcurl.so.4 not found。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates libcurl4 libxml2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/.build/release/voxai-mcp /usr/local/bin/voxai-mcp
ENTRYPOINT ["/usr/local/bin/voxai-mcp"]
