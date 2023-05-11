#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

ATOMICDIR=$(dirname $0)

. ${ATOMICDIR}/atomic-tbl.sh

#gen_template_fallback(template, meta, pfx, name, sfx, order, atomic, int, args...)
gen_template_fallback()
{
	local template="$1"; shift
	local meta="$1"; shift
	local pfx="$1"; shift
	local name="$1"; shift
	local sfx="$1"; shift
	local order="$1"; shift
	local atomic="$1"; shift
	local int="$1"; shift

	local atomicname="arch_${atomic}_${pfx}${name}${sfx}${order}"

	local ret="$(gen_ret_type "${meta}" "${int}")"
	local retstmt="$(gen_ret_stmt "${meta}")"
	local params="$(gen_params "${int}" "${atomic}" "$@")"
	local args="$(gen_args "$@")"

	. ${template}
	printf "#define ${atomicname} ${atomicname}\n"
}

#gen_order_fallback(meta, pfx, name, sfx, order, atomic, int, args...)
gen_order_fallback()
{
	local meta="$1"; shift
	local pfx="$1"; shift
	local name="$1"; shift
	local sfx="$1"; shift
	local order="$1"; shift

	local tmpl_order=${order#_}
	local tmpl="${ATOMICDIR}/fallbacks/${tmpl_order:-fence}"
	gen_template_fallback "${tmpl}" "${meta}" "${pfx}" "${name}" "${sfx}" "${order}" "$@"
}

#gen_proto_fallback(meta, pfx, name, sfx, order, atomic, int, args...)
gen_proto_fallback()
{
	local meta="$1"; shift
	local pfx="$1"; shift
	local name="$1"; shift
	local sfx="$1"; shift
	local order="$1"; shift

	local tmpl="$(find_fallback_template "${pfx}" "${name}" "${sfx}" "${order}")"
	gen_template_fallback "${tmpl}" "${meta}" "${pfx}" "${name}" "${sfx}" "${order}" "$@"
}

#gen_basic_fallbacks(basename)
gen_basic_fallbacks()
{
	local basename="$1"; shift
cat << EOF
#define ${basename}_acquire ${basename}
#define ${basename}_release ${basename}
#define ${basename}_relaxed ${basename}
EOF
}

#gen_proto_order_variant(meta, pfx, name, sfx, order, atomic, int, args...)
gen_proto_order_variant()
{
	local meta="$1"; shift
	local pfx="$1"; shift
	local name="$1"; shift
	local sfx="$1"; shift
	local order="$1"; shift
	local atomic="$1"

	local atomicname="arch_${atomic}_${pfx}${name}${sfx}${order}"
	local basename="arch_${atomic}_${pfx}${name}${sfx}"

	local template="$(find_fallback_template "${pfx}" "${name}" "${sfx}" "${order}")"

	# Where there is no possible fallback, this order variant is mandatory
	# and must be provided by arch code. Add a comment to the header to
	# make this obvious.
	#
	# Ideally we'd error on a missing definition, but arch code might
	# define this order variant as a C function without a preprocessor
	# symbol.
	if [ -z ${template} ] && [ -z "${order}" ] && ! meta_has_relaxed "${meta}"; then
		printf "/* ${atomicname}() is mandatory */\n\n"
		return
	fi

	printf "#if defined(${atomicname})\n"
	printf "/* Provided directly by arch code -- no fallback necessary. */\n"

	# Allow FULL/ACQUIRE/RELEASE ops to be defined in terms of RELAXED ops
	if [ "${order}" != "_relaxed" ] && meta_has_relaxed "${meta}"; then
		printf "#elif defined(${basename}_relaxed)\n"
		gen_order_fallback "${meta}" "${pfx}" "${name}" "${sfx}" "${order}" "$@"
	fi
	
	# Allow ACQUIRE/RELEASE/RELAXED ops to be defined in terms of FULL ops
	if [ ! -z "${order}" ]; then
		printf "#elif defined(${basename})\n"
		printf "#define ${atomicname} ${basename}\n"
	fi

	printf "#else\n"
	if [ ! -z "${template}" ]; then
		gen_proto_fallback "${meta}" "${pfx}" "${name}" "${sfx}" "${order}" "$@"
	else
		printf "#error \"Unable to define ${atomicname}\"\n"
	fi

	printf "#endif /* ${atomicname} */\n\n"
}


#gen_proto_order_variants(meta, pfx, name, sfx, atomic, int, args...)
gen_proto_order_variants()
{
	local meta="$1"; shift
	local pfx="$1"; shift
	local name="$1"; shift
	local sfx="$1"; shift
	local atomic="$1"

	gen_proto_order_variant "${meta}" "${pfx}" "${name}" "${sfx}" "" "$@"

	if meta_has_acquire "${meta}"; then
		gen_proto_order_variant "${meta}" "${pfx}" "${name}" "${sfx}" "_acquire" "$@"
	fi

	if meta_has_release "${meta}"; then
		gen_proto_order_variant "${meta}" "${pfx}" "${name}" "${sfx}" "_release" "$@"
	fi

	if meta_has_relaxed "${meta}"; then
		gen_proto_order_variant "${meta}" "${pfx}" "${name}" "${sfx}" "_relaxed" "$@"
	fi
}

gen_order_fallbacks()
{
	local xchg="$1"; shift

cat <<EOF

#ifndef ${xchg}_acquire
#define ${xchg}_acquire(...) \\
	__atomic_op_acquire(${xchg}, __VA_ARGS__)
#endif

#ifndef ${xchg}_release
#define ${xchg}_release(...) \\
	__atomic_op_release(${xchg}, __VA_ARGS__)
#endif

#ifndef ${xchg}
#define ${xchg}(...) \\
	__atomic_op_fence(${xchg}, __VA_ARGS__)
#endif

EOF
}

gen_xchg_fallbacks()
{
	local xchg="$1"; shift
	printf "#ifndef ${xchg}_relaxed\n"

	gen_basic_fallbacks ${xchg}

	printf "#else /* ${xchg}_relaxed */\n"

	gen_order_fallbacks ${xchg}

	printf "#endif /* ${xchg}_relaxed */\n\n"
}

gen_try_cmpxchg_fallback()
{
	local cmpxchg="$1"; shift;
	local order="$1"; shift;

cat <<EOF
#ifndef arch_try_${cmpxchg}${order}
#define arch_try_${cmpxchg}${order}(_ptr, _oldp, _new) \\
({ \\
	typeof(*(_ptr)) *___op = (_oldp), ___o = *___op, ___r; \\
	___r = arch_${cmpxchg}${order}((_ptr), ___o, (_new)); \\
	if (unlikely(___r != ___o)) \\
		*___op = ___r; \\
	likely(___r == ___o); \\
})
#endif /* arch_try_${cmpxchg}${order} */

EOF
}

gen_try_cmpxchg_fallbacks()
{
	local cmpxchg="$1"; shift;

	printf "#ifndef arch_try_${cmpxchg}_relaxed\n"
	printf "#ifdef arch_try_${cmpxchg}\n"

	gen_basic_fallbacks "arch_try_${cmpxchg}"

	printf "#endif /* arch_try_${cmpxchg} */\n\n"

	for order in "" "_acquire" "_release" "_relaxed"; do
		gen_try_cmpxchg_fallback "${cmpxchg}" "${order}"
	done

	printf "#else /* arch_try_${cmpxchg}_relaxed */\n"

	gen_order_fallbacks "arch_try_${cmpxchg}"

	printf "#endif /* arch_try_${cmpxchg}_relaxed */\n\n"
}

cat << EOF
// SPDX-License-Identifier: GPL-2.0

// Generated by $0
// DO NOT MODIFY THIS FILE DIRECTLY

#ifndef _LINUX_ATOMIC_FALLBACK_H
#define _LINUX_ATOMIC_FALLBACK_H

#include <linux/compiler.h>

EOF

for xchg in "arch_xchg" "arch_cmpxchg" "arch_cmpxchg64"; do
	gen_xchg_fallbacks "${xchg}"
done

for cmpxchg in "cmpxchg" "cmpxchg64"; do
	gen_try_cmpxchg_fallbacks "${cmpxchg}"
done

for cmpxchg in "cmpxchg_local" "cmpxchg64_local"; do
	gen_try_cmpxchg_fallback "${cmpxchg}" ""
done

grep '^[a-z]' "$1" | while read name meta args; do
	gen_proto "${meta}" "${name}" "atomic" "int" ${args}
done

cat <<EOF
#ifdef CONFIG_GENERIC_ATOMIC64
#include <asm-generic/atomic64.h>
#endif

EOF

grep '^[a-z]' "$1" | while read name meta args; do
	gen_proto "${meta}" "${name}" "atomic64" "s64" ${args}
done

cat <<EOF
#endif /* _LINUX_ATOMIC_FALLBACK_H */
EOF
