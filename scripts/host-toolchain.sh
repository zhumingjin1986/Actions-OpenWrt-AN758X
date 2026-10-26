#!/bin/bash
# SPDX-License-Identifier: MIT
#
# host 侧 go-bootstrap / golang / rustc —— 真编译，然后把安装结果打包缓存。
#
# 与「复用 runner 预装的 go / rustup」那条路的区别：
#   那条路省时间但有版本耦合（feed pin 的 rustc 与 runner stable 不一致时炸包）；
#   本脚本是老老实实跑 make <pkg>/host/compile，编出的就是 feed 指定的版本，
#   再把 staging_dir 里的安装结果打包进缓存（actions/cache + Release 双通道，
#   与项目已有的工具链缓存同一套机制）。
#
# 为什么缓存 staging 而不是 build_dir：
#   build_dir/host/rust-<ver> 编完动辄 5~10 GB，GitHub 单条缓存上限 10 GB、
#   仓库总配额 10 GB，存不下。而 make 判断要不要重编看的是
#   staging_dir/host/stamp/.<pkg>_installed 这一组 stamp，不是 build_dir 在不在。
#   所以只打包「stamp + 装进 staging_dir/host 的二进制与库」，build_dir 不要。
#   万一哪次真被判成要重编，源码包还在 dl 缓存里，会自动重编，不会出错。
#
# 子命令（都在源码树根目录执行）：
#   key     算缓存 key，写 HOST_CACHE_KEY / HOST_CACHE_PREFIX / HAS_GO / HAS_RUST 到 GITHUB_OUTPUT
#   build   真编译 host 侧 go(-bootstrap) / rust
#   pack    把 host 产物打成 <KEY>.tzst 放进 $HOST_CACHE_DIR
#   unpack  把 <KEY>.tzst 解回源码树，并 touch stamp 让 make 认定已装
#   status  打印 host go / rustc 版本到 build-reports
#
# 环境变量：
#   HOST_CACHE_DIR        缓存目录（放 tzst），默认 /workdir/hosttool-cache
#   HOST_INCLUDE_BUILDDIR true 时连 build_dir/host 一起打包（默认 false，太大）
#   JOBS                  并发数，默认 nproc

set -uo pipefail

SUBCMD="${1:-status}"
OPENWRT_DIR="${2:-$PWD}"

cd "$OPENWRT_DIR" || { echo "::error::进不去 $OPENWRT_DIR" >&2; exit 1; }

HOST_CACHE_DIR="${HOST_CACHE_DIR:-/workdir/hosttool-cache}"
HOST_INCLUDE_BUILDDIR="${HOST_INCLUDE_BUILDDIR:-false}"
JOBS="${JOBS:-$(nproc)}"
REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"

mkdir -p "$HOST_CACHE_DIR" "$REPORT_DIR"

