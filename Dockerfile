# avoid conflict with builtin var BASH_VERSION
ARG BASH_VERSION_=5.3 
ARG BINUTILS_VERSION=2.47
ARG COREUTILS_VERSION=9.11
ARG GCC_VERSION=16.2.0
ARG GLIBC_VERSION=2.44
ARG GMP_VERSION=6.3.0
ARG LINUX_MAJOR=7
ARG LINUX_VERSION=${LINUX_MAJOR}.1.8
ARG MPC_VERSION=1.4.1
ARG MPFR_VERSION=4.2.2
ARG M4_VERSION=1.4.21
ARG NCURSES_VERSION=6.6
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
ENV MAKEFLAGS=-j7

FROM ch4.4 AS ch5.2
WORKDIR /work
ARG BINUTILS_VERSION
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
ARG GCC_VERSION
ARG MPFR_VERSION
ARG MPC_VERSION
ARG GMP_VERSION
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

FROM ch5.3 AS ch5.4
WORKDIR /work
ARG LINUX_MAJOR
ARG LINUX_VERSION
RUN wget https://www.kernel.org/pub/linux/kernel/v${LINUX_MAJOR}.x/linux-${LINUX_VERSION}.tar.xz
RUN tar -xf linux-${LINUX_VERSION}.tar.xz
WORKDIR /work/linux-${LINUX_VERSION}
RUN make headers
RUN find usr/include -type f ! -name '*.h' -delete
RUN cp -rv usr/include $LFS/usr

FROM ch5.4 AS ch5.5
WORKDIR /work
ARG GLIBC_VERSION
RUN wget https://ftpmirror.gnu.org/glibc/glibc-${GLIBC_VERSION}.tar.xz
RUN wget https://www.linuxfromscratch.org/patches/lfs/13.1/glibc-fhs-1.patch
RUN wget https://www.linuxfromscratch.org/patches/lfs/13.1/glibc-${GLIBC_VERSION}-upstream_fixes-1.patch
RUN tar -xf glibc-${GLIBC_VERSION}.tar.xz
WORKDIR /work/glibc-${GLIBC_VERSION}
RUN ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
RUN ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
RUN patch -Np1 -i ../glibc-fhs-1.patch
RUN patch -Np1 -i ../glibc-2.44-upstream_fixes-1.patch
RUN mkdir -v build
WORKDIR /work/glibc-${GLIBC_VERSION}/build
RUN echo "rootsbindir=/usr/sbin" > configparms
RUN ../configure                        \
    --prefix=/usr                       \
    --host=$LFS_TGT                     \
    --build=$(../scripts/config.guess)  \
    --disable-nscd                      \
    libc_cv_slibdir=/usr/lib            \
    --enable-kernel=5.10
RUN make
RUN make DESTDIR=$LFS install
RUN sed '/RTLDLIST=/s@/usr@@g' -i $LFS/usr/bin/ldd
# test
RUN echo 'int main(){}' | $LFS_TGT-gcc -x c - -v -Wl,--verbose &> dummy.log
RUN $LFS_TGT-readelf -l a.out | grep ': /lib'
RUN rm a.out dummy.log

FROM ch5.5 AS ch5.6
WORKDIR /work
ARG GCC_VERSION
WORKDIR /work/gcc-${GCC_VERSION}
RUN mkdir -pv build-pass1-libstdc++
WORKDIR /work/gcc-${GCC_VERSION}/build-pass1-libstdc++
RUN ../libstdc++-v3/configure   \
    --host=$LFS_TGT             \
    --build=$(../config.guess)  \
    CXX=$LFS_TGT-gcc            \
    --prefix=/usr               \
    --disable-multilib          \
    --disable-nls               \
    --disable-libstdcxx-pch     \
    --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/16.2.0
RUN make
RUN make DESTDIR=$LFS install
RUN rm -v $LFS/usr/lib/lib{stdc++{,exp,fs},supc++}.la

FROM ch5.6 AS ch6.2
WORKDIR /work
ARG M4_VERSION
RUN wget https://ftpmirror.gnu.org/m4/m4-${M4_VERSION}.tar.xz
RUN echo ac_cv_func_posix_spawn_file_actions_addchdir=yes >> $LFS/usr/share/config.site
RUN echo ac_cv_func_posix_spawn_file_actions_addfchdir=yes >> $LFS/usr/share/config.site
RUN tar -xf m4-${M4_VERSION}.tar.xz
WORKDIR /work/m4-${M4_VERSION}
RUN ./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
RUN make
RUN make DESTDIR=$LFS install

FROM ch6.2 AS ch6.3
WORKDIR /work
ARG NCURSES_VERSION
RUN wget https://invisible-mirror.net/archives/ncurses/ncurses-${NCURSES_VERSION}.tar.gz
RUN tar -xf ncurses-${NCURSES_VERSION}.tar.gz
WORKDIR /work/ncurses-${NCURSES_VERSION}
RUN mkdir -pv build
WORKDIR /work/ncurses-${NCURSES_VERSION}/build
RUN ../configure --prefix=$LFS/tools AWK=gawk
RUN make -C include
RUN make -C progs tic
RUN install progs/tic $LFS/tools/bin
WORKDIR /work/ncurses-${NCURSES_VERSION}
RUN ./configure --prefix=/usr       \
    --host=$LFS_TGT                 \
    --build=$(./config.guess)       \
    --mandir=/usr/share/man         \
    --with-manpage-format=normal    \
    --with-shared                   \
    --without-normal                \
    --with-cxx-shared               \
    --without-debug                 \
    --without-ada                   \
    --disable-stripping             \
    AWK=gawk
RUN make
RUN make DESTDIR=$LFS install
RUN ln -sv libncursesw.so $LFS/usr/lib/libncurses.so
RUN sed -e 's/^#if.*XOPEN.*$/#if 1/' -i $LFS/usr/include/curses.h

FROM ch6.3 AS ch6.4
WORKDIR /work
ARG BASH_VERSION_
RUN wget https://ftpmirror.gnu.org/bash/bash-${BASH_VERSION_}.tar.gz
RUN tar -xf bash-${BASH_VERSION_}.tar.gz
WORKDIR /work/bash-${BASH_VERSION_}
RUN ./configure --prefix=/usr           \
    --build=$(sh support/config.guess)  \
    --host=$LFS_TGT                     \
    --without-bash-malloc               \
    --docdir=/usr/share/doc/bash-5.3
RUN make
RUN make DESTDIR=$LFS install

FROM ch6.4 AS ch6.5
WORKDIR /work
ARG COREUTILS_VERSION
RUN wget https://ftpmirror.gnu.org/coreutils/coreutils-${COREUTILS_VERSION}.tar.xz
RUN tar -xf coreutils-${COREUTILS_VERSION}.tar.xz
WORKDIR /work/coreutils-${COREUTILS_VERSION}
RUN ./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(build-aux/config.guess)   \
    --enable-install-program=hostname
RUN make
RUN make DESTDIR=$LFS install
RUN mv -v $LFS/usr/bin/chroot              $LFS/usr/sbin
RUN mkdir -pv $LFS/usr/share/man/man8
RUN mv -v $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
RUN sed -i 's/"1"/"8"/'                    $LFS/usr/share/man/man8/chroot.8