#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# helpers for dealing with atomics.tbl

#meta_in(meta, match)
meta_in()
{
	case "$1" in
	[$2]) return 0;;
	esac

	return 1
}

#meta_has_ret(meta)
meta_has_ret()
{
	meta_in "$1" "bBiIfFlR"
}

#meta_has_acquire(meta)
meta_has_acquire()
{
	meta_in "$1" "BFIlR"
}

#meta_has_release(meta)
meta_has_release()
{
	meta_in "$1" "BFIRs"
}

#meta_has_relaxed(meta)
meta_has_relaxed()
{
	meta_in "$1" "BFIR"
}

#find_fallback_template(pfx, name, sfx, order)
find_fallback_template()
{
	local pfx="$1"; shift
	local name="$1"; shift
	local sfx="$1"; shift
	local order="$1"; shift

	local base=""
	local file=""

	# We may have fallbacks for a specific case (e.g. read_acquire()), or
	# an entire class, e.g. *inc*().
	#
	# Start at the most specific, and fall back to the most general. Once
	# we find a specific fallback, don't bother looking for more.
	for base in "${pfx}${name}${sfx}${order}" "${name}"; do
		file="${ATOMICDIR}/fallbacks/${base}"

		if [ -f "${file}" ]; then
			printf "${file}"
			break
		fi
	done
}

#gen_ret_type(meta, int)
gen_ret_type() {
	local meta="$1"; shift
	local int="$1"; shift

	case "${meta}" in
	[sv]) printf "void";;
	[bB]) printf "bool";;
	[aiIfFlR]) printf "${int}";;
	esac
}

#gen_ret_stmt(meta)
gen_ret_stmt()
{
	if meta_has_ret "${meta}"; then
		printf "return ";
	fi
}

# gen_param_name(arg)
gen_param_name()
{
	# strip off the leading 'c' for 'cv'
	local name="${1#c}"
	printf "${name#*:}"
}

# gen_param_type(arg, int, atomic)
gen_param_type()
{
	local type="${1%%:*}"; shift
	local int="$1"; shift
	local atomic="$1"; shift

	case "${type}" in
	i) type="${int} ";;
	p) type="${int} *";;
	v) type="${atomic}_t *";;
	cv) type="const ${atomic}_t *";;
	esac

	printf "${type}"
}

#gen_param(arg, int, atomic)
gen_param()
{
	local arg="$1"; shift
	local int="$1"; shift
	local atomic="$1"; shift
	local name="$(gen_param_name "${arg}")"
	local type="$(gen_param_type "${arg}" "${int}" "${atomic}")"

	printf "${type}${name}"
}

#gen_params(int, atomic, arg...)
gen_params()
{
	local int="$1"; shift
	local atomic="$1"; shift

	while [ "$#" -gt 0 ]; do
		gen_param "$1" "${int}" "${atomic}"
		[ "$#" -gt 1 ] && printf ", "
		shift;
	done
}

#gen_args(arg...)
gen_args()
{
	while [ "$#" -gt 0 ]; do
		printf "$(gen_param_name "$1")"
		[ "$#" -gt 1 ] && printf ", "
		shift;
	done
}

