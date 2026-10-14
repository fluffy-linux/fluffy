# avoid conflict with builtin var BASH_VERSION
ARG BASH_VERSION_=5.3
ARG BINUTILS_VERSION=2.47
ARG BISON_VERSION=3.8.2
ARG COREUTILS_VERSION=9.11
ARG DIFFUTILS_VERSION=3.12
ARG FILE_VERSION=5.48
ARG FINDUTILS_VERSION=4.11.0
ARG GAWK_VERSION=5.4.1
ARG GCC_VERSION=16.2.0
ARG GETTEXT_VERSION=1.0
ARG GLIBC_VERSION=2.44
ARG GMP_VERSION=6.3.0
ARG GREP_VERSION=3.12
ARG GZIP_VERSION=1.14
ARG IANA_ETC_VERSION=20260805
ARG LINUX_MAJOR=7
ARG LINUX_VERSION=${LINUX_MAJOR}.1.8
ARG MAKE_VERSION=4.4.1
ARG MAN_PAGES_VERSION=6.18
ARG MPC_VERSION=1.4.1
ARG MPDECIMAL_VERSION=4.0.1
ARG MPFR_VERSION=4.2.2
ARG M4_VERSION=1.4.21
ARG NCURSES_VERSION=6.6
ARG PATCH_VERSION=2.8
ARG PERL_MAJOR_MINOR_VERSION=5.44
ARG PERL_VERSION=${PERL_MAJOR_MINOR_VERSION}.0
ARG PYTHON_VERSION=3.14.7
ARG SED_VERSION=4.10
ARG TAR_VERSION=1.35
ARG TEXINFO_VERSION=7.3
ARG UTIL_LINUX_VERSION=2.42.2
ARG XZ_VERSION=5.8.3
ARG ZLIB_VERSION=1.3.2

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
COPY --from=ch4.4 --link $LFS $LFS
WORKDIR /work
ARG BINUTILS_VERSION
COPY --chown=lfs packages/binutils-${BINUTILS_VERSION}.tar.xz binutils-${BINUTILS_VERSION}.tar.xz
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

FROM ch4.4 AS ch5.3
COPY --from=ch5.2 --link $LFS $LFS
WORKDIR /work
ARG GLIBC_VERSION
ARG GCC_VERSION
ARG MPFR_VERSION
ARG MPC_VERSION
ARG GMP_VERSION
COPY --chown=lfs packages/gcc-${GCC_VERSION}.tar.xz gcc-${GCC_VERSION}.tar.xz
COPY --chown=lfs packages/mpfr-${MPFR_VERSION}.tar.xz mpfr-${MPFR_VERSION}.tar.xz
COPY --chown=lfs packages/mpc-${MPC_VERSION}.tar.xz mpc-${MPC_VERSION}.tar.xz
COPY --chown=lfs packages/gmp-${GMP_VERSION}.tar.xz gmp-${GMP_VERSION}.tar.xz
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
    --with-glibc-version=${GLIBC_VERSION} \
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
RUN cat ../gcc/{limitx,glimits,limity}.h  > $($LFS_TGT-gcc -print-file-name=include)/limits.h

FROM ch4.4 AS ch5.4
COPY --from=ch5.3 --link $LFS $LFS
WORKDIR /work
ARG LINUX_MAJOR
ARG LINUX_VERSION
COPY --chown=lfs packages/linux-${LINUX_VERSION}.tar.xz linux-${LINUX_VERSION}.tar.xz
RUN tar -xf linux-${LINUX_VERSION}.tar.xz
WORKDIR /work/linux-${LINUX_VERSION}
RUN make mrproper
RUN make headers
RUN find usr/include -type f ! -name '*.h' -delete
RUN cp -rv usr/include $LFS/usr

