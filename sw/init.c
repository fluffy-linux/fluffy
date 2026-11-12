#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <mntent.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <linux/loop.h>

#define FLUFFY_FSTAB "/etc/fluffy/fstab"
#define SYSTEM_FSTAB "/etc/fstab"
#define SYSTEMD_PATH "/sw/systemd/lib/systemd/systemd"
#define SYSTEMD_FALLBACK "/sw/systemd/bin/init"
#define EMERGENCY_SHELL "/sw/bash/bin/bash"

static void log_msg(const char *msg)
{
    printf("init: %s\n", msg);
    fflush(stdout);
}

static int mkdir_p(const char *path, mode_t mode)
{
    char tmp[1024];
    char *p = NULL;
    size_t len;

    if (!path || !*path)
        return -1;

    snprintf(tmp, sizeof(tmp), "%s", path);
    len = strlen(tmp);
    if (tmp[len - 1] == '/')
        tmp[len - 1] = 0;

    for (p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (mkdir(tmp, mode) != 0 && errno != EEXIST)
                return -1;
            *p = '/';
        }
    }
    if (mkdir(tmp, mode) != 0 && errno != EEXIST)
        return -1;
    return 0;
}

static void setup_console(void)
{
    int fd = open("/dev/console", O_RDWR);
    if (fd >= 0) {
        if (dup2(fd, 0) < 0 || dup2(fd, 1) < 0 || dup2(fd, 2) < 0) {
            /* ignore */
        }
        if (fd > 2)
            close(fd);
    }
}

static int mount_pseudo(const char *source, const char *target, const char *fstype,
                        unsigned long flags, const char *data)
{
    mkdir_p(target, 0755);
    if (mount(source, target, fstype, flags, data) < 0) {
        if (errno != EBUSY) {
            printf("init: failed to mount %s on %s (%s): %s\n",
                   source, target, fstype, strerror(errno));
            return -1;
        }
    }
    return 0;
}

static int loop_mount_squashfs(const char *image_path, const char *target_dir)
{
    int ctrl_fd = open("/dev/loop-control", O_RDWR | O_CLOEXEC);
    if (ctrl_fd < 0) {
        printf("init: open /dev/loop-control failed: %s\n", strerror(errno));
        return -1;
    }

    int devnr = ioctl(ctrl_fd, LOOP_CTL_GET_FREE);
    close(ctrl_fd);
    if (devnr < 0) {
        printf("init: LOOP_CTL_GET_FREE failed: %s\n", strerror(errno));
        return -1;
    }

    char loop_dev[64];
    snprintf(loop_dev, sizeof(loop_dev), "/dev/loop%d", devnr);

    int file_fd = open(image_path, O_RDONLY | O_CLOEXEC);
    if (file_fd < 0) {
        printf("init: open %s failed: %s\n", image_path, strerror(errno));
        return -1;
    }

    int loop_fd = open(loop_dev, O_RDWR | O_CLOEXEC);
    if (loop_fd < 0)
        loop_fd = open(loop_dev, O_RDONLY | O_CLOEXEC);

    if (loop_fd < 0) {
        printf("init: open %s failed: %s\n", loop_dev, strerror(errno));
        close(file_fd);
        return -1;
    }

#ifdef LOOP_CONFIGURE
    struct loop_config config;
    memset(&config, 0, sizeof(config));
    config.fd = file_fd;
    config.info.lo_flags = LO_FLAGS_AUTOCLEAR | LO_FLAGS_READ_ONLY;
    snprintf((char *)config.info.lo_file_name, LO_NAME_SIZE, "%s", image_path);
    if (ioctl(loop_fd, LOOP_CONFIGURE, &config) < 0)
#endif
    {
        if (ioctl(loop_fd, LOOP_SET_FD, file_fd) < 0) {
            printf("init: LOOP_SET_FD on %s failed: %s\n", loop_dev, strerror(errno));
            close(loop_fd);
            close(file_fd);
            return -1;
        }

        struct loop_info64 info;
        memset(&info, 0, sizeof(info));
        info.lo_flags = LO_FLAGS_AUTOCLEAR | LO_FLAGS_READ_ONLY;
        snprintf((char *)info.lo_file_name, LO_NAME_SIZE, "%s", image_path);
        ioctl(loop_fd, LOOP_SET_STATUS64, &info);
    }

    close(file_fd);

    mkdir_p(target_dir, 0755);
    /* Keep loop_fd open across mount() so LO_FLAGS_AUTOCLEAR does not detach
     * the loop device before the filesystem opens it. */
    if (mount(loop_dev, target_dir, "squashfs", MS_RDONLY, NULL) < 0) {
        printf("init: mount %s on %s failed: %s\n", loop_dev, target_dir, strerror(errno));
        close(loop_fd);
        return -1;
    }

    close(loop_fd);
    return 0;
}

