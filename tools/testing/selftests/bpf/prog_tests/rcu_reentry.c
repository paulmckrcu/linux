// SPDX-License-Identifier: GPL-2.0
/*
 * Exercise re-entry into call_srcu() from BPF; see progs/rcu_reentry.c.
 *
 * On a kernel without the call_srcu() any-context fix the nested call
 * self-deadlocks on the srcu_data lock, so this hangs rather than fails.
 */
#define _GNU_SOURCE
#include <sched.h>
#include <sys/syscall.h>
#include <test_progs.h>
#include "rcu_reentry.skel.h"

static int sys_pidfd_open(pid_t pid, unsigned int flags)
{
	return syscall(__NR_pidfd_open, pid, flags);
}

/* Tiny RCU builds have no rcu_segcblist_enqueue() to attach to. */
static bool have_attach_target(void)
{
	char buf[256];
	bool found = false;
	FILE *f;

	f = fopen("/proc/kallsyms", "r");
	if (!f)
		return true;	/* cannot tell; let the attach decide */
	while (fgets(buf, sizeof(buf), f)) {
		if (strstr(buf, " rcu_segcblist_enqueue\n")) {
			found = true;
			break;
		}
	}
	fclose(f);
	return found;
}

void test_rcu_reentry(void)
{
	struct rcu_reentry *skel;
	int err, pidfd = -1, map_fd;
	cpu_set_t set, old_set;
	bool affinity_saved;
	__u64 val = 1;

	if (!have_attach_target()) {
		test__skip();
		return;
	}

	skel = rcu_reentry__open_and_load();
	if (!ASSERT_OK_PTR(skel, "skel_open_and_load"))
		return;

	err = rcu_reentry__attach(skel);
	if (!ASSERT_OK(err, "skel_attach"))
		goto out;

	/* Keep the re-entry on a single CPU. */
	affinity_saved = !sched_getaffinity(0, sizeof(old_set), &old_set);
	CPU_ZERO(&set);
	CPU_SET(0, &set);
	if (!ASSERT_OK(sched_setaffinity(0, sizeof(set), &set), "setaffinity"))
		goto out;

	pidfd = sys_pidfd_open(getpid(), 0);
	if (!ASSERT_GE(pidfd, 0, "pidfd_open"))
		goto restore;
	map_fd = bpf_map__fd(skel->maps.task_stg);
	err = bpf_map_update_elem(map_fd, &pidfd, &val, BPF_NOEXIST);
	if (!ASSERT_OK(err, "boot_create"))
		goto restore;

	/* Arm the handler for this thread, then trigger call_rcu_tasks_trace(). */
	skel->bss->target_pid = syscall(__NR_gettid);
	err = bpf_map_delete_elem(map_fd, &pidfd);
	if (!ASSERT_OK(err, "boot_delete"))
		goto restore;

	/* Only Tree SRCU enqueues via rcu_segcblist_enqueue(); skip elsewhere. */
	if (!skel->bss->hits) {
		test__skip();
		goto restore;
	}
	ASSERT_EQ(skel->bss->get_errs, 0, "nested_storage_get");
	ASSERT_EQ(skel->bss->del_errs, 0, "nested_storage_delete");
restore:
	if (affinity_saved)
		sched_setaffinity(0, sizeof(old_set), &old_set);
out:
	if (pidfd >= 0)
		close(pidfd);
	rcu_reentry__destroy(skel);
}