FROM ch4.4 AS ch5.5
COPY --from=ch5.4 --link $LFS $LFS
WORKDIR /work
ARG GLIBC_VERSION
COPY --chown=lfs packages/glibc-${GLIBC_VERSION}.tar.xz glibc-${GLIBC_VERSION}.tar.xz
COPY --chown=lfs packages/glibc-fhs-1.patch glibc-fhs-1.patch
COPY --chown=lfs packages/glibc-${GLIBC_VERSION}-upstream_fixes-1.patch glibc-${GLIBC_VERSION}-upstream_fixes-1.patch
RUN tar -xf glibc-${GLIBC_VERSION}.tar.xz
WORKDIR /work/glibc-${GLIBC_VERSION}
RUN ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
RUN ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
RUN patch -Np1 -i ../glibc-fhs-1.patch
RUN patch -Np1 -i ../glibc-${GLIBC_VERSION}-upstream_fixes-1.patch
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

# special case - builds off prior gcc
FROM ch5.3 AS ch5.6
COPY --from=ch5.5 --link $LFS $LFS
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

FROM ch4.4 AS ch6.2
COPY --from=ch5.6 --link $LFS $LFS
WORKDIR /work
ARG M4_VERSION
COPY --chown=lfs packages/m4-${M4_VERSION}.tar.xz m4-${M4_VERSION}.tar.xz
RUN echo ac_cv_func_posix_spawn_file_actions_addchdir=yes >> $LFS/usr/share/config.site
RUN echo ac_cv_func_posix_spawn_file_actions_addfchdir=yes >> $LFS/usr/share/config.site
RUN tar -xf m4-${M4_VERSION}.tar.xz
WORKDIR /work/m4-${M4_VERSION}
RUN ./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
RUN make
RUN make DESTDIR=$LFS install

FROM ch4.4 AS ch6.3
COPY --from=ch6.2 --link $LFS $LFS
WORKDIR /work
ARG NCURSES_VERSION
COPY --chown=lfs packages/ncurses-${NCURSES_VERSION}.tar.gz ncurses-${NCURSES_VERSION}.tar.gz
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

FROM ch4.4 AS ch6.4
COPY --from=ch6.3 --link $LFS $LFS
WORKDIR /work
ARG BASH_VERSION_
COPY --chown=lfs packages/bash-${BASH_VERSION_}.tar.gz bash-${BASH_VERSION_}.tar.gz
RUN tar -xf bash-${BASH_VERSION_}.tar.gz
WORKDIR /work/bash-${BASH_VERSION_}
RUN ./configure --prefix=/usr           \
    --build=$(sh support/config.guess)  \
    --host=$LFS_TGT                     \
    --without-bash-malloc               \
    --docdir=/usr/share/doc/bash-${BASH_VERSION_}
RUN make
RUN make DESTDIR=$LFS install
RUN ln -sv bash $LFS/bin/sh

FROM ch4.4 AS ch6.5
COPY --from=ch6.4 --link $LFS $LFS
WORKDIR /work
ARG COREUTILS_VERSION
COPY --chown=lfs packages/coreutils-${COREUTILS_VERSION}.tar.xz coreutils-${COREUTILS_VERSION}.tar.xz
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

FROM ch4.4 AS ch6.6
COPY --from=ch6.5 --link $LFS $LFS
WORKDIR /work
ARG DIFFUTILS_VERSION
COPY --chown=lfs packages/diffutils-${DIFFUTILS_VERSION}.tar.xz diffutils-${DIFFUTILS_VERSION}.tar.xz
RUN tar -xf diffutils-${DIFFUTILS_VERSION}.tar.xz
WORKDIR /work/diffutils-${DIFFUTILS_VERSION}
RUN ./configure --prefix=/usr       \
    --host=$LFS_TGT                 \
    gl_cv_func_strcasecmp_works=yes \
    --build=$(./build-aux/config.guess)
RUN make
RUN make DESTDIR=$LFS install

FROM ch4.4 AS ch6.7
COPY --from=ch6.6 --link $LFS $LFS
WORKDIR /work
ARG FILE_VERSION
COPY --chown=lfs packages/file-${FILE_VERSION}.tar.gz file-${FILE_VERSION}.tar.gz
RUN tar -xf file-${FILE_VERSION}.tar.gz
WORKDIR /work/file-${FILE_VERSION}
RUN mkdir build
WORKDIR /work/file-${FILE_VERSION}/build
RUN ../configure            \
    --disable-bzlib         \
    --disable-libseccomp    \
    --disable-xzlib         \
    --disable-zlib