static void parse_mount_options(const char *opts, unsigned long *flags, char *extra, size_t extra_sz)
{
    char buf[1024];
    char *saveptr = NULL, *tok;
    size_t extra_pos = 0;

    *flags = 0;
    extra[0] = 0;

    if (!opts || !*opts)
        return;

    snprintf(buf, sizeof(buf), "%s", opts);
    tok = strtok_r(buf, ",", &saveptr);
    while (tok) {
        if (strcmp(tok, "ro") == 0)
            *flags |= MS_RDONLY;
        else if (strcmp(tok, "rw") == 0)
            *flags &= ~MS_RDONLY;
        else if (strcmp(tok, "nosuid") == 0)
            *flags |= MS_NOSUID;
        else if (strcmp(tok, "suid") == 0)
            *flags &= ~MS_NOSUID;
        else if (strcmp(tok, "nodev") == 0)
            *flags |= MS_NODEV;
        else if (strcmp(tok, "dev") == 0)
            *flags &= ~MS_NODEV;
        else if (strcmp(tok, "noexec") == 0)
            *flags |= MS_NOEXEC;
        else if (strcmp(tok, "exec") == 0)
            *flags &= ~MS_NOEXEC;
        else if (strcmp(tok, "sync") == 0)
            *flags |= MS_SYNCHRONOUS;
        else if (strcmp(tok, "async") == 0)
            *flags &= ~MS_SYNCHRONOUS;
        else if (strcmp(tok, "noatime") == 0)
            *flags |= MS_NOATIME;
        else if (strcmp(tok, "atime") == 0)
            *flags &= ~MS_NOATIME;
        else if (strcmp(tok, "nodiratime") == 0)
            *flags |= MS_NODIRATIME;
        else if (strcmp(tok, "relatime") == 0)
            *flags |= MS_RELATIME;
        else if (strcmp(tok, "remount") == 0)
            *flags |= MS_REMOUNT;
        else if (strcmp(tok, "defaults") != 0) {
            /* Filesystem-specific mount options (e.g. subvol=..., mode=...) */
            size_t toklen = strlen(tok);
            if (extra_pos + toklen + 2 < extra_sz) {
                if (extra_pos > 0)
                    extra[extra_pos++] = ',';
                memcpy(extra + extra_pos, tok, toklen);
                extra_pos += toklen;
                extra[extra_pos] = 0;
            }
        }
        tok = strtok_r(NULL, ",", &saveptr);
    }
}

