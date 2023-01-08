#ifndef _ZIGX_XFUNCPROTO_H
#define _ZIGX_XFUNCPROTO_H

#ifndef _Xconst
    #define _Xconst const
#endif

#ifndef _XFUNCPROTOBEGIN
    #if defined(__cplusplus) || defined(c_plusplus)
        #define _XFUNCPROTOBEGIN extern "C" {
        #define _XFUNCPROTOEND }
    #else
        #define _XFUNCPROTOBEGIN
        #define _XFUNCPROTOEND
    #endif
#endif

/* http://clang.llvm.org/docs/LanguageExtensions.html#has-attribute */
#ifndef __has_attribute
    # define __has_attribute(x) 0  /* Compatibility with non-clang compilers. */
#endif
#ifndef __has_feature
    # define __has_feature(x) 0    /* Compatibility with non-clang compilers. */
#endif
#ifndef __has_extension
    # define __has_extension(x) 0  /* Compatibility with non-clang compilers. */
#endif

#if __has_attribute(__sentinel__) || (defined(__GNUC__) && (__GNUC__ >= 4))
    # define _X_SENTINEL(x) __attribute__ ((__sentinel__(x)))
#else
    # define _X_SENTINEL(x)
#endif /* GNUC >= 4 */

#if (__has_attribute(visibility) || (defined(__GNUC__) && (__GNUC__ >= 4))) \
    && !defined(__CYGWIN__) && !defined(__MINGW32__)

    # define _X_EXPORT      __attribute__((visibility("default")))
    # define _X_HIDDEN      __attribute__((visibility("hidden")))
    # define _X_INTERNAL    __attribute__((visibility("internal")))
#elif defined(__SUNPRO_C) && (__SUNPRO_C >= 0x550)
    # define _X_EXPORT      __global
    # define _X_HIDDEN      __hidden
    # define _X_INTERNAL    __hidden
#else /* not gcc >= 4 and not Sun Studio >= 8 */
    # define _X_EXPORT
    # define _X_HIDDEN
    # define _X_INTERNAL
#endif /* GNUC >= 4 */

#if defined(__GNUC__) && ((__GNUC__ * 100 + __GNUC_MINOR__) >= 303)
    # define _X_LIKELY(x)   __builtin_expect(!!(x), 1)
    # define _X_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else /* not gcc >= 3.3 */
    # define _X_LIKELY(x)   (x)
    # define _X_UNLIKELY(x) (x)
#endif

#if __has_attribute(__cold__) || \
    (defined(__GNUC__) && ((__GNUC__ * 100 + __GNUC_MINOR__) >= 403)) /* 4.3+ */

    # define _X_COLD __attribute__((__cold__))
#else
    # define _X_COLD /* nothing */
#endif

#if __has_attribute(deprecated) \
    || (defined(__GNUC__) && ((__GNUC__ * 100 + __GNUC_MINOR__) >= 301)) \
    || (defined(__SUNPRO_C) && (__SUNPRO_C >= 0x5130))

    # define _X_DEPRECATED  __attribute__((deprecated))
#else /* not gcc >= 3.1 */
    # define _X_DEPRECATED
#endif

#if __has_extension(attribute_deprecated_with_message) || \
                (defined(__GNUC__) && ((__GNUC__ >= 5) || ((__GNUC__ == 4) && (__GNUC_MINOR__ >= 5))))
    # define _X_DEPRECATED_MSG(_msg) __attribute__((deprecated(_msg)))
#else
    # define _X_DEPRECATED_MSG(_msg) _X_DEPRECATED
#endif

#if __has_attribute(noreturn) \
    || (defined(__GNUC__) && ((__GNUC__ * 100 + __GNUC_MINOR__) >= 205)) \
    || (defined(__SUNPRO_C) && (__SUNPRO_C >= 0x590))

    # define _X_NORETURN __attribute((noreturn))
#else
    # define _X_NORETURN
#endif /* GNUC  */

#if __has_attribute(__format__) \
    || defined(__GNUC__) && ((__GNUC__ * 100 + __GNUC_MINOR__) >= 203)

    # define _X_ATTRIBUTE_PRINTF(x,y) __attribute__((__format__(__printf__,x,y)))
#else /* not gcc >= 2.3 */
    # define _X_ATTRIBUTE_PRINTF(x,y)
#endif

#if __has_attribute(nonnull) \
    && defined(__STDC_VERSION__) && (__STDC_VERSION__ - 0 >= 199901L) /* C99 */

    #define _X_NONNULL(...)  __attribute__((nonnull(__VA_ARGS__)))
#elif __has_attribute(nonnull) \
    || defined(__GNUC__) &&  ((__GNUC__ * 100 + __GNUC_MINOR__) >= 303)

    #define _X_NONNULL(args...)  __attribute__((nonnull(args)))
#elif defined(__STDC_VERSION__) && (__STDC_VERSION__ - 0 >= 199901L) /* C99 */
    #define _X_NONNULL(...)  /* */
#endif

#if __has_attribute(__unused__) \
    || defined(__GNUC__) &&  ((__GNUC__ * 100 + __GNUC_MINOR__) >= 205)

    #define _X_UNUSED  __attribute__((__unused__))
#else
    #define _X_UNUSED  /* */
#endif

#if defined(inline) /* assume autoconf set it correctly */ || \
   (defined(__STDC_VERSION__) && (__STDC_VERSION__ - 0 >= 199901L)) /* C99 */ || \
   (defined(__SUNPRO_C) && (__SUNPRO_C >= 0x550))

    # define _X_INLINE inline
#elif defined(__GNUC__) && !defined(__STRICT_ANSI__) /* gcc w/C89+extensions */
    # define _X_INLINE __inline__
#else
    # define _X_INLINE
#endif

#ifndef _X_RESTRICT_KYWD
    #if defined(restrict) /* assume autoconf set it correctly */ || \
        (defined(__STDC_VERSION__) && (__STDC_VERSION__ - 0 >= 199901L) /* C99 */ \
        && !defined(__cplusplus)) /* Workaround g++ issue on Solaris */

        #define _X_RESTRICT_KYWD  restrict
    #elif defined(__GNUC__) && !defined(__STRICT_ANSI__) /* gcc w/C89+extensions */
        #define _X_RESTRICT_KYWD __restrict__
    #else
        #define _X_RESTRICT_KYWD
    #endif
#endif

#endif /* _ZIGX_XFUNCPROTO_H */