RUN make
WORKDIR /work/file-${FILE_VERSION}
RUN ./configure     \
    --prefix=/usr   \
    --host=$LFS_TGT \
    --build=$(./config.guess)
RUN make FILE_COMPILE=$(pwd)/build/src/file
RUN make DESTDIR=$LFS install
RUN rm -v $LFS/usr/lib/libmagic.la

FROM ch4.4 AS ch6.8
COPY --from=ch6.7 --link $LFS $LFS
WORKDIR /work
ARG FINDUTILS_VERSION
COPY --chown=lfs packages/findutils-${FINDUTILS_VERSION}.tar.xz findutils-${FINDUTILS_VERSION}.tar.xz
RUN tar -xf findutils-${FINDUTILS_VERSION}.tar.xz
WORKDIR /work/findutils-${FINDUTILS_VERSION}
RUN ./configure --prefix=/usr       \
    --localstatedir=/var/lib/locate \
    --host=$LFS_TGT                 \
    --build=$(build-aux/config.guess)
RUN make
RUN make DESTDIR=$LFS install

FROM ch4.4 AS ch6.9
COPY --from=ch6.8 --link $LFS $LFS
WORKDIR /work
ARG GAWK_VERSION
COPY --chown=lfs packages/gawk-${GAWK_VERSION}.tar.xz gawk-${GAWK_VERSION}.tar.xz
RUN tar -xf gawk-${GAWK_VERSION}.tar.xz
WORKDIR /work/gawk-${GAWK_VERSION}
RUN sed -i 's/extras//' Makefile.in
RUN ./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(build-aux/config.guess)
RUN make
RUN make DESTDIR=$LFS install

FROM ch4.4 AS ch6.10
COPY --from=ch6.9 --link $LFS $LFS
WORKDIR /work
ARG GREP_VERSION
COPY --chown=lfs packages/grep-${GREP_VERSION}.tar.xz grep-${GREP_VERSION}.tar.xz
RUN tar -xf grep-${GREP_VERSION}.tar.xz
WORKDIR /work/grep-${GREP_VERSION}
RUN ./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(./build-aux/config.guess)
RUN make
RUN make DESTDIR=$LFS install

FROM ch4.4 AS ch6.11
COPY --from=ch6.10 --link $LFS $LFS
WORKDIR /work
ARG GZIP_VERSION
COPY --chown=lfs packages/gzip-${GZIP_VERSION}.tar.xz gzip-${GZIP_VERSION}.tar.xz
RUN tar -xf gzip-${GZIP_VERSION}.tar.xz
WORKDIR /work/gzip-${GZIP_VERSION}
RUN ./configure --prefix=/usr   \
    --host=$LFS_TGT
RUN make
RUN make DESTDIR=$LFS install

FROM ch4.4 AS ch6.12
COPY --from=ch6.11 --link $LFS $LFS
WORKDIR /work
ARG MAKE_VERSION
COPY --chown=lfs packages/make-${MAKE_VERSION}.tar.gz make-${MAKE_VERSION}.tar.gz
RUN tar -xf make-${MAKE_VERSION}.tar.gz
WORKDIR /work/make-${MAKE_VERSION}
RUN ./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
RUN make
RUN make DESTDIR=$LFS install

FROM ch4.4 AS ch6.13
COPY --from=ch6.12 --link $LFS $LFS
WORKDIR /work
ARG PATCH_VERSION
COPY --chown=lfs packages/patch-${PATCH_VERSION}.tar.xz patch-${PATCH_VERSION}.tar.xz
RUN tar -xf patch-${PATCH_VERSION}.tar.xz
WORKDIR /work/patch-${PATCH_VERSION}
RUN ./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
RUN make
RUN make DESTDIR=$LFS install

FROM ch4.4 AS ch6.14
COPY --from=ch6.13 --link $LFS $LFS
WORKDIR /work
ARG SED_VERSION
COPY --chown=lfs packages/sed-${SED_VERSION}.tar.xz sed-${SED_VERSION}.tar.xz
RUN tar -xf sed-${SED_VERSION}.tar.xz
WORKDIR /work/sed-${SED_VERSION}
RUN ./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(./build-aux/config.guess)
RUN make
RUN make DESTDIR=$LFS install