# ---------------------------------------------------------------
# 包探测：feed 装好后符号链接在 package/feeds/<feed>/<pkg>
# ---------------------------------------------------------------
probe_pkg() {  # $1=包名 → 输出 package/ 下的相对路径
  local rel
  rel=$(ls -d package/feeds/*/"$1" 2>/dev/null | head -1)
  [ -n "$rel" ] && printf '%s' "${rel#package/}"
}

pkg_version_mk() {  # $1=Makefile 路径 → GO_VERSION 优先，其次 PKG_VERSION
  [ -f "$1" ] || return 0
  sed -n 's/^GO_VERSION:=[[:space:]]*//p' "$1" 2>/dev/null | head -1 | tr -d '"'
}

# ---------------------------------------------------------------
# 让 make 自己展开变量。
#
#   踩过的坑：golang 的 Makefile 里写的是
#     GO_VERSION:=$(GO_DEFAULT_VERSION)
#   直接 sed 取出来是字面量 "$(GO_DEFAULT_VERSION)"；它原样进了缓存 key，
#   再被 workflow 塞回 shell（KEY="...-go$(GO_DEFAULT_VERSION)-..."），
#   bash 当场当成命令替换执行 → GO_DEFAULT_VERSION: command not found。
#
#   所以：先让 make 展开，取不到再退回 sed 字面量，最后由 sanitize 兜底。
# ---------------------------------------------------------------
make_var() {  # $1=Makefile 路径 $2=变量名
  local mk="$1" var="$2" tmp
  [ -f "$mk" ] || return 0
  tmp=$(mktemp)
  # ⚠ 两个讲究：
  #   1) 配方行必须以真实 TAB 开头，所以整段用 cat heredoc 写，
  #      不用 printf（printf 会把 \n 解释成真换行，把配方行劈成两截）；
  #   2) $(VAR) 外面套单引号：make 展开后交给 shell 打印时，
  #      单引号能挡住值里的反引号 / $() 被 shell 再执行一次
  #      （实测过：写成 echo "$(VAR)" 的话，值里的 `cmd` 会被真跑）。
  cat > "$tmp" <<MAKE
include $mk
ci-print:
	@printf '%s\n' '\$($var)'
MAKE
  make --no-print-directory -s -f "$tmp" TOPDIR="$PWD" ci-print 2>/dev/null | head -1
  rm -f "$tmp"
}

# key 只接受 [A-Za-z0-9._-]，其余一律换成下划线。
# 这是最后一道保险：不管上游 Makefile 写出什么花样（含 $() 、反引号、
# 空格、引号），都不会变成 shell 语法被 workflow 里的 KEY="..." 执行。
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# GO_REL / RUST_REL 是相对 package/ 的路径（make target 用）；
# 读版本与算 hash 要的是绝对路径，两者别混用。
GO_REL=$(probe_pkg golang)
RUST_REL=$(probe_pkg rust)
GO_BOOT_REL=$(probe_pkg golang-bootstrap)

# 包还没 install 到 package/feeds 时，退回 feed 源码里的 Makefile
FEED_GO_MK=$(find feeds -maxdepth 5 -type f -path "*lang/golang/golang/Makefile" 2>/dev/null | head -1)
FEED_RUST_MK=$(find feeds -maxdepth 5 -type f -path "*lang/rust/Makefile" 2>/dev/null | head -1)

GO_MK="${GO_REL:+package/$GO_REL/Makefile}"
RUST_MK="${RUST_REL:+package/$RUST_REL/Makefile}"
[ -n "$GO_MK" ] || GO_MK="$FEED_GO_MK"
[ -n "$RUST_MK" ] || RUST_MK="$FEED_RUST_MK"

# 先让 make 展开（能解析 GO_VERSION:=$(GO_DEFAULT_VERSION) 这类间接定义），
# 展开不出来（Makefile 顶部 include 一堆 rules.mk 时常见）再退回 sed 字面量。
GO_VER=$(make_var "$GO_MK" GO_VERSION)
RUST_VER=$(make_var "$RUST_MK" PKG_VERSION)
[ -n "$GO_VER" ] || GO_VER=$(pkg_version_mk "$GO_MK")
[ -n "$RUST_VER" ] || RUST_VER=$(sed -n 's/^PKG_VERSION:=[[:space:]]*//p' "$RUST_MK" 2>/dev/null | head -1 | tr -d '"')

# 展开出来还是含 $() 的（说明 make 也没解析出来）→ 不硬猜，标 unknown。
# 版本只影响 key 的可读部分，Makefile 的 md5 已经在 hash 里，
# 版本真变了 key 照样会变，不会复用错缓存。
case "$GO_VER"   in *'$('*|'' ) GO_VER=unknown   ;; esac
case "$RUST_VER" in *'$('*|'' ) RUST_VER=unknown ;; esac

# ★ 强制白名单：这是防「$(...) 被 workflow 的 KEY="..." 当命令执行」的最后一道
GO_VER=$(sanitize "$GO_VER")
RUST_VER=$(sanitize "$RUST_VER")

HAS_GO=$([ -n "$GO_REL" ] && echo true || echo false)
HAS_RUST=$([ -n "$RUST_REL" ] && echo true || echo false)

out() { # 同时写 GITHUB_OUTPUT（CI 里）和 stdout
  echo "$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"
}

case "$SUBCMD" in

