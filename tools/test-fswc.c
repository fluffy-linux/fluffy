/* test-fswc.c -- Tier-2 Standalone Unprivileged + Privileged CLONE_NEWNS
 *                Torture & Differential Oracle Runner for FSWC v5.
 *
 * Host-independent & non-glibc-caller-aware:
 *   - Zero hardcoded /sw, /snap, /bin/sh, or /usr/bin assumptions (discovers
 *     live SquashFS parent prefixes generically via /proc/self/mountinfo and
 *     always exercises a synthetic multi-package fallback tree as well).
 *   - Zero system() calls (never depends on _PATH_BSHELL existing on the host).
 *   - Uses self-contained static ET_EXEC ELF binaries for execvpe/posix_spawnp.
 *   - Exercises both glibc wrappers AND raw syscall(SYS_mount/SYS_umount2/
 *     SYS_chroot/SYS_setresuid) coherence (0 ms stale window for glob/execvpe,
 *     matching Go/Rust runtimes that skip glibc wrappers).
 *
 * Build:
 *   gcc -O2 -Wall -Wextra -pthread -o test-fswc tools/test-fswc.c -ldl
 *
 * Run unprivileged:
 *   ./test-fswc [--runner <ld.so> --library-path <...> ./test-fswc]
 *
 * Run as root (isolated CLONE_NEWNS MS_PRIVATE SquashFS torture):
 *   sudo ./test-fswc
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <glob.h>
#include <grp.h>
#include <limits.h>
#include <paths.h>
#include <sched.h>
#include <spawn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fsuid.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#ifndef SQUASHFS_MAGIC
# define SQUASHFS_MAGIC 0x73717368
#endif
#ifndef GLOB_DOTDOT
# define GLOB_DOTDOT       (1 << 24)
#endif
#ifndef GLOB_GLOBSTAR
# define GLOB_GLOBSTAR     (1 << 25)
#endif
#ifndef GLOB_SKIPDOTS
# define GLOB_SKIPDOTS     (1 << 26)
#endif
#ifndef GLOB_CASEFOLD
# define GLOB_CASEFOLD     (1 << 27)
#endif
#ifndef GLOB_EXTMATCH
# define GLOB_EXTMATCH     (1 << 28)
#endif
#ifndef GLOB_PATHS
# define GLOB_PATHS        (1 << 29)
#endif
#ifndef GLOB_KEEP_SLASHES
# define GLOB_KEEP_SLASHES (1 << 30)
#endif

#define ASSERT_OK(cond, ...)                                                   \
  do                                                                           \
    {                                                                          \
      if (!(cond))                                                             \
        {                                                                      \
          fprintf (stderr, "FAIL (%s:%d): ", __FILE__, __LINE__);              \
          fprintf (stderr, __VA_ARGS__);                                       \
          fprintf (stderr, " (errno=%d: %s)\n", errno, strerror (errno));      \
          exit (1);                                                            \
        }                                                                      \
    }                                                                          \
  while (0)

static void
mkdir_p (const char *path, mode_t mode)
{
  char tmp[PATH_MAX];
  snprintf (tmp, sizeof (tmp), "%s", path);
  for (char *p = tmp + 1; *p != '\0'; ++p)
    if (*p == '/')
      {
        *p = '\0';
        mkdir (tmp, 0755);
        *p = '/';
      }
  mkdir (tmp, mode);
  chmod (tmp, mode);
}

static void
write_str (const char *path, const char *s, mode_t mode)
{
  int fd = open (path, O_WRONLY | O_CREAT | O_TRUNC, mode);
  ASSERT_OK (fd >= 0, "open(%s)", path);
  size_t len = strlen (s);
  if (len > 0)
    ASSERT_OK (write (fd, s, len) == (ssize_t) len, "write(%s)", path);
  close (fd);
  chmod (path, mode);
}

#ifndef FSWC_TOOL_DEFPATH
# define FSWC_TOOL_DEFPATH \
  _PATH_DEFPATH ":" _PATH_STDPATH \
  ":/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
#endif

static bool
find_prog_in_path (const char *prog, char *out, size_t out_sz)
{
  const char *path_env = getenv ("PATH");
  if (path_env == NULL || *path_env == '\0')
    path_env = FSWC_TOOL_DEFPATH;

  /* Split ':' manually without GLOB_PATHS so the outer launcher works even on
     an unpatched host glibc when --runner points to the new ld.so.  */
  const char *p = path_env;
  while (*p != '\0')
    {
      const char *colon = strchr (p, ':');
      size_t slen = colon != NULL ? (size_t) (colon - p) : strlen (p);
      char seg[PATH_MAX];
      if (slen == 0)
        {
          seg[0] = '.';
          seg[1] = '\0';
        }
      else if (slen < sizeof (seg))
        {
          memcpy (seg, p, slen);
          seg[slen] = '\0';
        }
      else
        {
          if (colon == NULL)
            break;
          p = colon + 1;
          continue;
        }

      glob_t gl;
      memset (&gl, 0, sizeof (gl));
      if (glob (seg, GLOB_NOESCAPE | GLOB_NOCHECK, NULL, &gl) == 0)
        {
          for (size_t i = 0; i < gl.gl_pathc; ++i)
            {
              char cand[PATH_MAX];
              if ((size_t) snprintf (cand, sizeof (cand), "%s/%s",
                                     gl.gl_pathv[i], prog) < sizeof (cand)
                  && access (cand, X_OK) == 0)
                {
                  struct stat st;
                  if (stat (cand, &st) == 0 && S_ISREG (st.st_mode))
                    {
                      snprintf (out, out_sz, "%s", cand);
                      globfree (&gl);
                      return true;
                    }
                }
            }
          globfree (&gl);
        }

      if (colon == NULL)
        break;
      p = colon + 1;
    }
  return false;
}

static const char *
resolve_self_exe (const char *argv0, char *buf, size_t buf_sz)
{
  if (strchr (argv0, '/') != NULL)
    return argv0;
  ssize_t nr = readlink ("/proc/self/exe", buf, buf_sz - 1);
  if (nr > 0)
    {
      buf[nr] = '\0';
      return buf;
    }
  if (find_prog_in_path (argv0, buf, buf_sz))
    return buf;
  return argv0;
}