#gen_proto_order_variants(meta, pfx, name, sfx, ...)
gen_proto_order_variants()
{
	local meta="$1"; shift
	local pfx="$1"; shift
	local name="$1"; shift
	local sfx="$1"; shift

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

#gen_proto_variants(meta, name, ...)
gen_proto_variants()
{
	local meta="$1"; shift
	local name="$1"; shift
	local pfx=""
	local sfx=""

	meta_in "${meta}" "fF" && pfx="fetch_"
	meta_in "${meta}" "R" && sfx="_return"

	gen_proto_order_variants "${meta}" "${pfx}" "${name}" "${sfx}" "$@"
}

#gen_proto(meta, ...)
gen_proto() {
	local meta="$1"; shift
	for m in $(echo "${meta}" | grep -o .); do
		gen_proto_variants "${m}" "$@"
	done
}

#gen_kerneldoc(meta, atomicname, pfx, name, sfx, order, atomic, int, args...)
gen_kerneldoc()
{
	local meta="$1"; shift
	local atomicname="$1"; shift
	local pfx="$1"; shift
	local name="$1"; shift
	local sfx="$1"; shift
	local order="$1"; shift
	local atomic="$1"; shift

	local params="$(gen_params "$@")"
	shift;shift # discard types
	local args="$(gen_args "$@")"

	# Compute the order outside of awk because we need meta_has_ret.
	local kd_ord=full
	case "${order}" in
	_relaxed) kd_ord=no;;
	?*)	kd_ord="`echo $order | sed -e 's/_//'`";;
	*)	if ! meta_has_ret ${meta} || test "${name}" = read
		then
			kd_ord=no
		fi
		;;
	esac

	echo ${args} | tr -d ' ' | tr ',' '\012' |
	awk -v atomic=${atomic} \
	    -v basefuncname=arch_${atomic}_${pfx}${name}${sfx} \
	    -v name_op=${name} \
	    -v ord=${kd_ord} \
	    -v order=${order} \
	    -v pfx=${pfx} \
	    -v sfx=${sfx} '
	BEGIN {
		sfxord = "_" order;
		if (ord == "full")
			sfxord = "";

		fdesc["add"] = fdesc["add_negative"] = fdesc["add_unless"] = "add";
		fdesc["and"] = "AND";
		fdesc["andnot"] = "complement then AND";
		fdesc["cmpxchg"] = "compare and exchange";
		fdesc["dec"] = fdesc["dec_and_test"] = fdesc["dec_if_positive"] = fdesc["dec_unless_positive"] = "decrement";
		fdesc["inc"] = fdesc["inc_and_test"] = fdesc["inc_not_zero"] = fdesc["inc_unless_negative"] = "increment";
		fdesc["or"] = "OR";
		fdesc["read"] = "load";
		fdesc["set"] = "store";
		fdesc["sub"] = fdesc["sub_and_test"] = "subtract";
		fdesc["try_cmpxchg"] = "boolean compare and exchange";
		fdesc["xchg"] = "exchange";
		fdesc["xor"] = "XOR";
		opmod = "with";
		if (name_op ~ /add/ || name_op ~ /set/)
			opmod = "to";
		else if (name_op ~ /sub/ || name_op ~ /read/)
			opmod = "from";

		pdesc["a"] = "the amount to add to @v...";
		pdesc["i"] = "value to " fdesc[name_op];
		pdesc["u"] = "...unless v is equal to u";
		pdesc["v"] = "pointer of type " atomic "_t";
		pdesc["old"] = "desired old value to match";
		pdesc["new"] = "new value to put in";

		# kernel-doc header.
		print "/**";
		print " * " basefuncname order " - Atomic " fdesc[name_op] " with " ord " ordering";
	}

	{
		# Function parameters.
		print " * @" $1 ": " pdesc[$1];
		parm[$1] = 1;
		if (pdesc[$i] == "") {
			print " * ??? Need parameter description for " $1 ".";
		}
	}

	END {
		if (fdesc[name_op] == "") {
			print " * ??? Need function description for " name_op ".";
		}
		fcond=""

		# Conditional action?
		if (name_op ~ /_if_positive$/)
			fcond = ",\n * but only if @v is greater than zero"
		if (name_op ~ /_not_zero$/)
			fcond = ",\n * but only if @v is non-zero"
		if (name_op ~ /_unless$/)
			fcond = ",\n * but only if @v was not already @u"
		if (name_op ~ /_unless_negative$/)
			fcond = ",\n * but only if @v is greater than or equal to zero"
		if (name_op ~ /_unless_positive$/)
			fcond = ",\n * but only if @v is less than or equal to zero"

		# Description.
		print " *";
		indirect = "";
		if (name_op ~ /try_cmpxchg/) {
			indirect = "*";
		}
		if (name_op == "andnot") {
			print " * Complement @i, then atomically AND into @v with " ord " ordering" fcond ".";
		} else if (name_op ~ /cmpxchg/) {
			print " * Atomically compare " indirect "@old to *@v, and if equal,";
			print " * store @new to *@v with " ord " ordering.";
		} else if (parm["i"]) {
			print " * Atomically " fdesc[name_op] " @i " opmod " @v, providing " ord " ordering" fcond ".";
		} else {
			print " * Atomically " fdesc[name_op] " @v, providing " ord " ordering" fcond ".";
		}

		# Return value?
		if (name_op == "add_negative") {
			print " * Return @true if the result is negative, or @false when"
			print " * the result is greater than or equal to zero.";
		} else if (name_op ~ /^add_unless$/) {
			print " * Either way, return old value.";
		} else if (name_op ~ /try_cmpxchg/) {
			print " * Return @true if the operation succeeded,";
			print " * and @false otherwise.  On failure, store the failure-inducing";
			print " * value of *@v to *@old, which permits a retry without";
			print " * an explicit reload from *@v.";
		} else if (name_op == "cmpxchg") {
			print " * Return the old value of *@v regardless of the result of";
			print " * the comparison.  Therefore, if the return value is not";
			print " * equal to @old, the cmpxchg operation failed.";
		} else if (pfx == "fetch_" || name_op ~ /^cmpxchg$|^xchg$/) {
			print " * Return old value.";
		} else if (sfx == "_return") {
			print " * Return new value.";
		} else if (name_op ~ /^read$/) {
			print " * Return value loaded.";
		} else if (name_op ~ /^dec_and_test$|^inc_and_test$|^sub_and_test$/) {
			print " * Return @true if the result is zero and @false otherwise.";
		} else if (name_op ~ /^dec_unless_positive$|^inc_not_zero$|^inc_unless_negative$/) {
			print " * Return @true if the " fdesc[name_op] " was executed and @false otherwise.";
		} else if (name_op ~ /^dec_if_positive$/) {
			print " * Return intended new value, even when the decrement was not"
			print " * executed.";
			print " *";
			print " * For example, if the old value is -3, then @v will not";
			print " * be decremented, but -4 will be returned.  As a result,";
			print " * if the return value is greater than or equal to zero,";
			print " * then @v was in fact decremented.";
		} else if (name_op ~ /^add$|^and$|^andnot$|^dec$|^inc$|^or$|^set$|^sub$|^xor$/) {
			# No return value, so print nothing.
		} else {
			print " * ??? Need return value definition.";
		}

		print " *";
		print " * For more information, see Documentation/atomic_t.txt.";
		print " */";
	}'
}