# ---------------------------------------------------------------
key)
  TARGET=$(sed -n 's/^CONFIG_TARGET_BOARD="\(.*\)"$/\1/p' .config 2>/dev/null | head -1)
  SUBTARGET=$(sed -n 's/^CONFIG_TARGET_SUBTARGET="\(.*\)"$/\1/p' .config 2>/dev/null | head -1)
  [ -n "$TARGET" ] || TARGET="unknown"

  # 版本 + 包 Makefile + host 编译器版本 → 任一变化都换 key，避免复用错版本
  HASH_SRC="$(md5sum "$GO_MK" 2>/dev/null)"
  HASH_SRC="$HASH_SRC$(md5sum "$RUST_MK" 2>/dev/null)"
  HASH_SRC="$HASH_SRC$(md5sum "${GO_MK%/Makefile}/Config.in" "${RUST_MK%/Makefile}/Config.in" 2>/dev/null)"
  HASH_SRC="$HASH_SRC$(gcc --version 2>/dev/null | head -1)"
  HASH_SRC="$HASH_SRC$(g++ --version 2>/dev/null | head -1)"
  HASH_SRC="$HASH_SRC$TARGET$SUBTARGET$HOST_INCLUDE_BUILDDIR"
  HASH=$(printf '%s' "$HASH_SRC" | md5sum | cut -d' ' -f1)

  GO_TAG=$(printf '%s' "$GO_VER" | tr '.' '_')
  RUST_TAG=$(printf '%s' "$RUST_VER" | tr '.' '_')

  # 整串再过一遍白名单：TARGET/SUBTARGET 来自 .config，理论上干净，
  # 但多一道不亏 —— 这个 KEY 会被 workflow 直接插进 KEY="..." 里。
  KEY=$(sanitize "ponwrt-hosttools-${TARGET}-${SUBTARGET}-go${GO_TAG}-rs${RUST_TAG}-${HASH:0:16}")
  PREFIX=$(sanitize "ponwrt-hosttools-${TARGET}-${SUBTARGET}")

  out "HOST_CACHE_KEY=$KEY"
  out "HOST_CACHE_PREFIX=$PREFIX"
  out "HAS_GO=$HAS_GO"
  out "HAS_RUST=$HAS_RUST"
  out "GO_VER=$GO_VER"
  out "RUST_VER=$RUST_VER"
  echo "========================================"
  echo "host 缓存 Key : $KEY"
  echo "  golang=$GO_VER ($HAS_GO)  rust=$RUST_VER ($HAS_RUST)"
  echo "========================================"
  ;;

# ---------------------------------------------------------------
build)
  FAIL=0
  compile_host() { # $1=显示名 $2=package/相对路径
    local name="$1" rel="$2"
    if [ -z "$rel" ]; then
      echo "::warning::$name 不在 package/feeds 下，跳过 host 编译"
      return 0
    fi
    echo "===== make package/$rel/host/compile ($JOBS 线程) ====="
    if make "package/$rel/host/compile" -j"$JOBS"; then
      echo "✅ $name host 编译完成"
    elif make "package/$rel/host/compile" -j1 V=s; then
      echo "✅ $name host 编译完成（单线程重试）"
    else
      echo "::warning::$name host 编译失败；不写缓存，后续 make 会再试一次"
      FAIL=1
    fi
  }

  # bootstrap 只在 CONFIG_GOLANG_BUILD_BOOTSTRAP=y 时才有意义，
  # 但包在树里就先编，make 自己会按依赖决定要不要用
  [ -n "$GO_BOOT_REL" ] && compile_host "golang-bootstrap" "$GO_BOOT_REL"
  [ "$HAS_GO" = "true" ] && compile_host "golang" "$GO_REL"
  [ "$HAS_RUST" = "true" ] && compile_host "rust" "$RUST_REL"

  if [ "$FAIL" != "0" ]; then
    echo "host_build_failed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  else
    echo "host_build_failed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  fi
  ;;

