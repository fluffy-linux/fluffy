/* bench-fswc.c -- FSWC Phase 0 measurement worker (GLOB.md §6 Phase 0).

   Version-agnostic: measures whatever glibc runs it (plain walk, FSWC v5,
   or v6) through public interfaces only (glob, posix_spawn, posix_spawnp,
   dlopen).  The FSWC state under test is chosen by the caller via
   GLIBC_TUNABLES and by removing or keeping the index directory; see
   tools/bench-fswc.sh, which builds the fixture and drives every mode.

   Host-independent: every path comes from the command line; nothing here
   assumes /sw, /usr, /bin/sh, or any host layout.

   Build:  cc -O2 -Wall -Wextra -o bench-fswc tools/bench-fswc.c -ldl
   Modes (all print one line: "<mode> <label> <value> <unit> [extra]"):
     glob <pattern> <flags> <iters>
         In-process glob() latency; <flags> is a decimal int.
     spawn <iters> <argv...>
         posix_spawn + waitpid of an absolute argv, wall time per spawn
         (execve to exit of a trivial program).
     spawnp <iters> <path-env> <cmd>
         posix_spawnp PATH search with PATH=<path-env>, per spawn.
     dlopen <soname>
         One cold dlopen of <soname> in this process (run once per process
         by the driver), using the library search path in effect.
     first <argv...>
         Wall time of a single spawn (used by the driver for cold-index
         measurements, where the first process may build the index).  */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <glob.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static uint64_t
now_ns (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (uint64_t) ts.tv_sec * 1000000000ULL + (uint64_t) ts.tv_nsec;
}

static void
usage (void)
{
  fputs ("usage: bench-fswc glob <pattern> <flags> <iters>\n"
         "       bench-fswc spawn <iters> <argv...>\n"
         "       bench-fswc spawnp <iters> <path-env> <cmd>\n"
         "       bench-fswc dlopen <soname>\n"
         "       bench-fswc first <argv...>\n", stderr);
  exit (2);
}

static long
parse_count (const char *s)
{
  char *end;
  long n = strtol (s, &end, 10);
  if (*s == '\0' || *end != '\0' || n <= 0)
    usage ();
  return n;
}

/* Spawn ARGV once, wait for it, and return the elapsed nanoseconds.  With
   SEARCH, resolve argv[0] through posix_spawnp and ENVP's PATH.  */
static uint64_t
spawn_once (char **argv, char **envp, int search)
{
  pid_t pid;
  uint64_t t0 = now_ns ();
  int r = search ? posix_spawnp (&pid, argv[0], NULL, NULL, argv, envp)
                 : posix_spawn (&pid, argv[0], NULL, NULL, argv, envp);
  if (r != 0)
    {
      fprintf (stderr, "bench-fswc: spawn %s: %s\n", argv[0], strerror (r));
      exit (1);
    }
  int st;
  if (waitpid (pid, &st, 0) != pid || !WIFEXITED (st) || WEXITSTATUS (st) != 0)
    {
      fprintf (stderr, "bench-fswc: %s did not exit 0\n", argv[0]);
      exit (1);
    }
  return now_ns () - t0;
}

int
main (int argc, char **argv)
{
  if (argc < 3)
    usage ();
  const char *mode = argv[1];

  if (strcmp (mode, "glob") == 0 && argc == 5)
    {
      const char *pat = argv[2];
      int flags = (int) strtol (argv[3], NULL, 10);
      long iters = parse_count (argv[4]);
      size_t matches = 0;
      uint64_t t0 = now_ns ();
      for (long i = 0; i < iters; ++i)
        {
          glob_t gl;
          memset (&gl, 0, sizeof (gl));
          int r = glob (pat, flags, NULL, &gl);
          if (r != 0 && r != GLOB_NOMATCH)
            {
              fprintf (stderr, "bench-fswc: glob(%s) = %d\n", pat, r);
              return 1;
            }
          matches = r == 0 ? gl.gl_pathc : 0;
          globfree (&gl);
        }
      double us = (double) (now_ns () - t0) / 1e3 / (double) iters;
      printf ("glob %s %.3f us/call matches=%zu\n", pat, us, matches);
      return 0;
    }

  if (strcmp (mode, "spawn") == 0 && argc >= 4)
    {
      long iters = parse_count (argv[2]);
      uint64_t total = 0;
      for (long i = 0; i < iters; ++i)
        total += spawn_once (&argv[3], environ, 0);
      printf ("spawn %s %.1f us/spawn\n", argv[3],
              (double) total / 1e3 / (double) iters);
      return 0;
    }

  if (strcmp (mode, "spawnp") == 0 && argc == 5)
    {
      long iters = parse_count (argv[2]);
      /* posix_spawnp searches the caller's own PATH, not ENVP's.  */
      if (setenv ("PATH", argv[3], 1) != 0)
        return 1;
      char *cargv[] = { argv[4], NULL };
      uint64_t total = 0;
      for (long i = 0; i < iters; ++i)
        total += spawn_once (cargv, environ, 1);
      printf ("spawnp %s %.1f us/spawn\n", argv[4],
              (double) total / 1e3 / (double) iters);
      return 0;
    }

  if (strcmp (mode, "dlopen") == 0 && argc == 3)
    {
      uint64_t t0 = now_ns ();
      void *h = dlopen (argv[2], RTLD_NOW | RTLD_LOCAL);
      uint64_t dt = now_ns () - t0;
      if (h == NULL)
        {
          fprintf (stderr, "bench-fswc: dlopen(%s): %s\n", argv[2], dlerror ());
          return 1;
        }
      printf ("dlopen %s %.1f us\n", argv[2], (double) dt / 1e3);
      return 0;
    }

  if (strcmp (mode, "first") == 0 && argc >= 3)
    {
      uint64_t dt = spawn_once (&argv[2], environ, 0);
      printf ("first %s %.1f us\n", argv[2], (double) dt / 1e3);
      return 0;
    }

  usage ();
}
