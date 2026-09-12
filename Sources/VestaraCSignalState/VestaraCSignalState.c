#include "VestaraCSignalState.h"
#include <stdatomic.h>
#include <signal.h>

// Enforce at compile time that atomic_bool is always lock-free on the target platform (2 = always lock-free).
#if !defined(ATOMIC_BOOL_LOCK_FREE) || (ATOMIC_BOOL_LOCK_FREE != 2)
#error "atomic_bool is not lock-free on this target platform"
#endif

_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "atomic_bool must be lock-free on supported Apple targets");

// In-memory one-shot suppression tokens using C11 lock-free atomics with relaxed memory ordering.
static atomic_bool s_rn_fatal_exception_token = false;
static atomic_bool s_rn_sigabrt_token = false;

void vestara_signal_state_reset(void) {
    atomic_store_explicit(&s_rn_fatal_exception_token, false, memory_order_relaxed);
    atomic_store_explicit(&s_rn_sigabrt_token, false, memory_order_relaxed);
}

void vestara_signal_state_arm_exception(void) {
    atomic_store_explicit(&s_rn_fatal_exception_token, true, memory_order_relaxed);
    atomic_store_explicit(&s_rn_sigabrt_token, false, memory_order_relaxed);
}

bool vestara_signal_state_consume_exception(void) {
    return atomic_exchange_explicit(&s_rn_fatal_exception_token, false, memory_order_relaxed);
}

void vestara_signal_state_arm_sigabrt(void) {
    atomic_store_explicit(&s_rn_sigabrt_token, true, memory_order_relaxed);
}

bool vestara_signal_state_consume_sigabrt(int signal_code) {
    if (signal_code == SIGABRT) {
        return atomic_exchange_explicit(&s_rn_sigabrt_token, false, memory_order_relaxed);
    }
    return false;
}

bool vestara_signal_state_is_exception_armed(void) {
    return atomic_load_explicit(&s_rn_fatal_exception_token, memory_order_relaxed);
}

bool vestara_signal_state_is_sigabrt_armed(void) {
    return atomic_load_explicit(&s_rn_sigabrt_token, memory_order_relaxed);
}