FROM ch4.4 AS ch6.15
COPY --from=ch6.14 --link $LFS $LFS
WORKDIR /work
ARG TAR_VERSION
COPY --chown=lfs packages/tar-${TAR_VERSION}.tar.xz tar-${TAR_VERSION}.tar.xz
RUN tar -xf tar-${TAR_VERSION}.tar.xz
WORKDIR /work/tar-${TAR_VERSION}
RUN ./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
RUN make
RUN make DESTDIR=$LFS install

FROM ch4.4 AS ch6.16
COPY --from=ch6.15 --link $LFS $LFS
WORKDIR /work
ARG XZ_VERSION
COPY --chown=lfs packages/xz-${XZ_VERSION}.tar.xz xz-${XZ_VERSION}.tar.xz
RUN tar -xf xz-${XZ_VERSION}.tar.xz
WORKDIR /work/xz-${XZ_VERSION}
RUN ./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(build-aux/config.guess)   \
    --disable-static                    \
    --docdir=/usr/share/doc/xz-${XZ_VERSION}
RUN make
RUN make DESTDIR=$LFS install
RUN rm -v $LFS/usr/lib/liblzma.la

# binutils pass 2
FROM ch5.2 AS ch6.17
COPY --from=ch6.16 --link $LFS $LFS
ARG BINUTILS_VERSION
WORKDIR /work/binutils-${BINUTILS_VERSION}
RUN sed '6031s/$add_dir//' -i ltmain.sh
RUN mkdir -v build-pass2
WORKDIR /work/binutils-${BINUTILS_VERSION}/build-pass2
RUN ../configure                \
    --prefix=/usr               \
    --build=$(../config.guess)  \
    --host=$LFS_TGT             \
    --disable-nls               \
    --enable-shared             \
    --enable-gprofng=no         \
    --disable-werror            \
    --enable-64-bit-bfd         \
    --enable-new-dtags          \
    --enable-default-hash-style=gnu
RUN make
RUN make DESTDIR=$LFS install
RUN rm -v $LFS/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}

# gcc pass 2
FROM ch5.2 AS ch6.18
COPY --from=ch6.17 --link $LFS $LFS
WORKDIR /work
ARG GLIBC_VERSION
ARG GCC_VERSION
ARG MPFR_VERSION
ARG MPC_VERSION
ARG GMP_VERSION
COPY --chown=lfs packages/gcc-${GCC_VERSION}.tar.xz gcc-${GCC_VERSION}.tar.xz
COPY --chown=lfs packages/mpfr-${MPFR_VERSION}.tar.xz mpfr-${MPFR_VERSION}.tar.xz
COPY --chown=lfs packages/mpc-${MPC_VERSION}.tar.xz mpc-${MPC_VERSION}.tar.xz
COPY --chown=lfs packages/gmp-${GMP_VERSION}.tar.xz gmp-${GMP_VERSION}.tar.xz
RUN tar -xf gcc-${GCC_VERSION}.tar.xz
WORKDIR /work/gcc-${GCC_VERSION}
RUN tar -xf ../mpfr-${MPFR_VERSION}.tar.xz
RUN mv -v mpfr-${MPFR_VERSION} mpfr
RUN tar -xf ../mpc-${MPC_VERSION}.tar.xz
RUN mv -v mpc-${MPC_VERSION} mpc
RUN tar -xf ../gmp-${GMP_VERSION}.tar.xz
RUN mv -v gmp-${GMP_VERSION} gmp
RUN sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
RUN sed '/thread_header =/s/@.*@/gthr-posix.h/' -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
RUN mkdir -v build-pass2
WORKDIR /work/gcc-${GCC_VERSION}/build-pass2
RUN ../configure                                        \
    --build=$(../config.guess)                          \
    --host=$LFS_TGT                                     \
    --target=$LFS_TGT                                   \
    --prefix=/usr                                       \
    --with-build-sysroot=$LFS                           \
    --enable-default-pie                                \
    --enable-default-ssp                                \
    --disable-fixincludes                               \
    --disable-nls                                       \
    --disable-multilib                                  \
    --disable-libatomic                                 \
    --disable-libgomp                                   \
    --disable-libquadmath                               \
    --disable-libsanitizer                              \
    --disable-libssp                                    \
    --disable-libvtv                                    \
    --enable-languages=c,c++                            \
    CXX_FOR_TARGET="$LFS_TGT-gcc -nostdinc++"           \
    LDFLAGS_FOR_TARGET=-L$PWD/$LFS_TGT/libgcc           \
    target_configargs=gcc_cv_target_thread_file=posix