# ---------------------------------------------------------------
pack)
  KEY="${HOST_CACHE_KEY:-}"
  [ -n "$KEY" ] || { echo "::error::缺 HOST_CACHE_KEY" >&2; exit 1; }

  # 只收存在的文件：缺哪个都不让 tar 失败
  LIST=$(mktemp)
  # 1) stamp —— 决定下次 make 会不会重编，最重要
  find staging_dir/host/stamp -maxdepth 1 -type f \
       \( -name '.golang*' -o -name '.rust*' -o -name '.go-bootstrap*' \) 2>/dev/null >> "$LIST"
  # 2) 装进 host 的二进制与库
  for f in staging_dir/host/bin/go staging_dir/host/bin/gofmt \
           staging_dir/host/bin/rustc staging_dir/host/bin/cargo \
           staging_dir/host/bin/rustdoc; do
    [ -e "$f" ] && echo "$f" >> "$LIST"
  done
  find staging_dir/host/lib -maxdepth 1 \( -name 'go' -o -name 'go-*' -o -name 'rustlib' \) 2>/dev/null >> "$LIST"
  find staging_dir/host/libexec -maxdepth 1 -name 'gcc-*' 2>/dev/null >> "$LIST"
  # 3) 可选：build_dir（默认关，rust 的构建树太大）
  if [ "$HOST_INCLUDE_BUILDDIR" = "true" ]; then
    find build_dir/host -maxdepth 1 \( -name 'golang*' -o -name 'go-bootstrap*' -o -name 'rust*' \) 2>/dev/null >> "$LIST"
  fi

  if [ ! -s "$LIST" ]; then
    echo "::warning::没有任何 host 产物可打包（go/rust 都没编出来？）"
    rm -f "$LIST"
    exit 0
  fi

  echo "打包 $(wc -l < "$LIST") 个条目："
  sed 's/^/  /' "$LIST"

  TARBALL="$HOST_CACHE_DIR/${KEY}.tzst"
  rm -f "$TARBALL"
  if tar -I zstdmt -cf "$TARBALL" -T "$LIST"; then
    ls -lh "$TARBALL"
    echo "packed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  else
    echo "::warning::打包失败，本次不缓存 host 工具链"
    rm -f "$TARBALL"
    echo "packed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  fi
  rm -f "$LIST"
  ;;

# ---------------------------------------------------------------
unpack)
  KEY="${HOST_CACHE_KEY:-}"
  [ -n "$KEY" ] || { echo "::error::缺 HOST_CACHE_KEY" >&2; exit 1; }
  TARBALL="$HOST_CACHE_DIR/${KEY}.tzst"
  if [ ! -f "$TARBALL" ]; then
    echo "restored=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "::warning::$TARBALL 不存在"
    exit 0
  fi
  which unzstd >/dev/null 2>&1 || sudo -E apt-get -yqq install zstd >/dev/null 2>&1 || true

  if ! tar -I unzstd -xf "$TARBALL"; then
    echo "unpacked=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "::warning::host 工具链解压失败，将走真实编译"
    exit 0
  fi

  # tar 会还原 mtime，但解压后 stamp 相对 feeds/Makefile 的新旧关系不保证，
  # 统一 touch 一遍，确保 make 认定 host 包已装、不再重编。
  find staging_dir/host/stamp -maxdepth 1 -type f \
       \( -name '.golang*' -o -name '.rust*' -o -name '.go-bootstrap*' \) \
       -exec touch {} + 2>/dev/null || true

  # 解出来却没有任何 host 二进制 = 这份缓存是空的，别让 make 以为装好了
  if ! ls staging_dir/host/bin/go staging_dir/host/bin/rustc >/dev/null 2>&1; then
    echo "unpacked=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "::warning::解压后 staging_dir/host/bin 里没有 go / rustc，视为无效缓存"
    exit 0
  fi

  echo "unpacked=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "✅ host 工具链已从缓存恢复"
  ;;

# ---------------------------------------------------------------
status)
  {
    echo "golang: $GO_VER ($HAS_GO)"
    echo "rust:   $RUST_VER ($HAS_RUST)"
    for b in go gofmt rustc cargo rustdoc; do
      if [ -e "staging_dir/host/bin/$b" ]; then
        printf '%-8s %s\n' "$b" "$(staging_dir/host/bin/$b --version 2>&1 | head -1)"
      fi
    done
  } | tee "$REPORT_DIR/host-toolchain.txt"
  ;;

*)
  echo "用法: $0 {key|build|pack|unpack|status} [源码树]" >&2
  exit 2
  ;;
esac
