#ifndef _GBI_INTERNAL_H_
#define _GBI_INTERNAL_H_

// These MUST be the same as the definitions in gbi.h, for some reason
// these are in a _LANGUAGE_C region of the file so we cannot access them...
// guard them incase a custom gbi.h exposes them properly
#ifndef G_MV_MMTX
# define G_MV_MMTX      2
# define G_MV_PMTX      6
# define G_MV_VIEWPORT  8
# define G_MV_LIGHT     10
# define G_MV_POINT     12
# define G_MV_MATRIX    14
#endif

// Point lighting gbi extension, stock gbi.h doesn't have thes so provide them
// and guard them incase a custom gbi.h has them
#if CFG_POINT_LIGHTING
#ifndef G_LIGHTING_POSITIONAL
# define G_LIGHTING_POSITIONAL   0x00400000
#endif
#ifndef G_LIGHTING_POSITIONAL_H
# define G_LIGHTING_POSITIONAL_H (G_LIGHTING_POSITIONAL/0x10000)
#endif
#endif

// Convenience macros for referring to matrix flags
#define G_MTX_MV_P        (G_MTX_MODELVIEW | G_MTX_PROJECTION)
#define G_MTX_MUL_LOAD    (G_MTX_MUL | G_MTX_LOAD)
#define G_MTX_NOPUSH_PUSH (G_MTX_NOPUSH | G_MTX_PUSH)

#define lightSize 0x18

// Input Vertex structure offsets, should match Vtx structure in gbi.h
#define inputVtxSize    0x10
  #define VTX_IN_OB         0x00
#define VTX_IN_X            0x00
#define VTX_IN_Y            0x02
#define VTX_IN_Z            0x04
#define VTX_IN_FLAG         0x06
  #define VTX_IN_TC         0x08
#define VTX_IN_S            0x08
#define VTX_IN_T            0x0A
  #define VTX_IN_CN         0x0C // color or normal

// RSP Vertex structure offsets
#define vtxSize         0x28
  #define VTX_INT_VEC       0x00
#define VTX_X_INT           0x00
#define VTX_Y_INT           0x02
#define VTX_Z_INT           0x04
#define VTX_W_INT           0x06
  #define VTX_FRAC_VEC      0x08
#define VTX_X_FRAC          0x08
#define VTX_Y_FRAC          0x0A
#define VTX_Z_FRAC          0x0C
#define VTX_W_FRAC          0x0E
  #define VTX_COLOR_VEC     0x10
#define VTX_COLOR_R         0x10
#define VTX_COLOR_G         0x11
#define VTX_COLOR_B         0x12
#define VTX_COLOR_A         0x13
  #define VTX_TC_VEC        0x14
#define VTX_TC_S            0x14
#define VTX_TC_T            0x16
  #define VTX_SCR_VEC       0x18
#define VTX_SCR_X           0x18
#define VTX_SCR_Y           0x1A
#define VTX_SCR_Z           0x1C
#define VTX_SCR_Z_FRAC      0x1E
  #define VTX_INV_W_VEC     0x20
#define VTX_INV_W_INT       0x20
#define VTX_INV_W_FRAC      0x22
  #define VTX_CLIP          0x24
#define VTX_CLIP_SCAL       0x24
#define VTX_CLIP_SCRN       0x26

// Clipping flags. Bits 0-3, 8-11, etc. contain garbage (values from another
// vertex or zeros) and are not used. Also, the bits for comparisons to W in
// clip ratio scaled clipping are actually for Z, but only X and Y are used in
// clip ratio scaled clipping.
#define CLIP_NX (1 <<  4)
#define CLIP_NY (1 <<  5)
#define CLIP_NZ (1 <<  6)
#define CLIP_NW (1 <<  7)
#define CLIP_PX (1 << 12)
#define CLIP_PY (1 << 13)
#define CLIP_PZ (1 << 14)
#define CLIP_PW (1 << 15) // never used
// These values apply to either screen space clipping or clip ratio scaled
// clipping, with appropriate shifts when used as one whole word.
#define CLIP_SHIFT_SCAL 16
#define CLIP_SHIFT_SCRN 0
// Values used for far and near clipping.
#define CLIP_FAR CLIP_PZ
#if CFG_NoN
    // No Nearclipping uses -w instead of -z
#define CLIP_NEAR CLIP_NW
#else
#define CLIP_NEAR CLIP_NZ
#endif

#define CLIP_ALL (CLIP_NX | CLIP_NY | CLIP_PX | CLIP_PY | CLIP_FAR | CLIP_NEAR)

#define CLIP_ALL_SCRN (CLIP_ALL << CLIP_SHIFT_SCRN)
#define CLIP_ALL_SCAL (CLIP_ALL << CLIP_SHIFT_SCAL)

#endif
