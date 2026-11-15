/* bench-fswc.c -- FSWC v5 Tier 0..3 micro/macro benchmark & CoW verifier.
 *
 * Host-independent:
 *   - Discovers live SquashFS parent prefixes generically via /proc/self/mountinfo
 *     (or --prefix / FSWC_TEST_PREFIX), falling back to a synthetic 16-package
 *     temp directory tree when zero SquashFS mounts exist on the host.
 *   - Zero system() calls and zero hardcoded /sw, /snap, /bin/sh, or /usr/bin
 *     host path dependencies.
 *
 * Build:
 *   gcc -O2 -Wall -Wextra -pthread -o bench-fswc tools/bench-fswc.c -ldl
 * Run under newly built glibc:
 *   ./bench-fswc [--prefix <dir>] [--runner <ld.so> --library-path <...> ./bench-fswc]
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <glob.h>
#include <limits.h>
#include <paths.h>
#include <spawn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef SQUASHFS_MAGIC
# define SQUASHFS_MAGIC 0x73717368
#endif
#ifndef GLOB_PATHS
# define GLOB_PATHS (1 << 29)
#endif

extern char **environ;

static uint64_t
now_ns (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (uint64_t) ts.tv_sec * 1000000000ULL + (uint64_t) ts.tv_nsec;
}

static int
rm_rf_cb (const char *fpath, const struct stat *sb, int tflag,
          struct FTW *ftwbuf)
{
  (void) sb;
  (void) tflag;
  (void) ftwbuf;
  remove (fpath);
  return 0;
}

static void
rm_rf (const char *path)
{
  nftw (path, rm_rf_cb, 32, FTW_DEPTH | FTW_PHYS);
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

static bool
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
  if (fd < 0)
    return false;
  ssize_t nw = write (fd, &img, total);
  close (fd);
  chmod (path, 0755);
  return nw == (ssize_t) total;
#else
  char true_path[PATH_MAX];
  if (!find_prog_in_path ("true", true_path, sizeof (true_path)))
    return false;
  int sfd = open (true_path, O_RDONLY);
  if (sfd < 0)
    return false;
  int dfd = open (path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
  if (dfd < 0)
    {
      close (sfd);
      return false;
    }
  char buf[4096];
  ssize_t r;
  bool ok = true;
  while ((r = read (sfd, buf, sizeof (buf))) > 0)
    if (write (dfd, buf, (size_t) r) != r)
      {
        ok = false;
        break;
      }
  close (dfd);
  close (sfd);
  chmod (path, 0755);
  return ok;
#endif
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

static void
mkdir_p (const char *path)
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
  mkdir (tmp, 0755);
}

static void
populate_synthetic_prefix (const char *pfx)
{
  for (int i = 0; i < 16; ++i)
    {
      char d[512], f[576];
      snprintf (d, sizeof (d), "%s/pkg%02d/bin", pfx, i);
      mkdir_p (d);
      snprintf (d, sizeof (d), "%s/pkg%02d/include", pfx, i);
      mkdir_p (d);
      snprintf (d, sizeof (d), "%s/pkg%02d/lib/python3.14/site-packages", pfx, i);
      mkdir_p (d);
      snprintf (d, sizeof (d), "%s/pkg%02d/share/terminfo/x", pfx, i);
      mkdir_p (d);
      if (i == 0)
        {
          snprintf (f, sizeof (f), "%s/pkg00/bin/bash", pfx);
          write_tiny_exit0_exe (f);
          snprintf (f, sizeof (f), "%s/pkg00/bin/true", pfx);
          write_tiny_exit0_exe (f);
          snprintf (f, sizeof (f), "%s/pkg00/share/terminfo/x/xterm", pfx);
          close (open (f, O_WRONLY | O_CREAT | O_TRUNC, 0644));
        }
    }
}

static void
clean_shm_dir (bool keep_pkg_tier1)
{
  char shm[128];
  snprintf (shm, sizeof (shm), "/dev/shm/.fswc-%u", (unsigned) geteuid ());
  DIR *d = opendir (shm);
  if (d == NULL)
    return;
  int dfd = dirfd (d);
  struct dirent *de;
  while ((de = readdir (d)) != NULL)
    {
      if (de->d_name[0] == '.')
        continue;
      if (keep_pkg_tier1 && strncmp (de->d_name, "pkg_", 4) == 0)
        continue;
      unlinkat (dfd, de->d_name, 0);
    }
  closedir (d);
}

struct smaps_fswc_stats
{
  size_t mappings;
  long anon_kb;
  long priv_dirty_kb;
  long shared_dirty_kb;
  bool all_mayshare;
};

static bool
check_blob_smaps (struct smaps_fswc_stats *st)
{
  memset (st, 0, sizeof (*st));
  st->all_mayshare = true;
  FILE *fp = fopen ("/proc/self/smaps", "r");
  if (fp == NULL)
    return false;
  char line[1024];
  bool in_fswc = false;
  while (fgets (line, sizeof (line), fp) != NULL)
    {
      if ((line[0] >= '0' && line[0] <= '9')
          || (line[0] >= 'a' && line[0] <= 'f'))
        {
          in_fswc = (strstr (line, "/.fswc-") != NULL);
          if (in_fswc)
            ++st->mappings;
        }
      else if (in_fswc)
        {
          long kb = 0;
          if (strncmp (line, "Anonymous:", 10) == 0
              && sscanf (line + 10, "%ld", &kb) == 1)
            st->anon_kb += kb;
          else if (strncmp (line, "Private_Dirty:", 14) == 0
                   && sscanf (line + 14, "%ld", &kb) == 1)
            st->priv_dirty_kb += kb;
          else if (strncmp (line, "Shared_Dirty:", 13) == 0
                   && sscanf (line + 13, "%ld", &kb) == 1)
            st->shared_dirty_kb += kb;
          else if (strncmp (line, "VmFlags:", 8) == 0)
            {
              if (strstr (line + 8, " ms") == NULL)
                st->all_mayshare = false;
            }
        }
    }
  fclose (fp);
  return true;
}

static int
hold_shm_blobs_worker (int ready_wfd, int hold_rfd)
{
  char shm[128];
  snprintf (shm, sizeof (shm), "/dev/shm/.fswc-%u", (unsigned) geteuid ());
  DIR *d = opendir (shm);
  volatile uint64_t sink = 0;
  if (d != NULL)
    {
      int dfd = dirfd (d);
      struct dirent *de;
      while ((de = readdir (d)) != NULL)
        {
          if (strncmp (de->d_name, "blob_", 5) != 0)
            continue;
          int fd = openat (dfd, de->d_name, O_RDONLY | O_CLOEXEC);
          if (fd < 0)
            continue;
          struct stat st;
          if (fstat (fd, &st) == 0 && st.st_size > 0)
            {
              size_t sz = (size_t) st.st_size;
              const uint8_t *m = mmap (NULL, sz, PROT_READ, MAP_SHARED, fd, 0);
              if (m != MAP_FAILED)
                {
                  for (size_t off = 0; off < sz; off += 4096)
                    sink += m[off];
                  sink += m[sz - 1];
                }
            }
          close (fd);
        }
      closedir (d);
    }
  (void) sink;
  char c = 'R';
  if (write (ready_wfd, &c, 1) != 1)
    return 1;
  close (ready_wfd);
  while (read (hold_rfd, &c, 1) > 0)
    ;
  return 0;
}

static int
worker_run (const char *prefix, const char *which)
{
  if (strcmp (which, "cold-glob") == 0)
    {
      char pat[512];
      snprintf (pat, sizeof (pat), "%s/*/bin/bash", prefix);
      glob_t gl;
      uint64_t t0 = now_ns ();
      int r = glob (pat, 0, NULL, &gl);
      if (r == GLOB_NOMATCH)
        {
          snprintf (pat, sizeof (pat), "%s/*/usr/bin/bash", prefix);
          r = glob (pat, 0, NULL, &gl);
        }
      uint64_t dt = now_ns () - t0;
      if (r == 0)
        globfree (&gl);
      printf ("%.3f\n", (double) dt / 1e6);
      return 0;
    }

  if (strcmp (which, "noop") == 0)
    return 0;

  if (strcmp (which, "suite") == 0)
    {
      const char *tun = getenv ("GLIBC_TUNABLES");
      printf ("\n=== Worker Suite (%s) [prefix=%s] ===\n",
              tun ? tun : "default", prefix);

      char pat[512];
      glob_t gl;

      /* Warm slot first.  */
      snprintf (pat, sizeof (pat), "%s/*", prefix);
      if (glob (pat, GLOB_ONLYDIR, NULL, &gl) == 0)
        globfree (&gl);

      struct smaps_fswc_stats sm;
      check_blob_smaps (&sm);
      printf ("  SHM mappings: %zu, Anonymous: %ld kB, Private_Dirty: %ld kB, Shared_Dirty: %ld kB\n",
              sm.mappings, sm.anon_kb, sm.priv_dirty_kb, sm.shared_dirty_kb);

      /* 1. Warm glob("<prefix>/<star>/bin/bash") or usr/bin/bash.  */
      snprintf (pat, sizeof (pat), "%s/*/bin/bash", prefix);
      if (glob (pat, 0, NULL, &gl) == GLOB_NOMATCH)
        snprintf (pat, sizeof (pat), "%s/*/usr/bin/bash", prefix);
      else
        globfree (&gl);

      const int N_GLOB = 2000;
      uint64_t t0 = now_ns ();
      size_t hits = 0;
      for (int i = 0; i < N_GLOB; ++i)
        {
          if (glob (pat, 0, NULL, &gl) == 0)
            {
              hits = gl.gl_pathc;
              globfree (&gl);
            }
        }
      uint64_t dt = now_ns () - t0;
      printf ("  %-44s %8.2f us/call (matches=%zu)\n",
              pat, (double) dt / 1000.0 / N_GLOB, hits);

      /* 2. Warm negative glob("<prefix>/<star>/bin/missing_fswc_bench").  */
      snprintf (pat, sizeof (pat), "%s/*/bin/missing_fswc_bench", prefix);
      t0 = now_ns ();
      for (int i = 0; i < N_GLOB; ++i)
        {
          if (glob (pat, 0, NULL, &gl) == 0)
            globfree (&gl);
        }
      dt = now_ns () - t0;
      printf ("  %-44s %8.2f us/call\n", pat, (double) dt / 1000.0 / N_GLOB);

      /* 3. GLOB_BRACE | GLOB_ONLYDIR {bin,include,lib,usr}.  */
      snprintf (pat, sizeof (pat), "%s/*/{bin,include,lib,usr}", prefix);
      t0 = now_ns ();
      hits = 0;
      for (int i = 0; i < 1000; ++i)
        {
          if (glob (pat, GLOB_BRACE | GLOB_ONLYDIR, NULL, &gl) == 0)
            {
              hits = gl.gl_pathc;
              globfree (&gl);
            }
        }
      dt = now_ns () - t0;
      printf ("  %-44s %8.2f us/call (matches=%zu)\n",
              "<prefix>/*/{bin,include,lib,usr}",
              (double) dt / 1000.0 / 1000, hits);

      /* 4. Deep wildcard scan (terminfo / share + Python site-packages).  */
      snprintf (pat, sizeof (pat), "%s/*/share/terminfo/*/*", prefix);
      if (glob (pat, 0, NULL, &gl) == GLOB_NOMATCH)
        snprintf (pat, sizeof (pat), "%s/*/usr/share/doc/*", prefix);
      else
        globfree (&gl);
      t0 = now_ns ();
      hits = 0;
      for (int i = 0; i < 200; ++i)
        {
          if (glob (pat, 0, NULL, &gl) == 0)
            {
              hits = gl.gl_pathc;
              globfree (&gl);
            }
        }
      dt = now_ns () - t0;
      printf ("  %-44s %8.2f us/call (matches=%zu)\n",
              pat, (double) dt / 1000.0 / 200, hits);

      snprintf (pat, sizeof (pat), "%s/*/lib/python3.*/site-packages/*", prefix);
      if (glob (pat, 0, NULL, &gl) == GLOB_NOMATCH)
        snprintf (pat, sizeof (pat), "%s/*/usr/lib/python3*/*", prefix);
      else
        globfree (&gl);
      t0 = now_ns ();
      hits = 0;
      for (int i = 0; i < 500; ++i)
        {
          if (glob (pat, 0, NULL, &gl) == 0)
            {
              hits = gl.gl_pathc;
              globfree (&gl);
            }
        }
      dt = now_ns () - t0;
      printf ("  %-44s %8.2f us/call (matches=%zu)\n",
              "<prefix>/*/lib/python3.*/site-packages/*",
              (double) dt / 1000.0 / 500, hits);

      /* 4b. Wildcard PATH posix_spawnp x 1,000 ("true"), with a host-neutral
         fallback bin directory at the tail of PATH so it works even if <prefix>
         itself does not ship a "true" executable.  */
      {
        char fb_bin[] = "/tmp/bench-fswc-bin.XXXXXX";
        if (mkdtemp (fb_bin) != NULL)
          {
            char fb_true[128];
            snprintf (fb_true, sizeof (fb_true), "%s/true", fb_bin);
            (void) write_tiny_exit0_exe (fb_true);

            const char *old_path = getenv ("PATH");
            char *saved = old_path != NULL ? strdup (old_path) : NULL;
            char wpath[1200];
            snprintf (wpath, sizeof (wpath), "%s/*/bin:%s/*/usr/bin:%s",
                      prefix, prefix, fb_bin);
            setenv ("PATH", wpath, 1);
            char *sp_argv[] = { (char *) "true", NULL };
            pid_t wp = 0;
            if (posix_spawnp (&wp, "true", NULL, NULL, sp_argv, environ) == 0)
              waitpid (wp, NULL, 0);
            const int N_PSPAWN = 1000;
            t0 = now_ns ();
            for (int i = 0; i < N_PSPAWN; ++i)
              {
                pid_t sp = 0;
                if (posix_spawnp (&sp, "true", NULL, NULL, sp_argv, environ) == 0)
                  waitpid (sp, NULL, 0);
              }
            dt = now_ns () - t0;
            printf ("  posix_spawnp wildcard PATH (%dx 'true'):   %8.1f us/spawn (%.2f ms total)\n",
                    N_PSPAWN, (double) dt / 1000.0 / N_PSPAWN, (double) dt / 1e6);
            if (saved != NULL)
              {
                setenv ("PATH", saved, 1);
                free (saved);
              }
            else
              unsetenv ("PATH");
            rm_rf (fb_bin);
          }
      }

      /* 5. Non-SquashFS /tmp bailout check (< 5 us target for FSWC probe).  */
      char tmp_dir[] = "/tmp/bench-fswc-plain.XXXXXX";
      if (mkdtemp (tmp_dir) != NULL)
        {
          char sub[128];
          snprintf (sub, sizeof (sub), "%s/sub", tmp_dir);
          mkdir (sub, 0755);
          snprintf (pat, sizeof (pat), "%s/*/missing", tmp_dir);
          if (glob (pat, 0, NULL, &gl) == 0)
            globfree (&gl);
          t0 = now_ns ();
          for (int i = 0; i < 2000; ++i)
            {
              if (glob (pat, 0, NULL, &gl) == 0)
                globfree (&gl);
            }
          dt = now_ns () - t0;
          printf ("  %-44s %8.2f us/call\n",
                  "non-SquashFS /tmp/<plain>/*/missing",
                  (double) dt / 1000.0 / 2000);
          rmdir (sub);
          rmdir (tmp_dir);
        }

      /* 6. Compiler-style -I search burst: N_DIRS * 200 missing headers via
         openat(O_RDONLY) and statx().  */
      snprintf (pat, sizeof (pat), "%s/*/include", prefix);
      int gr = glob (pat, GLOB_ONLYDIR, NULL, &gl);
      if (gr != 0 || gl.gl_pathc == 0)
        {
          if (gr == 0)
            globfree (&gl);
          snprintf (pat, sizeof (pat), "%s/*/usr/include", prefix);
          gr = glob (pat, GLOB_ONLYDIR, NULL, &gl);
        }
      if (gr == 0 && gl.gl_pathc > 0)
        {
          size_t ndirs = 0;
          char inc_paths[52][512];
          for (size_t d = 0; d < gl.gl_pathc && ndirs < 52; ++d)
            {
              /* Skip mutable top-level symlinks so we measure immutable -I
                 directories directly.  */
              const char *s = gl.gl_pathv[d] + strlen (prefix) + 1;
              const char *slash = strchr (s, '/');
              if (slash != NULL)
                {
                  char top[512];
                  size_t tlen = (size_t) (slash - gl.gl_pathv[d]);
                  if (tlen < sizeof (top))
                    {
                      memcpy (top, gl.gl_pathv[d], tlen);
                      top[tlen] = '\0';
                      struct stat lst;
                      if (lstat (top, &lst) == 0 && S_ISLNK (lst.st_mode))
                        continue;
                    }
                }
              snprintf (inc_paths[ndirs++], sizeof (inc_paths[0]), "%s",
                        gl.gl_pathv[d]);
            }
          if (ndirs == 0)
            {
              ndirs = gl.gl_pathc < 52 ? gl.gl_pathc : 52;
              for (size_t d = 0; d < ndirs; ++d)
                snprintf (inc_paths[d], sizeof (inc_paths[d]), "%s",
                          gl.gl_pathv[d]);
            }

          const int N_HDRS = 200;
          t0 = now_ns ();
          for (int h = 0; h < N_HDRS; ++h)
            {
              for (size_t d = 0; d < ndirs; ++d)
                {
                  char pbuf[640];
                  snprintf (pbuf, sizeof (pbuf),
                            "%.500s/nonexistent_hdr_%d.h", inc_paths[d], h);
                  int fd = openat (AT_FDCWD, pbuf, O_RDONLY | O_CLOEXEC);
                  if (fd >= 0)
                    close (fd);
                }
            }
          dt = now_ns () - t0;
          double total_probes = (double) ndirs * N_HDRS;
          printf ("  openat -I burst (%zux%d=%0.f misses):       %8.1f ns/probe (%.2f ms total)\n",
                  ndirs, N_HDRS, total_probes,
                  (double) dt / total_probes, (double) dt / 1e6);

          struct statx stx;
          t0 = now_ns ();
          for (int h = 0; h < N_HDRS; ++h)
            {
              for (size_t d = 0; d < ndirs; ++d)
                {
                  char pbuf[640];
                  snprintf (pbuf, sizeof (pbuf),
                            "%.500s/nonexistent_hdr_%d.h", inc_paths[d], h);
                  statx (AT_FDCWD, pbuf, AT_NO_AUTOMOUNT,
                         STATX_BASIC_STATS, &stx);
                }
            }
          dt = now_ns () - t0;
          printf ("  statx  -I burst (%zux%d=%0.f misses):       %8.1f ns/probe (%.2f ms total)\n",
                  ndirs, N_HDRS, total_probes,
                  (double) dt / total_probes, (double) dt / 1e6);

          globfree (&gl);
        }

      check_blob_smaps (&sm);
      printf ("  Post-suite SHM: mappings=%zu, Anonymous=%ld kB, Private_Dirty=%ld kB, Shared_Dirty=%ld kB\n",
              sm.mappings, sm.anon_kb, sm.priv_dirty_kb, sm.shared_dirty_kb);
      if (!sm.all_mayshare || sm.anon_kb > 0 || sm.priv_dirty_kb > 0)
        {
          fprintf (stderr,
                   "FAIL: CoW check failed (mayshare=%d, Anonymous=%ld kB, Private_Dirty=%ld kB)!\n",
                   (int) sm.all_mayshare, sm.anon_kb, sm.priv_dirty_kb);
          return 1;
        }
      return 0;
    }

  return 1;
}