static void mount_etc_fstab(const char *fstab_path)
{
    FILE *fp = setmntent(fstab_path, "r");
    if (!fp)
        return;

    struct mntent *ent;
    while ((ent = getmntent(fp)) != NULL) {
        if (!ent->mnt_fsname || ent->mnt_fsname[0] == '#' || !ent->mnt_dir)
            continue;

        if (strcmp(ent->mnt_type, "swap") == 0 || strcmp(ent->mnt_dir, "none") == 0)
            continue;

        if (strcmp(ent->mnt_dir, "/") == 0) {
            unsigned long flags = MS_REMOUNT;
            char extra[1024];
            parse_mount_options(ent->mnt_opts, &flags, extra, sizeof(extra));
            flags |= MS_REMOUNT;
            if (mount(NULL, "/", NULL, flags, extra[0] ? extra : NULL) < 0) {
                printf("init: warning: remount / failed: %s\n", strerror(errno));
            }
            continue;
        }

        /* Skip pseudo filesystems already mounted */
        if (strcmp(ent->mnt_dir, "/dev") == 0 ||
            strcmp(ent->mnt_dir, "/proc") == 0 ||
            strcmp(ent->mnt_dir, "/sys") == 0 ||
            strcmp(ent->mnt_dir, "/run") == 0)
            continue;

        unsigned long flags = 0;
        char extra[1024];
        parse_mount_options(ent->mnt_opts, &flags, extra, sizeof(extra));

        mkdir_p(ent->mnt_dir, 0755);
        if (mount(ent->mnt_fsname, ent->mnt_dir, ent->mnt_type, flags, extra[0] ? extra : NULL) < 0) {
            printf("init: warning: mount %s on %s (%s) failed: %s\n",
                   ent->mnt_fsname, ent->mnt_dir, ent->mnt_type, strerror(errno));
        } else {
            printf("init: mounted %s on %s\n", ent->mnt_fsname, ent->mnt_dir);
        }
    }
    endmntent(fp);
}

static void mount_fluffy_packages(const char *fluffy_fstab_path)
{
    FILE *fp = setmntent(fluffy_fstab_path, "r");
    if (!fp) {
        printf("init: error: %s not found\n", fluffy_fstab_path);
        return;
    }

    struct mntent *ent;
    int count = 0;
    while ((ent = getmntent(fp)) != NULL) {
        if (!ent->mnt_fsname || ent->mnt_fsname[0] == '#' || !ent->mnt_dir)
            continue;

        if (loop_mount_squashfs(ent->mnt_fsname, ent->mnt_dir) == 0)
            count++;
    }
    endmntent(fp);
    printf("init: mounted %d fluffy squashfs packages\n", count);
}

int main(int argc, char *argv[])
{
    (void)argc;

    log_msg("starting fluffy init...");

    /* 1. Early pseudo filesystems */
    mount_pseudo("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
    setup_console();

    mount_pseudo("proc", "/proc", "proc", MS_NODEV | MS_NOEXEC | MS_NOSUID, NULL);
    mount_pseudo("sysfs", "/sys", "sysfs", MS_NODEV | MS_NOEXEC | MS_NOSUID, NULL);
    mount_pseudo("tmpfs", "/run", "tmpfs", MS_NODEV | MS_NOSUID, "mode=0755");
    mount_pseudo("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC, "mode=0620,gid=5");
    mount_pseudo("tmpfs", "/dev/shm", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");

    /* 2. Mount persistent standard filesystems from /etc/fstab */
    mount_etc_fstab(SYSTEM_FSTAB);

    /* 3. Mount fluffy squashfs packages from /etc/fluffy/fstab */
    mount_fluffy_packages(FLUFFY_FSTAB);

    /* 4. Prepare environment and forward arguments to systemd */
    log_msg("executing systemd...");
    setenv("PATH", "/sw/*/bin:/sw/systemd/bin:/sw/coreutils/bin", 1);
    setenv("TERM", "linux", 0);

    argv[0] = (char *)SYSTEMD_PATH;
    execv(SYSTEMD_PATH, argv);

    /* Fallback to /sw/systemd/bin/init if direct path fails */
    printf("init: exec %s failed (%s), trying fallback %s...\n",
           SYSTEMD_PATH, strerror(errno), SYSTEMD_FALLBACK);
    argv[0] = (char *)SYSTEMD_FALLBACK;
    execv(SYSTEMD_FALLBACK, argv);

    /* Emergency shell */
    printf("init: FATAL: failed to exec systemd: %s\n", strerror(errno));
    printf("init: spawning emergency shell: %s\n", EMERGENCY_SHELL);
    char *const sh_argv[] = { (char *)EMERGENCY_SHELL, NULL };
    execv(EMERGENCY_SHELL, sh_argv);

    printf("init: FATAL: emergency shell failed: %s\n", strerror(errno));
    while (1) {
        sleep(3600);
    }

    return 1;
}
