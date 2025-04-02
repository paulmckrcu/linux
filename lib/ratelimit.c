// SPDX-License-Identifier: GPL-2.0-only
/*
 * ratelimit.c - Do something with rate limit.
 *
 * Isolated from kernel/printk.c by Dave Young <hidave.darkstar@gmail.com>
 *
 * 2008-05-01 rewrite the function and use a ratelimit_state data struct as
 * parameter. Now every user can use their own standalone ratelimit_state.
 */

#include <linux/ratelimit.h>
#include <linux/jiffies.h>
#include <linux/export.h>

/*
 * __ratelimit - rate limiting
 * @rs: ratelimit_state data
 * @func: name of calling function
 *
 * This enforces a rate limit: not more than @rs->burst callbacks
 * in every @rs->interval
 *
 * RETURNS:
 * 0 means callbacks will be suppressed.
 * 1 means go ahead and do it.
 */
int ___ratelimit(struct ratelimit_state *rs, const char *func)
{
	unsigned long begin;
	int burst = READ_ONCE(rs->burst);
	int delta = 0;
	unsigned long flags;
	bool gotlock = false;
	bool initialized;
	int interval = READ_ONCE(rs->interval);
	unsigned long j;
	int n_left;

	/*
	 * If the burst or interval settings mark this ratelimit_state
	 * structure as disabled, then clear the RATELIMIT_INITIALIZED bit
	 * in ->flags to force resetting of the ratelimiting interval when
	 * this ratelimit_state structure is next re-enabled.
	 */
	if (burst <= 0 || interval <= 0) {
		if ((READ_ONCE(rs->flags) & RATELIMIT_INITIALIZED) &&
		    raw_spin_trylock_irqsave(&rs->lock, flags)) {
			if (READ_ONCE(rs->flags) & RATELIMIT_INITIALIZED)
				smp_store_release(&rs->flags, rs->flags & ~RATELIMIT_INITIALIZED);
			raw_spin_unlock_irqrestore(&rs->lock, flags);
		}
		return true;
	}

	/*
	 * If this structure has just now been ratelimited, but not yet
	 * reset for the next rate-limiting interval, take an early and
	 * low-cost exit.
	 */
	if (atomic_read_acquire(&rs->rs_n_left) <= 0) /* Pair with release. */
		goto limited;

	/*
	 * If this structure is marked as initialized and has been
	 * recently used, pick up its ->begin field.  Otherwise, pick up
	 * the current time and attempt to re-initialized the structure.
	 */
	j = jiffies;
	initialized = smp_load_acquire(&rs->flags) & RATELIMIT_INITIALIZED; /* Pair with release. */
	if (initialized) {
		begin = READ_ONCE(rs->begin);
	} else {
		/*
		 * Uninitialized or long idle, so reset ->begin and
		 * mark initialized.  If we fail to acquire the lock,
		 * let the lock holder do the work.
		 */
		begin = j;
		if (raw_spin_trylock_irqsave(&rs->lock, flags)) {
			if (!(READ_ONCE(rs->flags) & RATELIMIT_INITIALIZED)) {
				begin = jiffies;
				j = begin;
				WRITE_ONCE(rs->begin, begin);
				smp_store_release(&rs->flags, /* Pair with acquire. */
						  rs->flags | RATELIMIT_INITIALIZED);
				initialized = true;
			}
			raw_spin_unlock_irqrestore(&rs->lock, flags);
		}
	}

	/*
	 * If this structure is still in the interval in which has
	 * already hit the rate limit, take an early and low-cost exit.
	 */
	if (initialized && time_before(begin - 2 * interval, j) && time_before(j, begin))
		goto limited;

	/*
	 * Register another request, and take an early (but not low-cost)
	 * exit if rate-limiting just nowcame into effect.
	 */
	n_left = atomic_dec_return(&rs->rs_n_left);
	if (n_left < 0)
		goto limited; /* Just now started ratelimiting. */
	if (n_left > 0) {
		/*
		 * Otherwise, there is not yet any rate limiting for the
		 * current interval, and furthermore there is at least one
		 * last count remaining.  But check to see if initialization
		 * is required or if we have run off the end of the interval
		 * without rate limiting having been imposed.  Either way,
		 * we eventually return @true to tell our caller to go ahead.
		 */
		if (initialized &&
		    time_before(begin - interval, j) && time_before(j, begin + interval))
			return true;  /* Nothing special to do. */
		if (!raw_spin_trylock_irqsave(&rs->lock, flags))
			return true; /* Let lock holder do special work. */
		interval = READ_ONCE(rs->interval);
		begin = rs->begin;
		initialized = smp_load_acquire(&rs->flags) & RATELIMIT_INITIALIZED;
		if (interval <= 0 ||
		    (initialized &&
		     time_before(begin - interval, j) && time_before(j, begin + interval))) {
			/*
			 * Someone else beat us to the special work,
			 * so release the lock and return.
			 */
			raw_spin_unlock_irqrestore(&rs->lock, flags);
			return true;
		}

		/* We have the lock and will do initialization. */
		gotlock = true;
		delta = -1;
	}
	if (!gotlock) {
		/*
		 * We get here if we got the last count (n_left == 0),
		 * so that rate limiting is in effect for the next caller.
		 * We will return @true to tell our caller to go ahead,
		 * but first we acquire the lock and set things up for
		 * the next rate-limiting interval.
		 */
		raw_spin_lock_irqsave(&rs->lock, flags);
		interval = READ_ONCE(rs->interval);
		j = jiffies;
		begin = rs->begin;
		initialized = smp_load_acquire(&rs->flags) & RATELIMIT_INITIALIZED;
	}
	burst = READ_ONCE(rs->burst);
	if (interval <= 0 || !initialized ||
	    time_after(j, begin + interval) || time_after(begin - interval, j))
		begin = j; /* Long delay, reset interval. */
	else
		begin += interval; /* Next interval. */

	/*
	 * If an acquire sees the value stored by either of these two
	 * store-release operations, it will also see the value from
	 * following store to ->begin, or from some later store.  But not
	 * from any earlier now-obsolete earlier store to ->begin.
	 */
	WRITE_ONCE(rs->begin, begin);
	atomic_set_release(&rs->rs_n_left, burst + delta); /* Pair with acquire.*/
	smp_store_release(&rs->flags, rs->flags | RATELIMIT_INITIALIZED); /* ^^^ */

	/* Print suppressed callback count if requested. */
	if (!(rs->flags & RATELIMIT_MSG_ON_RELEASE)) {
		delta = ratelimit_state_reset_miss(rs);
		if (delta)
			printk_deferred(KERN_WARNING "%s: %d callbacks suppressed\n", func, delta);
	}
	raw_spin_unlock_irqrestore(&rs->lock, flags);
	return true;

limited:
	/*
	 * Count the number of rate-limited requests and tell the caller
	 * that this is a no-go.
	 */
	ratelimit_state_inc_miss(rs);
	return false;
}
EXPORT_SYMBOL(___ratelimit);