static int
spawn_self_mode (int argc, char **argv, int mode, const char *prefix,
                 const char *which)
{
  pid_t pid = fork ();
  if (pid < 0)
    return -1;
  if (pid == 0)
    {
      char tun[64];
      snprintf (tun, sizeof (tun), "glibc.fswc.mode=%d", mode);
      setenv ("GLIBC_TUNABLES", tun, 1);

      char *cargv[32];
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
        {
          for (int i = r_idx; i < argc && k < 24; ++i)
            cargv[k++] = argv[i];
        }
      else
        cargv[k++] = (char *) resolve_self_exe (argv[0], self_buf,
                                                sizeof (self_buf));

      cargv[k++] = (char *) "--worker";
      cargv[k++] = (char *) prefix;
      cargv[k++] = (char *) which;
      cargv[k] = NULL;
      execv (cargv[0], cargv);
      _exit (127);
    }
  int status = 0;
  waitpid (pid, &status, 0);
  return (WIFEXITED (status) && WEXITSTATUS (status) == 0) ? 0 : -1;
}

static int
run_gpp_mode (const char *gpp_bin, char **gpp_argv, int mode)
{
  pid_t pid = fork ();
  if (pid < 0)
    return -1;
  if (pid == 0)
    {
      char tun[64];
      snprintf (tun, sizeof (tun), "glibc.fswc.mode=%d", mode);
      setenv ("GLIBC_TUNABLES", tun, 1);
      const char *cp = getenv ("PATH");
      if (cp == NULL || *cp == '\0')
        setenv ("PATH", FSWC_TOOL_DEFPATH, 1);
      execv (gpp_bin, gpp_argv);
      _exit (127);
    }
  int status = 0;
  if (waitpid (pid, &status, 0) != pid)
    return -1;
  return (WIFEXITED (status) && WEXITSTATUS (status) == 0) ? 0 : -1;
}

