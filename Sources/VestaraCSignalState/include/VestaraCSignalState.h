#ifndef VESTARA_C_SIGNAL_STATE_H
#define VESTARA_C_SIGNAL_STATE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Resets both the RN fatal exception suppression token and SIGABRT suppression token to false.
 */
void vestara_signal_state_reset(void);

/**
 * Arms ONLY the RN fatal exception suppression token.
 * Leaves SIGABRT suppression token disarmed (false).
 */
void vestara_signal_state_arm_exception(void);

/**
 * Atomically checks and consumes the RN fatal exception suppression token.
 * Returns true if the token was armed (and atomically disarms it), false otherwise.
 */
bool vestara_signal_state_consume_exception(void);

/**
 * Arms the SIGABRT suppression token.
 */
void vestara_signal_state_arm_sigabrt(void);

/**
 * Signal-safe consume operation called from POSIX signal handler.
 * If signal_code == SIGABRT, atomically checks and consumes the SIGABRT suppression token.
 * If signal_code != SIGABRT, returns false without touching the token.
 * Returns true if signal_code == SIGABRT and the token was armed (and atomically disarms it), false otherwise.
 */
bool vestara_signal_state_consume_sigabrt(int signal_code);

/**
 * Test helpers for inspecting token state without consuming.
 */
bool vestara_signal_state_is_exception_armed(void);
bool vestara_signal_state_is_sigabrt_armed(void);

#ifdef __cplusplus
}
#endif

#endif /* VESTARA_C_SIGNAL_STATE_H */