RUN make
RUN make DESTDIR=$LFS install
RUN ln -sv gcc $LFS/usr/bin/cc

FROM ch4.4 AS ch7.2
COPY --from=ch6.18 --link $LFS $LFS
USER root
RUN chown --from lfs -R root:root $LFS/{usr,var,etc,tools,lib64}

FROM scratch AS ch7.4
COPY --from=ch7.2 --link /mnt/lfs /
ENV HOME=/root
ENV PATH=/usr/bin:/usr/sbin
ENV MAKEFLAGS=-j7
ENV TESTSUITEFLAGS=-j7
SHELL ["/bin/bash", "--login", "-c"]
RUN mkdir -p /work


FROM ch7.4 AS ch7.5
RUN mkdir -pv /{boot,home,mnt,opt,srv}

RUN mkdir -pv /etc/{opt,sysconfig}
RUN mkdir -pv /lib/firmware
RUN mkdir -pv /media/{floppy,cdrom}
RUN mkdir -pv /usr/{,local/}{include,src}
RUN mkdir -pv /usr/lib/locale
RUN mkdir -pv /usr/local/{bin,lib,sbin}
RUN mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
RUN mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
RUN mkdir -pv /usr/{,local/}share/man/man{1..8}
RUN mkdir -pv /var/{cache,local,log,mail,opt,spool}
RUN mkdir -pv /var/lib/{color,misc,locate}

RUN ln -sfv /run /var/run
RUN ln -sfv /run/lock /var/lock

RUN install -dv -m 0750 /root
RUN install -dv -m 1777 /tmp /var/tmp

FROM ch7.4 AS ch7.6
COPY --from=ch7.5 --link / /
RUN ln -sv /proc/self/mounts /etc/mtab
# TODO write real /etc/hosts after export
RUN cat <<EOF >/etc/hosts.tmp
127.0.0.1  localhost $(hostname)
::1        localhost
EOF
RUN cat <<"EOF" >/etc/passwd

root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
systemd-journal-gateway:x:73:73:systemd Journal Gateway:/:/usr/bin/false
systemd-journal-remote:x:74:74:systemd Journal Remote:/:/usr/bin/false
systemd-journal-upload:x:75:75:systemd Journal Upload:/:/usr/bin/false
systemd-network:x:76:76:systemd Network Management:/:/usr/bin/false
systemd-resolve:x:77:77:systemd Resolver:/:/usr/bin/false
systemd-timesync:x:78:78:systemd Time Synchronization:/:/usr/bin/false
systemd-coredump:x:79:79:systemd Core Dumper:/:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
systemd-oom:x:81:81:systemd Out Of Memory Daemon:/:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF
RUN cat <<"EOF" >/etc/group
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
clock:x:14:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
systemd-journal:x:23:
input:x:24:
mail:x:34:
kvm:x:61:
systemd-journal-gateway:x:73:
systemd-journal-remote:x:74:
systemd-journal-upload:x:75:
systemd-network:x:76:
systemd-resolve:x:77:
systemd-timesync:x:78:
systemd-coredump:x:79:
uuidd:x:80:
systemd-oom:x:81:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF
RUN echo "tester:x:101:101::/home/tester:/bin/bash" >> /etc/passwd
RUN echo "tester:x:101:" >> /etc/group
RUN install -o tester -d /home/tester
RUN touch /var/log/{btmp,lastlog,faillog,wtmp}
RUN chgrp -v utmp /var/log/lastlog
RUN chmod -v 664  /var/log/lastlog
RUN chmod -v 600  /var/log/btmp