int
main (int argc, char **argv)
{
  const char *prefix = NULL;
  for (int i = 1; i < argc; ++i)
    {
      if (strcmp (argv[i], "--worker") == 0 && i + 2 < argc)
        return worker_run (argv[i + 1], argv[i + 2]);
      if (strcmp (argv[i], "--prefix") == 0 && i + 1 < argc)
        prefix = argv[++i];
      if (strcmp (argv[i], "--runner") == 0)
        break;
    }

  char disc_buf[512] = "";
  char synth_root[] = "/tmp/bench-fswc-synth.XXXXXX";
  bool using_synth = false;
  if (prefix == NULL)
    {
      prefix = discover_squash_prefix (disc_buf, sizeof (disc_buf));
      if (prefix == NULL)
        {
          if (mkdtemp (synth_root) == NULL)
            return 1;
          chmod (synth_root, 0755);
          populate_synthetic_prefix (synth_root);
          prefix = synth_root;
          using_synth = true;
        }
    }

  printf ("FSWC v5 Benchmark Harness (target prefix: %s%s)\n",
          prefix, using_synth ? " [synthetic no-SquashFS fallback]" : "");

  /* Tier 0: Cold /dev/shm build (mode=1 default).  */
  clean_shm_dir (false);
  printf ("Tier 0 (cold /dev/shm build + glob ms): ");
  fflush (stdout);
  if (spawn_self_mode (argc, argv, 1, prefix, "cold-glob") != 0)
    {
      if (using_synth)
        rm_rf (synth_root);
      return 1;
    }

  /* Tier 1: Cold ns and blob caches with warm pkg Tier-1 subtree cache.  */
  clean_shm_dir (true);
  printf ("Tier 1 (warm pkg_* -> blob_* assembly ms): ");
  fflush (stdout);
  if (spawn_self_mode (argc, argv, 1, prefix, "cold-glob") != 0)
    {
      if (using_synth)
        rm_rf (synth_root);
      return 1;
    }

  /* Tier 2: Warm cross-process spawn x 200 across mode={0, 1, 2}.  */
  for (int m = 0; m <= 2; ++m)
    {
      const int N_SPAWN = 200;
      uint64_t t0 = now_ns ();
      for (int i = 0; i < N_SPAWN; ++i)
        if (spawn_self_mode (argc, argv, m, prefix, "noop") != 0)
          {
            if (using_synth)
              rm_rf (synth_root);
            return 1;
          }
      uint64_t dt = now_ns () - t0;
      printf ("Tier 2 (%d process spawns, mode=%d): %.2f ms total (%.1f us/proc)\n",
              N_SPAWN, m, (double) dt / 1e6, (double) dt / 1000.0 / N_SPAWN);
    }

  /* Start concurrent MAP_SHARED reader process holding /dev/shm/.fswc-<uid>/blob_*
     faulted in so smaps verifies folio_mapcount >= 2 zero-CoW Shared_Dirty
     (Anonymous == 0 kB, Private_Dirty == 0 kB) across independent processes! */
  int ready_pipe[2] = { -1, -1 };
  int hold_pipe[2] = { -1, -1 };
  pid_t holder_pid = -1;
  if (pipe (ready_pipe) == 0)
    {
      if (pipe (hold_pipe) == 0)
        {
          holder_pid = fork ();
          if (holder_pid == 0)
            {
              close (ready_pipe[0]);
              close (hold_pipe[1]);
              _exit (hold_shm_blobs_worker (ready_pipe[1], hold_pipe[0]));
            }
          else if (holder_pid > 0)
            {
              close (ready_pipe[1]);
              close (hold_pipe[0]);
              char rch = 0;
              if (read (ready_pipe[0], &rch, 1) != 1)
                {
                  close (ready_pipe[0]);
                  close (hold_pipe[1]);
                  waitpid (holder_pid, NULL, 0);
                  if (using_synth)
                    rm_rf (synth_root);
                  return 1;
                }
              close (ready_pipe[0]);
            }
          else
            {
              close (ready_pipe[0]);
              close (ready_pipe[1]);
              close (hold_pipe[0]);
              close (hold_pipe[1]);
            }
        }
      else
        {
          close (ready_pipe[0]);
          close (ready_pipe[1]);
        }
    }

  int rc = 0;
  /* Tier 3: In-process micro/macro suite across mode={0, 1, 2}.  */
  for (int mode = 0; mode <= 2; ++mode)
    if (spawn_self_mode (argc, argv, mode, prefix, "suite") != 0)
      {
        rc = 1;
        break;
      }

  if (holder_pid > 0)
    {
      close (hold_pipe[1]);
      int st = 0;
      waitpid (holder_pid, &st, 0);
    }

  /* End-to-end g++ <iostream> compile + link macrobenchmark when g++ is in PATH
     (invoked directly via fork + execv with zero system() shell dependency!). */
  char gpp_bin[PATH_MAX];
  if (rc == 0 && find_prog_in_path ("g++", gpp_bin, sizeof (gpp_bin)))
    {
      char cxx_dir[] = "/tmp/bench-fswc-cxx.XXXXXX";
      if (mkdtemp (cxx_dir) != NULL)
        {
          char src[256], bin[256];
          snprintf (src, sizeof (src), "%s/hello.cc", cxx_dir);
          snprintf (bin, sizeof (bin), "%s/hello", cxx_dir);
          FILE *fp = fopen (src, "w");
          if (fp != NULL)
            {
              fputs ("#include <iostream>\nint main() { std::cout << \"\"; return 0; }\n", fp);
              fclose (fp);

              char ipat[512], lpat[512];
              snprintf (ipat, sizeof (ipat), "%s/*/include", prefix);
              snprintf (lpat, sizeof (lpat), "%s/*/lib", prefix);
              glob_t gi = { 0 }, glb = { 0 };
              int gri = glob (ipat, GLOB_ONLYDIR, NULL, &gi);
              int grl = glob (lpat, GLOB_ONLYDIR, NULL, &glb);

              char *gpp_argv[80];
              char arg_storage[68][540];
              size_t na = 0, ns = 0;
              gpp_argv[na++] = gpp_bin;
              gpp_argv[na++] = (char *) "-O0";
              gpp_argv[na++] = src;
              gpp_argv[na++] = (char *) "-o";
              gpp_argv[na++] = bin;

              if (gri == 0)
                for (size_t i = 0; i < gi.gl_pathc && i < 32 && ns < 64; ++i)
                  {
                    snprintf (arg_storage[ns], sizeof (arg_storage[ns]),
                              "-I%s", gi.gl_pathv[i]);
                    gpp_argv[na++] = arg_storage[ns++];
                  }
              if (grl == 0)
                for (size_t i = 0; i < glb.gl_pathc && i < 32 && ns < 68; ++i)
                  {
                    snprintf (arg_storage[ns], sizeof (arg_storage[ns]),
                              "-L%s", glb.gl_pathv[i]);
                    gpp_argv[na++] = arg_storage[ns++];
                  }
              gpp_argv[na] = NULL;

              globfree (&gi);
              globfree (&glb);

              printf ("\n=== End-to-End g++ <iostream> Compile + Link Macrobenchmark ===\n");
              for (int mode = 0; mode <= 2; ++mode)
                {
                  uint64_t t0 = now_ns ();
                  int sys_rc = run_gpp_mode (gpp_bin, gpp_argv, mode);
                  uint64_t dt = now_ns () - t0;
                  if (sys_rc == 0)
                    printf ("  g++ <iostream> + ld (mode=%d): %7.2f ms\n",
                            mode, (double) dt / 1e6);
                }
            }
          rm_rf (cxx_dir);
        }
    }

  if (using_synth)
    rm_rf (synth_root);
  return rc;
}
