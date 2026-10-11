FROM debian:12.15-slim AS ch2.2

RUN apt update
RUN apt install -y bash binutils bison gawk gcc g++ make patch perl python3 texinfo wget xz-utils

SHELL ["/bin/bash", "-c"]

FROM ch2.2 AS ch2.6
ENV LFS=/mnt/lfs

FROM ch2.6 AS ch4.2
RUN mkdir -pv $LFS/{etc,var} $LFS/usr/{bin,lib,sbin}
RUN for i in bin lib sbin; do \
  ln -sv usr/$i $LFS/$i; \
done

RUN case $(uname -m) in \
  x86_64) mkdir -pv $LFS/lib64 ;; \
esac

RUN mkdir -pv $LFS/tools
RUN mkdir -pv /work

FROM ch4.2 AS ch4.3
RUN groupadd lfs
RUN useradd -s /bin/bash -g lfs -m -k /dev/null lfs
RUN chown -v lfs $LFS/{usr{,/*},var,etc,tools} /work
RUN case $(uname -m) in \
  x86_64) chown -v lfs $LFS/lib64 ;; \
esac

USER lfs
FROM ch4.3 AS ch4.4
ENV LC_ALL=POSIX
ENV LFS_TGT=x86_64-lfs-linux-gnu
ENV PATH=$LFS/tools/bin:/bin:/usr/bin
ENV CONFIG_SITE=$LFS/usr/share/config.site
ENV MAKEFLAGS=-j4

FROM ch4.4 AS ch5.2
ARG BINUTILS_VERSION=2.47
WORKDIR /work
RUN wget https://sourceware.org/pub/binutils/releases/binutils-${BINUTILS_VERSION}.tar.xz
RUN tar -xf binutils-${BINUTILS_VERSION}.tar.xz
WORKDIR /work/binutils-${BINUTILS_VERSION}
RUN mkdir -pv build-pass1
WORKDIR /work/binutils-${BINUTILS_VERSION}/build-pass1
RUN ../configure --prefix=$LFS/tools \
    --with-sysroot=$LFS \
    --target=$LFS_TGT   \
    --disable-nls       \
    --enable-gprofng=no \
    --disable-werror    \
    --enable-new-dtags  \
    --enable-default-hash-style=gnu
RUN make
RUN make install

FROM ch5.2 AS ch5.3
WORKDIR /work
ARG GCC_VERSION=16.2.0
ARG MPFR_VERSION=4.2.2
ARG MPC_VERSION=1.4.1
ARG GMP_VERSION=6.3.0
RUN wget https://ftpmirror.gnu.org/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
RUN wget https://ftpmirror.gnu.org/mpfr/mpfr-${MPFR_VERSION}.tar.xz
RUN wget https://ftpmirror.gnu.org/mpc/mpc-${MPC_VERSION}.tar.xz
RUN wget https://ftpmirror.gnu.org/gmp/gmp-${GMP_VERSION}.tar.xz
RUN tar -xf gcc-${GCC_VERSION}.tar.xz
WORKDIR /work/gcc-${GCC_VERSION}
RUN tar -xf ../mpfr-${MPFR_VERSION}.tar.xz
RUN mv -v mpfr-${MPFR_VERSION} mpfr
RUN tar -xf ../mpc-${MPC_VERSION}.tar.xz
RUN mv -v mpc-${MPC_VERSION} mpc
RUN tar -xf ../gmp-${GMP_VERSION}.tar.xz
RUN mv -v gmp-${GMP_VERSION} gmp
RUN sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
RUN mkdir -pv build-pass1
WORKDIR /work/gcc-${GCC_VERSION}/build-pass1
RUN ../configure                  \
    --target=$LFS_TGT         \
    --prefix=$LFS/tools       \
    --with-glibc-version=2.44 \
    --with-sysroot=$LFS       \
    --with-newlib             \
    --without-headers         \
    --enable-default-pie      \
    --enable-default-ssp      \
    --disable-fixincludes     \
    --disable-nls             \
    --disable-shared          \
    --disable-multilib        \
    --disable-threads         \
    --disable-libatomic       \
    --disable-libgomp         \
    --disable-libquadmath     \
    --disable-libssp          \
    --disable-libvtv          \
    --disable-libstdcxx       \
    --enable-languages=c,c++
RUN make
RUN make install
RUN cat ../gcc/{limitx,glimits,limity}.h > $($LFS_TGT-gcc -print-file-name=include)/limits.h