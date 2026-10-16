#ifndef AnchorWatch_AudioSignal_h
#define AnchorWatch_AudioSignal_h
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>

// The render callback must never wait on a mutex. Fail compilation on a target
// whose C atomic bool implementation would require a lock.
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "Audio signal requires lock-free atomics");
typedef void *AWAudioSignalRef;
static inline AWAudioSignalRef _Nullable AWAudioSignalCreate(void) {
    atomic_bool *signal = malloc(sizeof(atomic_bool));
    if (signal) atomic_init(signal, false);
    return signal;
}
static inline bool AWAudioSignalLoad(AWAudioSignalRef _Nonnull signal) {
    return atomic_load_explicit((atomic_bool *)signal, memory_order_relaxed);
}
static inline void AWAudioSignalStore(AWAudioSignalRef _Nonnull signal, bool sounding) {
    atomic_store_explicit((atomic_bool *)signal, sounding, memory_order_relaxed);
}
static inline void AWAudioSignalDestroy(AWAudioSignalRef _Nonnull signal) { free(signal); }
#endif