static void
write_tiny_exit0_exe (const char *path)
{
#if defined (__linux__) && (defined (__x86_64__) || defined (__aarch64__))
  struct
  {
    Elf64_Ehdr ehdr;
    Elf64_Phdr phdr;
    uint8_t code[16];
  } img;
  memset (&img, 0, sizeof (img));
  img.ehdr.e_ident[EI_MAG0] = ELFMAG0;
  img.ehdr.e_ident[EI_MAG1] = ELFMAG1;
  img.ehdr.e_ident[EI_MAG2] = ELFMAG2;
  img.ehdr.e_ident[EI_MAG3] = ELFMAG3;
  img.ehdr.e_ident[EI_CLASS] = ELFCLASS64;
  img.ehdr.e_ident[EI_DATA] = ELFDATA2LSB;
  img.ehdr.e_ident[EI_VERSION] = EV_CURRENT;
  img.ehdr.e_ident[EI_OSABI] = ELFOSABI_SYSV;
  img.ehdr.e_type = ET_EXEC;
  img.ehdr.e_version = EV_CURRENT;
  img.ehdr.e_entry = 0x400000ULL + offsetof (__typeof__ (img), code);
  img.ehdr.e_phoff = offsetof (__typeof__ (img), phdr);
  img.ehdr.e_ehsize = sizeof (Elf64_Ehdr);
  img.ehdr.e_phentsize = sizeof (Elf64_Phdr);
  img.ehdr.e_phnum = 1;
# if defined (__x86_64__)
  img.ehdr.e_machine = EM_X86_64;
  static const uint8_t stub[] =
    { 0x31, 0xff, 0xb8, 0x3c, 0x00, 0x00, 0x00, 0x0f, 0x05 };
# elif defined (__aarch64__)
  img.ehdr.e_machine = EM_AARCH64;
  static const uint8_t stub[] =
    { 0x00, 0x00, 0x80, 0xd2, 0xa8, 0x0b, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4 };
# endif
  memcpy (img.code, stub, sizeof (stub));
  size_t total = offsetof (__typeof__ (img), code) + sizeof (stub);
  img.phdr.p_type = PT_LOAD;
  img.phdr.p_flags = PF_R | PF_X;
  img.phdr.p_offset = 0;
  img.phdr.p_vaddr = 0x400000ULL;
  img.phdr.p_paddr = 0x400000ULL;
  img.phdr.p_filesz = total;
  img.phdr.p_memsz = total;
  img.phdr.p_align = 0x1000;

  int fd = open (path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
  ASSERT_OK (fd >= 0, "open(%s)", path);
  ASSERT_OK (write (fd, &img, total) == (ssize_t) total, "write(%s)", path);
  close (fd);
  chmod (path, 0755);
#else
  char true_path[PATH_MAX];
  ASSERT_OK (find_prog_in_path ("true", true_path, sizeof (true_path)),
             "find 'true' in PATH");
  int sfd = open (true_path, O_RDONLY);
  ASSERT_OK (sfd >= 0, "open(%s)", true_path);
  int dfd = open (path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
  ASSERT_OK (dfd >= 0, "open(%s)", path);
  char buf[4096];
  ssize_t r;
  while ((r = read (sfd, buf, sizeof (buf))) > 0)
    ASSERT_OK (write (dfd, buf, (size_t) r) == r, "write(%s)", path);
  close (dfd);
  close (sfd);
  chmod (path, 0755);
#endif
}

static int
run_prog (char *const argv[])
{
  pid_t pid = fork ();
  if (pid < 0)
    return -1;
  if (pid == 0)
    {
      execvp (argv[0], argv);
      _exit (127);
    }
  int status = 0;
  if (waitpid (pid, &status, 0) != pid)
    return -1;
  return (WIFEXITED (status) && WEXITSTATUS (status) == 0) ? 0 : -1;
}

static int
rm_rf_cb (const char *fpath, const struct stat *sb, int tflag,
          struct FTW *ftwbuf)
{
  (void) sb;
  (void) ftwbuf;
  if (tflag == FTW_DP || tflag == FTW_D || tflag == FTW_DNR)
    chmod (fpath, 0700);
  remove (fpath);
  return 0;
}

static void
rm_rf (const char *path)
{
  chmod (path, 0700);
  nftw (path, rm_rf_cb, 32, FTW_DEPTH | FTW_PHYS);
}

static const char *
discover_squash_prefix (char *buf, size_t buf_sz)
{
  const char *env_p = getenv ("FSWC_TEST_PREFIX");
  if (env_p != NULL)
    {
      if (strcmp (env_p, "none") == 0)
        return NULL;
      if (env_p[0] == '/')
        {
          snprintf (buf, buf_sz, "%s", env_p);
          return buf;
        }
    }

  FILE *fp = fopen ("/proc/self/mountinfo", "r");
  if (fp == NULL)
    return NULL;

  char best[512] = "";
  size_t best_cnt = 0;
  char line[2048];
  while (fgets (line, sizeof (line), fp) != NULL)
    {
      const char *sep = strstr (line, " - ");
      if (sep == NULL)
        continue;
      const char *fstype = sep + 3;
      if (strncmp (fstype, "squashfs ", 9) != 0
          && strncmp (fstype, "squashfs\t", 9) != 0)
        continue;
      const char *p = line;
      for (int f = 0; f < 4 && p < sep; ++f)
        {
          while (p < sep && *p != ' ')
            ++p;
          while (p < sep && *p == ' ')
            ++p;
        }
      const char *mp_end = p;
      while (mp_end < sep && *mp_end != ' ')
        ++mp_end;
      size_t mp_len = (size_t) (mp_end - p);
      if (mp_len < 3 || mp_len >= sizeof (best) || p[0] != '/'
          || memchr (p, '\\', mp_len) != NULL)
        continue;
      const char *last_slash = NULL;
      size_t slashes = 0;
      for (size_t i = 0; i < mp_len; ++i)
        if (p[i] == '/')
          {
            last_slash = p + i;
            ++slashes;
          }
      if (last_slash == NULL || last_slash == p || slashes >= 15)
        continue;
      size_t par_len = (size_t) (last_slash - p);
      char par[512];
      memcpy (par, p, par_len);
      par[par_len] = '\0';
      if (strcmp (par, best) == 0)
        continue;
      DIR *d = opendir (par);
      if (d == NULL)
        continue;
      size_t sq_cnt = 0;
      struct dirent *de;
      while ((de = readdir (d)) != NULL)
        {
          if (de->d_name[0] == '.')
            continue;
          char sub[768];
          snprintf (sub, sizeof (sub), "%s/%s", par, de->d_name);
          struct stat st;
          struct statfs sfs;
          if (lstat (sub, &st) == 0 && S_ISDIR (st.st_mode)
              && statfs (sub, &sfs) == 0 && sfs.f_type == SQUASHFS_MAGIC)
            ++sq_cnt;
        }
      closedir (d);
      if (sq_cnt > best_cnt)
        {
          best_cnt = sq_cnt;
          memcpy (best, par, par_len + 1);
        }
    }
  fclose (fp);
  if (best_cnt == 0)
    return NULL;
  snprintf (buf, buf_sz, "%s", best);
  return buf;
}

static int
count_errfunc_calls;

static int
record_errfunc (const char *epath, int eerrno)
{
  (void) epath;
  (void) eerrno;
  ++count_errfunc_calls;
  return 0;
}

static void
dump_oracle_snapshot (FILE *out, const char *prefix)
{
  static const struct { const char *suf; int flags; bool use_errfn; } pats[] =
    {
      { "/*", 0, false },
      { "/*.squashfs", 0, false },
      { "/*", GLOB_ONLYDIR, false },
      { "/*", GLOB_MARK, false },
      { "/*", GLOB_ONLYDIR | GLOB_MARK, false },
      { "/*/bin/*", 0, false },
      { "/*/include/ncursesw/*.h", 0, false },
      { "/*/include/*.h", 0, false },
      { "/*/secret0700/*", 0, true },
      { "/*/exec0111/*", 0, true },
      { "/*/weird0005/*", 0, true },
      { "/*/acl_deny/*", 0, true },
      { "/*/deep/**", GLOB_GLOBSTAR, false },
      { "/*/**", GLOB_GLOBSTAR, false },
      { "/*/**/*.h", GLOB_GLOBSTAR, false },
      { "/*/include/ncursesw/**/*.h", GLOB_GLOBSTAR, false },
      { "/*/*/*", GLOB_PERIOD, false },
      { "/*/*/*", GLOB_PERIOD | GLOB_SKIPDOTS, false },
    };

  for (size_t i = 0; i < sizeof (pats) / sizeof (pats[0]); ++i)
    {
      char pat[1024];
      snprintf (pat, sizeof (pat), "%s%s", prefix, pats[i].suf);
      for (int pass = 0; pass < 2; ++pass)
        {
          glob_t gl;
          memset (&gl, 0, sizeof (gl));
          count_errfunc_calls = 0;
          int r = glob (pat, pats[i].flags,
                        pats[i].use_errfn ? record_errfunc : NULL, &gl);
          if (pass == 1)
            {
              fprintf (out, "G|%s|0x%x|r=%d|fl=0x%x|errfn=%d|n=%zu\n",
                       pats[i].suf, pats[i].flags, r,
                       r == 0 ? gl.gl_flags : 0, count_errfunc_calls,
                       r == 0 ? gl.gl_pathc : 0);
              if (r == 0)
                for (size_t j = 0; j < gl.gl_pathc; ++j)
                  fprintf (out, "  %s\n", gl.gl_pathv[j]);
            }
          if (r == 0)
            globfree (&gl);
        }
    }

  static const char *const rels[] =
    {
      "pkgA/bin/hello",
      "pkgA/bin/hello/",
      "pkgA/bin/hello/sub",
      "pkgA/bin/missing",
      "pkgA/include/ncursesw/curses.h",
      "pkgA/include/ncursesw/missing.h",
      "pkgA/links/dangling",
      "pkgA/links/eloop",
      "pkgA/links/ext_tmp",
      "pkgA/secret0700/topsecret",
      "pkgA/secret0700/missing",
      "pkgA/exec0111/hidden_bin",
      "pkgA/exec0111/missing",
      "pkgA/weird0005/file",
      "pkgA/weird0005/missing",
      "pkgA/acl_deny/file",
      "pkgA/acl_deny/missing",
      "pkgA/empty_dir",
      "pkgA/empty_dir/missing",
      "pkgA/deep/d1/d2/d3/d4/d5/d6/../../../../../../bin/hello",
      "pkgA/deep/d1/d2/d3/d4/d5/d6/../../../../../../bin/missing",
      "local_mut/bin/local_tool",
      "local_mut/bin/missing",
      "pkgA-1.0.squashfs/notadir",
    };

  for (size_t i = 0; i < sizeof (rels) / sizeof (rels[0]); ++i)
    {
      char pbuf[1024];
      snprintf (pbuf, sizeof (pbuf), "%s/%s", prefix, rels[i]);
      for (int pass = 0; pass < 2; ++pass)
        {
          errno = 0;
          int fd = openat (AT_FDCWD, pbuf, O_RDONLY | O_CLOEXEC);
          int o_err = fd < 0 ? errno : 0;
          if (fd >= 0)
            close (fd);

          struct stat st, lst;
          errno = 0;
          int sr = stat (pbuf, &st);
          int s_err = sr < 0 ? errno : 0;

          errno = 0;
          int lsr = lstat (pbuf, &lst);
          int ls_err = lsr < 0 ? errno : 0;

          struct statx stx;
          errno = 0;
          int xr = statx (AT_FDCWD, pbuf, 0, STATX_BASIC_STATS, &stx);
          int x_err = xr < 0 ? errno : 0;

          errno = 0;
          int ar = access (pbuf, R_OK);
          int a_err = ar < 0 ? errno : 0;

          if (pass == 1)
            fprintf (out, "V|%s|o=%d/%d|s=%d/%d|ls=%d/%d|x=%d/%d|a=%d/%d\n",
                     rels[i], fd >= 0 ? 0 : -1, o_err, sr, s_err,
                     lsr, ls_err, xr, x_err, ar, a_err);
        }
    }

  /* Also verify wildcard PATH posix_spawnp across restricted subdirs and
     dlopen/dlerror ENOENT invariants across mode={0,1,2}.  */
  {
    const char *old_path = getenv ("PATH");
    char *saved = old_path != NULL ? strdup (old_path) : NULL;
    char wpath[1024];
    snprintf (wpath, sizeof (wpath),
              "%s/*/bin:%s/*/exec0111:%s/*/secret0700:%s/*/acl_deny",
              prefix, prefix, prefix, prefix);
    setenv ("PATH", wpath, 1);
    static const char *const sp_names[] =
      {
        "hello", "hidden_only_cmd", "nonexec_probe", "topsecret",
        "missing_exec_probe"
      };
    for (size_t s = 0; s < sizeof (sp_names) / sizeof (sp_names[0]); ++s)
      {
        char *sp_argv[] = { (char *) sp_names[s], NULL };
        for (int pass = 0; pass < 2; ++pass)
          {
            pid_t spid = 0;
            int sr = posix_spawnp (&spid, sp_names[s], NULL, NULL,
                                   sp_argv, environ);
            int wst = 0;
            if (sr == 0)
              waitpid (spid, &wst, 0);
            if (pass == 1)
              fprintf (out, "S|%s|sr=%d|exit=%d\n", sp_names[s], sr,
                       (sr == 0 && WIFEXITED (wst)) ? WEXITSTATUS (wst) : -1);
          }
      }
    if (saved != NULL)
      {
        setenv ("PATH", saved, 1);
        free (saved);
      }
    else
      unsetenv ("PATH");

    errno = EBADF;
    void *dh = dlopen ("libnonexistent_test_fswc_oracle.so", RTLD_NOW);
    const char *derr = dlerror ();
    ASSERT_OK (dh == NULL && derr != NULL && strstr (derr, "Success") == NULL
               && strstr (derr, "Bad file descriptor") == NULL,
               "dlerror returned NULL, Success, or stale EBADF");
    fprintf (out, "DL|missing=%s\n", derr);

    void *dh2 = dlopen ("libfswc_eacces_only.so", RTLD_NOW);
    const char *derr2 = dlerror ();
    ASSERT_OK (dh2 == NULL && derr2 != NULL
               && strstr (derr2, "Success") == NULL,
               "dlerror on libfswc_eacces_only.so returned NULL or Success");
    fprintf (out, "DL|eacces=%s\n", derr2);
  }
}

static int
oracle_worker (const char *prefix, const char *out_file, const char *cred_mode)
{
  if (strcmp (cred_mode, "fsuid_nobody") == 0)
    setfsuid (65534);
  else if (strcmp (cred_mode, "uid_nobody") == 0)
    {
      ASSERT_OK (setresgid (65534, 65534, 65534) == 0, "setresgid");
      ASSERT_OK (setresuid (65534, 65534, 65534) == 0, "setresuid");
    }

  FILE *fp = fopen (out_file, "wb");
  ASSERT_OK (fp != NULL, "fopen(%s)", out_file);
  dump_oracle_snapshot (fp, prefix);
  fclose (fp);
  return 0;
}

static char *
read_all (const char *path, size_t *len_out)
{
  int fd = open (path, O_RDONLY);
  ASSERT_OK (fd >= 0, "open(%s)", path);
  struct stat st;
  ASSERT_OK (fstat (fd, &st) == 0, "fstat");
  char *buf = malloc ((size_t) st.st_size + 1);
  ASSERT_OK (buf != NULL, "malloc");
  if (st.st_size > 0)
    ASSERT_OK (read (fd, buf, (size_t) st.st_size) == st.st_size, "read");
  buf[st.st_size] = '\0';
  close (fd);
  *len_out = (size_t) st.st_size;
  return buf;
}

static void
verify_modes_identical (int argc, char **argv, const char *prefix,
                        const char *work_dir, const char *cred_mode)
{
  char outs[3][512];
  for (int mode = 0; mode <= 2; ++mode)
    {
      snprintf (outs[mode], sizeof (outs[mode]),
                "%s/oracle_%s_m%d.txt", work_dir, cred_mode, mode);
      chmod (work_dir, 0777);
      pid_t pid = fork ();
      ASSERT_OK (pid >= 0, "fork");
      if (pid == 0)
        {
          char tun[64];
          snprintf (tun, sizeof (tun), "glibc.fswc.mode=%d", mode);
          setenv ("GLIBC_TUNABLES", tun, 1);

          char extra_llp[1024];
          const char *cur_llp = getenv ("LD_LIBRARY_PATH");
          if (cur_llp != NULL && cur_llp[0] != '\0')
            snprintf (extra_llp, sizeof (extra_llp), "%s:%s/*/onlylib",
                      cur_llp, prefix);
          else
            snprintf (extra_llp, sizeof (extra_llp), "%s/*/onlylib", prefix);
          setenv ("LD_LIBRARY_PATH", extra_llp, 1);

          char *cargv[32];
          char merged_libpath[4096];
          int k = 0;
          int r_idx = -1;
          for (int i = 1; i < argc; ++i)
            if (strcmp (argv[i], "--runner") == 0)
              {
                r_idx = i + 1;
                break;
              }
          char self_buf[PATH_MAX];
          if (r_idx > 0)
            for (int i = r_idx; i < argc && k < 22; ++i)
              {
                if (i > r_idx && strcmp (argv[i - 1], "--library-path") == 0)
                  {
                    snprintf (merged_libpath, sizeof (merged_libpath),
                              "%s:%s/*/onlylib", argv[i], prefix);
                    cargv[k++] = merged_libpath;
                  }
                else
                  cargv[k++] = argv[i];
              }
          else
            cargv[k++] = (char *) resolve_self_exe (argv[0], self_buf,
                                                    sizeof (self_buf));

          cargv[k++] = (char *) "--oracle-worker";
          cargv[k++] = (char *) prefix;
          cargv[k++] = outs[mode];
          cargv[k++] = (char *) cred_mode;
          cargv[k] = NULL;
          execv (cargv[0], cargv);
          _exit (127);
        }
      int status = 0;
      ASSERT_OK (waitpid (pid, &status, 0) == pid, "waitpid");
      ASSERT_OK (WIFEXITED (status) && WEXITSTATUS (status) == 0,
                 "oracle worker mode=%d (%s) failed", mode, cred_mode);
    }

  size_t l0 = 0, l1 = 0, l2 = 0;
  char *b0 = read_all (outs[0], &l0);
  char *b1 = read_all (outs[1], &l1);
  char *b2 = read_all (outs[2], &l2);

  ASSERT_OK (l0 == l1 && memcmp (b0, b1, l0) == 0,
             "mode=0 vs mode=1 mismatch (%s)!", cred_mode);
  ASSERT_OK (l0 == l2 && memcmp (b0, b2, l0) == 0,
             "mode=0 vs mode=2 mismatch (%s)!", cred_mode);
  free (b0);
  free (b1);
  free (b2);
}

static void
populate_pkgA_tree (const char *srcA)
{
  char p[4096];
  snprintf (p, sizeof (p), "%s/bin", srcA);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/bin/hello", srcA);
  write_tiny_exit0_exe (p);

  /* Unreadable 0000 .so in onlylib/ (absent in pkgB/mutable_pkg) to test
     open_path_wildcard EACCES preservation across later packages lacking
     the subpath directory!  */
  snprintf (p, sizeof (p), "%s/onlylib", srcA);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/onlylib/libfswc_eacces_only.so", srcA);
  write_str (p, "UNREADABLE_SO", 0000);

  /* ncursesw -> . internal directory symlink!  */
  snprintf (p, sizeof (p), "%s/include", srcA);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/include/curses.h", srcA);
  write_str (p, "/* curses */\n", 0644);
  snprintf (p, sizeof (p), "%s/include/ncursesw", srcA);
  ASSERT_OK (symlink (".", p) == 0, "symlink ncursesw -> .");

  /* Dangling, ELOOP, and external symlinks.  */
  snprintf (p, sizeof (p), "%s/links", srcA);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/links/dangling", srcA);
  ASSERT_OK (symlink ("does_not_exist", p) == 0, "dangling");
  snprintf (p, sizeof (p), "%s/links/eloop", srcA);
  ASSERT_OK (symlink ("eloop", p) == 0, "eloop");
  snprintf (p, sizeof (p), "%s/links/ext_tmp", srcA);
  ASSERT_OK (symlink ("/tmp", p) == 0, "ext_tmp");

  /* 0700 owner-only, 0111 execute-only, and 0005 owner-denied directories!  */
  snprintf (p, sizeof (p), "%s/secret0700", srcA);
  mkdir_p (p, 0700);
  snprintf (p, sizeof (p), "%s/secret0700/topsecret", srcA);
  write_str (p, "secret\n", 0600);

  snprintf (p, sizeof (p), "%s/exec0111", srcA);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/exec0111/hidden_bin", srcA);
  write_tiny_exit0_exe (p);
  snprintf (p, sizeof (p), "%s/exec0111/nonexec_probe", srcA);
  write_str (p, "noexec\n", 0644);
  snprintf (p, sizeof (p), "%s/exec0111", srcA);
  chmod (p, 0111);

  snprintf (p, sizeof (p), "%s/weird0005", srcA);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/weird0005/file", srcA);
  write_str (p, "w\n", 0644);
  snprintf (p, sizeof (p), "%s/weird0005", srcA);
  chmod (p, 0005);

  /* POSIX ACL restricted directory (st_mode 0755, ACL denies UID 65534).  */
  snprintf (p, sizeof (p), "%s/acl_deny", srcA);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/acl_deny/file", srcA);
  write_str (p, "acl\n", 0644);
  {
    struct __attribute__ ((packed))
    {
      uint32_t version;
      struct __attribute__ ((packed))
      {
        uint16_t tag;
        uint16_t perm;
        uint32_t id;
      } entries[5];
    } raw_acl =
      {
        .version = 2u,
        .entries =
          {
            { 0x0001u, 0x0007u, 0xffffffffu },
            { 0x0002u, 0x0000u, 65534u },
            { 0x0004u, 0x0005u, 0xffffffffu },
            { 0x0010u, 0x0005u, 0xffffffffu },
            { 0x0020u, 0x0005u, 0xffffffffu },
          }
      };
    snprintf (p, sizeof (p), "%s/acl_deny", srcA);
    (void) setxattr (p, "system.posix_acl_access", &raw_acl, sizeof (raw_acl), 0);
  }

  /* Empty DT_DIR + hidden intermediate dir + 16-level deep chain + 255B leaf. */
  snprintf (p, sizeof (p), "%s/empty_dir", srcA);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/.hiddendir", srcA);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/.hiddendir/subfile", srcA);
  write_str (p, "hid\n", 0644);

  char deep[2048];
  snprintf (deep, sizeof (deep), "%s/deep", srcA);
  for (int d = 1; d <= 16; ++d)
    {
      char next[2064];
      ASSERT_OK ((size_t) snprintf (next, sizeof (next), "%s/d%d", deep, d)
                 < sizeof (next), "deep path");
      mkdir_p (next, 0755);
      memcpy (deep, next, strlen (next) + 1);
    }
  char name255[256];
  memset (name255, 'z', 255);
  name255[255] = '\0';
  snprintf (p, sizeof (p), "%s/%s", deep, name255);
  write_str (p, "255\n", 0644);
}

static int
mount_loop_squashfs (const char *mount_bin, const char *sq_file,
                     const char *mnt_point)
{
  char *const av[] =
    {
      (char *) mount_bin,
      (char *) "-t",
      (char *) "squashfs",
      (char *) "-o",
      (char *) "loop,ro",
      (char *) sq_file,
      (char *) mnt_point,
      NULL
    };
  return run_prog (av);
}

static void
spawn_priv_torture_mode (int argc, char **argv, int mode, const char *work,
                         const char *pfx, const char *mntA, const char *mntB,
                         const char *sqA, const char *sqB,
                         const char *mount_bin);

static void
run_privileged_squashfs_torture (int argc, char **argv)
{
  char mksq_bin[PATH_MAX], mount_bin[PATH_MAX];
  if (!find_prog_in_path ("mksquashfs", mksq_bin, sizeof (mksq_bin))
      || !find_prog_in_path ("mount", mount_bin, sizeof (mount_bin)))
    {
      printf ("SKIP privileged SquashFS torture: mksquashfs/mount not in PATH\n");
      return;
    }

  /* Isolate mount namespace completely so host mounts are NEVER touched!  */
  ASSERT_OK (unshare (CLONE_NEWNS) == 0, "unshare(CLONE_NEWNS)");
  ASSERT_OK (mount ("none", "/", NULL, MS_REC | MS_PRIVATE, NULL) == 0,
             "mount(/, MS_REC|MS_PRIVATE)");

  char work[] = "/tmp/fswc-torture.XXXXXX";
  ASSERT_OK (mkdtemp (work) != NULL, "mkdtemp");
  chmod (work, 0755);

  char srcA[256], srcB[256], sqA[320], sqB[320], pfx[256];
  snprintf (srcA, sizeof (srcA), "%s/srcA", work);
  snprintf (srcB, sizeof (srcB), "%s/srcB", work);
  snprintf (pfx, sizeof (pfx), "%s/sw", work);
  mkdir_p (pfx, 0755);
  snprintf (sqA, sizeof (sqA), "%s/pkgA-1.0.squashfs", pfx);
  snprintf (sqB, sizeof (sqB), "%s/pkgB-1.0.squashfs", pfx);

  populate_pkgA_tree (srcA);

  char p[4096];
  snprintf (p, sizeof (p), "%s/bin", srcB);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/bin/world", srcB);
  write_tiny_exit0_exe (p);

  {
    char *const avA[] =
      {
        mksq_bin, srcA, sqA, (char *) "-noappend", (char *) "-quiet", NULL
      };
    ASSERT_OK (run_prog (avA) == 0, "mksquashfs pkgA");
    char *const avB[] =
      {
        mksq_bin, srcB, sqB, (char *) "-noappend", (char *) "-quiet", NULL
      };
    ASSERT_OK (run_prog (avB) == 0, "mksquashfs pkgB");
  }

  char mntA[320], mntB[320], mutDir[320];
  snprintf (mntA, sizeof (mntA), "%s/pkgA", pfx);
  snprintf (mntB, sizeof (mntB), "%s/pkgB", pfx);
  snprintf (mutDir, sizeof (mutDir), "%s/local_mut/bin", pfx);
  mkdir_p (mntA, 0755);
  mkdir_p (mntB, 0755);
  mkdir_p (mutDir, 0755);
  snprintf (p, sizeof (p), "%s/local_tool", mutDir);
  write_str (p, "mut\n", 0755);
  snprintf (p, sizeof (p), "%s/.hidden_pkg/bin", pfx);
  mkdir_p (p, 0755);
  snprintf (p, sizeof (p), "%s/.hidden_pkg/bin/hidden_only_cmd", pfx);
  write_tiny_exit0_exe (p);

  ASSERT_OK (mount_loop_squashfs (mount_bin, sqA, mntA) == 0, "mount pkgA");
  ASSERT_OK (mount_loop_squashfs (mount_bin, sqB, mntB) == 0, "mount pkgB");

  printf ("  [priv] 1. Differential oracle across mode={0,1,2} as root, fsuid=nobody, uid=nobody...\n");
  verify_modes_identical (argc, argv, pfx, work, "root");
  verify_modes_identical (argc, argv, pfx, work, "fsuid_nobody");
  verify_modes_identical (argc, argv, pfx, work, "uid_nobody");

  for (int m = 0; m <= 2; ++m)
    spawn_priv_torture_mode (argc, argv, m, work, pfx, mntA, mntB,
                             sqA, sqB, mount_bin);

  umount2 (mntA, MNT_DETACH);
  umount2 (mntB, MNT_DETACH);
  rm_rf (work);
  printf ("  [priv] PASS: All privileged SquashFS torture checks passed!\n");
}

static int
priv_torture_worker (int mode, const char *work, const char *pfx,
                     const char *mntA, const char *mntB,
                     const char *sqA, const char *sqB, const char *mount_bin)
{
  char p[4096];
  printf ("  [priv mode=%d] 2. Live grandchild overmount + raw SYSCALL mount/umount2 0-ms coherence...\n",
          mode);
  glob_t gl;
  char pat[1024];
  snprintf (pat, sizeof (pat), "%s/*/include/curses.h", pfx);
  ASSERT_OK (glob (pat, 0, NULL, &gl) == 0 && gl.gl_pathc == 1, "pre-overmount");
  globfree (&gl);

  char over_inc[640];
  snprintf (over_inc, sizeof (over_inc), "%s/include", mntA);
  /* Use raw SYS_mount / SYS_umount2 (bypassing glibc C wrappers, matching Go)! */
  ASSERT_OK (syscall (SYS_mount, "tmpfs", over_inc, "tmpfs", 0UL, "size=1M") == 0,
             "raw SYS_mount overmount");

  /* 0-ms sleep: glob() MUST immediately observe the raw-syscall overmount!  */
  ASSERT_OK (glob (pat, 0, NULL, &gl) == GLOB_NOMATCH,
             "raw SYS_mount overmount must hide curses.h immediately (0 ms)!");
  snprintf (p, sizeof (p), "%s/overmount.h", over_inc);
  write_str (p, "/* live */\n", 0644);
  {
    int ofd = open (p, O_RDONLY);
    ASSERT_OK (ofd >= 0, "open overmount.h immediately");
    close (ofd);
  }

  ASSERT_OK (syscall (SYS_umount2, over_inc, 0) == 0, "raw SYS_umount2");
  ASSERT_OK (glob (pat, 0, NULL, &gl) == 0 && gl.gl_pathc == 1,
             "raw SYS_umount2 must restore curses.h immediately (0 ms)!");
  globfree (&gl);

  printf ("  [priv mode=%d] 3. External-process mount coherence (0 ms glob, <= 65 ms mode=2 VFS)...\n",
          mode);
  char ext_probe[1024];
  snprintf (ext_probe, sizeof (ext_probe), "%s/ext_vfs_probe.h", over_inc);
  /* Warm single-path negative lookup before external process mounts over_inc! */
  ASSERT_OK (openat (AT_FDCWD, ext_probe, O_RDONLY) == -1 && errno == ENOENT,
             "pre-warm missing ext_vfs_probe.h");

  pid_t ext = fork ();
  ASSERT_OK (ext >= 0, "fork ext");
  if (ext == 0)
    {
      if (syscall (SYS_mount, "tmpfs", over_inc, "tmpfs", 0UL, "size=1M") != 0)
        _exit (2);
      int efd = open (ext_probe, O_WRONLY | O_CREAT | O_TRUNC, 0644);
      if (efd < 0)
        _exit (3);
      close (efd);
      _exit (0);
    }
  int st_ext = 0;
  waitpid (ext, &st_ext, 0);
  ASSERT_OK (WIFEXITED (st_ext) && WEXITSTATUS (st_ext) == 0, "ext mount");

  /* Zero sleep: glob() revalidates live kernel listmount(LSMT_ROOT) on every call! */
  ASSERT_OK (glob (pat, 0, NULL, &gl) == GLOB_NOMATCH,
             "glob() must detect external-process overmount with 0 ms delay!");

  /* Within <= 65 ms (past the 50 ms epoch window), mode=2 single-path statx and
     openat must also observe the external mount!  */
  usleep (65000);
  {
    struct statx stx;
    ASSERT_OK (statx (AT_FDCWD, ext_probe, 0, STATX_BASIC_STATS, &stx) == 0,
               "mode=%d statx after <= 65 ms external mount", mode);
    int efd = openat (AT_FDCWD, ext_probe, O_RDONLY);
    ASSERT_OK (efd >= 0, "mode=%d openat after <= 65 ms external mount", mode);
    close (efd);
  }
  ASSERT_OK (umount2 (over_inc, 0) == 0, "cleanup ext overmount");

  printf ("  [priv mode=%d] 4. Loop-mount swap churn (pkgA <-> pkgB)...\n", mode);
  ASSERT_OK (umount2 (mntA, 0) == 0, "umount pkgA");
  ASSERT_OK (umount2 (mntB, 0) == 0, "umount pkgB");
  ASSERT_OK (mount_loop_squashfs (mount_bin, sqB, mntA) == 0, "mount sqB on pkgA");
  ASSERT_OK (mount_loop_squashfs (mount_bin, sqA, mntB) == 0, "mount sqA on pkgB");
  snprintf (pat, sizeof (pat), "%s/*/bin/hello", pfx);
  ASSERT_OK (glob (pat, 0, NULL, &gl) == 0 && gl.gl_pathc == 1, "swapped glob");
  ASSERT_OK (strstr (gl.gl_pathv[0], "/pkgB/bin/hello") != NULL,
             "expected /pkgB/bin/hello after swap, got %s", gl.gl_pathv[0]);
  globfree (&gl);
  /* Restore original pkgA / pkgB mounts for subsequent mode runs.  */
  ASSERT_OK (umount2 (mntA, 0) == 0, "umount swapped pkgA");
  ASSERT_OK (umount2 (mntB, 0) == 0, "umount swapped pkgB");
  ASSERT_OK (mount_loop_squashfs (mount_bin, sqA, mntA) == 0, "restore pkgA");
  ASSERT_OK (mount_loop_squashfs (mount_bin, sqB, mntB) == 0, "restore pkgB");

  printf ("  [priv mode=%d] 4b. Intra-namespace raw MS_MOVE coherence (unchanged mnt_id set & pfx mtime)...\n",
          mode);
  {
    char mntC[320], stage_sq[320], stage_tmp[320], moved_hdr[700];
    snprintf (mntC, sizeof (mntC), "%s/pkgC", pfx);
    snprintf (stage_sq, sizeof (stage_sq), "%s/stage_sq_m%d", work, mode);
    snprintf (stage_tmp, sizeof (stage_tmp), "%s/stage_tmp_m%d", work, mode);
    mkdir_p (mntC, 0755);
    mkdir_p (stage_sq, 0755);
    mkdir_p (stage_tmp, 0755);
    ASSERT_OK (mount_loop_squashfs (mount_bin, sqB, stage_sq) == 0,
               "pre-mount stage_sq");
    ASSERT_OK (syscall (SYS_mount, "tmpfs", stage_tmp, "tmpfs", 0UL, "size=1M") == 0,
               "pre-mount stage_tmp");
    snprintf (p, sizeof (p), "%s/moved_over.h", stage_tmp);
    write_str (p, "/* moved */\n", 0644);

    /* Warm FSWC AFTER pre-creating mntC and pre-mounting stage_sq/stage_tmp so
       neither pfx's ctime/mtime nor the namespace's mnt_id_unique set changes! */
    char wpat[1024];
    snprintf (wpat, sizeof (wpat), "%s/*/bin/world", pfx);
    ASSERT_OK (glob (wpat, 0, NULL, &gl) == 0 && gl.gl_pathc == 1,
               "pre-move world count");
    globfree (&gl);

    snprintf (moved_hdr, sizeof (moved_hdr), "%s/moved_over.h", over_inc);
    ASSERT_OK (openat (AT_FDCWD, moved_hdr, O_RDONLY) == -1 && errno == ENOENT,
               "pre-warm missing moved_over.h");

    /* Move stage_sq -> mntC via raw SYS_mount(MS_MOVE) (bypassing glibc)! */
    ASSERT_OK (syscall (SYS_mount, stage_sq, mntC, NULL,
                        (unsigned long) MS_MOVE, NULL) == 0,
               "raw MS_MOVE stage_sq -> mntC");
    ASSERT_OK (glob (wpat, 0, NULL, &gl) == 0 && gl.gl_pathc == 2,
               "raw MS_MOVE into <prefix>/pkgC must be visible in 0 ms!");
    globfree (&gl);

    /* Move stage_tmp -> <prefix>/pkgA/include via raw SYS_mount(MS_MOVE)! */
    ASSERT_OK (syscall (SYS_mount, stage_tmp, over_inc, NULL,
                        (unsigned long) MS_MOVE, NULL) == 0,
               "raw MS_MOVE stage_tmp -> over_inc");
    snprintf (pat, sizeof (pat), "%s/*/include/curses.h", pfx);
    ASSERT_OK (glob (pat, 0, NULL, &gl) == GLOB_NOMATCH,
               "raw MS_MOVE overmount must hide curses.h in 0 ms!");

    usleep (65000);
    int mfd = openat (AT_FDCWD, moved_hdr, O_RDONLY);
    ASSERT_OK (mfd >= 0, "mode=%d openat moved_over.h after <= 65 ms", mode);
    close (mfd);

    ASSERT_OK (umount2 (over_inc, 0) == 0, "umount moved over_inc");
    ASSERT_OK (umount2 (mntC, 0) == 0, "umount moved mntC");
    rmdir (mntC);
    rmdir (stage_sq);
    rmdir (stage_tmp);
  }

  printf ("  [priv mode=%d] 5. 0700 ancestor warmed as root + raw SYS_setresuid(65534) DAC safety...\n",
          mode);
  char sec_anc[256], sec_sw[320], sec_pkg[384];
  snprintf (sec_anc, sizeof (sec_anc), "%s/root_only_anc_m%d", work, mode);
  snprintf (sec_sw, sizeof (sec_sw), "%s/sw", sec_anc);
  snprintf (sec_pkg, sizeof (sec_pkg), "%s/pkgA", sec_sw);
  mkdir_p (sec_pkg, 0755);
  chmod (sec_anc, 0700);
  ASSERT_OK (mount_loop_squashfs (mount_bin, sqA, sec_pkg) == 0, "mount sec_pkg");

  pid_t dac = fork ();
  ASSERT_OK (dac >= 0, "fork dac");
  if (dac == 0)
    {
      char spat[640], smiss[640];
      snprintf (spat, sizeof (spat), "%s/*", sec_sw);
      glob_t g2;
      if (glob (spat, 0, NULL, &g2) == 0)
        globfree (&g2);
      snprintf (smiss, sizeof (smiss), "%s/bin/nonexistent_dac_probe", sec_pkg);
      (void) open (smiss, O_RDONLY);

      /* Drop privileges via raw SYSCALL (bypassing glibc's setxid wrapper):
         open(smiss) MUST return EACCES, NEVER ENOENT, and glob(spat) MUST
         return GLOB_NOMATCH!  */
      if (syscall (SYS_setresgid, 65534, 65534, 65534) != 0
          || syscall (SYS_setresuid, 65534, 65534, 65534) != 0)
        _exit (3);
      errno = 0;
      int r = open (smiss, O_RDONLY);
      if (r != -1 || errno != EACCES)
        {
          fprintf (stderr, "DAC LEAK: expected EACCES, got r=%d errno=%d (%s)\n",
                   r, errno, strerror (errno));
          _exit (4);
        }
      memset (&g2, 0, sizeof (g2));
      if (glob (spat, 0, NULL, &g2) != GLOB_NOMATCH)
        _exit (5);
      _exit (0);
    }
  int st_dac = 0;
  waitpid (dac, &st_dac, 0);
  umount2 (sec_pkg, MNT_DETACH);
  ASSERT_OK (WIFEXITED (st_dac) && WEXITSTATUS (st_dac) == 0, "DAC safety failed");

  printf ("  [priv mode=%d] 6. Raw SYS_chroot() 0-ms cache invalidation...\n", mode);
  {
    char jail[320], jail_pkg[700], jail_mark[768];
    snprintf (jail, sizeof (jail), "%s/jail_m%d", work, mode);
    snprintf (jail_pkg, sizeof (jail_pkg), "%s%s/chroot_only_pkg", jail, pfx);
    mkdir_p (jail_pkg, 0755);
    snprintf (jail_mark, sizeof (jail_mark), "%s/inside_jail", jail_pkg);
    write_str (jail_mark, "ok\n", 0644);

    pid_t chr = fork ();
    ASSERT_OK (chr >= 0, "fork chroot");
    if (chr == 0)
      {
        char cpat[512];
        snprintf (cpat, sizeof (cpat), "%s/*", pfx);
        glob_t cg = { 0 };
        if (glob (cpat, 0, NULL, &cg) == 0)
          globfree (&cg);
        if (syscall (SYS_chroot, jail) != 0 || chdir ("/") != 0)
          _exit (2);
        snprintf (cpat, sizeof (cpat), "%s/*/inside_jail", pfx);
        memset (&cg, 0, sizeof (cg));
        int gr = glob (cpat, 0, NULL, &cg);
        bool ok = (gr == 0 && cg.gl_pathc == 1
                   && strstr (cg.gl_pathv[0], "chroot_only_pkg/inside_jail") != NULL);
        globfree (&cg);
        _exit (ok ? 0 : 3);
      }
    int st_chr = 0;
    waitpid (chr, &st_chr, 0);
    ASSERT_OK (WIFEXITED (st_chr) && WEXITSTATUS (st_chr) == 0,
               "raw SYS_chroot() invalidation failed");
  }

  printf ("  [priv mode=%d] 7. Host/tmpfs ancestor POSIX ACL xattr + setresuid(65534) DAC safety...\n",
          mode);
  {
    char acl_anc[256], acl_sw[320], acl_pkg[384];
    snprintf (acl_anc, sizeof (acl_anc), "%s/acl_anc_m%d", work, mode);
    snprintf (acl_sw, sizeof (acl_sw), "%s/sw", acl_anc);
    snprintf (acl_pkg, sizeof (acl_pkg), "%s/pkgA", acl_sw);
    mkdir_p (acl_pkg, 0755);
    ASSERT_OK (mount_loop_squashfs (mount_bin, sqA, acl_pkg) == 0, "mount acl_pkg");

    struct __attribute__ ((packed))
    {
      uint32_t version;
      struct __attribute__ ((packed))
      {
        uint16_t tag;
        uint16_t perm;
        uint32_t id;
      } entries[5];
    } anc_acl =
      {
        .version = 2u,
        .entries =
          {
            { 0x0001u, 0x0007u, 0xffffffffu },
            { 0x0002u, 0x0000u, 65534u },
            { 0x0004u, 0x0005u, 0xffffffffu },
            { 0x0010u, 0x0005u, 0xffffffffu },
            { 0x0020u, 0x0005u, 0xffffffffu },
          }
      };
    if (setxattr (acl_anc, "system.posix_acl_access", &anc_acl,
                  sizeof (anc_acl), 0) == 0)
      {
        pid_t adac = fork ();
        ASSERT_OK (adac >= 0, "fork adac");
        if (adac == 0)
          {
            char spat[640], smiss[640];
            snprintf (spat, sizeof (spat), "%s/*", acl_sw);
            glob_t g2;
            if (glob (spat, 0, NULL, &g2) == 0)
              globfree (&g2);
            snprintf (smiss, sizeof (smiss),
                      "%s/bin/nonexistent_acl_anc_probe", acl_pkg);
            (void) open (smiss, O_RDONLY);

            if (setresgid (65534, 65534, 65534) != 0
                || setresuid (65534, 65534, 65534) != 0)
              _exit (3);
            if (access (acl_sw, X_OK) < 0 && errno == EACCES)
              {
                errno = 0;
                int r = open (smiss, O_RDONLY);
                if (r != -1 || errno != EACCES)
                  _exit (4);
              }
            _exit (0);
          }
        int st_adac = 0;
        waitpid (adac, &st_adac, 0);
        ASSERT_OK (WIFEXITED (st_adac) && WEXITSTATUS (st_adac) == 0,
                   "Ancestor POSIX ACL DAC safety failed");
      }
    umount2 (acl_pkg, MNT_DETACH);
  }

  printf ("  [priv mode=%d] 8. 0751 group-readable <prefix> + setgroups() drop DAC safety...\n",
          mode);
  {
    char grp_sw[320], grp_pkg[384];
    snprintf (grp_sw, sizeof (grp_sw), "%s/grp0751_sw_m%d", work, mode);
    snprintf (grp_pkg, sizeof (grp_pkg), "%s/pkgA", grp_sw);
    mkdir_p (grp_pkg, 0755);
    ASSERT_OK (chown (grp_sw, 0, 42) == 0, "chown grp_sw");
    ASSERT_OK (chmod (grp_sw, 0751) == 0, "chmod grp_sw 0751");
    ASSERT_OK (mount_loop_squashfs (mount_bin, sqA, grp_pkg) == 0, "mount grp_pkg");

    pid_t gdac = fork ();
    ASSERT_OK (gdac >= 0, "fork gdac");
    if (gdac == 0)
      {
        gid_t g42 = 42;
        if (setgroups (1, &g42) != 0)
          _exit (2);
        char gpat[640];
        snprintf (gpat, sizeof (gpat), "%s/*/bin/hello", grp_sw);
        glob_t g2 = { 0 };
        if (glob (gpat, 0, NULL, &g2) != 0 || g2.gl_pathc != 1)
          _exit (3);
        globfree (&g2);

        if (setgroups (0, NULL) != 0
            || setresgid (65534, 65534, 65534) != 0
            || setresuid (65534, 65534, 65534) != 0)
          _exit (4);
        memset (&g2, 0, sizeof (g2));
        int gr = glob (gpat, 0, NULL, &g2);
        globfree (&g2);
        if (gr != GLOB_NOMATCH)
          _exit (5);

        char wpath[640];
        snprintf (wpath, sizeof (wpath), "%s/*/bin", grp_sw);
        setenv ("PATH", wpath, 1);
        char *sp_argv[] = { (char *) "hello", NULL };
        pid_t spid = 0;
        int sr = posix_spawnp (&spid, "hello", NULL, NULL, sp_argv, environ);
        if (sr == 0)
          {
            waitpid (spid, NULL, 0);
            _exit (6);
          }
        _exit (0);
      }
    int st_gdac = 0;
    waitpid (gdac, &st_gdac, 0);
    ASSERT_OK (WIFEXITED (st_gdac) && WEXITSTATUS (st_gdac) == 0,
               "0751 prefix + setgroups() drop DAC safety failed");
    umount2 (grp_pkg, MNT_DETACH);
  }
  return 0;
}

static void
spawn_priv_torture_mode (int argc, char **argv, int mode, const char *work,
                         const char *pfx, const char *mntA, const char *mntB,
                         const char *sqA, const char *sqB,
                         const char *mount_bin)
{
  pid_t pid = fork ();
  ASSERT_OK (pid >= 0, "fork priv worker");
  if (pid == 0)
    {
      char tun[64], mstr[16];
      snprintf (tun, sizeof (tun), "glibc.fswc.mode=%d", mode);
      snprintf (mstr, sizeof (mstr), "%d", mode);
      setenv ("GLIBC_TUNABLES", tun, 1);

      char *cargv[40];
      char self_buf[PATH_MAX];
      int k = 0;
      int r_idx = -1;
      for (int i = 1; i < argc; ++i)
        if (strcmp (argv[i], "--runner") == 0)
          {
            r_idx = i + 1;
            break;
          }
      if (r_idx > 0)
        for (int i = r_idx; i < argc && k < 24; ++i)
          cargv[k++] = argv[i];
      else
        cargv[k++] = (char *) resolve_self_exe (argv[0], self_buf,
                                                sizeof (self_buf));

      cargv[k++] = (char *) "--priv-worker";
      cargv[k++] = mstr;
      cargv[k++] = (char *) work;
      cargv[k++] = (char *) pfx;
      cargv[k++] = (char *) mntA;
      cargv[k++] = (char *) mntB;
      cargv[k++] = (char *) sqA;
      cargv[k++] = (char *) sqB;
      cargv[k++] = (char *) mount_bin;
      cargv[k] = NULL;
      execv (cargv[0], cargv);
      _exit (127);
    }
  int status = 0;
  ASSERT_OK (waitpid (pid, &status, 0) == pid, "waitpid priv worker");
  ASSERT_OK (WIFEXITED (status) && WEXITSTATUS (status) == 0,
             "priv worker mode=%d failed", mode);
}

int
main (int argc, char **argv)
{
  for (int i = 1; i + 3 < argc; ++i)
    if (strcmp (argv[i], "--oracle-worker") == 0)
      return oracle_worker (argv[i + 1], argv[i + 2], argv[i + 3]);

  for (int i = 1; i + 8 < argc; ++i)
    if (strcmp (argv[i], "--priv-worker") == 0)
      return priv_torture_worker (atoi (argv[i + 1]), argv[i + 2],
                                  argv[i + 3], argv[i + 4], argv[i + 5],
                                  argv[i + 6], argv[i + 7], argv[i + 8]);

  printf ("=== FSWC v5 Tier-2 Torture & Differential Test Runner ===\n");

  char work[] = "/tmp/fswc-unpriv.XXXXXX";
  ASSERT_OK (mkdtemp (work) != NULL, "mkdtemp");
  chmod (work, 0755);

  /* 1a. Host-independent synthetic multi-package differential oracle (always
     runs, ensuring 100% coverage even on ephemeral runners with 0 SquashFS). */
  {
    char synth[320], p[512];
    snprintf (synth, sizeof (synth), "%s/synth_sw", work);
    snprintf (p, sizeof (p), "%s/pkgA", synth);
    populate_pkgA_tree (p);
    snprintf (p, sizeof (p), "%s/pkgB/bin", synth);
    mkdir_p (p, 0755);
    snprintf (p, sizeof (p), "%s/pkgB/bin/world", synth);
    write_tiny_exit0_exe (p);
    snprintf (p, sizeof (p), "%s/local_mut/bin", synth);
    mkdir_p (p, 0755);
    snprintf (p, sizeof (p), "%s/local_mut/bin/local_tool", synth);
    write_str (p, "mut\n", 0755);
    snprintf (p, sizeof (p), "%s/.hidden_pkg/bin", synth);
    mkdir_p (p, 0755);
    snprintf (p, sizeof (p), "%s/.hidden_pkg/bin/hidden_only_cmd", synth);
    write_tiny_exit0_exe (p);
    snprintf (p, sizeof (p), "%s/pkgA-1.0.squashfs", synth);
    write_str (p, "decoy\n", 0644);

    printf ("  [unpriv] Testing synthetic multi-package tree across mode={0,1,2}...\n");
    verify_modes_identical (argc, argv, synth, work, "synth");
  }

  /* 1b. Unprivileged live SquashFS differential test if any SquashFS mount
     is present in /proc/self/mountinfo.  */
  char live_buf[512] = "";
  const char *live = discover_squash_prefix (live_buf, sizeof (live_buf));
  if (live != NULL)
    {
      printf ("  [unpriv] Testing live SquashFS prefix: %s across mode={0,1,2}...\n",
              live);
      verify_modes_identical (argc, argv, live, work, "self");
    }
  else
    printf ("  [unpriv] No live SquashFS mounts on host; synthetic suite verified.\n");

  /* 2. Privileged CLONE_NEWNS pathological SquashFS torture if root.  */
  if (geteuid () == 0)
    run_privileged_squashfs_torture (argc, argv);
  else
    printf ("  [info] Running unprivileged (euid=%u); re-run under sudo for CLONE_NEWNS SquashFS mount/overmount/DAC torture.\n",
            (unsigned) geteuid ());

  rm_rf (work);

  printf ("=== ALL TEST-FSWC CHECKS PASSED ===\n");
  return 0;
}