FROM ch7.4 AS ch7.7
WORKDIR /work
COPY --from=ch7.6 --link / /
ARG GETTEXT_VERSION
COPY --chown=lfs packages/gettext-${GETTEXT_VERSION}.tar.xz gettext-${GETTEXT_VERSION}.tar.xz
RUN tar -xf gettext-${GETTEXT_VERSION}.tar.xz
WORKDIR /work/gettext-${GETTEXT_VERSION}
RUN ./configure --disable-shared
RUN make
RUN cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin

FROM ch7.4 AS ch7.8
WORKDIR /work
COPY --from=ch7.7 --link / /
ARG BISON_VERSION
COPY packages/bison-${BISON_VERSION}.tar.xz .
RUN tar -xf bison-${BISON_VERSION}.tar.xz
WORKDIR /work/bison-${BISON_VERSION}
RUN ./configure --prefix=/usr \
    --docdir=/usr/share/doc/bison-${BISON_VERSION}
RUN make
RUN make install

FROM ch7.4 AS ch7.9
WORKDIR /work
COPY --from=ch7.8 --link / /
ARG PERL_VERSION
COPY packages/perl-${PERL_VERSION}.tar.xz .
RUN tar -xf perl-${PERL_VERSION}.tar.xz
WORKDIR /work/perl-${PERL_VERSION}
RUN sh Configure -des                               \
    -D prefix=/usr                                  \
    -D vendorprefix=/usr                            \
    -D useshrplib                                   \
    -D privlib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/core_perl        \
    -D archlib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/core_perl        \
    -D sitelib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/site_perl        \
    -D sitearch=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/site_perl       \
    -D vendorlib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/vendor_perl    \
    -D vendorarch=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/vendor_perl
RUN make
RUN make install

FROM ch7.4 AS ch7.10
WORKDIR /work
COPY --from=ch7.9 --link / /
ARG ZLIB_VERSION
COPY packages/zlib-${ZLIB_VERSION}.tar.gz .
RUN tar -xf zlib-${ZLIB_VERSION}.tar.gz
WORKDIR /work/zlib-${ZLIB_VERSION}
RUN ./configure --prefix=/usr
RUN make
RUN make install
RUN rm -fv /usr/lib/libz.a

FROM ch7.4 AS ch7.11
WORKDIR /work
COPY --from=ch7.10 --link / /
ARG MPDECIMAL_VERSION
COPY packages/mpdecimal-${MPDECIMAL_VERSION}.tar.gz .
RUN tar -xf mpdecimal-${MPDECIMAL_VERSION}.tar.gz
WORKDIR /work/mpdecimal-${MPDECIMAL_VERSION}
RUN ./configure --prefix=/usr   \
    --disable-static            \
    --docdir=/usr/share/doc/mpdecimal-${MPDECIMAL_VERSION}
RUN make
RUN make install

FROM ch7.4 AS ch7.12
WORKDIR /work
COPY --from=ch7.11 --link / /
ARG PYTHON_VERSION
COPY packages/Python-${PYTHON_VERSION}.tar.xz .
RUN tar -xf Python-${PYTHON_VERSION}.tar.xz
WORKDIR /work/Python-${PYTHON_VERSION}
RUN ./configure --prefix=/usr   \
    --enable-shared             \
    --without-ensurepip         \
    --without-static-libpython
RUN make
RUN make install

FROM ch7.4 AS ch7.13
WORKDIR /work
COPY --from=ch7.12 --link / /
ARG TEXINFO_VERSION
COPY packages/texinfo-${TEXINFO_VERSION}.tar.xz .
RUN tar -xf texinfo-${TEXINFO_VERSION}.tar.xz
WORKDIR /work/texinfo-${TEXINFO_VERSION}
RUN ./configure --prefix=/usr
RUN make
RUN make install

FROM ch7.4 AS ch7.14
WORKDIR /work
COPY --from=ch7.13 --link / /
ARG UTIL_LINUX_VERSION
COPY packages/util-linux-${UTIL_LINUX_VERSION}.tar.xz .
RUN tar -xf util-linux-${UTIL_LINUX_VERSION}.tar.xz
WORKDIR /work/util-linux-${UTIL_LINUX_VERSION}
RUN mkdir -pv /var/lib/hwclock
RUN ./configure --libdir=/usr/lib     \
    --runstatedir=/run    \
    --disable-chfn-chsh   \
    --disable-login       \
    --disable-nologin     \
    --disable-su          \
    --disable-setpriv     \
    --disable-runuser     \
    --disable-pylibmount  \
    --disable-static      \
    --disable-liblastlog2 \
    --without-python      \
    ADJTIME_PATH=/var/lib/hwclock/adjtime \
    --docdir=/usr/share/doc/util-linux-${UTIL_LINUX_VERSION}
