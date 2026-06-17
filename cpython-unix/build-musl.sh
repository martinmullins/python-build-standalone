#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -ex

cd /build

export PATH=/tools/${TOOLCHAIN}/bin:/tools/host/bin:$PATH
export CC=clang

tar -xf "musl-${MUSL_VERSION}.tar.gz"

pushd "musl-${MUSL_VERSION}"

# Debian as of at least bullseye ships musl 1.2.1. musl 1.2.2
# added reallocarray(), which gets used by at least OpenSSL.
# Here, we disable this single function so as to not introduce
# symbol dependencies on clients using an older musl version.
if [ "${MUSL_VERSION}" = "1.2.2" ]; then
    patch -p1 <<EOF
diff --git a/include/stdlib.h b/include/stdlib.h
index b54a051f..194c2033 100644
--- a/include/stdlib.h
+++ b/include/stdlib.h
@@ -145,7 +145,6 @@ int getloadavg(double *, int);
 int clearenv(void);
 #define WCOREDUMP(s) ((s) & 0x80)
 #define WIFCONTINUED(s) ((s) == 0xffff)
-void *reallocarray (void *, size_t, size_t);
 #endif
 
 #ifdef _GNU_SOURCE
diff --git a/src/malloc/reallocarray.c b/src/malloc/reallocarray.c
deleted file mode 100644
index 4a6ebe46..00000000
--- a/src/malloc/reallocarray.c
+++ /dev/null
@@ -1,13 +0,0 @@
-#define _BSD_SOURCE
-#include <errno.h>
-#include <stdlib.h>
-
-void *reallocarray(void *ptr, size_t m, size_t n)
-{
-	if (n && m > -1 / n) {
-		errno = ENOMEM;
-		return 0;
-	}
-
-	return realloc(ptr, m * n);
-}
EOF
else
    # There is a different patch for newer musl versions, used in static distributions
    patch -p1 <<EOF
diff --git a/include/stdlib.h b/include/stdlib.h
index b507ca3..8259e27 100644
--- a/include/stdlib.h
+++ b/include/stdlib.h
@@ -147,7 +147,6 @@ int getloadavg(double *, int);
 int clearenv(void);
 #define WCOREDUMP(s) ((s) & 0x80)
 #define WIFCONTINUED(s) ((s) == 0xffff)
-void *reallocarray (void *, size_t, size_t);
 void qsort_r (void *, size_t, size_t, int (*)(const void *, const void *, void *), void *);
 #endif
 
diff --git a/src/malloc/reallocarray.c b/src/malloc/reallocarray.c
deleted file mode 100644
index 4a6ebe4..0000000
--- a/src/malloc/reallocarray.c
+++ /dev/null
@@ -1,13 +0,0 @@
-#define _BSD_SOURCE
-#include <errno.h>
-#include <stdlib.h>
-
-void *reallocarray(void *ptr, size_t m, size_t n)
-{
-	if (n && m > -1 / n) {
-		errno = ENOMEM;
-		return 0;
-	}
-
-	return realloc(ptr, m * n);
-}
EOF
fi

SHARED=
if [ -n "${STATIC}" ]; then
    SHARED="--disable-shared"
else
    SHARED="--enable-shared"
    CFLAGS="${CFLAGS} -fPIC" CPPFLAGS="${CPPFLAGS} -fPIC"
fi


CONFIGURE_TARGET=""
if [[ "${TARGET_TRIPLE:-}" == i686-* ]]; then
    CFLAGS="${CFLAGS} -m32"
    CPPFLAGS="${CPPFLAGS} -m32"
    CONFIGURE_TARGET="--target i686-linux-musl"

    # Patch ld.musl-clang.in to inject libgcc.a and libatomic.a AFTER -lc in
    # every linker exec line. The LLVM toolchain defaults to compiler-rt so
    # clang never emits -lgcc; the standard handler never fires.
    # libgcc.a must come after -lc: libc.a internally references __divdi3,
    # __moddi3, __udivdi3, etc. — if libgcc.a precedes -lc, GNU ld has already
    # passed it by the time those undefined refs appear.
    # libatomic.a is needed for 64-bit atomic ops (__atomic_store, etc.) which
    # cannot be done inline on 32-bit x86 (e.g. used by OpenSSL threads_pthread.c).
    # Both the dynamic (-dynamic-linker) and static (no dynamic linker) exec
    # lines are patched to cover both shared and lto+static build variants.
    {
        while IFS= read -r line; do
            if [[ "$line" == *'exec $($cc -print-prog-name=ld) -nostdlib "$@" -lc -dynamic-linker "$ldso"'* ]]; then
                echo 'lgcc=; test -f "$libc_lib/libgcc.a" && lgcc="$libc_lib/libgcc.a"'
                echo 'latomic=; test -f "$libc_lib/libatomic.a" && latomic="$libc_lib/libatomic.a"'
                echo 'exec $($cc -print-prog-name=ld) -nostdlib "$@" -lc $lgcc $latomic -dynamic-linker "$ldso"'
            elif [[ "$line" == *'exec $($cc -print-prog-name=ld) -nostdlib "$@" -lc'* ]]; then
                echo 'lgcc=; test -f "$libc_lib/libgcc.a" && lgcc="$libc_lib/libgcc.a"'
                echo 'latomic=; test -f "$libc_lib/libatomic.a" && latomic="$libc_lib/libatomic.a"'
                echo 'exec $($cc -print-prog-name=ld) -nostdlib "$@" -lc $lgcc $latomic'
            else
                echo "$line"
            fi
        done < tools/ld.musl-clang.in
    } > tools/ld.musl-clang.in.new
    mv tools/ld.musl-clang.in.new tools/ld.musl-clang.in
fi

CFLAGS="${CFLAGS}" CPPFLAGS="${CPPFLAGS}" ./configure \
    --prefix=/tools/host \
    ${CONFIGURE_TARGET} \
    "${SHARED}"

make -j "$(nproc)"
make -j "$(nproc)" install DESTDIR=/build/out

if [[ "${TARGET_TRIPLE:-}" == i686-* ]]; then
    # Bundle GCC's 32-bit libgcc.a and libatomic.a into the musl toolchain so
    # ld.musl-clang can resolve 64-bit arithmetic and atomic helpers when
    # linking i686 binaries (no gcc-multilib in the build container).
    LIBGCC=$(gcc -m32 -print-file-name=libgcc.a 2>/dev/null || true)
    if [ -f "${LIBGCC}" ]; then
        cp "${LIBGCC}" /build/out/tools/host/lib/libgcc.a
    fi
    LIBATOMIC=$(gcc -m32 -print-file-name=libatomic.a 2>/dev/null || true)
    if [ -f "${LIBATOMIC}" ]; then
        cp "${LIBATOMIC}" /build/out/tools/host/lib/libatomic.a
    fi

    # Create musl-clang++ from musl-clang by switching the compiler binary from
    # clang to clang++. Without this, CXX=clang++ fails C++ preprocessor sanity
    # checks when CPPFLAGS contains -m32 (no 32-bit C++ headers on Debian), so
    # autoconf falls back to /lib/cpp which also fails.
    sed '/^cc=/s|clang$|clang++|' \
        /build/out/tools/host/bin/musl-clang \
        > /build/out/tools/host/bin/musl-clang++
    chmod +x /build/out/tools/host/bin/musl-clang++
fi

popd
