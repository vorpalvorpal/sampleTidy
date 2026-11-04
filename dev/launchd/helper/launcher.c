/* Launcher for the launchd auto-import job.
 *
 * macOS TCC refuses /bin/bash access to the OneDrive File Provider folder when launchd runs it,
 * and granting /bin/bash Full Disk Access would grant it to every bash script. So launchd runs
 * this app instead and only this app gets the grant. TCC attributes a child process to its
 * responsible parent, so the script is SPAWNED and waited for, never exec'd: after exec the
 * process would be /bin/bash again and lose the grant.
 *
 * The script path is compiled in (build.sh passes -DSAMPLETIDY_SCRIPT) and argv is ignored, so
 * the granted app cannot be pointed at another script.
 */
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SAMPLETIDY_SCRIPT
#error "compile with -DSAMPLETIDY_SCRIPT=\"\\\"/absolute/path/to/auto-import.sh\\\"\" (see build.sh)"
#endif

extern char **environ;
static volatile sig_atomic_t child = 0;

static void forward(int sig) {
  if (child > 0) kill(child, sig);
}

int main(void) {
  char *args[] = {"/bin/bash", SAMPLETIDY_SCRIPT, NULL};
  const int sigs[] = {SIGTERM, SIGINT, SIGHUP};

  /* Block the signals until the child exists, so an early SIGTERM is forwarded, not lost. */
  sigset_t block, old;
  sigemptyset(&block);
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = forward;
  sigemptyset(&sa.sa_mask);
  for (size_t i = 0; i < sizeof sigs / sizeof *sigs; i++) {
    sigaddset(&block, sigs[i]);
    sigaction(sigs[i], &sa, NULL);
  }
  sigprocmask(SIG_BLOCK, &block, &old);

  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setsigmask(&attr, &old);
  sigset_t dflt;
  sigemptyset(&dflt);
  for (size_t i = 0; i < sizeof sigs / sizeof *sigs; i++) sigaddset(&dflt, sigs[i]);
  posix_spawnattr_setsigdefault(&attr, &dflt);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);

  pid_t pid;
  int rc = posix_spawn(&pid, "/bin/bash", NULL, &attr, args, environ);
  if (rc != 0) {
    fprintf(stderr, "sampletidy launcher: cannot run /bin/bash: %s\n", strerror(rc));
    return 127;
  }
  child = pid;
  sigprocmask(SIG_SETMASK, &old, NULL);

  int status;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) {
      fprintf(stderr, "sampletidy launcher: waitpid: %s\n", strerror(errno));
      return 127;
    }
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 127;
}