RUN make
RUN make install

FROM ch7.4 AS ch7.15
COPY --from=ch7.14 --link / /
RUN rm -rf /usr/share/{info,man,doc}/*
RUN find /usr/{lib,libexec} -name \*.la -delete
RUN rm -rf /tools

FROM ch7.4 AS ch8.3
WORKDIR /work
COPY --from=ch7.15 --link / /
ARG MAN_PAGES_VERSION
COPY packages/man-pages-${MAN_PAGES_VERSION}.tar.xz .
RUN tar -xf man-pages-${MAN_PAGES_VERSION}.tar.xz
WORKDIR /work/man-pages-${MAN_PAGES_VERSION}
RUN rm -v man3/crypt*
RUN make -R GIT=false prefix=/usr install

FROM ch7.4 AS ch8.4
WORKDIR /work
COPY --from=ch8.3 --link / /
ARG IANA_ETC_VERSION
COPY packages/iana-etc-${IANA_ETC_VERSION}.tar.gz .
RUN tar -xf iana-etc-${IANA_ETC_VERSION}.tar.gz
WORKDIR /work/iana-etc-${IANA_ETC_VERSION}
RUN cp -v services protocols /etc

FROM ch7.4 AS ch8.5
WORKDIR /work
COPY --from=ch8.4 --link / /
ARG GLIBC_VERSION
COPY packages/glibc-${GLIBC_VERSION}.tar.xz .
COPY packages/glibc-fhs-1.patch .
COPY packages/glibc-${GLIBC_VERSION}-upstream_fixes-1.patch .
RUN tar -xf glibc-${GLIBC_VERSION}.tar.xz
WORKDIR /work/glibc-${GLIBC_VERSION}
RUN patch -Np1 -i ../glibc-fhs-1.patch
RUN patch -Np1 -i ../glibc-${GLIBC_VERSION}-upstream_fixes-1.patch
RUN mkdir -v build
WORKDIR /work/glibc-${GLIBC_VERSION}/build
RUN ../configure --prefix=/usr      \
    --disable-werror                \
    --disable-nscd                  \
    libc_cv_slibdir=/usr/lib        \
    --enable-stack-protector=strong \
    --enable-kernel=5.10
RUN make
RUN make check
RUN touch /etc/ld.so.conf
RUN sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile
RUN make install
RUN sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
RUN make localedata/install-locales
RUN cat <<"EOF" >/etc/nsswitch.conf
# Begin /etc/nsswitch.conf

passwd: files systemd
group: files systemd
shadow: files systemd

hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns
networks: files

protocols: files
services: files
ethers: files
rpc: files

# End /etc/nsswitch.conf
EOF
RUN tar -xf ../../tzdata2026c.tar.gz
ENV ZONEINFO=/usr/share/zoneinfo
RUN mkdir -pv $ZONEINFO/{posix,right}
RUN for tz in etcetera southamerica northamerica europe africa antarctica asia australasia backward; do \
    zic -L /dev/null   -d $ZONEINFO       ${tz} \
    zic -L /dev/null   -d $ZONEINFO/posix ${tz} \
    zic -L leapseconds -d $ZONEINFO/right ${tz} \
done
RUN cp -v zone.tab zone1970.tab iso3166.tab $ZONEINFO
RUN zic -d $ZONEINFO -p America/New_York
RUN ln -sfv $ZONEINFO/America/New_York /etc/localtime
ENV ZONEINFO=
RUN cat <<"EOF" > /etc/ld.so.conf
# Begin /etc/ld.so.conf
/usr/local/lib
/opt/lib

EOF
RUN cat <<"EOF" >> /etc/ld.so.conf
# Add an include directory
include /etc/ld.so.conf.d/*.conf

EOF
RUN mkdir -pv /etc/ld.so.conf.d
