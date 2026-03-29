#ifndef SIDLITE_DEFS_H
#define SIDLITE_DEFS_H

// Compiler specifics.
#define HAVE_BUILTIN_EXPECT 1

// Branch prediction macros, lifted off the Linux kernel.
#if HAVE_BUILTIN_EXPECT
#  define LIKELY(x)      __builtin_expect(!!(x), 1)
#  define UNLIKELY(x)    __builtin_expect(!!(x), 0)
#else
#  define LIKELY(x)      (x)
#  define UNLIKELY(x)    (x)
#endif

#endif // SIDLITE_DEFS_H
