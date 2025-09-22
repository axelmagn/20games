#if defined(IMPL)
#define FONTSTASH_IMPLEMENTATION
#define SOKOL_FONTSTASH_IMPL
#endif
#include "sokol_defines.h"
#include "sokol_gfx.h"
#include "sokol_gl.h"

#include <stdio.h>  // needed by fontstash's IO functions even though they are not used
#include <stdlib.h>  // needed by fontstash's IO functions even though they are not used
#if defined(_MSC_VER )
#pragma warning(disable:4996)   // strncpy use in fontstash.h
#endif
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wsign-conversion"
#endif
// #include "fontstash/fontstash.h"
#include "fontstash.h"
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif

#include "sokol_fontstash.h"
