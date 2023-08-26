.rsp

.include "rsp/rsp_defs.inc"
.include "rsp/gbi.inc"

// This file assumes DATA_FILE and CODE_FILE are set on the command line

.if version() < 110
    .error "armips 0.11 or newer is required"
.endif

// Tweak the li and la macros so that the output matches
.macro li, reg, imm
    addi reg, $zero, imm
.endmacro

.macro la, reg, imm
    addiu reg, $zero, imm
.endmacro

.macro move, dst, src
    ori dst, src, 0
.endmacro

// Prohibit macros involving slt; this silently clobbers $1. You can of course
// manually write the slt and branch instructions if you want this behavior.
.macro blt, ra, rb, lbl
    .error "blt is a macro using slt, and silently clobbers $1!"
.endmacro

.macro bgt, ra, rb, lbl
    .error "bgt is a macro using slt, and silently clobbers $1!"
.endmacro

.macro ble, ra, rb, lbl
    .error "ble is a macro using slt, and silently clobbers $1!"
.endmacro

.macro bge, ra, rb, lbl
    .error "bge is a macro using slt, and silently clobbers $1!"
.endmacro

// Vector macros
.macro vcopy, dst, src
    vadd dst, src, $v0[0]
.endmacro

.macro vclr, dst
    vxor dst, dst, dst
.endmacro

ACC_UPPER equ 0
ACC_MIDDLE equ 1
ACC_LOWER equ 2
.macro vreadacc, dst, N
    vsar dst, dst, dst[N]
.endmacro

/*
There are two different memory spaces for the overlays: (a) IMEM and (b) the
microcode file (which, plus an offset, is also the location in DRAM).

A label marks both an IMEM addresses and a file address, but evaluating the
label in an integer context (e.g. in a branch) gives the IMEM address.
`orga(your_label)` gets the file address of the label, and `.orga` sets the
file address.
`.headersize`, as well as the value after `.create`, sets the difference
between IMEM addresses and file addresses, so you can set the IMEM address
with `.headersize desired_imem_addr - orga()`.

In IMEM, the whole microcode is organized as (each row is the same address):

0x80 space             |                |
for boot code       Overlay 0       Overlay 1
                      (End          (More cmd 
start                 task)         handlers)
(initialization)       |                |

Many command
handlers

Overlay 2           Overlay 3
(Lighting)          (Clipping)

Vertex and
tri handlers

DMA code

In the file, the microcode is organized as:
start (file addr 0x0 = IMEM 0x1080)
Many command handlers
Overlay 3
Vertex and tri handlers
DMA code (end of this = IMEM 0x2000 = file 0xF80)
Overlay 0
Overlay 1
Overlay 2
*/

// Overlay table data member offsets
overlay_load equ 0x0000
overlay_len  equ 0x0004
overlay_imem equ 0x0006
.macro OverlayEntry, loadStart, loadEnd, imemAddr
    .dw loadStart
    .dh (loadEnd - loadStart - 1) & 0xFFFF
    .dh (imemAddr) & 0xFFFF
.endmacro

.macro jumpTableEntry, addr
    .dh addr & 0xFFFF
.endmacro

// RSP DMEM
.create DATA_FILE, 0x0000

/*
Matrices are stored and used in a transposed format compared to how they are
normally written in mathematics. For the integer part:
00 02 04 06  typical  Xscl Rot  Rot  0
08 0A 0C 0E  use:     Rot  Yscl Rot  0
10 12 14 16           Rot  Rot  Zscl 0
18 1A 1C 1E           Xpos Ypos Zpos 1
The fractional part comes next and is in the same format.
Applying this transformation is done by multiplying a row vector times the
matrix, like:
X  Y  Z  1  *  Xscl Rot  Rot  0  =  NewX NewY NewZ 1
               Rot  Yscl Rot  0
               Rot  Rot  Zscl 0
               Xpos Ypos Zpos 1
In C, the matrix is accessed as matrix[row][col], and the vector is vector[row].
*/
// 0x0000-0x0040: modelview matrix
mvMatrix:
    .fill 64

// 0x0040-0x0080: projection matrix
pMatrix:
    .fill 64

// 0x0080-0x00C0: modelviewprojection matrix
mvpMatrix:
    .fill 64
    
// 0x00C0-0x00C8: scissor (four 12-bit values)
scissorUpLeft: // the command byte is included since the command word is copied verbatim
    .dw (G_SETSCISSOR << 24) | ((  0 * 4) << 12) | ((  0 * 4) << 0)
scissorBottomRight:
    .dw ((320 * 4) << 12) | ((240 * 4) << 0)

// 0x00C8-0x00D0: othermode
otherMode0: // command byte included, same as above
    .dw (G_RDPSETOTHERMODE << 24) | (0x080CFF)
otherMode1:
    .dw 0x00000000

// 0x00D0-0x00D8: Saved texrect state for combining the multiple input commands into one RDP texrect command
texrectWord1:
    .fill 4 // first word, has command byte, xh and yh
texrectWord2:
    .fill 4 // second word, has tile, xl, yl

// 0x00D8: First half of RDP value for split commands (shared by perspNorm moveword to be able to write a 32-bit value)
rdpHalf1Val:
    .fill 4

// 0x00DC: perspective norm
perspNorm:
    .dh 0xFFFF

// 0x00DE: displaylist stack length
displayListStackLength:
    .db 0x00 // starts at 0, increments by 4 for each "return address" pushed onto the stack

    .db 0x48 // this seems to be the max displaylist length

// 0x00E0-0x00F0: viewport
viewport:
    .fill 16

// 0x00F0-0x00F4: Current RDP fifo output position
rdpFifoPos:
    .fill 4

// 0x00F4-0x00F8:
matrixStackPtr:
    .dw 0x00000000

// 0x00F8-0x0138: segment table
segmentTable:
    .fill (4 * 16) // 16 DRAM pointers

// 0x0138-0x0180: displaylist stack
displayListStack:

// 0x0138-0x0180: ucode text (shared with DL stack)
.if CFG_EXTRA_0A_BEFORE_ID_STR // F3DEX2 2.04H puts an extra 0x0A before the name
    .db 0x0A
.endif
    .ascii ID_STR, 0x0A

.align 16
.if . - displayListStack != 0x48
    .warning "ID_STR incorrect length, affects displayListStack"
.endif

// Base address for RSP effects DMEM region (see discussion in lighting below).
// Could pick a better name, basically a global fixed DMEM pointer used with
// fixed offsets to things in this region. It seems potentially data below this
// could be shared by different running microcodes whereas data after this is
// only used by the current microcode. Also this is used for a base address in
// vtx write / lighting because vector load offsets can't reach all of DMEM.
spFxBase:

// 0x0180-0x1B0: clipping values
clipRatio: // This is an array of 6 doublewords
// G_MWO_CLIP_R** point to the second word of each of these, and end up setting
// the Z scale (always 0 for X and Y components) and the W scale (clip ratio)
    .dw 0x00010000, 0x00000002 // 1 * x,    G_MWO_CLIP_RNX * w = negative x clip
    .dw 0x00000001, 0x00000002 // 1 * y,    G_MWO_CLIP_RNY * w = negative y clip
    .dw 0x00010000, 0x0000FFFE // 1 * x, (-)G_MWO_CLIP_RPX * w = positive x clip
    .dw 0x00000001, 0x0000FFFE // 1 * x, (-)G_MWO_CLIP_RPY * w = positive y clip
    .dw 0x00000000, 0x0001FFFF // 1 * z,  -1 * w = far clip
.if CFG_NoN
    .dw 0x00000000, 0x00000001 // 0 * all, 1 * w = no nearclipping
.else
    .dw 0x00000000, 0x00010001 // 1 * z,   1 * w = nearclipping
.endif

// 0x1B0: constants for register $v31
.align 0x10 // loaded with lqv
// VCC patterns used:
// vlt xxx, $v31, $v31[3]  = 11101110 in load_spfx_global_values
// vne xxx, $v31, $v31[3h] = 11101110 in lighting
// veq xxx, $v31, $v31[3h] = 00010001 in lighting
v31Value:
    .dh -1     // used in init, clipping
    .dh 4      // used in clipping, vtx write for Newton-Raphson reciprocal
    .dh 8      // old ucode only: used in tri write
    .dh 0x7F00 // used in vtx write and pre-jump instrs to there, also 4 put here during point lighting
    .dh -4     // used in clipping, vtx write for Newton-Raphson reciprocal
    .dh 0x4000 // used in tri write, texgen
    .dh vertexBuffer // 0x420; used in tri write
    .dh 0x7FFF // used in vtx write, tri write, lighting, point lighting

// 0x1C0: constants for register $v30
.align 0x10 // loaded with lqv
// VCC patterns used:
// vge xxx, $v30, $v30[7] = 11110001 in tri write
v30Value:
    .dh 0x7FFC // not used!
    .dh vtxSize << 7 // 0x1400; it's not 0x2800 because vertex indices are *2; used in tri write for vtx index to addr
.if CFG_OLD_TRI_WRITE // See discussion in tri write where v30 values used
    .dh 0x01CC // used in tri write, vcr?
    .dh 0x0200 // not used!
    .dh -16    // used in tri write for Newton-Raphson reciprocal 
    .dh 0x0010 // used in tri write for Newton-Raphson reciprocal
    .dh 0x0020 // used in tri write, both signed and unsigned multipliers
    .dh 0x0100 // used in tri write, vertex color >>= 8; also in lighting
.else
    .dh 0x1000 // used in tri write, some multiplier
    .dh 0x0100 // used in tri write, vertex color >>= 8 and vcr?; also in lighting and point lighting
    .dh -16    // used in tri write for Newton-Raphson reciprocal 
    .dh 0xFFF8 // used in tri write, mask away lower ST bits?
    .dh 0x0010 // used in tri write for Newton-Raphson reciprocal; value moved to elem 7 for point lighting
    .dh 0x0020 // used in tri write, both signed and unsigned multipliers; value moved from elem 6 from point lighting
.endif

/*
Quick note on Newton-Raphson:
https://en.wikipedia.org/wiki/Division_algorithm#Newton%E2%80%93Raphson_division
Given input D, we want to find the reciprocal R. The base formula for refining
the estimate of R is R_new = R*(2 - D*R). However, since the RSP reciprocal
instruction moves the radix point 1 to the left, the result has to be multiplied
by 2. So it's 2*R*(2 - D*2*R) = R*(4 - 4*D*R) = R*(1*4 + D*R*-4). This is where
the 4 and -4 come from. For tri write, the result needs to be multiplied by 4
for subpixels, so it's 16 and -16.
*/

.align 0x10 // loaded with lqv
linearGenerateCoefficients:
    .dh 0xC000
    .dh 0x44D3
    .dh 0x6CB3
    .dh 2

// 0x01D8
    .db 0x00 // Padding to allow mvpValid to be written to as a 32-bit word
mvpValid:
    .db 0x01

// 0x01DA
    .dh 0x0000 // Shared padding so that:
               // -- mvpValid can be written on its own for G_MW_FORCEMTX
               // -- Writing numLightsx18 with G_MW_NUMLIGHT sets lightsValid to 0
               // -- do_popmtx and load_mtx can invalidate both with one zero word write

// 0x01DC
lightsValid:   // Gets overwritten with 0 when numLights is written with moveword.
    .db 1
numLightsx18:
    .db 0

    .db 11
    .db 7 * 0x18

// 0x01E0
fogFactor:
    .dw 0x00000000

// 0x01E4
textureSettings1:
    .dw 0x00000000 // first word, has command byte, bowtie val, level, tile, and on

// 0x01E8
textureSettings2:
    .dw 0x00000000 // second word, has s and t scale

// 0x01EC
geometryModeLabel:
    .dw G_CLIPPING

// excluding ambient light
MAX_LIGHTS equ 7

// 0x01F0-0x02E0: Light data; a total of 10 * lightSize light slots.
// Each slot's data is either directional or point (each pair of letters is a byte):
//      Directional lights:
// 0x00 RR GG BB 00 RR GG BB -- NX NY NZ -- -- -- -- --
// 0x10 TX TY TZ -- TX TY TZ -- (Normals transformed to camera space)
//      Point lights: 
// 0x00 RR GG BB CC RR GG BB LL XXXX YYYY ZZZZ QQ --
// 0x10 -- -- -- -- -- -- -- -- (Invalid transformed normals get stored here)
// CC: constant attenuation factor (0 indicates directional light)
// LL: linear attenuation factor
// QQ: quadratic attenuation factor
//
// First there are two lights, whose directions define the X and Y directions
// for texgen, via g(s)SPLookAtX/Y. The colors are ignored. These lights get
// transformed normals. g(s)SPLight which point here start copying at n*24+24,
// where n starts from 1 for one light (or zero lights), which effectively
// points at lightBufferMain.
lightBufferLookat:
    .fill (2 * lightSize)
// Then there are the main 8 lights. This is between one and seven directional /
// point (if built with this enabled) lights, plus the ambient light at the end.
// Zero lights is not supported, and is encoded as one light with black color
// (does not affect the result). Directional and point lights can be mixed in
// any order; ambient is always at the end.
lightBufferMain:
    .fill (8 * lightSize)
// Code uses pointers relative to spFxBase, with immediate offsets, so that
// another register isn't needed to store the start or end address of the array.
// Pointers are kept relative to spFxBase; this offset gets them to point to
// lightBufferMain instead.
ltBufOfs equ (lightBufferMain - spFxBase)
// One more topic on lighting: The point lighting code uses MV transpose instead
// of MV inverse to transform from camera space to model space. If MV has a
// uniform scale (same scale in X, Y, and Z), MV transpose = MV inverse times a
// scale factor. The lighting code effectively gets rid of the scale factor, so
// this is okay. But, if the matrix has nonuniform scaling, and especially if it
// has shear (nonuniform scaling applied somewhere in the middle of the matrix
// stack, such as to a whole skeletal / skinned mesh), this will not be correct.

// 0x02E0-0x02F0: Overlay 0/1 Table
overlayInfo0:
    OverlayEntry orga(ovl0_start), orga(ovl0_end), ovl0_start
overlayInfo1:
    OverlayEntry orga(ovl1_start), orga(ovl1_end), ovl1_start

// 0x02F0-0x02FE: Movemem table
movememTable:
    // Temporary matrix in clipTempVerts scratch space, aligned to 16 bytes
    .dh (clipTempVerts + 15) & ~0xF // G_MTX multiply temp matrix (model)
    .dh mvMatrix          // G_MV_MMTX
    .dh (clipTempVerts + 15) & ~0xF // G_MTX multiply temp matrix (projection)
    .dh pMatrix           // G_MV_PMTX
    .dh viewport          // G_MV_VIEWPORT
    .dh lightBufferLookat // G_MV_LIGHT
    .dh vertexBuffer      // G_MV_POINT
// Further entries in the movemem table come from the moveword table

// 0x02FE-0x030E: moveword table
movewordTable:
    .dh mvpMatrix        // G_MW_MATRIX
    .dh numLightsx18 - 3 // G_MW_NUMLIGHT
    .dh clipRatio        // G_MW_CLIP
    .dh segmentTable     // G_MW_SEGMENT
    .dh fogFactor        // G_MW_FOG
    .dh lightBufferMain  // G_MW_LIGHTCOL
    .dh mvpValid - 1     // G_MW_FORCEMTX
    .dh perspNorm - 2    // G_MW_PERSPNORM

// 0x030E-0x0314: G_POPMTX, G_MTX, G_MOVEMEM Command Jump Table
movememHandlerTable:
jumpTableEntry G_POPMTX_end   // G_POPMTX
jumpTableEntry G_MTX_end      // G_MTX (multiply)
jumpTableEntry G_MOVEMEM_end  // G_MOVEMEM, G_MTX (load)

// 0x0314-0x0370: RDP/Immediate Command Jump Table
jumpTableEntry G_SPECIAL_3_handler
jumpTableEntry G_SPECIAL_2_handler
jumpTableEntry G_SPECIAL_1_handler
jumpTableEntry G_DMA_IO_handler
jumpTableEntry G_TEXTURE_handler
jumpTableEntry G_POPMTX_handler
jumpTableEntry G_GEOMETRYMODE_handler
jumpTableEntry G_MTX_handler
jumpTableEntry G_MOVEWORD_handler
jumpTableEntry G_MOVEMEM_handler
jumpTableEntry G_LOAD_UCODE_handler
jumpTableEntry G_DL_handler
jumpTableEntry G_ENDDL_handler
jumpTableEntry G_SPNOOP_handler
jumpTableEntry G_RDPHALF_1_handler
jumpTableEntry G_SETOTHERMODE_L_handler
jumpTableEntry G_SETOTHERMODE_H_handler
jumpTableEntry G_TEXRECT_handler
jumpTableEntry G_TEXRECTFLIP_handler
jumpTableEntry G_SYNC_handler    // G_RDPLOADSYNC
jumpTableEntry G_SYNC_handler    // G_RDPPIPESYNC
jumpTableEntry G_SYNC_handler    // G_RDPTILESYNC
jumpTableEntry G_SYNC_handler    // G_RDPFULLSYNC
jumpTableEntry G_RDP_handler     // G_SETKEYGB
jumpTableEntry G_RDP_handler     // G_SETKEYR
jumpTableEntry G_RDP_handler     // G_SETCONVERT
jumpTableEntry G_SETSCISSOR_handler
jumpTableEntry G_RDP_handler     // G_SETPRIMDEPTH
jumpTableEntry G_RDPSETOTHERMODE_handler
jumpTableEntry G_RDP_handler     // G_LOADTLUT
jumpTableEntry G_RDPHALF_2_handler
jumpTableEntry G_RDP_handler     // G_SETTILESIZE
jumpTableEntry G_RDP_handler     // G_LOADBLOCK
jumpTableEntry G_RDP_handler     // G_LOADTILE
jumpTableEntry G_RDP_handler     // G_SETTILE
jumpTableEntry G_RDP_handler     // G_FILLRECT
jumpTableEntry G_RDP_handler     // G_SETFILLCOLOR
jumpTableEntry G_RDP_handler     // G_SETFOGCOLOR
jumpTableEntry G_RDP_handler     // G_SETBLENDCOLOR
jumpTableEntry G_RDP_handler     // G_SETPRIMCOLOR
jumpTableEntry G_RDP_handler     // G_SETENVCOLOR
jumpTableEntry G_RDP_handler     // G_SETCOMBINE
jumpTableEntry G_SETxIMG_handler // G_SETTIMG
jumpTableEntry G_SETxIMG_handler // G_SETZIMG
jumpTableEntry G_SETxIMG_handler // G_SETCIMG

commandJumpTable:
jumpTableEntry G_NOOP_handler

// 0x0370-0x0380: DMA Command Jump Table
jumpTableEntry G_VTX_handler
jumpTableEntry G_MODIFYVTX_handler
jumpTableEntry G_CULLDL_handler
jumpTableEntry G_BRANCH_WZ_handler // different for F3DZEX
jumpTableEntry G_TRI1_handler
jumpTableEntry G_TRI2_handler
jumpTableEntry G_QUAD_handler
jumpTableEntry G_LINE3D_handler

// 0x0380-0x03C4: vertex pointers
vertexTable:

// The vertex table is a list of pointers to the location of each vertex in the buffer
// After the last vertex pointer, there is a pointer to the address after the last vertex
// This means there are really 33 entries in the table

.macro vertexTableEntry, i
    .dh vertexBuffer + (i * vtxSize)
.endmacro

.macro vertexTableEntries, i
    .if i > 0
        vertexTableEntries (i - 1)
    .endif
    vertexTableEntry i
.endmacro

    vertexTableEntries 32

// 0x03C2-0x0410: ??
gCullMagicNumbers:
// Values added to cross product (16-bit sign extended).
// Then if sign bit is clear, cull the triangle.
    .dh 0xFFFF // }-G_CULL_NEITHER -- makes any value negative.
    .dh 0x8000 // }/    }-G_CULL_FRONT -- inverts the sign.
    .dh 0x0000 //       }/    }-G_CULL_BACK -- no change.
    .dh 0x0000 //             }/    }-G_CULL_BOTH -- makes any value positive.
    .dh 0x8000 //                   }/
// G_CULL_BOTH is useless as the tri will always be culled, so might as well not
// bother drawing it at all. Guess they just wanted completeness, and it only
// costs two bytes of DMEM.

activeClipPlanes:
    .dw ((CLIP_NX | CLIP_NY | CLIP_PX | CLIP_PY) << CLIP_SHIFT_SCAL) | ((CLIP_FAR | CLIP_NEAR) << CLIP_SHIFT_SCRN)

// 0x3D0: Clipping polygons, as lists of vertex addresses. When handling each
// clipping condition, the polygon is read off one list and the modified polygon
// is written to the next one.
// Max verts in each polygon:
clipPoly:
    .fill 10 * 2   // 3   5   7   9
clipPoly2:         //  \ / \ / \ /
    .fill 10 * 2   //   4   6   8
// but there needs to be room for the terminating 0, and clipMaskList below needs
// to be word-aligned. So this is why it's 10 each.

clipMaskList:
    .dw CLIP_NX   << CLIP_SHIFT_SCAL
    .dw CLIP_NY   << CLIP_SHIFT_SCAL
    .dw CLIP_PX   << CLIP_SHIFT_SCAL
    .dw CLIP_PY   << CLIP_SHIFT_SCAL
    .dw CLIP_FAR  << CLIP_SHIFT_SCRN
    .dw CLIP_NEAR << CLIP_SHIFT_SCRN

// 0x0410-0x0420: Overlay 2/3 table
overlayInfo2:
    OverlayEntry orga(ovl2_start), orga(ovl2_end), ovl2_start
overlayInfo3:
    OverlayEntry orga(ovl3_start), orga(ovl3_end), ovl3_start

// 0x0420-0x0920: Vertex buffer in RSP internal format
vertexBuffer:
    .skip (vtxSize * 32) // 32 vertices

.if . > OS_YIELD_DATA_SIZE - 8
    // OS_YIELD_DATA_SIZE (0xC00) bytes of DMEM are saved; the last two words are
    // the ucode and the DL pointer. Make sure anything past there is temporary.
    // (Input buffer will be reloaded from next instruction in the source DL.)
    .error "Important things in DMEM will not be saved at yield!"
.endif

// 0x0920-0x09C8: Input buffer
inputBuffer:
inputBufferLength equ 0xA8
    .skip inputBufferLength
inputBufferEnd:

// 0x09C8-0x0BA8: Space for temporary verts for clipping code
clipTempVerts:
clipTempVertsCount equ 12 // Up to 2 temp verts can be created for each of the 6 clip conditions.
    .skip clipTempVertsCount * vtxSize

// 0x09D0-0x0A10: Temp matrix for G_MTX multiplication mode, overlaps with clipTempVerts

RDP_CMD_BUFSIZE equ 0x158
RDP_CMD_BUFSIZE_EXCESS equ 0xB0 // Maximum size of an RDP triangle command
RDP_CMD_BUFSIZE_TOTAL equ RDP_CMD_BUFSIZE + RDP_CMD_BUFSIZE_EXCESS
// 0x0BA8-0x0D00: First RDP Command Buffer
rdpCmdBuffer1:
    .skip RDP_CMD_BUFSIZE
rdpCmdBuffer1End:
    .skip RDP_CMD_BUFSIZE_EXCESS


// 0x0DB0-0x0FB8: Second RDP Command Buffer
rdpCmdBuffer2:
    .skip RDP_CMD_BUFSIZE
rdpCmdBuffer2End:
    .skip RDP_CMD_BUFSIZE_EXCESS

.if . > 0x00000FC0
    .error "Not enough room in DMEM"
.endif

.org 0xFC0

// 0x0FC0-0x1000: OSTask
OSTask:
    .skip 0x40

.close // DATA_FILE

// RSP IMEM
.create CODE_FILE, 0x00001080

////////////////////////////////////////////////////////////////////////////////
/////////////////////////////// Register Use Map ///////////////////////////////
////////////////////////////////////////////////////////////////////////////////

// Registers marked as "global" are only used for one purpose in the vanilla
// microcode. However, this does not necessarily mean they can't be used for
// other things in mods--this depends on which group they're listed in below.

// Note that these lists do not cover registers which are just used locally in
// a particular region of code--you're still responsible for not breaking the
// code you modify. This is designed to help you avoid breaking one part of the
// code by modifying a different part.

// Local register definitions are included with their code, not here.

// These registers are used globally, and their values can't be rebuilt, so
// they should never be used for anything besides their original purpose.
//                 $zero // global
rdpCmdBufEnd   equ $22   // global
rdpCmdBufPtr   equ $23   // global
taskDataPtr    equ $26   // global
inputBufferPos equ $27   // global
//                 $ra   // global

// These registers are used throughout the codebase and expected to have
// certain values, but you're free to overwrite them as long as you
// reconstruct the normal values after you're done (in fact point lighting does
// this for $v30 and $v31).
vZero equ $v0  // global
vOne  equ $v1  // global
//        $v30 // global
//        $v31 // global

// Must keep values during the full clipping process: clipping overlay, vertex
// write, tri drawing.
clipPolySelect        equ $18 // global
clipPolyWrite         equ $21 // also input_mtx_0
savedActiveClipPlanes equ $29 // global
savedRA               equ $30 // global

// Must keep values during the first part of the clipping process only: polygon
// subdivision and vertex write.
// $2: vertex at end of edge
clipMaskIdx  equ $5
secondVtxPos equ $8
outputVtxPos equ $15 // global
clipFlags    equ $16 // global
clipPolyRead equ $17 // global

// Must keep values during tri drawing.
// They are also used throughout the codebase, but can be overwritten once their
// use has been fulfilled for the specific command.
cmd_w1_dram equ $24 // Command word 1, which is also DMA DRAM addr; almost global, occasionally used locally
cmd_w0      equ $25 // Command word 0; almost global, occasionally used locally

// Must keep values during the full vertex process: load, lighting, and vertex write
// $1: count of remaining vertices
topLightPtr  equ $6   // Used locally elsewhere
curLight     equ $9   // Used locally elsewhere
inputVtxPos  equ $14  // global
mxr0i        equ $v8  // "matrix row 0 int part"
mxr1i        equ $v9  // All of these used locally elsewhere
mxr2i        equ $v10
mxr3i        equ $v11
mxr0f        equ $v12
mxr1f        equ $v13
mxr2f        equ $v14
mxr3f        equ $v15
vPairST      equ $v22
vPairMVPPosF equ $v23
vPairMVPPosI equ $v24
// v25: prev vertex screen pos
// v26: prev vertex screen Z
// For point lighting
mvTc0f equ $v3
mvTc0i equ $v4
mvTc1i equ $v21
mvTc1f equ $v28 // same as vPairAlpha37
mvTc2i equ $v30
mvTc2f equ $v31

// Values set up by load_spfx_global_values, which must be kept during the full
// vertex process, and which are reloaded for each vert during clipping. See
// that routine for the detailed contents of each of these registers.
// secondVtxPos
spFxBaseReg equ $13  // global
vVpFgScale  equ $v16 // All of these used locally elsewhere
vVpFgOffset equ $v17
vVpMisc     equ $v18
vFogMask    equ $v19
vVpNegScale equ $v21

// Arguments to mtx_multiply
output_mtx  equ $19 // also dmaLen, also used by itself
input_mtx_1 equ $20 // also dmemAddr and xfrmLtPtr
input_mtx_0 equ $21 // also clipPolyWrite

// Arguments to dma_read_write
dmaLen   equ $19 // also output_mtx, also used by itself
dmemAddr equ $20 // also input_mtx_1 and xfrmLtPtr
// cmd_w1_dram   // used for all dma_read_write DRAM addresses, not just second word of command

// Arguments to load_overlay_and_enter
ovlTableEntry equ $11 // Commonly used locally
postOvlRA     equ $12 // Commonly used locally

// ==== Summary of uses of all registers
// $zero: Hardwired zero scalar register
// $1: vertex 1 addr, count of remaining vertices, pointer to store texture coefficients, local
// $2: vertex 2 addr, vertex at end of edge in clipping, pointer to store shade coefficients, local
// $3: vertex 3 addr, vertex at start of edge in clipping, local
// $4: pre-shuffle vertex 1 addr for flat shading, local
// $5: clipMaskIdx, geometry mode high short during vertex load / lighting, local
// $6: topLightPtr, geometry mode low byte during tri write, local
// $7: fog flag in vtx write, local
// $8: secondVtxPos, local
// $9: curLight, local
// $10: briefly used local in vtx write
// $11: ovlTableEntry, very common local
// $12: postOvlRA, curMatrix, local
// $13: spFxBaseReg
// $14: inputVtxPos
// $15: outputVtxPos
// $16: clipFlags
// $17: clipPolyRead
// $18: clipPolySelect
// $19: dmaLen, output_mtx, briefly used local
// $20: dmemAddr, input_mtx_1, xfrmLtPtr
// $21: clipPolyWrite, input_mtx_0
// $22: rdpCmdBufEnd
// $23: rdpCmdBufPtr
// $24: cmd_w1_dram, local
// $25: cmd_w0
// $26: taskDataPtr
// $27: inputBufferPos
// $28: not used!
// $29: savedActiveClipPlanes
// $30: savedRA
// $ra: Return address for jal, b*al
// $v0: vZero (every element 0)
// $v1: vOne (every element 1)
// $v2: very common local
// $v3: mvTc0f, local
// $v4: mvTc0i, local
// $v5: vPairNZ, local
// $v6: vPairNY, local
// $v7: vPairNX, vPairRGBATemp, local
// $v8: mxr0i, local
// $v9: mxr1i, local
// $v10: mxr2i, local
// $v11: mxr3i, local
// $v12: mxr0f, local
// $v13: mxr1f, local
// $v14: mxr2f, local
// $v15: mxr3f, local
// $v16: vVpFgScale, local
// $v17: vVpFgOffset, local
// $v18: vVpMisc, local
// $v19: vFogMask, local
// $v20: local
// $v21: mvTc1i, vVpNegScale, local
// $v22: vPairST, local
// $v23: vPairMVPPosF, local
// $v24: vPairMVPPosI, local
// $v25: prev vertex data, local
// $v26: prev vertex data, local
// $v27: vPairRGBA, local
// $v28: mvTc1f, vPairAlpha37, local
// $v29: register to write to discard results, local
// $v30: mvTc2i, constant values for tri write
// $v31: mvTc2f, general constant values


// Initialization routines
// Everything up until displaylist_dma will get overwritten by ovl0 and/or ovl1
start: // This is at IMEM 0x1080, not the start of IMEM
.if BUG_WRONG_INIT_VZERO
    vor     vZero, $v16, $v16 // Sets vZero to $v16--maybe set to zero by the boot ucode?
.else
    vclr    vZero             // Clear vZero
.endif
    lqv     $v31[0], (v31Value)($zero)
    lqv     $v30[0], (v30Value)($zero)
    li      rdpCmdBufPtr, rdpCmdBuffer1
.if !BUG_FAIL_IF_CARRY_SET_AT_INIT
    vadd    vOne, vZero, vZero   // Consume VCO (carry) value possibly set by the previous ucode, before vsub below
.endif
    li      rdpCmdBufEnd, rdpCmdBuffer1End
    vsub    vOne, vZero, $v31[0]   // Vector of 1s
.if !CFG_XBUS // FIFO version
    lw      $11, rdpFifoPos
    lw      $12, OSTask + OSTask_flags
    li      $1, SP_CLR_SIG2 | SP_CLR_SIG1   // task done and yielded signals
    beqz    $11, task_init
     mtc0   $1, SP_STATUS
    andi    $12, $12, OS_TASK_YIELDED
    beqz    $12, calculate_overlay_addrs    // skip overlay address calculations if resumed from yield?
     sw     $zero, OSTask + OSTask_flags
    j       load_overlay1_init              // Skip the initialization and go straight to loading overlay 1
     lw     taskDataPtr, OS_YIELD_DATA_SIZE - 8  // Was previously saved here at yield time
task_init:
    mfc0    $11, DPC_STATUS
    andi    $11, $11, DPC_STATUS_XBUS_DMA
    bnez    $11, wait_dpc_start_valid
     mfc0   $2, DPC_END
    lw      $3, OSTask + OSTask_output_buff
    sub     $11, $3, $2
    bgtz    $11, wait_dpc_start_valid
     mfc0   $1, DPC_CURRENT
    lw      $4, OSTask + OSTask_output_buff_size
    beqz    $1, wait_dpc_start_valid
     sub    $11, $1, $4
    bgez    $11, wait_dpc_start_valid
     nop
    bne     $1, $2, f3dzex_0000111C
wait_dpc_start_valid:
     mfc0   $11, DPC_STATUS
    andi    $11, $11, DPC_STATUS_START_VALID
    bnez    $11, wait_dpc_start_valid
     li     $11, DPC_STATUS_CLR_XBUS
    mtc0    $11, DPC_STATUS
    lw      $2, OSTask + OSTask_output_buff_size
    mtc0    $2, DPC_START
    mtc0    $2, DPC_END
f3dzex_0000111C:
    sw      $2, rdpFifoPos
.else // CFG_XBUS
wait_dpc_start_valid:
    mfc0 $11, DPC_STATUS
    andi $11, $11, DPC_STATUS_DMA_BUSY | DPC_STATUS_START_VALID 
    bne $11, $zero, wait_dpc_start_valid
     sw $zero, rdpFifoPos
    addi $11, $zero, DPC_STATUS_SET_XBUS
    mtc0 $11, DPC_STATUS
    addi rdpCmdBufPtr, $zero, rdpCmdBuffer1
    mtc0 rdpCmdBufPtr, DPC_START
    mtc0 rdpCmdBufPtr, DPC_END
    lw $12, OSTask + OSTask_flags
    addi $1, $zero, SP_CLR_SIG2 | SP_CLR_SIG1
    mtc0 $1, SP_STATUS
    andi $12, $12, OS_TASK_YIELDED
    beqz $12, f3dzex_xbus_0000111C
     sw $zero, OSTask + OSTask_flags
    j load_overlay1_init
     lw taskDataPtr, OS_YIELD_DATA_SIZE - 8 // Was previously saved here at yield time
.fill 16 * 4 // Bunch of nops here to make it the same size as the fifo code.
f3dzex_xbus_0000111C:
.endif
    lw      $11, matrixStackPtr
    bnez    $11, calculate_overlay_addrs
     lw     $11, OSTask + OSTask_dram_stack
    sw      $11, matrixStackPtr
calculate_overlay_addrs:
    lw      $1, OSTask + OSTask_ucode
    lw      $2, overlayInfo0 + overlay_load
    lw      $3, overlayInfo1 + overlay_load
    lw      $4, overlayInfo2 + overlay_load
    lw      $5, overlayInfo3 + overlay_load
    add     $2, $2, $1
    add     $3, $3, $1
    sw      $2, overlayInfo0 + overlay_load
    sw      $3, overlayInfo1 + overlay_load
    add     $4, $4, $1
    add     $5, $5, $1
    sw      $4, overlayInfo2 + overlay_load
    sw      $5, overlayInfo3 + overlay_load
    lw      taskDataPtr, OSTask + OSTask_data_ptr
load_overlay1_init:
    li      ovlTableEntry, overlayInfo1   // set up loading of overlay 1

// Make room for overlays 0 and 1. Normally, overlay 1 ends exactly at ovl01_end,
// and overlay 0 is much shorter, but if things are modded this constraint must be met.
// The 0x88 is because the file starts 0x80 into IMEM, and the overlays can extend 8
// bytes over the next two instructions as well.
.orga max(orga(), max(ovl0_end - ovl0_start, ovl1_end - ovl1_start) - 0x88)

// Also needs to be aligned so that ovl01_end is a DMA word, in case ovl0 and ovl1
// are shorter than the code above and the code above is an odd number of instructions.
.align 8

// Unnecessarily clever code. The jal sets $ra to the address of the next instruction,
// which is displaylist_dma. So the padding has to be before these two instructions,
// so that this is immediately before displaylist_dma; otherwise the return address
// will be in the last few instructions of overlay 1. However, this was unnecessary--
// it could have been a jump and then `la postOvlRA, displaylist_dma`,
// and the padding put after this.
    jal     load_overlay_and_enter  // load overlay 1 and enter
     move   postOvlRA, $ra          // set up the return address, since load_overlay_and_enter returns to postOvlRA

ovl01_end:
// Overlays 0 and 1 overwrite everything up to this point (2.08 versions overwrite up to the previous .align 8)

displaylist_dma: // loads inputBufferLength bytes worth of displaylist data via DMA into inputBuffer
    li      dmaLen, inputBufferLength - 1               // set the DMA length
    move    cmd_w1_dram, taskDataPtr                    // set up the DRAM address to read from
    jal     dma_read_write                              // initiate the DMA read
     la     dmemAddr, inputBuffer                       // set the address to DMA read to
    addiu   taskDataPtr, taskDataPtr, inputBufferLength // increment the DRAM address to read from next time
    li      inputBufferPos, -inputBufferLength          // reset the DL word index
wait_for_dma_and_run_next_command:
G_POPMTX_end:
G_MOVEMEM_end:
    jal     while_wait_dma_busy                         // wait for the DMA read to finish
G_LINE3D_handler:
G_SPNOOP_handler:
.if !CFG_G_SPECIAL_1_IS_RECALC_MVP                      // F3DEX2 2.04H has this as a real command
G_SPECIAL_1_handler:
.endif
G_SPECIAL_2_handler:
G_SPECIAL_3_handler:
run_next_DL_command:
     mfc0   $1, SP_STATUS                               // load the status word into register $1
    lw      cmd_w0, (inputBufferEnd)(inputBufferPos)    // load the command word into cmd_w0
    beqz    inputBufferPos, displaylist_dma             // load more DL commands if none are left
     andi   $1, $1, SP_STATUS_SIG0                      // check if the task should yield
    sra     $12, cmd_w0, 24                             // extract DL command byte from command word
    sll     $11, $12, 1                                 // multiply command byte by 2 to get jump table offset
    lhu     $11, (commandJumpTable)($11)                // get command subroutine address from command jump table
    bnez    $1, load_overlay_0_and_enter                // load and execute overlay 0 if yielding; $1 > 0
     lw     cmd_w1_dram, (inputBufferEnd + 4)(inputBufferPos) // load the next DL word into cmd_w1_dram
    jr      $11                                         // jump to the loaded command handler; $1 == 0
     addiu  inputBufferPos, inputBufferPos, 0x0008      // increment the DL index by 2 words

.if CFG_G_SPECIAL_1_IS_RECALC_MVP // Microcodes besides F3DEX2 2.04H have this as a noop
G_SPECIAL_1_handler:    // Seems to be a manual trigger for mvp recalculation
    li      $ra, run_next_DL_command
    li      input_mtx_0, pMatrix
    li      input_mtx_1, mvMatrix
    li      output_mtx, mvpMatrix
    j       mtx_multiply
     sb     cmd_w0, mvpValid
.endif

G_DMA_IO_handler:
    jal     segmented_to_physical // Convert the provided segmented address (in cmd_w1_dram) to a virtual one
     lh     dmemAddr, (inputBufferEnd - 0x07)(inputBufferPos) // Get the 16 bits in the middle of the command word (since inputBufferPos was already incremented for the next command)
    andi    dmaLen, cmd_w0, 0x0FF8 // Mask out any bits in the length to ensure 8-byte alignment
    // At this point, dmemAddr's highest bit is the flag, it's next 13 bits are the DMEM address, and then it's last two bits are the upper 2 of size
    // So an arithmetic shift right 2 will preserve the flag as being the sign bit and get rid of the 2 size bits, shifting the DMEM address to start at the LSbit
    sra     dmemAddr, dmemAddr, 2
    j       dma_read_write  // Trigger a DMA read or write, depending on the G_DMA_IO flag (which will occupy the sign bit of dmemAddr)
     li     $ra, wait_for_dma_and_run_next_command  // Setup the return address for running the next DL command

G_GEOMETRYMODE_handler:
    lw      $11, geometryModeLabel  // load the geometry mode value
    and     $11, $11, cmd_w0        // clears the flags in cmd_w0 (set in g*SPClearGeometryMode)
    or      $11, $11, cmd_w1_dram   // sets the flags in cmd_w1_dram (set in g*SPSetGeometryMode)
    j       run_next_DL_command     // run the next DL command
     sw     $11, geometryModeLabel  // update the geometry mode value

G_ENDDL_handler:
    lbu     $1, displayListStackLength          // Load the DL stack index
    beqz    $1, load_overlay_0_and_enter        // Load overlay 0 if there is no DL return address, to end the graphics task processing; $1 < 0
     addi   $1, $1, -4                          // Decrement the DL stack index
    j       f3dzex_ovl1_00001020                // has a different version in ovl1
     lw     taskDataPtr, (displayListStack)($1) // Load the address of the DL to return to into the taskDataPtr (the current DL address)

G_RDPHALF_2_handler:
    ldv     $v29[0], (texrectWord1)($zero)
    lw      cmd_w0, rdpHalf1Val                 // load the RDPHALF1 value into w0
    addi    rdpCmdBufPtr, rdpCmdBufPtr, 8
    sdv     $v29[0], -8(rdpCmdBufPtr)
G_RDP_handler:
    sw      cmd_w1_dram, 4(rdpCmdBufPtr)        // Add the second word of the command to the RDP command buffer
G_SYNC_handler:
G_NOOP_handler:
    sw      cmd_w0, 0(rdpCmdBufPtr)         // Add the command word to the RDP command buffer
    j       check_rdp_buffer_full_and_run_next_cmd
     addi   rdpCmdBufPtr, rdpCmdBufPtr, 8   // Increment the next RDP command pointer by 2 words

G_SETxIMG_handler:
    li      $ra, G_RDP_handler          // Load the RDP command handler into the return address, then fall through to convert the address to virtual
// Converts the segmented address in cmd_w1_dram to the corresponding physical address
segmented_to_physical:
    srl     $11, cmd_w1_dram, 22          // Copy (segment index << 2) into $11
    andi    $11, $11, 0x3C                // Clear the bottom 2 bits that remained during the shift
    lw      $11, (segmentTable)($11)      // Get the current address of the segment
    sll     cmd_w1_dram, cmd_w1_dram, 8   // Shift the address to the left so that the top 8 bits are shifted out
    srl     cmd_w1_dram, cmd_w1_dram, 8   // Shift the address back to the right, resulting in the original with the top 8 bits cleared
    jr      $ra
     add    cmd_w1_dram, cmd_w1_dram, $11 // Add the segment's address to the masked input address, resulting in the virtual address

G_RDPSETOTHERMODE_handler:
    sw      cmd_w0, otherMode0       // Record the local otherMode0 copy
    j       G_RDP_handler            // Send the command to the RDP
     sw     cmd_w1_dram, otherMode1  // Record the local otherMode1 copy

G_SETSCISSOR_handler:
    sw      cmd_w0, scissorUpLeft            // Record the local scissorUpleft copy
    j       G_RDP_handler                    // Send the command to the RDP
     sw     cmd_w1_dram, scissorBottomRight  // Record the local scissorBottomRight copy

check_rdp_buffer_full_and_run_next_cmd:
    li      $ra, run_next_DL_command    // Set up running the next DL command as the return address

.if !CFG_XBUS // FIFO version
check_rdp_buffer_full:
     sub    $11, rdpCmdBufPtr, rdpCmdBufEnd
    blez    $11, return_routine         // Return if rdpCmdBufEnd >= rdpCmdBufPtr
flush_rdp_buffer:
     mfc0   $12, SP_DMA_BUSY
    lw      cmd_w1_dram, rdpFifoPos
    addiu   dmaLen, $11, RDP_CMD_BUFSIZE
    bnez    $12, flush_rdp_buffer
     lw     $12, OSTask + OSTask_output_buff_size
    mtc0    cmd_w1_dram, DPC_END
    add     $11, cmd_w1_dram, dmaLen
    sub     $12, $12, $11
    bgez    $12, f3dzex_000012A8
@@await_start_valid:
     mfc0   $11, DPC_STATUS
    andi    $11, $11, DPC_STATUS_START_VALID
    bnez    $11, @@await_start_valid
     lw     cmd_w1_dram, OSTask + OSTask_output_buff
f3dzex_00001298:
    mfc0    $11, DPC_CURRENT
    beq     $11, cmd_w1_dram, f3dzex_00001298
     nop
    mtc0    cmd_w1_dram, DPC_START
f3dzex_000012A8:
    mfc0    $11, DPC_CURRENT
    sub     $11, $11, cmd_w1_dram
    blez    $11, f3dzex_000012BC
     sub    $11, $11, dmaLen
    blez    $11, f3dzex_000012A8
f3dzex_000012BC:
     add    $11, cmd_w1_dram, dmaLen
    sw      $11, rdpFifoPos
    // Set up the DMA from DMEM to the RDP fifo in RDRAM
    addi    dmaLen, dmaLen, -1                                  // subtract 1 from the length
    addi    dmemAddr, rdpCmdBufEnd, -(0x2000 | RDP_CMD_BUFSIZE) // The 0x2000 is meaningless, negative means write
    xori    rdpCmdBufEnd, rdpCmdBufEnd, rdpCmdBuffer1End ^ rdpCmdBuffer2End // Swap between the two RDP command buffers
    j       dma_read_write
     addi   rdpCmdBufPtr, rdpCmdBufEnd, -RDP_CMD_BUFSIZE
.else // CFG_XBUS
check_rdp_buffer_full:
    addi $11, rdpCmdBufPtr, -(OSTask - RDP_CMD_BUFSIZE_EXCESS)
    blez $11, ovl0_04001284
     mtc0 rdpCmdBufPtr, DPC_END
ovl0_04001260:
    mfc0 $11, DPC_STATUS
    andi $11, $11, DPC_STATUS_END_VALID | DPC_STATUS_START_VALID
    bne $11, $zero, ovl0_04001260
ovl0_0400126C:
     mfc0 $11, DPC_CURRENT
    addi rdpCmdBufPtr, $zero, rdpCmdBuffer1
    beq $11, rdpCmdBufPtr, ovl0_0400126C
     nop
    mtc0 rdpCmdBufPtr, DPC_START
    mtc0 rdpCmdBufPtr, DPC_END
ovl0_04001284:
    mfc0 $11, DPC_CURRENT
    sub $11, $11, rdpCmdBufPtr
    blez $11, ovl0_0400129C
     addi $11, $11, -RDP_CMD_BUFSIZE_EXCESS
    blez $11, ovl0_04001284
     nop
ovl0_0400129C:
    jr $ra
     nop
.endif

.align 8
ovl23_start:

ovl3_start:

// Jump here to do lighting. If overlay 3 is loaded (this code), loads and jumps
// to overlay 2 (same address as right here).
ovl23_lighting_entrypoint_copy:  // same IMEM address as ovl23_lighting_entrypoint
    li      ovlTableEntry, overlayInfo2          // set up a load for overlay 2
    j       load_overlay_and_enter               // load overlay 2
     li     postOvlRA, ovl23_lighting_entrypoint // set the return address

// Jump here to do clipping. If overlay 3 is loaded (this code), directly starts
// the clipping code.
ovl23_clipping_entrypoint:
    move    savedRA, $ra
ovl3_clipping_nosavera:
    la      clipMaskIdx, 0x0014
    la      clipPolySelect, 6  // Everything being indexed from 6 saves one instruction at the end of the loop
    la      outputVtxPos, clipTempVerts
    // Write the current three verts as the initial polygon
    sh      $1, (clipPoly - 6 + 0)(clipPolySelect)
    sh      $2, (clipPoly - 6 + 2)(clipPolySelect)
    sh      $3, (clipPoly - 6 + 4)(clipPolySelect)
    sh      $zero, (clipPoly)(clipPolySelect) // Zero to mark end of polygon
    lw      savedActiveClipPlanes, activeClipPlanes
clipping_condlooptop: // Loop over six clipping conditions: near, far, +y, +x, -y, -x
    lw      $9, (clipMaskList)(clipMaskIdx)          // Load clip mask
    lw      clipFlags, VTX_CLIP($3)                  // Load flags for V3, which will be the final vertex of the last polygon
    and     clipFlags, clipFlags, $9                 // Mask V3's flags to current clip condition
    addi    clipPolyRead,   clipPolySelect, -6       // Start reading at the beginning of the old polygon
    xori    clipPolySelect, clipPolySelect, 6 ^ (clipPoly2 + 6 - clipPoly) // Swap to the other polygon memory
    addi    clipPolyWrite,  clipPolySelect, -6       // Start writing at the beginning of the new polygon
clipping_edgelooptop: // Loop over edges connecting verts, possibly subdivide the edge
    // Edge starts from V3, ends at V2
    lhu     $2, (clipPoly)(clipPolyRead)       // Read next vertex of input polygon as V2 (end of edge)
    addi    clipPolyRead, clipPolyRead, 0x0002 // Increment read pointer
    beqz    $2, clipping_nextcond              // If V2 is 0, done with input polygon
     lw     $11, VTX_CLIP($2)                  // Load flags for V2
    and     $11, $11, $9                       // Mask V2's flags to current clip condition
    beq     $11, clipFlags, clipping_nextedge  // Both set or both clear = both off screen or both on screen, no subdivision
     move   clipFlags, $11                     // clipFlags = masked V2's flags
    beqz    clipFlags, clipping_skipswap23     // V2 flag is clear / on screen, therefore V3 is set / off screen
     move   $19, $2                            // 
    move    $19, $3                            // Otherwise swap V2 and V3; note we are overwriting $3 but not $2
    move    $3, $2                             // 
clipping_skipswap23: // After possible swap, $19 = vtx not meeting clip cond / on screen, $3 = vtx meeting clip cond / off screen
    // Interpolate between these two vertices; create a new vertex which is on the
    // clipping boundary (e.g. at the screen edge)
    sll     $11, clipMaskIdx, 1  // clipMaskIdx counts by 4, so this is now by 8
    ldv     $v2[0], (clipRatio)($11) // Load four shorts holding clip ratio for this clip condition
    ldv     $v4[0], VTX_FRAC_VEC($19) // Vtx on screen, frac pos
    ldv     $v5[0], VTX_INT_VEC ($19) // Vtx on screen, int pos
    ldv     $v6[0], VTX_FRAC_VEC($3)  // Vtx off screen, frac pos
    ldv     $v7[0], VTX_INT_VEC ($3)  // Vtx off screen, int pos
    vmudh   $v3, $v2, $v31[0]         // v3 = -clipRatio
    vmudn   $v8, $v4, $v2             // frac:   vtx on screen * clip ratio
    vmadh   $v9, $v5, $v2             // int:  + vtx on screen * clip ratio   9:8
    vmadn   $v10, $v6, $v3            // frac: - vtx off screen * clip ratio
    vmadh   $v11, $v7, $v3            // int:  - vtx off screen * clip ratio 11:10
    vaddc   $v8, $v8, $v8[0q]         // frac: y += x, w += z, vtx on screen only
    lqv     $v25[0], (linearGenerateCoefficients)($zero) // Used just to load the value 2
    vadd    $v9, $v9, $v9[0q]         // int:  y += x, w += z, vtx on screen only
    vaddc   $v10, $v10, $v10[0q]      // frac: y += x, w += z, vtx on screen - vtx off screen
    vadd    $v11, $v11, $v11[0q]      // int:  y += x, w += z, vtx on screen - vtx off screen
    vaddc   $v8, $v8, $v8[1h]         // frac: w += y (sum of all 4), vtx on screen only
    vadd    $v9, $v9, $v9[1h]         // int:  w += y (sum of all 4), vtx on screen only
    vaddc   $v10, $v10, $v10[1h]      // frac: w += y (sum of all 4), vtx on screen - vtx off screen
    vadd    $v11, $v11, $v11[1h]      // int:  w += y (sum of all 4), vtx on screen - vtx off screen
    // Not sure what the first reciprocal is for.
.if BUG_CLIPPING_FAIL_WHEN_SUM_ZERO   // Only in F3DEX2 2.04H
    vrcph   $v29[0], $v11[3]          // int:  1 / (x+y+z+w), vtx on screen - vtx off screen
.else
    vor     $v29, $v11, vOne[0]       // round up int sum to odd; this ensures the value is not 0, otherwise v29 will be 0 instead of +/- 2
    vrcph   $v3[3], $v11[3]
.endif
    vrcpl   $v2[3], $v10[3]           // frac: 1 / (x+y+z+w), vtx on screen - vtx off screen
    vrcph   $v3[3], vZero[0]          // get int result of reciprocal
.if BUG_CLIPPING_FAIL_WHEN_SUM_ZERO   // Only in F3DEX2 2.04H
    vabs    $v29, $v11, $v25[3] // 0x0002 // v29 = +/- 2 based on sum positive or negative (Bug: or 0 if sum is 0)
.else
    vabs    $v29, $v29, $v25[3] // 0x0002 // v29 = +/- 2 based on sum positive (incl. zero) or negative
.endif
    vmudn   $v2, $v2, $v29[3]         // multiply reciprocal by +/- 2
    vmadh   $v3, $v3, $v29[3]
    veq     $v3, $v3, vZero[0]        // if reciprocal high is 0
    vmrg    $v2, $v2, $v31[0]         // keep reciprocal low, otherwise set to -1
    vmudl   $v29, $v10, $v2[3]        // sum frac * reciprocal, discard
    vmadm   $v11, $v11, $v2[3]        // sum int * reciprocal, frac out
    vmadn   $v10, vZero, vZero[0]     // get int out
    vrcph   $v13[3], $v11[3]          // reciprocal again (discard result)
    vrcpl   $v12[3], $v10[3]          // frac part
    vrcph   $v13[3], vZero[0]         // int part
    vmudl   $v29, $v12, $v10          // self * own reciprocal? frac*frac discard
    vmadm   $v29, $v13, $v10          // self * own reciprocal? int*frac discard
    vmadn   $v10, $v12, $v11          // self * own reciprocal? frac out
    vmadh   $v11, $v13, $v11          // self * own reciprocal? int out
    vmudh   $v29, vOne, $v31[1]       // 4 (int part), Newton-Raphson algorithm
    vmadn   $v10, $v10, $v31[4]       // - 4 * prev result frac part
    vmadh   $v11, $v11, $v31[4]       // - 4 * prev result frac part
    vmudl   $v29, $v12, $v10          // * own reciprocal again? frac*frac discard
    vmadm   $v29, $v13, $v10          // * own reciprocal again? int*frac discard
    vmadn   $v12, $v12, $v11          // * own reciprocal again? frac out
    vmadh   $v13, $v13, $v11          // * own reciprocal again? int out
    vmudl   $v29, $v8, $v12
    luv     $v26[0], VTX_COLOR_VEC($3)  // Vtx off screen, RGBA
    vmadm   $v29, $v9, $v12
    llv     $v26[8], VTX_TC_VEC   ($3)  // Vtx off screen, ST
    vmadn   $v10, $v8, $v13
    luv     $v25[0], VTX_COLOR_VEC($19) // Vtx on screen, RGBA
    vmadh   $v11, $v9, $v13           // 11:10 = vtx on screen sum * prev calculated value
    llv     $v25[8], VTX_TC_VEC   ($19) // Vtx on screen, RGBA
    vmudl   $v29, $v10, $v2[3]
    vmadm   $v11, $v11, $v2[3]
    vmadn   $v10, $v10, vZero[0]      // * one of the reciprocals above
    // Clamp fade factor
    vlt     $v11, $v11, vOne[0]       // If integer part of factor less than 1,
    vmrg    $v10, $v10, $v31[0]       // keep frac part of factor, else set to 0xFFFF (max val)
    vsubc   $v29, $v10, vOne[0]       // frac part - 1 for carry
    vge     $v11, $v11, vZero[0]      // If integer part of factor >= 0 (after carry, so overall value >= 0x0000.0001),
    vmrg    $v10, $v10, vOne[0]       // keep frac part of factor, else set to 1 (min val)
    vmudn   $v2, $v10, $v31[0]        // signed x * -1 = 0xFFFF - unsigned x! v2[3] is fade factor for on screen vert
    // Fade between attributes for on screen and off screen vert
    vmudl   $v29, $v6, $v10[3]        //   Fade factor for off screen vert * off screen vert pos frac
    vmadm   $v29, $v7, $v10[3]        // + Fade factor for off screen vert * off screen vert pos int
    vmadl   $v29, $v4, $v2[3]         // + Fade factor for on  screen vert * on  screen vert pos frac
    vmadm   vPairMVPPosI, $v5, $v2[3] // + Fade factor for on  screen vert * on  screen vert pos int
    vmadn   vPairMVPPosF, vZero, vZero[0] // Load resulting frac pos
    vmudm   $v29, $v26, $v10[3]       //   Fade factor for off screen vert * off screen vert color and TC
    vmadm   vPairST, $v25, $v2[3]     // + Fade factor for on  screen vert * on  screen vert color and TC
    li      $7, 0x0000 // Set no fog
    li      $1, 0x0002 // Set vertex count to 1, so will only write one
    sh      outputVtxPos, (clipPoly)(clipPolyWrite) // Add the address of the new vert to the output polygon
    j       load_spfx_global_values // Goes to load_spfx_global_values, then to vertices_store, then
     li   $ra, vertices_store + 0x8000 // comes back here, via bltz $ra, clipping_after_vtxwrite

clipping_after_vtxwrite:
// outputVtxPos has been incremented by 2 * vtxSize
// Store last vertex attributes which were skipped by the early return
.if BUG_NO_CLAMP_SCREEN_Z_POSITIVE
    sdv     $v25[0],    (VTX_SCR_VEC    - 2 * vtxSize)(outputVtxPos)
.else
    slv     $v25[0],    (VTX_SCR_VEC    - 2 * vtxSize)(outputVtxPos)
.endif
    ssv     $v26[4],    (VTX_SCR_Z_FRAC - 2 * vtxSize)(outputVtxPos)
    suv     vPairST[0], (VTX_COLOR_VEC  - 2 * vtxSize)(outputVtxPos)
    slv     vPairST[8], (VTX_TC_VEC     - 2 * vtxSize)(outputVtxPos)
.if !BUG_NO_CLAMP_SCREEN_Z_POSITIVE          // Not in F3DEX2 2.04H
    ssv     $v3[4],     (VTX_SCR_Z      - 2 * vtxSize)(outputVtxPos)
.endif
    addi    outputVtxPos, outputVtxPos, -vtxSize // back by 1 vtx so we are actually 1 ahead of where started
    addi    clipPolyWrite, clipPolyWrite, 2  // Original outputVtxPos was already written here; increment write ptr
clipping_nextedge:
    bnez    clipFlags, clipping_edgelooptop  // Discard V2 if it was off screen (whether inserted vtx or not)
     move   $3, $2                           // Move what was the end of the edge to be the new start of the edge
    sh      $3, (clipPoly)(clipPolyWrite)    // Former V2 was on screen, so add it to the output polygon
    j       clipping_edgelooptop
     addi   clipPolyWrite, clipPolyWrite, 2

clipping_nextcond:
    sub     $11, clipPolyWrite, clipPolySelect // Are there less than 3 verts in the output polygon?
    bltz    $11, clipping_done                 // If so, degenerate result, quit
     sh     $zero, (clipPoly)(clipPolyWrite)   // Terminate the output polygon with a 0
    lhu     $3, (clipPoly - 2)(clipPolyWrite)  // Initialize the edge start (V3) to the last vert
    bnez    clipMaskIdx, clipping_condlooptop  // Done with clipping conditions?
     addi   clipMaskIdx, clipMaskIdx, -0x0004  // Point to next condition
    sw      $zero, activeClipPlanes            // Disable all clipping planes while drawing tris
clipping_draw_tris_loop:
    // Current polygon starts 6 (3 verts) below clipPolySelect, ends 2 (1 vert) below clipPolyWrite
.if CFG_CLIPPING_SUBDIVIDE_DESCENDING
    // Draws verts in pattern like 0-4-3, 0-3-2, 0-2-1. This also draws them with
    // the opposite winding as they were originally drawn with, possibly a bug?
    reg1 equ clipPolyWrite
    val1 equ -0x0002
.else
    // Draws verts in pattern like 0-1-4, 1-2-4, 2-3-4
    reg1 equ clipPolySelect
    val1 equ 0x0002
.endif
    // Load addresses of three verts to draw; each vert may be in normal vertex array or temp buffer
    lhu     $1, (clipPoly - 6)(clipPolySelect)
    lhu     $2, (clipPoly - 4)(reg1)
    lhu     $3, (clipPoly - 2)(clipPolyWrite)
    mtc2    $1, $v2[10]               // Addresses go in vector regs too
    vor     $v3, vZero, $v31[5]       // Not sure what this is, was in init code before tri_to_rdp_noinit
    mtc2    $2, $v4[12]
    jal     tri_to_rdp_noinit         // Draw tri
     mtc2   $3, $v2[14]
    bne     clipPolyWrite, clipPolySelect, clipping_draw_tris_loop
     addi   reg1, reg1, val1
clipping_done:
    jr      savedRA  // This will be G_TRI1_handler if was first tri of pair, else run_next_DL_command
     sw     savedActiveClipPlanes, activeClipPlanes

.align 8

// Leave room for loading overlay 2 if it is larger than overlay 3 (true for f3dzex)
.orga max(ovl2_end - ovl2_start + orga(ovl3_start), orga())
ovl3_end:

ovl23_end:

vPairRGBATemp equ $v7

G_VTX_handler:
    lhu     dmemAddr, (vertexTable)(cmd_w0) // Load the address of the provided vertex array
    jal     segmented_to_physical           // Convert the vertex array's segmented address (in cmd_w1_dram) to a virtual one
     lhu    $1, (inputBufferEnd - 0x07)(inputBufferPos) // Load the size of the vertex array to copy into reg $1
    sub     dmemAddr, dmemAddr, $1          // Calculate the address to DMA the provided vertices into
    jal     dma_read_write                  // DMA read the vertices from DRAM
     addi   dmaLen, $1, -1                  // Set up the DMA length
    lhu     $5, geometryModeLabel           // Load the geometry mode into $5
    srl     $1, $1, 3
    sub     outputVtxPos, cmd_w0, $1
    lhu     outputVtxPos, (vertexTable)(outputVtxPos)
    move    inputVtxPos, dmemAddr
    lbu     secondVtxPos, mvpValid          // used as temp reg
    andi    topLightPtr, $5, G_LIGHTING_H   // If no lighting, topLightPtr is 0, skips transforming light dirs and setting this up as a pointer
    bnez    topLightPtr, ovl23_lighting_entrypoint // Run overlay 2 for lighting, either directly or via overlay 3 loading overlay 2
     andi   $7, $5, G_FOG_H
after_light_dir_xfrm:
    bnez    secondVtxPos, vertex_skip_recalc_mvp  // Skip recalculating the mvp matrix if it's already up-to-date
     sll    $7, $7, 3                 // $7 is 8 if G_FOG is set, 0 otherwise
    sb      cmd_w0, mvpValid          // Set mvpValid
    li      input_mtx_0, pMatrix      // Arguments to mtx_multiply
    li      input_mtx_1, mvMatrix
    // Calculate the MVP matrix
    jal     mtx_multiply
     li     output_mtx, mvpMatrix

vertex_skip_recalc_mvp:
    /* Load MVP matrix as follows--note that translation is in the bottom row,
    not the right column.
    Elem   0   1   2   3   4   5   6   7      (Example data)
    I v8  00  02  04  06  00  02  04  06      Xscl Rot  Rot   0
    I v9  08  0A  0C  0E  08  0A  0C  0E      Rot  Yscl Rot   0
    I v10 10  12  14  16  10  12  14  16      Rot  Rot  Zscl  0
    I v11 18  1A  1C  1E  18  1A  1C  1E      Xpos Ypos Zpos  1
    F v12 20  22  24  26  20  22  24  26
    F v13 28  2A  2C  2E  28  2A  2C  2E
    F v14 30  32  34  36  30  32  34  36
    F v15 38  3A  3C  3E  38  3A  3C  3E
    Vector regs contain rows of original matrix (v11/v15 have translations)
    */
    lqv     mxr0i,    (mvpMatrix +  0)($zero)
    lqv     mxr2i,    (mvpMatrix + 16)($zero)
    lqv     mxr0f,    (mvpMatrix + 32)($zero)
    lqv     mxr2f,    (mvpMatrix + 48)($zero)
    vcopy   mxr1i, mxr0i
    ldv     mxr1i,    (mvpMatrix +  8)($zero)
    vcopy   mxr3i, mxr2i
    ldv     mxr3i,    (mvpMatrix + 24)($zero)
    vcopy   mxr1f, mxr0f
    ldv     mxr1f,    (mvpMatrix + 40)($zero)
    vcopy   mxr3f, mxr2f
    ldv     mxr3f,    (mvpMatrix + 56)($zero)
    ldv     mxr0i[8], (mvpMatrix +  0)($zero)
    ldv     mxr2i[8], (mvpMatrix + 16)($zero)
    jal     load_spfx_global_values
     ldv    mxr0f[8], (mvpMatrix + 32)($zero)
    jal     while_wait_dma_busy
     ldv    mxr2f[8], (mvpMatrix + 48)($zero)
    ldv     $v20[0], (VTX_IN_OB + inputVtxSize * 0)(inputVtxPos) // load the position of the 1st vertex into v20's lower 8 bytes
    vmov    vVpFgScale[5], vVpNegScale[1]          // Finish building vVpFgScale
    ldv     $v20[8], (VTX_IN_OB + inputVtxSize * 1)(inputVtxPos) // load the position of the 2nd vertex into v20's upper 8 bytes

vertices_process_pair:
    // Two verts pos in v20; multiply by MVP
    vmudn   $v29, mxr3f, vOne[0]
    lw      $11, (VTX_IN_CN + inputVtxSize * 1)(inputVtxPos) // load the color/normal of the 2nd vertex into $11
    vmadh   $v29, mxr3i, vOne[0]
    llv     vPairST[12], (VTX_IN_TC + inputVtxSize * 0)(inputVtxPos) // load the texture coords of the 1st vertex into second half of vPairST
    vmadn   $v29, mxr0f, $v20[0h]
    move    curLight, topLightPtr
    vmadh   $v29, mxr0i, $v20[0h]
    lpv     $v2[0], (ltBufOfs + 0x10)(curLight)    // First instruction of lights_dircoloraccum2 loop; load light transformed dir
    vmadn   $v29, mxr1f, $v20[1h]
    sw      $11, (VTX_IN_TC + inputVtxSize * 0)(inputVtxPos) // Move the second vertex's colors/normals into the word before the first vertex's
    vmadh   $v29, mxr1i, $v20[1h]
    lpv     vPairRGBATemp[0], (VTX_IN_TC + inputVtxSize * 0)(inputVtxPos) // Load both vertex's colors/normals into v7's elements RGBARGBA or XYZAXYZA
    vmadn   vPairMVPPosF, mxr2f, $v20[2h]          // vPairMVPPosF = MVP * vpos result frac
    bnez    topLightPtr, light_vtx                 // Zero if lighting disabled, pointer if enabled
     vmadh  vPairMVPPosI, mxr2i, $v20[2h]          // vPairMVPPosI = MVP * vpos result int
    // These two instructions are repeated at the end of all the lighting codepaths,
    // since they're skipped here if lighting is being performed
    // This is the original location of INSTR 1 and INSTR 2
    vge     $v27, $v25, $v31[3]                    // INSTR 1: Clamp W/fog to >= 0x7F00 (low byte is used)
    llv     vPairST[4], (VTX_IN_TC + inputVtxSize * 1)(inputVtxPos)  // INSTR 2: load the texture coords of the 2nd vertex into first half of vPairST

vertices_store:
    // "First" and "second" vertices mean first and second in the input list,
    // which is also first and second in the output list.
    // This is also in the first half and second half of vPairMVPPosI / vPairMVPPosF.
    // However, they are reversed in vPairST and the vector regs used for lighting.
.if !BUG_NO_CLAMP_SCREEN_Z_POSITIVE        // Bugfixed version
    vge     $v3, $v25, vZero[0]            // Clamp Z to >= 0
.endif
    addi    $1, $1, -4                     // Decrement vertex count by 2
    vmudl   $v29, vPairMVPPosF, vVpMisc[4] // Persp norm
    // First time through, secondVtxPos is temp memory in the current RDP output buffer,
    // so these writes don't harm anything. On subsequent loops, this is finishing the
    // store of the previous two vertices.
    sub     $11, secondVtxPos, $7          // Points 8 above secondVtxPos if fog, else 0
    vmadm   $v2, vPairMVPPosI, vVpMisc[4]  // Persp norm
    sbv     $v27[15],         (VTX_COLOR_A + 8 - 1 * vtxSize)($11) // In VTX_SCR_Y if fog disabled...
    vmadn   $v21, vZero, vZero[0]
    sbv     $v27[7],          (VTX_COLOR_A + 8 - 2 * vtxSize)($11) // ...which gets overwritten below
.if !BUG_NO_CLAMP_SCREEN_Z_POSITIVE        // Bugfixed version
    vmov    $v26[1], $v3[2]
    ssv     $v3[12],          (VTX_SCR_Z      - 1 * vtxSize)(secondVtxPos)
.endif
    vmudn   $v7, vPairMVPPosF, vVpMisc[5]  // Clip ratio
.if BUG_NO_CLAMP_SCREEN_Z_POSITIVE
    sdv     $v25[8],          (VTX_SCR_VEC    - 1 * vtxSize)(secondVtxPos)
.else
    slv     $v25[8],          (VTX_SCR_VEC    - 1 * vtxSize)(secondVtxPos)
.endif
    vmadh   $v6, vPairMVPPosI, vVpMisc[5]  // Clip ratio
    sdv     $v25[0],          (VTX_SCR_VEC    - 2 * vtxSize)(secondVtxPos)
    vrcph   $v29[0], $v2[3]
    ssv     $v26[12],         (VTX_SCR_Z_FRAC - 1 * vtxSize)(secondVtxPos)
    vrcpl   $v5[3], $v21[3]
.if BUG_NO_CLAMP_SCREEN_Z_POSITIVE
    ssv     $v26[4],          (VTX_SCR_Z_FRAC - 2 * vtxSize)(secondVtxPos)
.else
    slv     $v26[2],          (VTX_SCR_Z      - 2 * vtxSize)(secondVtxPos)
.endif
    vrcph   $v4[3], $v2[7]
    ldv     $v3[0], 8(inputVtxPos)  // Load RGBARGBA for two vectors (was stored this way above)
    vrcpl   $v5[7], $v21[7]
    sra     $11, $1, 31             // -1 if only first vert of two is valid, else 0
    vrcph   $v4[7], vZero[0]
    andi    $11, $11, vtxSize       // vtxSize if only first vert of two is valid, else 0
    vch     $v29, vPairMVPPosI, vPairMVPPosI[3h] // Compare XYZW to W, two verts, MSB
    addi    outputVtxPos, outputVtxPos, (2 * vtxSize) // Advance two positions forward in the output vertices
    vcl     $v29, vPairMVPPosF, vPairMVPPosF[3h] // Compare XYZW to W, two verts, LSB
    // If only the first vert of two is valid,
    // (VTX_ABC - 1 * vtxSize)(secondVtxPos) == (VTX_ABC - 2 * vtxSize)(outputVtxPos)
    // secondVtxPos always writes first, so then outputVtxPos overwrites it with the
    // first-and-only vertex's data.
    // If both are valid, secondVtxPos == outputVtxPos,
    // so outputVtxPos is the first vertex and secondVtxPos is the second.
    sub     secondVtxPos, outputVtxPos, $11
    vmudl   $v29, $v21, $v5
    cfc2    $10, $vcc                   // Load 16 bit screen space clip results, two verts
    vmadm   $v29, $v2, $v5
    sdv     vPairMVPPosF[8],  (VTX_FRAC_VEC   - 1 * vtxSize)(secondVtxPos)
    vmadn   $v21, $v21, $v4
    ldv     $v20[0], (VTX_IN_OB + 2 * inputVtxSize)(inputVtxPos) // Load pos of 1st vector on next iteration
    vmadh   $v2, $v2, $v4
    sdv     vPairMVPPosF[0],  (VTX_FRAC_VEC   - 2 * vtxSize)(outputVtxPos)
    vge     $v29, vPairMVPPosI, vZero[0] // Int position XYZW >= 0
    lsv     vPairMVPPosF[14], (VTX_Z_FRAC     - 1 * vtxSize)(secondVtxPos) // load Z into W slot, will be for fog below
    vmudh   $v29, vOne, $v31[1]
    sdv     vPairMVPPosI[8],  (VTX_INT_VEC    - 1 * vtxSize)(secondVtxPos)
    vmadn   $v26, $v21, $v31[4]
    lsv     vPairMVPPosF[6],  (VTX_Z_FRAC     - 2 * vtxSize)(outputVtxPos) // load Z into W slot, will be for fog below
    vmadh   $v25, $v2, $v31[4]
    sdv     vPairMVPPosI[0],  (VTX_INT_VEC    - 2 * vtxSize)(outputVtxPos)
    vmrg    $v2, vZero, $v31[7] // Set to 0 where positive, 0x7FFF where negative
    ldv     $v20[8], (VTX_IN_OB + 3 * inputVtxSize)(inputVtxPos) // Load pos of 2nd vector on next iteration
    vch     $v29, vPairMVPPosI, $v6[3h] // Compare XYZZ to clip-ratio-scaled W (int part)
    slv     $v3[0],           (VTX_COLOR_VEC  - 1 * vtxSize)(secondVtxPos) // Store RGBA for first vector
    vmudl   $v29, $v26, $v5
    lsv     vPairMVPPosI[14], (VTX_Z_INT      - 1 * vtxSize)(secondVtxPos) // load Z into W slot, will be for fog below
    vmadm   $v29, $v25, $v5
    slv     $v3[4],           (VTX_COLOR_VEC  - 2 * vtxSize)(outputVtxPos) // Store RGBA for second vector
    vmadn   $v5, $v26, $v4
    lsv     vPairMVPPosI[6],  (VTX_Z_INT      - 2 * vtxSize)(outputVtxPos) // load Z into W slot, will be for fog below
    vmadh   $v4, $v25, $v4
    sh      $10,              (VTX_CLIP_SCRN  - 1 * vtxSize)(secondVtxPos) // XYZW/W second vtx results in bits 0xF0F0
    vmadh   $v2, $v2, $v31[7]           // Makes screen coords a large number if W < 0
    sll     $11, $10, 4                 // Shift first vtx screen space clip into positions 0xF0F0
    vcl     $v29, vPairMVPPosF, $v7[3h] // Compare XYZZ to clip-ratio-scaled W (frac part)
    cfc2    $10, $vcc                   // Load 16 bit clip-ratio-scaled results, two verts
    vmudl   $v29, vPairMVPPosF, $v5[3h] // Pos times inv W
    ssv     $v5[14],          (VTX_INV_W_FRAC - 1 * vtxSize)(secondVtxPos)
    vmadm   $v29, vPairMVPPosI, $v5[3h] // Pos times inv W
    addi    inputVtxPos, inputVtxPos, (2 * inputVtxSize) // Advance two positions forward in the input vertices
    vmadn   $v26, vPairMVPPosF, $v2[3h] // Makes screen coords a large number if W < 0
    sh      $10,              (VTX_CLIP_SCAL  - 1 * vtxSize)(secondVtxPos) // Clip scaled second vtx results in bits 0xF0F0
    vmadh   $v25, vPairMVPPosI, $v2[3h] // v25:v26 = pos times inv W
    sll     $10, $10, 4                 // Shift first vtx scaled clip into positions 0xF0F0
    vmudm   $v3, vPairST, vVpMisc       // Scale ST for two verts, using TexSScl and TexTScl in elems 2, 3, 6, 7
    sh      $11,              (VTX_CLIP_SCRN  - 2 * vtxSize)(outputVtxPos) // Clip screen first vtx results
    sh      $10,              (VTX_CLIP_SCAL  - 2 * vtxSize)(outputVtxPos) // Clip scaled first vtx results
    vmudl   $v29, $v26, vVpMisc[4]      // Scale result by persp norm
    ssv     $v5[6],           (VTX_INV_W_FRAC - 2 * vtxSize)(outputVtxPos)
    vmadm   $v25, $v25, vVpMisc[4]      // Scale result by persp norm
    ssv     $v4[14],          (VTX_INV_W_INT  - 1 * vtxSize)(secondVtxPos)
    vmadn   $v26, vZero, vZero[0]       // Now v26:v25 = projected position
    ssv     $v4[6],           (VTX_INV_W_INT  - 2 * vtxSize)(outputVtxPos)
    slv     $v3[4],           (VTX_TC_VEC     - 1 * vtxSize)(secondVtxPos) // Store scaled S, T vertex 1
    vmudh   $v29, vVpFgOffset, vOne[0]  //   1 * vtrans (and fog offset in elems 3,7)
    slv     $v3[12],          (VTX_TC_VEC     - 2 * vtxSize)(outputVtxPos) // Store scaled S, T vertex 2
    vmadh   $v29, vFogMask, $v31[3]     // + 0x7F00 in fog elements (because auto-clamp to 0x7FFF, and will clamp to 0x7F00 below)
    vmadn   $v26, $v26, vVpFgScale      // + pos frac * scale
    bgtz    $1, vertices_process_pair
     vmadh  $v25, $v25, vVpFgScale      // int part, v25:v26 is now screen space pos
    bltz    $ra, clipping_after_vtxwrite // Return to clipping if from clipping
.if !BUG_NO_CLAMP_SCREEN_Z_POSITIVE     // Bugfixed version
     vge    $v3, $v25, vZero[0]         // Clamp Z to >= 0
    slv     $v25[8],          (VTX_SCR_VEC    - 1 * vtxSize)(secondVtxPos)
    vge     $v27, $v25, $v31[3] // INSTR 1: Clamp W/fog to >= 0x7F00 (low byte is used)
    slv     $v25[0],          (VTX_SCR_VEC    - 2 * vtxSize)(outputVtxPos)
    ssv     $v26[12],         (VTX_SCR_Z_FRAC - 1 * vtxSize)(secondVtxPos)
    ssv     $v26[4],          (VTX_SCR_Z_FRAC - 2 * vtxSize)(outputVtxPos)
    ssv     $v3[12],          (VTX_SCR_Z      - 1 * vtxSize)(secondVtxPos)
    beqz    $7, run_next_DL_command
     ssv    $v3[4],           (VTX_SCR_Z      - 2 * vtxSize)(outputVtxPos)
.else // This is the F3DEX2 2.04H version
     vge    $v27, $v25, $v31[3] // INSTR 1: Clamp W/fog to >= 0x7F00 (low byte is used)
    sdv     $v25[8],          (VTX_SCR_VEC    - 1 * vtxSize)(secondVtxPos)
    sdv     $v25[0],          (VTX_SCR_VEC    - 2 * vtxSize)(outputVtxPos)
    // Int part of Z stored in VTX_SCR_Z by sdv above
    ssv     $v26[12],         (VTX_SCR_Z_FRAC - 1 * vtxSize)(secondVtxPos)
    beqz    $7, run_next_DL_command
     ssv    $v26[4],          (VTX_SCR_Z_FRAC - 2 * vtxSize)(outputVtxPos)
.endif
    sbv     $v27[15],         (VTX_COLOR_A    - 1 * vtxSize)(secondVtxPos)
    j       run_next_DL_command
     sbv    $v27[7],          (VTX_COLOR_A    - 2 * vtxSize)(outputVtxPos)

load_spfx_global_values:
    /*
    vscale = viewport shorts 0:3, vtrans = viewport shorts 4:7, VpFg = Viewport Fog
    v16 = vVpFgScale = [vscale[0], -vscale[1], vscale[2], fogMult, (repeat)]
                       (element 5 written just before vertices_process_pair)
    v17 = vVpFgOffset = [vtrans[0], vtrans[1], vtrans[2], fogOffset, (repeat)]
    v18 = vVpMisc = [???, ???, TexSScl, TexTScl, perspNorm, clipRatio, TexSScl, TexTScl]
    v19 = vFogMask = [0x0000, 0x0000, 0x0000, 0x0001, 0x0000, 0x0000, 0x0000, 0x0001]
    v21 = vVpNegScale = -[vscale[0:3], vscale[0:3]]
    */
    li      spFxBaseReg, spFxBase
    ldv     vVpFgScale[0], (viewport)($zero)      // Load vscale duplicated in 0-3 and 4-7
    ldv     vVpFgScale[8], (viewport)($zero)
    llv     $v29[0], (fogFactor - spFxBase)(spFxBaseReg) // Load fog multiplier and offset
    ldv     vVpFgOffset[0], (viewport + 8)($zero) // Load vtrans duplicated in 0-3 and 4-7
    ldv     vVpFgOffset[8], (viewport + 8)($zero)
    vlt     vFogMask, $v31, $v31[3]               // VCC = 11101110
    vsub    vVpNegScale, vZero, vVpFgScale        // -vscale
    llv     vVpMisc[4], (textureSettings2 - spFxBase)(spFxBaseReg) // Texture ST scale
    vmrg    vVpFgScale, vVpFgScale, $v29[0]       // Put fog multiplier in elements 3,7 of vscale
    llv     vVpMisc[12], (textureSettings2 - spFxBase)(spFxBaseReg) // Texture ST scale
    vmrg    vFogMask, vZero, vOne[0]              // Put 0 in most elems, 1 in elems 3,7
    llv     vVpMisc[8], (perspNorm)($zero)        // Perspective normalization long (actually short)
    vmrg    vVpFgOffset, vVpFgOffset, $v29[1]     // Put fog offset in elements 3,7 of vtrans
    lsv     vVpMisc[10], (clipRatio + 6 - spFxBase)(spFxBaseReg) // Clip ratio (-x version, but normally +/- same in all dirs)
    vmov    vVpFgScale[1], vVpNegScale[1]         // Negate vscale[1] because RDP top = y=0
    jr      $ra
     addi   secondVtxPos, rdpCmdBufPtr, 0x50      // Pointer to currently unused memory in command buffer

G_TRI2_handler:
G_QUAD_handler:
    jal     tri_to_rdp                   // Send second tri; return here for first tri
     sw     cmd_w1_dram, 4(rdpCmdBufPtr) // Put second tri indices in temp memory
G_TRI1_handler:
    li      $ra, run_next_DL_command     // After done with this tri, run next cmd
    sw      cmd_w0, 4(rdpCmdBufPtr)      // Put first tri indices in temp memory
tri_to_rdp:

vtx_idxs equ $v2
_0x4000 equ $v31[5]
v0x4000 equ $v3

    lpv     vtx_idxs[0], 0(rdpCmdBufPtr)      // Load tri indexes to vector unit for shuffling
    // read the three vertex indices from the stored command word
    lbu     $1, 0x0005(rdpCmdBufPtr)     // $1 = vertex 1 index
    lbu     $2, 0x0006(rdpCmdBufPtr)     // $2 = vertex 2 index
    // $3 = vertex 3 index
    lbu     $3, 0x0007(rdpCmdBufPtr)        ::  vor     v0x4000, vZero, _0x4000 // $v3 = [0x4000, ...]

v1_addr equ $1
v2_addr equ $2
v3_addr equ $3

orig_v1_addr equ $4

vtx_addrs equ $v2

vtx_p1 equ $v6
vtx_p2 equ $v4
vtx_p3 equ $v8

    // scalar path: convert each vertex's index to its address
    lhu     v1_addr, (vertexTable)($1)      ::  vmudn   $v4, vOne, $v31[6]              // Move address of vertex buffer to accumulator mid
    lhu     v2_addr, (vertexTable)($2)      ::  vmadl   vtx_addrs, vtx_idxs, $v30[1]    // Multiply vtx indices times length and add addr
    lhu     v3_addr, (vertexTable)($3)      ::  vmadn   vtx_p2, vZero, vZero[0]         // Load accumulator again (addresses) to v4; need vertex 2 addr in elem 6
    // Save original vertex 1 addr (pre-shuffle) for flat shading
    move    orig_v1_addr, v1_addr
tri_to_rdp_noinit: // $ra is next cmd, second tri in TRI2, or middle of clipping

vtx_attrs_1_i equ $v18  // (integer)  [r1, g1, b1, a1, s1, t1, w1, z1]
vtx_attrs_1_f equ $v5   // (fraction) [r1, g1, b1, a1, s1, t1, w1, z1]
vtx_attrs_2_i equ $v19
vtx_attrs_2_f equ $v7
vtx_attrs_3_i equ $v21
vtx_attrs_3_f equ $v9

vtx_diff_13 equ $v12
vtx_diff_12 equ $v10
vtx_diff_21 equ $v11

v1_clip equ $5
v2_clip equ $6
v3_clip equ $7

_0x8000 equ $v31[7]

    /* unaligned branch target */                   vnxor   vtx_attrs_1_f, vZero, _0x8000   // vtx_attrs_1_f = [0x8000, ...]
    // Load pixel coords of vertex 1 into vtx_p1 (elems 0, 1 = x, y)
    llv     vtx_p1[0], VTX_SCR_VEC(v1_addr)     ::  vnxor   vtx_attrs_2_f, vZero, _0x8000   // vtx_attrs_2_f = [0x8000, ...]
    // Load pixel coords of vertex 2 into v4
    llv     vtx_p2[0], VTX_SCR_VEC(v2_addr)     ::  vmov    vtx_p1[6], vtx_addrs[5]         // elem 6 of vtx_p1 = vertex 1 addr
    // Load pixel coords of vertex 3 into v8
    llv     vtx_p3[0], VTX_SCR_VEC(v3_addr)     ::  vnxor   vtx_attrs_3_f, vZero, _0x8000   // vtx_attrs_3_f = [0x8000, ...]
    lw      v1_clip, VTX_CLIP(v1_addr)          ::  vmov    vtx_p3[6], vtx_addrs[7]         // elem 6 of vtx_p3 = vertex 3 addr
    lw      v2_clip, VTX_CLIP(v2_addr)          ::  vadd    $v2, vZero, vtx_p1[1]           // v2 = [v1.y, ...]
    lw      v3_clip, VTX_CLIP(v3_addr)          ::  vsub    vtx_diff_12, vtx_p1, vtx_p2     // v10 = vertex 1 - vertex 2 (x, y, addr)
    andi    $11, v1_clip, CLIP_ALL_SCRN         ::  vsub    vtx_diff_21, vtx_p2, vtx_p1     // v11 = vertex 2 - vertex 1 (x, y, addr)
    and     $11, v2_clip, $11                   ::  vsub    vtx_diff_13, vtx_p1, vtx_p3     // vtx_diff_13 = vertex 1 - vertex 3 (x, y, addr)
    // If there is any screen clipping plane where all three verts are past it... {cont.}
    and     $11, v3_clip, $11                   ::  vlt     $v13, $v2, vtx_p2[1]            // v13 = min(v1.y, v2.y), VCO = v1.y < v2.y

    // v14 = v1.y < v2.y ? v1 : v2 (lower vertex of v1, v2)
    vmrg    $v14, vtx_p1, vtx_p2                ::  bnez    $11, return_routine // {cont.} ...whole tri is offscreen, cull.
     lbu    $11, geometryModeLabel + 2  // Loads the geometry mode byte that contains face culling settings

CrossProduct equ $v29

Pos_H equ $v14  // v1 post-sort
Pos_M equ $v2   // v2 post-sort
Pos_L equ $v10  // v3 post-sort

    vmudh   CrossProduct, vtx_diff_12, vtx_diff_13[1]   ::  lw      $12, activeClipPlanes
    // CrossProduct[0] = (v1 - v2).x * (v1 - v3).y + (v1 - v3).x * (v2 - v1).y (triangle orientation)
    vmadh   CrossProduct, vtx_diff_13, vtx_diff_21[1]   ::  or      $5, v1_clip, v2_clip
    // v2 = max(vert1.y, vert2.y), VCO = vert1.y > vert2.y
    vge     $v2, $v2, vtx_p2[1]                         ::  or      $5, $5, v3_clip     // If any verts are past any clipping plane... {cont.}
    // v10 = vert1.y > vert2.y ? vert1 : vert2 (higher vertex of vert1, vert2)
    vmrg    $v10, vtx_p1, vtx_p2                        ::  lw      $11, (gCullMagicNumbers)($11)
    // v6 = max(max(vert1.y, vert2.y), vert3.y), VCO = max(vert1.y, vert2.y) > vert3.y
    vge     $v6, $v13, vtx_p3[1]                        ::  mfc2    $6, CrossProduct[0] // elem 0 = x = cross product => lower 16 bits, sign extended
    // v4 = max(vert1.y, vert2.y) > vert3.y : higher(vert1, vert2) ? vert3 (highest vertex of vert1, vert2, vert3)
    vmrg    $v4, $v14, vtx_p3                           ::  and     $5, $5, $12         // {cont.} ...which is in the set of currently enabled clipping planes (scaled for XY, screen for ZW)... {cont.}
    // v14 = max(vert1.y, vert2.y) > vert3.y : vert3 ? higher(vert1, vert2)
    vmrg    Pos_H, vtx_p3, $v14                         ::  bnez    $5, ovl23_clipping_entrypoint // {cont.} ...then run overlay 3 for clipping, either directly or via overlay 2 loading overlay 3.
     add     $11, $6, $11     // Add magic number; see description at gCullMagicNumbers

    // v6 (thrown out), VCO = max(vert1.y, vert2.y, vert3.y) < max(vert1.y, vert2.y)
    vlt     $v6, $v6, $v2                               ::  bgez    $11, return_routine // If sign bit is clear, cull.
     vmrg    Pos_M, $v4, Pos_L    // v2 = max(vert1.y, vert2.y, vert3.y) < max(vert1.y, vert2.y) : highest(vert1, vert2, vert3) ? highest(vert1, vert2)

Diff_LH equ $v8
Diff_HM equ $v11
Diff_HL equ $v12
Diff_LM equ $v15
Diff_MH equ $v6

inv_w_all equ $v13

y_spx_i equ $v26
y_spx_f equ $v4

    // v10 = max(vert1.y, vert2.y, vert3.y) < max(vert1.y, vert2.y) : highest(vert1, vert2) ? highest(vert1, vert2, vert3)
    vmrg    Pos_L, $v10, $v4            ::  mfc2    v1_addr, Pos_H[12]
    // y_spx_f = Pos_H * (1 << (16 - 2))    (convert 10.2 to 15.16 where the fraction occupies top 2 bits)
    // y_spx_f = [X * 0x4000, Y * 0x4000, Z * 0x4000, ...]
    vmudn   y_spx_f, Pos_H, _0x4000     ::  beqz    $6, return_routine // If cross product is 0, tri is degenerate (zero area), cull.
     vsub    Diff_MH, Pos_M, Pos_H

CrossProduct2_f equ $v16
CrossProduct2_i equ $v17

    // scalar path: reclaim (now sorted) addresses for v2 and v3, v1 reclaimed above. Load inverse w from vertices
    // vector path: compute differences along each edge
    // e.g. Diff_LH = [ L.x - H.x, L.y, - H.y, L.z - H.z, ... ]
    mfc2    v2_addr, Pos_M[12]                      ::  vsub    Diff_LH, Pos_L, Pos_H
    mfc2    v3_addr, Pos_L[12]                      ::  vsub    Diff_HM, Pos_H, Pos_M
    lw      $6, geometryModeLabel                   ::  vsub    Diff_HL, Pos_H, Pos_L
    llv     inv_w_all[0], VTX_INV_W_VEC(v1_addr)    ::  vsub    Diff_LM, Pos_L, Pos_M
    llv     inv_w_all[8], VTX_INV_W_VEC(v2_addr)    ::  vmudh   CrossProduct2_f, Diff_MH, Diff_LH[0]
    llv     inv_w_all[12], VTX_INV_W_VEC(v3_addr)   ::  vmadh   CrossProduct2_f, Diff_LH, Diff_HM[0]   // cross product: $ACC = Diff_MH * Diff_LH.x + Diff_LH * Diff_HM.x
    // inv_w_all = [W1i, W1f, -, -, W2i, W2f, W3i, W3f]
    // Moves the value of G_SHADING_SMOOTH into the sign bit
    sll     $11, $6, 10                             ::  vreadacc CrossProduct2_i, ACC_UPPER
    bgez    $11, flat_shading  // Branch to flat shading if G_SHADING_SMOOTH isn't set
     vreadacc CrossProduct2_f, ACC_MIDDLE

dX equ $v15
inv_CrossProduct2_i equ $v24
inv_CrossProduct2_f equ $v23

inv_Diff_LM_f equ $v20
inv_Diff_LM_i equ $v22

     // Load vert color of vertex 1
    lpv     vtx_attrs_1_i[0], VTX_COLOR_VEC(v1_addr)    ::  vmov    dX[2], Diff_MH[0]
    // Load vert color of vertex 2
    lpv     vtx_attrs_2_i[0], VTX_COLOR_VEC(v2_addr)    ::  vrcp    inv_Diff_LM_f[0], Diff_LM[1] // (L - M).y
    // Load vert color of vertex 3
    lpv     vtx_attrs_3_i[0], VTX_COLOR_VEC(v3_addr)    ::  vrcph   inv_Diff_LM_i[0], CrossProduct2_i[1]
                                                            vrcpl   inv_CrossProduct2_f[1], CrossProduct2_f[1]
    j       shading_done
                                                            vrcph   inv_CrossProduct2_i[1], vZero[0]
flat_shading:
    // scalar path: load vertex rgb from (pre-shuffled) first vertex, keep alpha per-vertex
    // vector path: compute various reciprocals
    /* unaligned branch target */                           lpv     vtx_attrs_1_i[0], VTX_COLOR_VEC(orig_v1_addr)
    vrcp    inv_Diff_LM_f[0], Diff_LM[1]                ::  lbv     vtx_attrs_1_i[6], VTX_COLOR_A(v1_addr)
    vrcph   inv_Diff_LM_i[0], CrossProduct2_i[1]        ::  lpv     vtx_attrs_2_i[0], VTX_COLOR_VEC(orig_v1_addr)
    vrcpl   inv_CrossProduct2_f[1], CrossProduct2_f[1]  ::  lbv     vtx_attrs_2_i[6], VTX_COLOR_A(v2_addr)
    vrcph   inv_CrossProduct2_i[1], vZero[0]            ::  lpv     vtx_attrs_3_i[0], VTX_COLOR_VEC(orig_v1_addr)
    vmov    dX[2], Diff_MH[0]                           ::  lbv     vtx_attrs_3_i[6], VTX_COLOR_A(v3_addr)
shading_done:
    // these only changed position
.if CFG_OLD_TRI_WRITE
    LSHIFT_5 equ $v30[6] // 1 << 5
    _16 equ $v30[5] // 16
    _0x100 equ $v30[7] // 0x100 ,   also used at the end of continue_light_dir_xfrm
.else
    LSHIFT_5 equ $v30[7] // 1 << 5
    _16 equ $v30[6] // 16
    _0x100 equ $v30[3] // 0x100 ,   also used at the end of continue_light_dir_xfrm
.endif

    // dx and dy scales adjusted between versions, likely for increasing fractional precision
.if CFG_OLD_TRI_WRITE
    dx_scale equ $v31[5] // 0x4000
    dy_scale equ $v31[2] // 8
.else
    dx_scale equ $v30[2] // 0x1000
    dy_scale equ $v30[7] // 32
.endif

    // vcr VT input changed, not sure what this is for
.if CFG_OLD_TRI_WRITE
    VCR_VT equ $v30[2] // 0x1CC
.else
    VCR_VT equ $v30[3] // 0x100
.endif

    // this is only used when !CFG_OLD_TRI_WRITE however it cannot be defined there due to an armips bug
    _0xFFF8 equ $v30[5]

// destination for intermediate quantities produced by MAC sequences that are not used
v___ equ $v29

inv_w1 equ $5
inv_w2 equ $7
inv_w3 equ $8

inv_dy_i equ $v22
inv_dy_f equ $v20

    // compute 1 / dY
    vrcp    inv_dy_f[2], Diff_MH[1]
    vrcph   inv_dy_i[2], Diff_MH[1]  ::  lw      inv_w1, VTX_INV_W_VEC(v1_addr)
    vrcp    inv_dy_f[3], Diff_LH[1]  ::  lw      inv_w2, VTX_INV_W_VEC(v2_addr)
    vrcph   inv_dy_i[3], Diff_LH[1]  ::  lw      inv_w3, VTX_INV_W_VEC(v3_addr)
    // inv_dy = [-, -, 1 / (M.y - H.y), 1 / (L.y  - H.y), -, -, -, -]

dX_scaled_f equ $v25
dX_scaled_i equ $v15

inv_dy_scaled_i equ $v20
inv_dy_scaled_f equ $v22

    // scalar path: computes max(inv_w1, inv_w2, inv_w3)
    // vertex color 1 >>= 8
    vmudl   vtx_attrs_1_i, vtx_attrs_1_i, _0x100    ::  lbu     $9, textureSettings1 + 3
    // vertex color 2 >>= 8
    vmudl   vtx_attrs_2_i, vtx_attrs_2_i, _0x100    ::  sub     $11, inv_w1, inv_w2     // $11 = inv_w1 - inv_w2
    // vertex color 3 >>= 8
    vmudl   vtx_attrs_3_i, vtx_attrs_3_i, _0x100    ::  sra     $12, $11, 31            // $12 = signbit($11) * 0xFFFFFFFF
    vmov    dX[3], Diff_LH[0]                       ::  and     $11, $11, $12           // $11 = $11 & $12
    // dX = [-, -, (M - H).x, (L - H).x, -, -, -, -]
    vmudl   v___, inv_dy_f, dy_scale                ::  sub     $5, inv_w1, $11         // $5 = inv_w1 - $11
    vmadm   inv_dy_scaled_f, inv_dy_i, dy_scale     ::  sub     $11, $5, inv_w3         // $11 = $5 - inv_w3
    vmadn   inv_dy_scaled_i, vZero, vZero[0]        ::  sra     $12, $11, 31            // $12 = signbit($11) * 0xFFFFFFFF
    vmudm   dX_scaled_f, dX, dx_scale               ::  and     $11, $11, $12           // $11 = $11 & $12
    vmadn   dX_scaled_i, vZero, vZero[0]            ::  sub     $5, $5, $11             // $5 -= $11
    // dX_scaled = dX * dx_scale
    // inv_dy_scaled = (1 / dY) * dy_scale

max_inv_w equ $v27
    // (vsubc, vsub) double-precision subtraction pattern (negate)
    // Since y_spx_f contains fractional parts only at this point, negating it is the same as doing `floor(x) - x`
    // on the full-precision numbers
    vsubc   y_spx_f, vZero, y_spx_f                 ::  sw      $5, 0x10(rdpCmdBufPtr)  // $5 = maximum inv_w value
    vsub    y_spx_i, vZero, vZero                   ::  llv     max_inv_w[0], 0x10(rdpCmdBufPtr) // reload into vector register

    // calculate dXdY
dXdY_i equ $v15 // (integer)  [dxldy, -, dxmdy, dxhdy, -, -, -, -]
dXdY_f equ $v20 // (fraction) [dxldy, -, dxmdy, dxhdy, -, -, -, -]
dXhdY_i equ dXdY_i[3]
dXhdY_f equ dXdY_f[3]

    // dXdY = dX * (1 / dY)
    vmudm   v___, dX_scaled_f, inv_dy_scaled_i      ::  mfc2    $5, CrossProduct2_i[1]
    vmadl   v___, dX_scaled_i, inv_dy_scaled_i      ::  lbu     $7, textureSettings1 + 2
    vmadn   dXdY_f, dX_scaled_i, inv_dy_scaled_f    ::  lsv     vtx_attrs_2_i[14], VTX_SCR_Z(v2_addr)
    vmadh   dXdY_i, dX_scaled_f, inv_dy_scaled_f    ::  lsv     vtx_attrs_3_i[14], VTX_SCR_Z(v3_addr)

NR_temp_f equ $v16
NR_temp_i equ $v17

    // Newton-Raphson refinement
    // NR_temp = (1 / CrossProduct2) * CrossProduct2
    vmudl   v___, inv_CrossProduct2_f, CrossProduct2_f      ::  lsv     vtx_attrs_2_f[14], VTX_SCR_Z_FRAC(v2_addr)
    vmadm   v___, inv_CrossProduct2_i, CrossProduct2_f      ::  lsv     vtx_attrs_3_f[14], VTX_SCR_Z_FRAC(v3_addr)
    vmadn   NR_temp_f, inv_CrossProduct2_f, CrossProduct2_i ::  ori     $11, $6, G_TRI_FILL // Combine geometry mode (only the low byte will matter) with the base triangle type to make the triangle command id
    vmadh   NR_temp_i, inv_CrossProduct2_i, CrossProduct2_i ::  or      $11, $11, $9 // Incorporate whether textures are enabled into the triangle command id

.if !CFG_OLD_TRI_WRITE
    dXdY_f_2 equ $v22
    // drops lowest 3 bits of dxdy fraction
    vand    $v22, dXdY_f, _0xFFF8
.else
    // leaves dxdy fraction as-is
    dXdY_f_2 equ dXdY_f
.endif

    // VCR_VT = (0x0100 or 0x01CC)
    vcr     dXdY_i, dXdY_i, VCR_VT      ::  sb      $11, 0x0000(rdpCmdBufPtr) // Store the triangle command id

_m16 equ $v30[4] // -16

    // Newton-Raphson
    // NR_temp = 16 - 16 * NR_temp = 16 - 16 * (inv_CrossProduct2 * CrossProduct2)
    vmudh   v___, vOne, _16                 ::  ssv     Pos_L[2], 0x0002(rdpCmdBufPtr) // Store YL edge coefficient
    vmadn   NR_temp_f, NR_temp_f, _m16      ::  ssv     Pos_M[2], 0x0004(rdpCmdBufPtr) // Store YM edge coefficient
    vmadh   NR_temp_i, NR_temp_i, _m16      ::  ssv     Pos_H[2], 0x0006(rdpCmdBufPtr) // Store YH edge coefficient

PosXHM_i equ $v3
PosXHM_f equ $v2

    // v0x4000 = [0x4000, ...]  (for converting 10.2 Pos_H to 15.16)
    // computes `Pos_H.x + y_spx * dXdY` at double-precision (15.16 inputs, 15.16 output)
    vmudn   v___, v0x4000, Pos_H[0]         ::  andi    $12, $5, 0x0080         // Extract the left major flag from $5
    vmadl   v___, dXdY_f_2, y_spx_f[1]      ::  or      $12, $12, $7            // Combine the left major flag with the level and tile from the texture settings
    vmadm   v___, dXdY_i, y_spx_f[1]        ::  sb      $12, 0x0001(rdpCmdBufPtr) // Store the left major flag, level, and tile settings
    vmadn   PosXHM_f, dXdY_f_2, y_spx_i[1]  ::  beqz    $9, skipped_textures    // If textures are not enabled, skip texture coefficient calculation
     vmadh  PosXHM_i, dXdY_i, y_spx_i[1]

inv_w_all_frac equ $v14

inv_max_inv_w_i equ $v27
inv_max_inv_w_f equ $v10

    vrcph   v___[0], max_inv_w[0]                   // maximum inverse w (int)
    vrcpl   inv_max_inv_w_f[0], max_inv_w[1]        // maximum inverse w (frac)
    vadd    inv_w_all_frac, vZero, inv_w_all[1q]    // inv_w_all_frac = [W1f, W1f, -, -, W2f, W2f, W3f, W3f]
    vrcph   inv_max_inv_w_i[0], vZero[0]

STW_i_12 equ $v22
STW_f_12 equ $v25

inv_w_normalized_f equ $v14
inv_w_normalized_i equ $v13

_0x7FFF equ $v31[7]

    vor     STW_i_12, vZero, _0x7FFF    // fill STW_i_12 with 0x7FFF
    vmudm   v___, inv_w_all, inv_max_inv_w_f[0]
    vmadl   v___, inv_w_all_frac, inv_max_inv_w_f[0]                ::  llv     STW_i_12[0], VTX_TC_VEC(v1_addr)
    vmadn   inv_w_normalized_f, inv_w_all_frac, inv_max_inv_w_i[0]  ::  llv     STW_i_12[8], VTX_TC_VEC(v2_addr)
    vmadh   inv_w_normalized_i, inv_w_all, inv_max_inv_w_i[0]
                                                                    // STW_i_12 = [S1, T1, 0x7FFF, 0x7FFF, S2, T2, 0x7FFF, 0x7FFF]
    // inv_w_normalized = [W1i, W1f, -, -, W2f, W2f, W3f, W3f] / max_inv_W

STW_i_3 equ $v10
STW_f_3 equ $v13

    vor     STW_i_3, vZero, _0x7FFF // fill STW_i_3 with 0x7FFF
    // vge sets $vcc to 11110001 for merging later, assumes the contents of $v30 give this result
    vge     v___, $v30, $v30[7]                     ::  llv     STW_i_3[8], VTX_TC_VEC(v3_addr)
                                                    // STW_i_3 = [0x7FFF, 0x7FFF, 0x7FFF, 0x7FFF, S3, T3, 0x7FFF, 0x7FFF]

    vmudm   v___, STW_i_12, inv_w_normalized_f[0h]
    vmadh   STW_i_12, STW_i_12, inv_w_normalized_i[0h]  // multiply in W1i and W2i
    vmadn   STW_f_12, vZero, vZero[0]                   // STW_f_12 = lo(clamp(acc)), extract result of MAC sequence

    vmudm   v___, STW_i_3, inv_w_normalized_f[6]
    vmadh   STW_i_3, STW_i_3, inv_w_normalized_i[6]
                                                    // shuffle first 4 16-bit elements from STW_i_12/STW_f_12 to last 4 16-bit elements in vtx_attrs_1_i/A0_f
    vmadn   STW_f_3, vZero, vZero[0]                ::  sdv     STW_i_12[0], 0x0020(rdpCmdBufPtr)
    // merge S,T,W into elements 4,5,6
    vmrg    vtx_attrs_2_i, vtx_attrs_2_i, STW_i_12  ::  sdv     STW_f_12[0], 0x0028(rdpCmdBufPtr)
    vmrg    vtx_attrs_2_f, vtx_attrs_2_f, STW_f_12  ::  ldv     vtx_attrs_1_i[8], 0x0020(rdpCmdBufPtr)
    vmrg    vtx_attrs_3_i, vtx_attrs_3_i, STW_i_3   ::  ldv     vtx_attrs_1_f[8], 0x0028(rdpCmdBufPtr)
    vmrg    vtx_attrs_3_f, vtx_attrs_3_f, STW_f_3
skipped_textures:
    // note this branch target is not 8-byte aligned in some versions so the dual-issue of instructions may be offset by one instruction, that is in
    // some versions the first vmudl does not dual issue with anything, while the lsv and vmadm would dual-issue and so on

TriShadePtr equ $2

inv_dX_i equ $v24
inv_dX_f equ $v23

    // Newton-Raphson
    // inv_dX = inv_CrossProduct2 * NR_temp - inv_CrossProduct2 * (16 - 16 * (inv_CrossProduct2 * CrossProduct2))
    vmudl   v___, NR_temp_f, inv_CrossProduct2_f        ::  lsv     vtx_attrs_1_f[14], VTX_SCR_Z_FRAC(v1_addr)  // load Z values into vtx_attrs_1_i and vtx_attrs_1_f
    vmadm   v___, NR_temp_i, inv_CrossProduct2_f        ::  lsv     vtx_attrs_1_i[14], VTX_SCR_Z(v1_addr)
    vmadn   inv_dX_f, NR_temp_f, inv_CrossProduct2_i    ::  lh      $1, VTX_SCR_X(v2_addr)          // load screen X for middle vertex
    vmadh   inv_dX_i, NR_temp_i, inv_CrossProduct2_i    ::  addiu   TriShadePtr, rdpCmdBufPtr, 0x20 // Increment the triangle pointer by 0x20 bytes (edge coefficients)

dA_M_i equ $v7
dA_M_f equ $v13
dA_H_i equ $v9
dA_H_f equ $v10

    // dAdH = v3_att - v1_att
    vsubc   dA_H_f, vtx_attrs_3_f, vtx_attrs_1_f    ::  andi    $3, $6, G_SHADE
    vsub    dA_H_i, vtx_attrs_3_i, vtx_attrs_1_i    ::  sll     $1, $1, 14                          // middle vertex X coord << 14
    // dAdM = v2_att - v1_att
    vsubc   dA_M_f, vtx_attrs_2_f, vtx_attrs_1_f    ::  sw      $1, 0x0008(rdpCmdBufPtr)            // Store XL int and frac (16 bits each)
    vsub    dA_M_i, vtx_attrs_2_i, vtx_attrs_1_i    ::  ssv     PosXHM_i[6], 0x0010(rdpCmdBufPtr)   // Store XH (integer part)

// d(attribute).x
dA_x_f equ $v2  // (fraction) [dr.x, dg.x, db.x, da.x, ds.x, dt.x, dw.x, dz.x]
dA_x_i equ $v3  // (integer)  [dr.x, dg.x, db.x, da.x, ds.x, dt.x, dw.x, dz.x]

    // dA_x = dMH.y * dAdH + dHL.y * dAdM
    vmudn   v___, dA_H_f, Diff_MH[1]    ::  ssv     PosXHM_f[6], 0x0012(rdpCmdBufPtr)   // Store XH (fractional part)
    vmadh   v___, dA_H_i, Diff_MH[1]    ::  ssv     PosXHM_i[4], 0x0018(rdpCmdBufPtr)   // Store XM (integer part)
    vmadn   v___, dA_M_f, Diff_HL[1]    ::  ssv     PosXHM_f[4], 0x001A(rdpCmdBufPtr)   // Store XM (fractional part)
    vmadh   v___, dA_M_i, Diff_HL[1]    ::  ssv     dXdY_i[0], 0x000C(rdpCmdBufPtr)     // Store DxLDy (integer part)
    vreadacc dA_x_f, ACC_MIDDLE         ::  ssv     dXdY_f[0], 0x000E(rdpCmdBufPtr)     // Store DxLDy (fractional part)
    vreadacc dA_x_i, ACC_UPPER          ::  ssv     dXdY_i[6], 0x0014(rdpCmdBufPtr)     // Store DxHDy (integer part)

// d(attribute).y
dA_y_f equ $v6  // (fraction) [dr.y, dg.y, db.y, da.y, ds.y, dt.y, dw.y, dz.y]
dA_y_i equ $v7  // (integer)  [dr.y, dg.y, db.y, da.y, ds.y, dt.y, dw.y, dz.y]

TriTexPtr equ $1

    // dAdY = dLH.x * dAdM + dHM.x * dAdH
    vmudn   v___, dA_M_f, Diff_LH[0]    ::  ssv     dXdY_f[6], 0x0016(rdpCmdBufPtr) // Store DxHDy (fractional part)
    vmadh   v___, dA_M_i, Diff_LH[0]    ::  ssv     dXdY_i[4], 0x001C(rdpCmdBufPtr) // Store DxMDy (integer part)
    vmadn   v___, dA_H_f, Diff_HM[0]    ::  ssv     dXdY_f[4], 0x001E(rdpCmdBufPtr) // Store DxMDy (fractional part)
    vmadh   v___, dA_H_i, Diff_HM[0]    ::  sll     $11, $3, 4                      // Shift (geometry mode & G_SHADE) (which is 4 when on) by 4 to get 0x40 if G_SHADE is set
    vreadacc dA_y_f, ACC_MIDDLE         ::  add     TriTexPtr, TriShadePtr, $11     // Increment the triangle pointer by 0x40 bytes (shade coefficients) if G_SHADE is set
    vreadacc dA_y_i, ACC_UPPER          ::  sll     $11, $9, 5                      // Shift texture enabled (which is 2 when on) by 5 to get 0x40 if textures are on

// compute d(attribute)/d[x,y,z]

dAdX_f equ dA_x_f
dAdX_i equ dA_x_i

    // dAdX = dA.x * (1 / dx)
    vmudl   v___, dA_x_f, inv_dX_f[1]           ::  add     rdpCmdBufPtr, TriTexPtr, $11    // Increment the triangle pointer by 0x40 bytes (texture coefficients) if textures are on
    vmadm   v___, dA_x_i, inv_dX_f[1]           ::  andi    $6, $6, G_ZBUFFER               // Get the value of G_ZBUFFER from the current geometry mode
    vmadn   dAdX_f, dA_x_f, inv_dX_i[1]         ::  sll     $11, $6, 4                      // Shift (geometry mode & G_ZBUFFER) by 4 to get 0x10 if G_ZBUFFER is set
    vmadh   dAdX_i, dA_x_i, inv_dX_i[1]         ::  add     rdpCmdBufPtr, rdpCmdBufPtr, $11 // Increment the triangle pointer by 0x10 bytes (depth coefficients) if G_ZBUFFER is set

dAdY_f equ dA_y_f
dAdY_i equ dA_y_i

dAdE_f equ $v8  // (fraction) [drde, dgde, dbde, dade, dsde, dtde, dwde, dzde]
dAdE_i equ $v9  // (integer)  [drde, dgde, dbde, dade, dsde, dtde, dwde, dzde]

    // dAdY = dA.y * (1 / dy)
    vmudl   v___, dA_y_f, inv_dX_f[1]
    vmadm   v___, dA_y_i, inv_dX_f[1]
    vmadn   dAdY_f, dA_y_f, inv_dX_i[1]         ::  sdv     dAdX_f[0], 0x0018(TriShadePtr)  // Store drdx, dgdx, dbdx, dadx shade coefficients (fractional)
    vmadh   dAdY_i, dA_y_i, inv_dX_i[1]         ::  sdv     dAdX_i[0], 0x0008(TriShadePtr)  // Store drdx, dgdx, dbdx, dadx shade coefficients (integer)
    // dAdE = dAdY + dAdX * dxhdy
    vmadl   v___, dAdX_f, dXhdY_f               ::  sdv     dAdX_f[8], 0x0018(TriTexPtr)    // Store dsdx, dtdx, dwdx texture coefficients (fractional)
    vmadm   v___, dAdX_i, dXhdY_f               ::  sdv     dAdX_i[8], 0x0008(TriTexPtr)    // Store dsdx, dtdx, dwdx texture coefficients (integer)
    vmadn   dAdE_f, dAdX_f, dXhdY_i             ::  sdv     dAdY_f[0], 0x0038(TriShadePtr)  // Store drdy, dgdy, dbdy, dady shade coefficients (fractional)
    vmadh   dAdE_i, dAdX_i, dXhdY_i             ::  sdv     dAdY_i[0], 0x0028(TriShadePtr)  // Store drdy, dgdy, dbdy, dady shade coefficients (integer)

// compute attribute base value

    // A' = A + dAdE * y_spx
    vmudn   v___, vtx_attrs_1_f, vOne[0]        ::  sdv     dAdY_f[8], 0x0038(TriTexPtr)    // Store dsdy, dtdy, dwdy texture coefficients (fractional)
    vmadh   v___, vtx_attrs_1_i, vOne[0]        ::  sdv     dAdY_i[8], 0x0028(TriTexPtr)    // Store dsdy, dtdy, dwdy texture coefficients (integer)
    vmadl   v___, dAdE_f, y_spx_f[1]            ::  sdv     dAdE_f[0], 0x0030(TriShadePtr)  // Store drde, dgde, dbde, dade shade coefficients (fractional)
    vmadm   v___, dAdE_i, y_spx_f[1]            ::  sdv     dAdE_i[0], 0x0020(TriShadePtr)  // Store drde, dgde, dbde, dade shade coefficients (integer)
    vmadn   vtx_attrs_1_f, dAdE_f, y_spx_i[1]   ::  sdv     dAdE_f[8], 0x0030(TriTexPtr)    // Store dsde, dtde, dwde texture coefficients (fractional)
    vmadh   vtx_attrs_1_i, dAdE_i, y_spx_i[1]   ::  sdv     dAdE_i[8], 0x0020(TriTexPtr)    // Store dsde, dtde, dwde texture coefficients (integer)

    // $v10 = dAdE_f * y_spx_f
    vmudn   $v10, dAdE_f, y_spx_f[1]            ::  beqz    $6, no_z_buffer
    // dAd* = dAd* * (1 << 5)
     vmudn  dAdE_f, dAdE_f, LSHIFT_5
    vmadh   dAdE_i, dAdE_i, LSHIFT_5            ::  sdv     vtx_attrs_1_f[0], 0x10(TriShadePtr) // Store RGBA shade color (fractional)
    vmudn   dAdX_f, dAdX_f, LSHIFT_5            ::  sdv     vtx_attrs_1_i[0], 0x00(TriShadePtr) // Store RGBA shade color (integer)
    vmadh   dAdX_i, dAdX_i, LSHIFT_5            ::  sdv     vtx_attrs_1_f[8], 0x10(TriTexPtr)   // Store S, T, W texture coefficients (fractional)
    vmudn   dAdY_f, dAdY_f, LSHIFT_5            ::  sdv     vtx_attrs_1_i[8], 0x00(TriTexPtr)   // Store S, T, W texture coefficients (integer)
    vmadh   dAdY_i, dAdY_i, LSHIFT_5            ::  ssv     dAdE_f[14], (0x000A - 0x10)(rdpCmdBufPtr) // Store dzde (frac)

    // A'' = A' * (1 << 5) + $v10 * (1 << 5) = (A' + dAdE_f * y_spx_f) * (1 << 5)
    vmudl   v___, $v10, LSHIFT_5                    ::  ssv     dAdE_i[14], (0x0008 - 0x10)(rdpCmdBufPtr) // Store dzde (int)
    vmadn   vtx_attrs_1_f, vtx_attrs_1_f, LSHIFT_5  ::  ssv     dAdX_f[14], (0x0006 - 0x10)(rdpCmdBufPtr) // Store dzdx (frac)
    vmadh   vtx_attrs_1_i, vtx_attrs_1_i, LSHIFT_5  ::  ssv     dAdX_i[14], (0x0004 - 0x10)(rdpCmdBufPtr) // Store dzdx (int)
                                                        ssv     dAdY_f[14], (0x000E - 0x10)(rdpCmdBufPtr) // Store dzdy (frac)
                                                        ssv     dAdY_i[14], (0x000C - 0x10)(rdpCmdBufPtr) // Store dzdy (int)
                                                        ssv     vtx_attrs_1_f[14], (0x0002 - 0x10)(rdpCmdBufPtr) // Store z (frac)
                                                        // eventually returns to $ra, which is next cmd, second tri in TRI2, or middle of clipping
                                                        j       check_rdp_buffer_full
                                                        ssv     vtx_attrs_1_i[14], (0x0000 - 0x10)(rdpCmdBufPtr) // Store z (int)
no_z_buffer:
    sdv     vtx_attrs_1_f[0], 0x10($2)  // Store RGBA shade color (fractional)
    sdv     vtx_attrs_1_i[0], 0x00($2)  // Store RGBA shade color (integer)
    sdv     vtx_attrs_1_f[8], 0x10($1)  // Store S, T, W texture coefficients (fractional)
    j       check_rdp_buffer_full       // eventually returns to $ra, which is next cmd, second tri in TRI2, or middle of clipping
     sdv    vtx_attrs_1_i[8], 0x00($1)  // Store S, T, W texture coefficients (integer)



vtxPtr    equ $25 // = cmd_w0
endVtxPtr equ $24 // = cmd_w1_dram
G_CULLDL_handler:
    lhu     vtxPtr, (vertexTable)(cmd_w0)     // load start vertex address
    lhu     endVtxPtr, (vertexTable)(cmd_w1_dram) // load end vertex address
    addiu   $1, $zero, CLIP_ALL
    lw      $11, VTX_CLIP(vtxPtr)             // read clip flags from vertex
culldl_loop:
    and     $1, $1, $11
    beqz    $1, run_next_DL_command           // Some vertex is on the screen-side of all clipping planes; have to render
     lw     $11, (vtxSize + VTX_CLIP)(vtxPtr) // next vertex clip flags
    bne     vtxPtr, endVtxPtr, culldl_loop    // loop until reaching the last vertex
     addiu  vtxPtr, vtxPtr, vtxSize           // advance to the next vertex
    j       G_ENDDL_handler                   // If got here, there's some clipping plane where all verts are outside it; skip DL
G_BRANCH_WZ_handler:
     lhu    vtxPtr, (vertexTable)(cmd_w0)     // get the address of the vertex being tested
.if CFG_G_BRANCH_W                            // BRANCH_W/BRANCH_Z difference; this defines F3DZEX vs. F3DEX2
    lh      vtxPtr, VTX_W_INT(vtxPtr)         // read the w coordinate of the vertex (f3dzex)
.else
    lw      vtxPtr, VTX_SCR_Z(vtxPtr)         // read the screen z coordinate (int and frac) of the vertex (f3dex2)
.endif
    sub     $2, vtxPtr, cmd_w1_dram           // subtract the w/z value being tested
    bgez    $2, run_next_DL_command           // if vtx.w/z >= cmd w/z, continue running this DL
     lw     cmd_w1_dram, rdpHalf1Val          // load the RDPHALF1 value as the location to branch to
    j       branch_dl
G_MODIFYVTX_handler:
     lbu    $1, (inputBufferEnd - 0x07)(inputBufferPos)
    j       do_moveword
     lhu    cmd_w0, (vertexTable)(cmd_w0)

     
.if . > 0x00001FAC
    .error "Not enough room in IMEM"
.endif
.org 0x1FAC

// This subroutine sets up the values to load overlay 0 and then falls through
// to load_overlay_and_enter to execute the load.
load_overlay_0_and_enter:
G_LOAD_UCODE_handler:
    li      postOvlRA, ovl0_start                    // Sets up return address
    li      ovlTableEntry, overlayInfo0              // Sets up ovl0 table address
// This subroutine accepts the address of an overlay table entry and loads that overlay.
// It then jumps to that overlay's address after DMA of the overlay is complete.
// ovlTableEntry is used to provide the overlay table entry
// postOvlRA is used to pass in a value to return to
load_overlay_and_enter:
    lw      cmd_w1_dram, overlay_load(ovlTableEntry) // Set up overlay dram address
    lhu     dmaLen, overlay_len(ovlTableEntry)       // Set up overlay length
    jal     dma_read_write                           // DMA the overlay
     lhu    dmemAddr, overlay_imem(ovlTableEntry)    // Set up overlay load address
    move    $ra, postOvlRA                // Set the return address to the passed in value

.if . > 0x1FC8
    .error "Constraints violated on what can be overwritten at end of ucode (relevant for G_LOAD_UCODE)"
.endif

while_wait_dma_busy:
    mfc0    ovlTableEntry, SP_DMA_BUSY    // Load the DMA_BUSY value into ovlTableEntry
while_dma_busy:
    bnez    ovlTableEntry, while_dma_busy // Loop until DMA_BUSY is cleared
     mfc0   ovlTableEntry, SP_DMA_BUSY    // Update ovlTableEntry's DMA_BUSY value
// This routine is used to return via conditional branch
return_routine:
    jr      $ra

dma_read_write:
     mfc0   $11, SP_DMA_FULL          // load the DMA_FULL value
while_dma_full:
    bnez    $11, while_dma_full       // Loop until DMA_FULL is cleared
     mfc0   $11, SP_DMA_FULL          // Update DMA_FULL value
    mtc0    dmemAddr, SP_MEM_ADDR     // Set the DMEM address to DMA from/to
    bltz    dmemAddr, dma_write       // If the DMEM address is negative, this is a DMA write, if not read
     mtc0   cmd_w1_dram, SP_DRAM_ADDR // Set the DRAM address to DMA from/to
    jr $ra
     mtc0   dmaLen, SP_RD_LEN         // Initiate a DMA read with a length of dmaLen
dma_write:
    jr $ra
     mtc0   dmaLen, SP_WR_LEN         // Initiate a DMA write with a length of dmaLen

.if . > 0x00002000
    .error "Not enough room in IMEM"
.endif

// first overlay table at 0x02E0
// overlay 0 (0x98 bytes loaded into 0x1000)

.headersize 0x00001000 - orga()

// Overlay 0 controls the RDP and also stops the RSP when work is done
// The action here is controlled by $1. If yielding, $1 > 0. If this was
// G_LOAD_UCODE, $1 == 0. If we got to the end of the parent DL, $1 < 0.
ovl0_start:
.if !CFG_XBUS // FIFO version
    sub     $11, rdpCmdBufPtr, rdpCmdBufEnd
    addiu   $12, $11, RDP_CMD_BUFSIZE - 1
    bgezal  $12, flush_rdp_buffer
     nop
    jal     while_wait_dma_busy
     lw     $24, rdpFifoPos
    bltz    $1, taskdone_and_break  // $1 < 0 = Got to the end of the parent DL
     mtc0   $24, DPC_END            // Set the end pointer of the RDP so that it starts the task
.else // CFG_XBUS
    bltz    $1, taskdone_and_break  // $1 < 0 = Got to the end of the parent DL
     nop
.endif
    bnez    $1, task_yield          // $1 > 0 = CPU requested yield
     add    taskDataPtr, taskDataPtr, inputBufferPos // inputBufferPos <= 0; taskDataPtr was where in the DL after the current chunk loaded
// If here, G_LOAD_UCODE was executed.
    lw      cmd_w1_dram, (inputBufferEnd - 0x04)(inputBufferPos) // word 1 = ucode code DRAM addr
    sw      taskDataPtr, OSTask + OSTask_data_ptr // Store where we are in the DL
    sw      cmd_w1_dram, OSTask + OSTask_ucode // Store pointer to new ucode about to execute
    la      dmemAddr, start         // Beginning of overwritable part of IMEM
    jal     dma_read_write          // DMA DRAM read -> IMEM write
     li     dmaLen, (while_wait_dma_busy - start) - 1 // End of overwritable part of IMEM
.if CFG_XBUS
ovl0_xbus_wait_for_rdp:
    mfc0 $11, DPC_STATUS
    andi $11, $11, DPC_STATUS_DMA_BUSY
    bnez $11, ovl0_xbus_wait_for_rdp // Keep looping while RDP is busy.
.endif
    lw      cmd_w1_dram, rdpHalf1Val // Get DRAM address of ucode data from rdpHalf1Val
    la      dmemAddr, spFxBase      // DMEM address is spFxBase
    andi    dmaLen, cmd_w0, 0x0FFF  // Extract DMEM length from command word
    add     cmd_w1_dram, cmd_w1_dram, dmemAddr // Start overwriting data from spFxBase
    jal     dma_read_write          // initate DMA read
     sub    dmaLen, dmaLen, dmemAddr // End that much before the end of DMEM
    j       while_wait_dma_busy
.if CFG_DONT_SKIP_FIRST_INSTR_NEW_UCODE
    // Not sure why we skip the first instruction of the new ucode; in this ucode, it's
    // zeroing vZero, but maybe it could be something else in other ucodes. But, starting
    // actually at the beginning is only in 2.04H, so skipping is likely the intended
    // behavior. Maybe some other ucodes use this for detecting whether they were run
    // from scratch or called from another ucode?
     li     $ra, start
.else
     li     $ra, start + 4
.endif

.if . > start
    .error "ovl0_start does not fit within the space before the start of the ucode loaded with G_LOAD_UCODE"
.endif

ucode equ $11
status equ $12
task_yield:
    lw      ucode, OSTask + OSTask_ucode
.if !CFG_XBUS // FIFO version
    sw      taskDataPtr, OS_YIELD_DATA_SIZE - 8
    sw      ucode, OS_YIELD_DATA_SIZE - 4
    li      status, SP_SET_SIG1 | SP_SET_SIG2   // yielded and task done signals
    lw      cmd_w1_dram, OSTask + OSTask_yield_data_ptr
    li      dmemAddr, 0x8000 // 0, but negative = write
    li      dmaLen, OS_YIELD_DATA_SIZE - 1
.else // CFG_XBUS
    // Instead of saving the whole first OS_YIELD_DATA_SIZE bytes of DMEM,
    // XBUS saves only up to inputBuffer, as everything after that can be erased,
    // and because the RDP may still be using the output buffer, which is where
    // we'd have to write taskDataPtr and ucode.
    sw      taskDataPtr, inputBuffer // save these values for below, somewhere outside
    sw      ucode, inputBuffer + 4   // the area being written
    lw      cmd_w1_dram, OSTask + OSTask_yield_data_ptr
    li      dmemAddr, 0x8000 // 0, but negative = write
    jal     dma_read_write
     li     dmaLen, inputBuffer - 1
    // At the end of the OS's yield buffer, write the taskDataPtr and ucode words.
    li      status, SP_SET_SIG1 | SP_SET_SIG2 // yielded and task done signals
    addiu   cmd_w1_dram, cmd_w1_dram, OS_YIELD_DATA_SIZE - 8
    li      dmemAddr, 0x8000 | inputBuffer // where they were saved above
    li      dmaLen, 8 - 1
.endif
    j       dma_read_write
     li     $ra, break

taskdone_and_break:
    li      status, SP_SET_SIG2   // task done signal
break:
.if CFG_XBUS
ovl0_xbus_wait_for_rdp_2:
    mfc0 $11, DPC_STATUS
    andi $11, $11, DPC_STATUS_DMA_BUSY
    bnez $11, ovl0_xbus_wait_for_rdp_2 // Keep looping while RDP is busy.
     nop
.endif
    mtc0    status, SP_STATUS
    break   0
    nop

.align 8
ovl0_end:

.if ovl0_end > ovl01_end
    .error "Automatic resizing for overlay 0 failed"
.endif

// overlay 1 (0x170 bytes loaded into 0x1000)
.headersize 0x00001000 - orga()

ovl1_start:

G_DL_handler:
    lbu     $1, displayListStackLength  // Get the DL stack length
    sll     $2, cmd_w0, 15              // Shifts the push/nopush value to the highest bit in $2
branch_dl:
    jal     segmented_to_physical
     add    $3, taskDataPtr, inputBufferPos
    bltz    $2, displaylist_dma         // If the operation is nopush (branch) then simply DMA the new displaylist
     move   taskDataPtr, cmd_w1_dram    // Set the task data pointer to the target display list
    sw      $3, (displayListStack)($1)
    addi    $1, $1, 4                   // Increment the DL stack length
f3dzex_ovl1_00001020:
    j       displaylist_dma
     sb     $1, displayListStackLength

G_TEXTURE_handler:
    li      $11, textureSettings1 - (texrectWord1 - G_TEXRECTFLIP_handler)  // Calculate the offset from texrectWord1 and $11 for saving to textureSettings
G_TEXRECT_handler:
G_TEXRECTFLIP_handler:
    // Stores first command word into textureSettings for gSPTexture, 0x00D0 for gSPTextureRectangle/Flip
    sw      cmd_w0, (texrectWord1 - G_TEXRECTFLIP_handler)($11)
G_RDPHALF_1_handler:
    j       run_next_DL_command
    // Stores second command word into textureSettings for gSPTexture, 0x00D4 for gSPTextureRectangle/Flip, 0x00D8 for G_RDPHALF_1
     sw     cmd_w1_dram, (texrectWord2 - G_TEXRECTFLIP_handler)($11)

G_MOVEWORD_handler:
    srl     $2, cmd_w0, 16                              // load the moveword command and word index into $2 (e.g. 0xDB06 for G_MW_SEGMENT)
    lhu     $1, (movewordTable - (G_MOVEWORD << 8))($2) // subtract the moveword label and offset the word table by the word index (e.g. 0xDB06 becomes 0x0304)
do_moveword:
    add     $1, $1, cmd_w0          // adds the offset in the command word to the address from the table (the upper 4 bytes are effectively ignored)
    j       run_next_DL_command     // process the next command
     sw     cmd_w1_dram, ($1)       // moves the specified value (in cmd_w1_dram) into the word (offset + moveword_table[index])

G_POPMTX_handler:
    lw      $11, matrixStackPtr             // Get the current matrix stack pointer
    lw      $2, OSTask + OSTask_dram_stack  // Read the location of the dram stack
    sub     cmd_w1_dram, $11, cmd_w1_dram           // Decrease the matrix stack pointer by the amount passed in the second command word
    sub     $1, cmd_w1_dram, $2                     // Subtraction to check if the new pointer is greater than or equal to $2
    bgez    $1, do_popmtx                   // If the new matrix stack pointer is greater than or equal to $2, then use the new pointer as is
     nop
    move    cmd_w1_dram, $2                         // If the new matrix stack pointer is less than $2, then use $2 as the pointer instead
do_popmtx:
    beq     cmd_w1_dram, $11, run_next_DL_command   // If no bytes were popped, then we don't need to make the mvp matrix as being out of date and can run the next command
     sw     cmd_w1_dram, matrixStackPtr             // Update the matrix stack pointer with the new value
    j       do_movemem
     sw     $zero, mvpValid                 // Mark the MVP matrix and light directions as being out of date (the word being written to contains both)

G_MTX_end: // Multiplies the loaded model matrix into the model stack
    lhu     output_mtx, (movememTable + G_MV_MMTX)($1) // Set the output matrix to the model or projection matrix based on the command
    jal     while_wait_dma_busy
     lhu    input_mtx_0, (movememTable + G_MV_MMTX)($1) // Set the first input matrix to the model or projection matrix based on the command
    li      $ra, run_next_DL_command
    // The second input matrix will correspond to the address that memory was moved into, which will be tempMtx for G_MTX

mtx_multiply:
    addi    $12, input_mtx_1, 0x0018
@@loop:
    vmadn   $v9, vZero, vZero[0]
    addi    $11, input_mtx_1, 0x0008
    vmadh   $v8, vZero, vZero[0]
    addi    input_mtx_0, input_mtx_0, -0x0020
    vmudh   $v29, vZero, vZero[0]
@@innerloop:
    ldv     $v5[0], 0x0040(input_mtx_0)
    ldv     $v5[8], 0x0040(input_mtx_0)
    lqv     $v3[0], 0x0020(input_mtx_1)
    ldv     $v4[0], 0x0020(input_mtx_0)
    ldv     $v4[8], 0x0020(input_mtx_0)
    lqv     $v2[0], 0x0000(input_mtx_1)
    vmadl   $v29, $v5, $v3[0h]
    addi    input_mtx_1, input_mtx_1, 0x0002
    vmadm   $v29, $v4, $v3[0h]
    addi    input_mtx_0, input_mtx_0, 0x0008
    vmadn   $v7, $v5, $v2[0h]
    bne     input_mtx_1, $11, @@innerloop
     vmadh  $v6, $v4, $v2[0h]
    bne     input_mtx_1, $12, @@loop
     addi   input_mtx_1, input_mtx_1, 0x0008
    // Store the results in the passed in matrix
    sqv     $v9[0], 0x0020(output_mtx)
    sqv     $v8[0], 0x0000(output_mtx)
    sqv     $v7[0], 0x0030(output_mtx)
    jr      $ra
     sqv    $v6[0], 0x0010(output_mtx)

G_MTX_handler:
    // The lower 3 bits of G_MTX are, from LSb to MSb (0 value/1 value),
    //  matrix type (modelview/projection)
    //  load type (multiply/load)
    //  push type (nopush/push)
    // In F3DEX2 (and by extension F3DZEX), G_MTX_PUSH is inverted, so 1 is nopush and 0 is push
    andi    $11, cmd_w0, G_MTX_P_MV | G_MTX_NOPUSH_PUSH // Read the matrix type and push type flags into $11
    bnez    $11, load_mtx                               // If the matrix type is projection or this is not a push, skip pushing the matrix
     andi   $2, cmd_w0, G_MTX_MUL_LOAD                  // Read the matrix load type into $2 (0 is multiply, 2 is load)
    lw      cmd_w1_dram, matrixStackPtr                 // Set up the DMA from dmem to rdram at the matrix stack pointer
    li      dmemAddr, -0x2000                           //
    jal     dma_read_write                              // DMA the current matrix from dmem to rdram
     li     dmaLen, 0x0040 - 1                          // Set the DMA length to the size of a matrix (minus 1 because DMA is inclusive)
    addi    cmd_w1_dram, cmd_w1_dram, 0x40              // Increase the matrix stack pointer by the size of one matrix
    sw      cmd_w1_dram, matrixStackPtr                 // Update the matrix stack pointer
    lw      cmd_w1_dram, (inputBufferEnd - 4)(inputBufferPos) // Load command word 1 again
load_mtx:
    add     $12, $12, $2        // Add the load type to the command byte, selects the return address based on whether the matrix needs multiplying or just loading
    sw      $zero, mvpValid     // Mark the MVP matrix and light directions as being out of date (the word being written to contains both)
G_MOVEMEM_handler:
    jal     segmented_to_physical   // convert the memory address cmd_w1_dram to a virtual one
do_movemem:
     andi   $1, cmd_w0, 0x00FE                              // Move the movemem table index into $1 (bits 1-7 of the first command word)
    lbu     dmaLen, (inputBufferEnd - 0x07)(inputBufferPos) // Move the second byte of the first command word into dmaLen
    lhu     dmemAddr, (movememTable)($1)                    // Load the address of the memory location for the given movemem index
    srl     $2, cmd_w0, 5                                   // Left shifts the index by 5 (which is then added to the value read from the movemem table)
    lhu     $ra, (movememHandlerTable - (G_POPMTX | 0xFF00))($12)  // Loads the return address from movememHandlerTable based on command byte
    j       dma_read_write
G_SETOTHERMODE_H_handler: // These handler labels must be 4 bytes apart for the code below to work
     add    dmemAddr, dmemAddr, $2                          // This is for the code above, does nothing for G_SETOTHERMODE_H
G_SETOTHERMODE_L_handler:
    lw      $3, (othermode0 - G_SETOTHERMODE_H_handler)($11) // resolves to othermode0 or othermode1 based on which handler was jumped to
    lui     $2, 0x8000
    srav    $2, $2, cmd_w0
    srl     $1, cmd_w0, 8
    srlv    $2, $2, $1
    nor     $2, $2, $zero
    and     $3, $3, $2
    or      $3, $3, cmd_w1_dram
    sw      $3, (othermode0 - G_SETOTHERMODE_H_handler)($11)
    lw      cmd_w0, otherMode0
    j       G_RDP_handler
     lw     cmd_w1_dram, otherMode1

.align 8
ovl1_end:

.if ovl1_end > ovl01_end
    .error "Automatic resizing for overlay 1 failed"
.endif

.headersize ovl23_start - orga()

ovl2_start:
ovl23_lighting_entrypoint:
    lbu     $11, lightsValid
    j       continue_light_dir_xfrm
     lbu    topLightPtr, numLightsx18

ovl23_clipping_entrypoint_copy:  // same IMEM address as ovl23_clipping_entrypoint
    move    savedRA, $ra
    li      ovlTableEntry, overlayInfo3       // set up a load of overlay 3
    j       load_overlay_and_enter            // load overlay 3
     li     postOvlRA, ovl3_clipping_nosavera // set up the return address in ovl3

continue_light_dir_xfrm:
    // Transform light directions from camera space to model space, by
    // multiplying by modelview transpose, then normalize and store the results
    // (not overwriting original dirs). This is applied starting from the two
    // lookat lights and through all directional and point lights, but not
    // ambient. For point lights, the data is garbage but doesn't harm anything.
    bnez    $11, after_light_dir_xfrm // Skip calculating lights if they're not out of date
     addi   topLightPtr, topLightPtr, spFxBase - lightSize // With ltBufOfs, points at top/max light.
    sb      cmd_w0, lightsValid     // Set as valid, reusing state of w0
    /* Load MV matrix 3x3 transposed as:
    mxr0i 00 08 10 06 08 0A 0C 0E
    mxr1i 02 0A 12
    mxr2i 04 0C 14
    mxr3i 
    mxr0f 20 28 30 26 28 2A 2C 2E
    mxr1f 22 2A 32
    mxr2f 24 2C 34
    mxr3f 
    Vector regs now contain columns of the original matrix
    This is computing:
    vec3_s8 origDir = light[0x8:0xA];
    vec3_s16 newDir = origDir * transpose(mvMatrix[0:2][0:2]);
    newDir /= sqrt(newDir.x**2 + newDir.y**2 + newDir.z**2); //normalize
    light[0x10:0x12] = light[0x14:0x16] = (vec3_s8)newDir;
    */
    lqv     mxr0f,    (mvMatrix + 0x20)($zero)
    lqv     mxr0i,    (mvMatrix + 0x00)($zero)
    lsv     mxr1f[2], (mvMatrix + 0x2A)($zero)
    lsv     mxr1i[2], (mvMatrix + 0x0A)($zero)
    vmov    mxr1f[0], mxr0f[1]
    lsv     mxr2f[4], (mvMatrix + 0x34)($zero)
    vmov    mxr1i[0], mxr0i[1]
    lsv     mxr2i[4], (mvMatrix + 0x14)($zero)
    vmov    mxr2f[0], mxr0f[2]
    // With ltBufOfs immediate add, points two lights behind lightBufferMain, i.e. lightBufferLookat.
    xfrmLtPtr equ $20 // also input_mtx_1 and dmemAddr
    li      xfrmLtPtr, spFxBase - 2 * lightSize
    vmov    mxr2i[0], mxr0i[2]                   
    lpv     $v7[0], (ltBufOfs + 0x8)(xfrmLtPtr) // Load light direction
    vmov    mxr2f[1], mxr0f[6]
    lsv     mxr1f[4], (mvMatrix + 0x32)($zero)
    vmov    mxr2i[1], mxr0i[6]
    lsv     mxr1i[4], (mvMatrix + 0x12)($zero)
    vmov    mxr0f[1], mxr0f[4]
    lsv     mxr0f[4], (mvMatrix + 0x30)($zero)
    vmov    mxr0i[1], mxr0i[4]
    lsv     mxr0i[4], (mvMatrix + 0x10)($zero)
@@loop:
    vmudn   $v29, mxr1f, $v7[1]         // light y direction (fractional)
    vmadh   $v29, mxr1i, $v7[1]         // light y direction (integer)
    vmadn   $v29, mxr0f, $v7[0]         // light x direction (fractional)
    spv     $v15[0], (ltBufOfs + 0x10)(xfrmLtPtr) // Store transformed light direction; first loop is garbage
    vmadh   $v29, mxr0i, $v7[0]         // light x direction (integer)
    lw      $12, (ltBufOfs + 0x10)(xfrmLtPtr) // Reload transformed light direction
    vmadn   $v29, mxr2f, $v7[2]         // light z direction (fractional)
    vmadh   $v29, mxr2i, $v7[2]         // light z direction (integer)
    // Square the low 32 bits of each accumulator element
    vreadacc $v11, ACC_MIDDLE           // read the middle (bits 16..31) of the accumulator elements into v11
    sw      $12, (ltBufOfs + 0x14)(xfrmLtPtr) // Store duplicate of transformed light direction
    vreadacc $v15, ACC_UPPER            // read the upper (bits 32..47) of the accumulator elements into v15
    beq     xfrmLtPtr, topLightPtr, after_light_dir_xfrm    // exit if equal
     vmudl  $v29, $v11, $v11            // calculate the low partial product of the accumulator squared (low * low)
    vmadm   $v29, $v15, $v11            // calculate the mid partial product of the accumulator squared (mid * low)
    vmadn   $v16, $v11, $v15            // calculate the mid partial product of the accumulator squared (low * mid)
    beqz    $11, @@skip_incr            // skip increment if $11 is 0 (first time through loop)
     vmadh  $v17, $v15, $v15            // calculate the high partial product of the accumulator squared (mid * mid)
    addi    xfrmLtPtr, xfrmLtPtr, lightSize // increment light pointer
@@skip_incr:
    vaddc   $v18, $v16, $v16[1]         // X**2 + Y**2 frac
    li      $11, 1                      // set flag to increment next time through loop
    vadd    $v29, $v17, $v17[1]         // X**2 + Y**2 int
    vaddc   $v16, $v18, $v16[2]         // + Z**2 frac
    vadd    $v17, $v29, $v17[2]         // + Z**2 int
    vrsqh   $v29[0], $v17[0]            // In upper rsq v17 (output discarded)
    lpv     $v7[0], (ltBufOfs + lightSize + 0x8)(xfrmLtPtr) // Load direction of next light
    vrsql   $v16[0], $v16[0]            // Lower rsq v16, do rsq, out lower to v16
    vrsqh   $v17[0], vZero[0]           // Out upper v17 (input zero)
    vmudl   $v29, $v11, $v16[0]         // Multiply vector by rsq to normalize
    vmadm   $v29, $v15, $v16[0]
    vmadn   $v11, $v11, $v17[0]
    vmadh   $v15, $v15, $v17[0]
    vmudn   $v11, $v11, _0x100          // 0x0100; scale results to become bytes
    j       @@loop
     vmadh  $v15, $v15, _0x100          // 0x0100; scale results to become bytes

curMatrix equ $12 // Overwritten during texgen, but with a value which is 0 or positive, so means cur matrix is MV
ltColor equ $v29
vPairRGBA equ $v27
vPairAlpha37 equ $v28 // Same as mvTc1f, but alpha values are left in elems 3, 7
vPairNX equ $v7 // also named vPairRGBATemp; with name vPairNX, uses X components = elems 0, 4
vPairNY equ $v6
vPairNZ equ $v5

light_vtx:
    vadd    vPairNY, vZero, vPairRGBATemp[1h] // Move vertex normals Y to separate reg
.if CFG_POINT_LIGHTING
    luv     ltColor[0], (ltBufOfs + lightSize + 0)(curLight) // Init to ambient light color
.else
    lpv     $v20[0], (ltBufOfs - lightSize + 0x10)(curLight) // Load next below transformed light direction as XYZ_XYZ_ for lights_dircoloraccum2
.endif
    vadd    vPairNZ, vZero, vPairRGBATemp[2h] // Move vertex normals Z to separate reg
    luv     vPairRGBA[0], 8(inputVtxPos)      // Load both verts' XYZAXYZA as unsigned
    vne     $v4, $v31, $v31[3h]               // Set VCC to 11101110
.if !CFG_POINT_LIGHTING
    luv     ltColor[0], (ltBufOfs + lightSize + 0)(curLight) // Init to ambient light color
.else
    andi    $11, $5, G_LIGHTING_POSITIONAL_H  // check if point lighting is enabled in the geometry mode
    beqz    $11, directional_lighting         // If not enabled, use directional algorithm for everything
     li     curMatrix, mvpMatrix + 0x8000     // Set flag in negative to indicate cur mtx is MVP
    vaddc   vPairAlpha37, vPairRGBA, vZero[0] // Copy vertex alpha
    suv     ltColor[0], 8(inputVtxPos)        // Store ambient light color to two verts' RGBARGBA
    ori     $11, $zero, 0x0004
    vmov    $v30[7], $v30[6]                  // v30[7] = 0x0010 because v30[0:2,4:6] will get clobbered
    mtc2    $11, $v31[6]                      // v31[3] = 0x0004 (was previously 0x7F00)
next_light_dirorpoint:
    lbu     $11, (ltBufOfs + 0x3)(curLight)   // Load light type / constant attenuation value at light structure + 3
    bnez    $11, light_point                  // If not zero, this is a point light
     lpv    $v2[0], (ltBufOfs + 0x10)(curLight) // Load light transformed direction
    luv     ltColor[0], 8(inputVtxPos)        // Load current light color of two verts RGBARGBA
    vmulu   $v20, vPairNX, $v2[0h]            // Vertex normals X * light transformed dir X
    vmacu   $v20, vPairNY, $v2[1h]            // + Vtx Y * light Y
    vmacu   $v20, vPairNZ, $v2[2h]            // + Vtx Z * light Z; only elements 0, 4 matter
    luv     $v2[0], (ltBufOfs + 0)(curLight)  // Load light RGB
    vmrg    ltColor, ltColor, vPairAlpha37    // Select original alpha
    vand    $v20, $v20, $v31[7]               // 0x7FFF; vmulu/vmacu produces 0xFFFF when 0x8000*0x8000, change this to 0x7FFF
    vmrg    $v2, $v2, vZero[0]                // Set elements 3 and 7 of light RGB to 0
    vmulf   ltColor, ltColor, $v31[7]         // Load light color to accumulator (0x7FFF = 0.5 b/c unsigned?)
    vmacf   ltColor, $v2, $v20[0h]            // + light color * dot product
    suv     ltColor[0], 8(inputVtxPos)        // Store new light color of two verts RGBARGBA
    bne     curLight, spFxBaseReg, next_light_dirorpoint // If at start of lights, done
     addi   curLight, curLight, -lightSize
after_dirorpoint_loop:
    lqv     $v31[0], (v31Value)($zero)        // Fix clobbered v31
    lqv     $v30[0], (v30Value)($zero)        // Fix clobbered v30
    llv     vPairST[4], (inputVtxSize + 0x8)(inputVtxPos) // INSTR 2: load the texture coords of the 2nd vertex into v22[4-7]
    bgezal  curMatrix, lights_loadmtxdouble   // Branch if current matrix is MV matrix
     li     curMatrix, mvpMatrix + 0x8000     // Load MVP matrix and set flag for is MVP
    andi    $11, $5, G_TEXTURE_GEN_H
    vmrg    $v3, vZero, $v31[5]               // INSTR 3: Setup for texgen: 0x4000 in elems 3, 7
    beqz    $11, vertices_store               // Done if no texgen
     vge    $v27, $v25, $v31[3]               // INSTR 1: Clamp W/fog to >= 0x7F00 (low byte is used)
    lpv     $v2[0], (ltBufOfs + 0x10)(curLight) // Load lookat 1 transformed dir for texgen (curLight was decremented)
    lpv     $v20[0], (ltBufOfs - lightSize + 0x10)(curLight) // Load lookat 0 transformed dir for texgen
    j       lights_texgenmain
     vmulf  $v21, vPairNX, $v2[0h]            // First instruction of texgen, vertex normal X * last transformed dir

lights_loadmtxdouble: // curMatrix is either positive mvMatrix or negative mvpMatrix
    /* Load MVP matrix as follows--note that translation is in the bottom row,
    not the right column.
        Elem   0   1   2   3   4   5   6   7      (Example data)
    I r0i v8  00  02  04  06  00  02  04  06      Xscl Rot  Rot   0
    I r1i v9  08  0A  0C  0E  08  0A  0C  0E      Rot  Yscl Rot   0
    I r2i v10 10  12  14  16  10  12  14  16      Rot  Rot  Zscl  0
    I r3i v11 18  1A  1C  1E  18  1A  1C  1E      Xpos Ypos Zpos  1
    F r0f v12 20  22  24  26  20  22  24  26
    F r1f v13 28  2A  2C  2E  28  2A  2C  2E
    F r2f v14 30  32  34  36  30  32  34  36
    F r3f v15 38  3A  3C  3E  38  3A  3C  3E
    Vector regs contain rows of original matrix (v11/v15 have translations)
    */
    lqv     mxr0i[0], 0x0000(curMatrix) // rows 0 and 1, int
    lqv     mxr2i[0], 0x0010(curMatrix) // rows 2 and 3, int
    lqv     mxr0f[0], 0x0020(curMatrix) // rows 0 and 1, frac
    lqv     mxr2f[0], 0x0030(curMatrix) // rows 2 and 3, frac
    vcopy   mxr1i, mxr0i
    ldv     mxr1i[0], 0x0008(curMatrix) // row 1 int twice
    vcopy   mxr3i, mxr2i
    ldv     mxr3i[0], 0x0018(curMatrix) // row 3 int twice
    vcopy   mxr1f, mxr0f
    ldv     mxr1f[0], 0x0028(curMatrix) // row 1 frac twice
    vcopy   mxr3f, mxr2f
    ldv     mxr3f[0], 0x0038(curMatrix) // row 3 frac twice
    ldv     mxr0i[8], 0x0000(curMatrix) // row 0 int twice
    ldv     mxr2i[8], 0x0010(curMatrix) // row 2 int twice
    ldv     mxr0f[8], 0x0020(curMatrix) // row 0 frac twice
    jr      $ra
     ldv    mxr2f[8], 0x0030(curMatrix) // row 2 frac twice

lights_loadmvtranspose3x3double:
    /* Load 3x3 portion of MV matrix in transposed orientation
    Vector regs now contain columns of original matrix; elems 3,7 not modified
    Importantly, v28 elements 3 and 7 contain vertices 1 and 2 alpha.
    This also clobbers v31 and v30 (except elements 3 and 7), which have to be
    restored after lighting.
            E 0   1   2   3   4   5   6   7
    I c0i  v4 00  08  10  -   00  08  10  - 
    I c1i v21 02  0A  12  -   02  0A  12  - 
    I c2i v30 04  0C  14 CNST 04  0C  14 CNST
    I XXX XXX -   -   -   -   -   -   -   - 
    F c0f  v3 20  28  30  -   20  28  30  - 
    F c1f v28 22  2A  32 V1A  22  2A  32 V2A
    F c2f v31 24  2C  34 CNST 24  2C  34 CNST
    F XXX XXX -   -   -   -   -   -   -   - 
    */
    lsv     mvTc0i[0], (mvMatrix)($zero)
    lsv     mvTc0f[0], (mvMatrix + 0x20)($zero)
    lsv     mvTc1i[0], (mvMatrix + 2)($zero)
    lsv     mvTc1f[0], (mvMatrix + 0x22)($zero)
    lsv     mvTc2i[0], (mvMatrix + 4)($zero)
    vmov    mvTc0i[4], mvTc0i[0]
    lsv     mvTc2f[0], (mvMatrix + 0x24)($zero)
    vmov    mvTc0f[4], mvTc0f[0]
    lsv     mvTc0i[2], (mvMatrix + 8)($zero)
    vmov    mvTc1i[4], mvTc1i[0]
    lsv     mvTc0f[2], (mvMatrix + 0x28)($zero)
    vmov    mvTc1f[4], mvTc1f[0]
    lsv     mvTc1i[2], (mvMatrix + 0xA)($zero)
    vmov    mvTc2i[4], mvTc2i[0]
    lsv     mvTc1f[2], (mvMatrix + 0x2A)($zero)
    vmov    mvTc2f[4], mvTc2f[0]
    lsv     mvTc2i[2], (mvMatrix + 0xC)($zero)
    vmov    mvTc0i[5], mvTc0i[1]
    lsv     mvTc2f[2], (mvMatrix + 0x2C)($zero)
    vmov    mvTc0f[5], mvTc0f[1]
    lsv     mvTc0i[4], (mvMatrix + 0x10)($zero)
    vmov    mvTc1i[5], mvTc1i[1]
    lsv     mvTc0f[4], (mvMatrix + 0x30)($zero)
    vmov    mvTc1f[5], mvTc1f[1]
    lsv     mvTc1i[4], (mvMatrix + 0x12)($zero)
    vmov    mvTc2i[5], mvTc2i[1]
    lsv     mvTc1f[4], (mvMatrix + 0x32)($zero)
    vmov    mvTc2f[5], mvTc2f[1]
    lsv     mvTc2i[4], (mvMatrix + 0x14)($zero)
    vmov    mvTc0i[6], mvTc0i[2]
    lsv     mvTc2f[4], (mvMatrix + 0x34)($zero)
    vmov    mvTc0f[6], mvTc0f[2]
    or      curMatrix, $zero, $zero // Set curMatrix = positive mvMatrix
    vmov    mvTc1i[6], mvTc1i[2]
    vmov    mvTc1f[6], mvTc1f[2]
    vmov    mvTc2i[6], mvTc2i[2]
    j       lights_loadmtxdouble
     vmov   mvTc2f[6], mvTc2f[2]

light_point:
    ldv     $v20[8], 0x0000(inputVtxPos) // Load v0 pos to upper 4 elements of v20
    bltzal  curMatrix, lights_loadmvtranspose3x3double // branch if curMatrix is MVP; need MV and MV^T
     ldv    $v20[0], 0x0010(inputVtxPos) // Load v1 pos to lower 4 elements of v20
    // Transform input vertices by MV; puts them in camera space
    vmudn   $v2, mxr3f, vOne[0]          // 1 * translation row
    ldv     $v29[0], (ltBufOfs + 0x8)(curLight) // Load light pos (shorts, same mem as non-transformed light dir) into lower 4 elements
    vmadh   $v2, mxr3i, vOne[0]          // 1 * translation row
    vmadn   $v2, mxr0f, $v20[0h]
    vmadh   $v2, mxr0i, $v20[0h]
    vmadn   $v2, mxr1f, $v20[1h]
    ldv     $v29[8], (ltBufOfs + 0x8)(curLight) // Load same light pos into upper 4
    vmadh   $v2, mxr1i, $v20[1h]
    vmadn   $v2, mxr2f, $v20[2h]
    vmadh   $v2, mxr2i, $v20[2h]
    vsub    $v20, $v29, $v2              // v20 = light pos - camera space verts pos
    vmrg    $v29, $v20, vZero[0]         // Set elems 3 and 7 to 0
    vmudh   $v2, $v29, $v29              // Squared
    vreadacc $v2, ACC_UPPER              // v2 = accumulator upper
    vreadacc $v29, ACC_MIDDLE            // v29 = accumulator middle
    vaddc   $v29, $v29, $v29[0q]         // Add X to Y, Z to alpha(0) (middle)
    vadd    $v2, $v2, $v2[0q]            // Add X to Y, Z to alpha(0) (upper)
    vaddc   $v29, $v29, $v29[2h]         // Add Z+alpha(0) to all (middle)
    vadd    $v2, $v2, $v2[2h]            // Add Z+alpha(0) to all (upper)
    vrsqh   $v29[3], $v2[1]              // Input upper sum vtx 1
    vrsql   $v29[3], $v29[1]             // Rsqrt lower
    vrsqh   $v29[2], $v2[5]              // Get upper result, input upper sum vtx 0
    vrsql   $v29[7], $v29[5]
    vrsqh   $v29[6], vZero[0]            // Results in v29[2:3, 6:7]
    // Transform vert-to-light vector by MV transpose. See note about why this is
    // not correct if non-uniform scale has been applied.
    vmudn   $v2, mvTc0f, $v20[0h]
    sll     $11, $11, 4                  // Holds light type / constant attenuation value (0x3)
    vmadh   $v2, mvTc0i, $v20[0h]
    lbu     $24, (ltBufOfs + 0xE)(curLight) // Quadratic attenuation factor byte from point light props
    vmadn   $v2, mvTc1f, $v20[1h]
    mtc2    $11, $v27[0]                 // 0x3 << 4 -> v27 elems 0, 1
    vmadh   $v2, mvTc1i, $v20[1h]
    vmadn   $v2, mvTc2f, $v20[2h]
    vmadh   $v20, mvTc2i, $v20[2h]       // v20 = int result of vert-to-light in model space
    vmudm   $v2, $v20, $v29[3h]          // v2l_model * length normalization frac
    vmadh   $v20, $v20, $v29[2h]         // v2l_model * length normalization int
    vmudn   $v2, $v2, $v31[3]            // this is 0x0004; v31 is mvTc2f but elem 3 replaced, elem 7 left
    vmadh   $v20, $v20, $v31[3]          // 
    vmulu   $v2, vPairNX, $v20[0h]       // Normal X * normalized vert-to-light X
    mtc2    $11, $v27[8]                 // 0x3 << 4 -> v27 elems 4, 5
    vmacu   $v2, vPairNY, $v20[1h]       // Y * Y
    lbu     $11, (ltBufOfs + 0x7)(curLight) // Linear attenuation factor byte from point light props
    vmacu   $v2, vPairNZ, $v20[2h]       // Z * Z
    sll     $24, $24, 5
    vand    $v20, $v2, $v31[7]           // 0x7FFF; vmulu/vmacu produces 0xFFFF when 0x8000*0x8000, change this to 0x7FFF
    mtc2    $24, $v20[14]                // 0xE << 5 -> v20 elem 7
    vrcph   $v29[0], $v29[2]             // rcp(rsqrt()) = sqrt = length of vert-to-light
    vrcpl   $v29[0], $v29[3]             // For vertex 1 in v29[0]
    vrcph   $v29[4], $v29[6]             // 
    vrcpl   $v29[4], $v29[7]             // For vertex 0 in v29[4]
    vmudh   $v2, $v29, $v30[7]           // scale by 0x0010 (value changed in light_vtx) (why?)
    mtc2    $11, $v20[6]                 // 0x7 -> v20 elem 3
    vmudl   $v2, $v2, $v2[0h]            // squared
    vmulf   $v29, $v29, $v20[3]          // Length * byte 0x7
    vmadm   $v29, $v2, $v20[7]           // + (scaled length squared) * byte 0xE << 5
    vmadn   $v29, $v27, $v30[3]          // + (byte 0x3 << 4) * 0x0100
    vreadacc $v2, ACC_MIDDLE
    vrcph   $v2[0], $v2[0]               // v2 int, v29 frac: function of distance to light
    vrcpl   $v2[0], $v29[0]              // Reciprocal = inversely proportional
    vrcph   $v2[4], $v2[4]
    vrcpl   $v2[4], $v29[4]
    luv     ltColor[0], 0x0008(inputVtxPos) // Get current RGBARGBA for two verts
    vand    $v2, $v2, $v31[7]            // 0x7FFF; vrcp produces 0xFFFF when 1/0, change this to 0x7FFF
    vmulf   $v2, $v2, $v20               // Inverse dist factor * dot product (elems 0, 4)
    luv     $v20[0], (ltBufOfs + 0)(curLight) // Light color RGB_RGB_
    vmrg    ltColor, ltColor, vPairAlpha37 // Select orig alpha; vPairAlpha37 = v28 = mvTc1f, but alphas were not overwritten
    vand    $v2, $v2, $v31[7]            // 0x7FFF; not sure what this is for, both inputs to the multiply are always positive
    vmrg    $v20, $v20, vZero[0]         // Zero elements 3 and 7 of light color
    vmulf   ltColor, ltColor, $v31[7]    // Load light color to accumulator (0x7FFF = 0.5 b/c unsigned?)
    vmacf   ltColor, $v20, $v2[0h]       // + light color * light amount
    suv     ltColor[0], 0x0008(inputVtxPos) // Store new RGBARGBA for two verts
    bne     curLight, spFxBaseReg, next_light_dirorpoint
     addi   curLight, curLight, -lightSize
    j       after_dirorpoint_loop
directional_lighting:
     lpv     $v20[0], (ltBufOfs - lightSize + 0x10)(curLight) // Load next light transformed dir; this value is overwritten with the same thing
.endif

// Loop for dot product normals and multiply-add color for 2 lights
// curLight starts pointing to the top light, and v2 and v20 already have the dirs
lights_dircoloraccum2:
    vmulu   $v21, vPairNX, $v2[0h]       // vtx normals all (X) * light transformed dir 2n+1 X
    luv     $v4[0], (ltBufOfs + 0)(curLight) // color light 2n+1
    vmacu   $v21, vPairNY, $v2[1h]       // + vtx n Y only * light dir 2n+1 Y
    beq     curLight, spFxBaseReg, lights_finishone // Finish pipeline for odd number of lights
     vmacu  $v21, vPairNZ, $v2[2h]       // + vtx n Z only * light dir 2n+1 Z
    vmulu   $v28, vPairNX, $v20[0h]      // vtx normals all (X) * light transformed dir 2n X
    luv     $v3[0], (ltBufOfs - lightSize + 0)(curLight) // color light 2n
    vmacu   $v28, vPairNY, $v20[1h]      // + vtx n Y only * light dir 2n Y
    addi    $11, curLight, -lightSize    // Subtract 1 light for comparison at bottom of loop
    vmacu   $v28, vPairNZ, $v20[2h]      // + vtx n Y only * light dir 2n Y
    addi    curLight, curLight, -(2 * lightSize)
    vmrg    ltColor, ltColor, vPairRGBA  // select orig alpha
    mtc2    $zero, $v4[6]                // light 2n+1 color comp 3 = 0 (to not interfere with alpha)
    vmrg    $v3, $v3, vZero[0]           // light 2n color components 3,7 = 0
    mtc2    $zero, $v4[14]               // light 2n+1 color comp 7 = 0 (to not interfere with alpha)
    vand    $v21, $v21, $v31[7]          // 0x7FFF; vmulu/vmacu produces 0xFFFF when 0x8000*0x8000, change this to 0x7FFF
    lpv     $v2[0], (ltBufOfs + 0x10)(curLight) // Normal for light or lookat next slot down, 2n+1
    vand    $v28, $v28, $v31[7]          // 0x7FFF; vmulu/vmacu produces 0xFFFF when 0x8000*0x8000, change this to 0x7FFF
    lpv     $v20[0], (ltBufOfs - lightSize + 0x10)(curLight) // Normal two slots down, 2n
    vmulf   ltColor, ltColor, $v31[7]    // Load light color to accumulator (0x7FFF = 0.5 b/c unsigned?)
    vmacf   ltColor, $v4, $v21[0h]       // + color 2n+1 * dot product
    bne     $11, spFxBaseReg, lights_dircoloraccum2 // Pointer 1 behind, minus 1 light, if at base then done
     vmacf  ltColor, $v3, $v28[0h]       // + color 2n * dot product
// End of loop for even number of lights
    vmrg    $v3, vZero, $v31[5]          // INSTR 3: Setup for texgen: 0x4000 in elems 3, 7
    llv     vPairST[4], (inputVtxSize + 8)(inputVtxPos)  // INSTR 2: load the texture coords of the 2nd vertex into v22[4-7]
    
lights_texgenpre:
// Texgen beginning
    vge     $v27, $v25, $v31[3]         // INSTR 1: Clamp W/fog to >= 0x7F00 (low byte is used)
    andi    $11, $5, G_TEXTURE_GEN_H
    vmulf   $v21, vPairNX, $v2[0h]      // Vertex normal X * lookat 1 dir X
    beqz    $11, vertices_store
     suv    ltColor[0], 0x0008(inputVtxPos) // write back color/alpha for two verts
lights_texgenmain:
// Texgen main
    vmacf   $v21, vPairNY, $v2[1h]      // VN Y * lookat 1 dir Y
    andi    $12, $5, G_TEXTURE_GEN_LINEAR_H
    vmacf   $v21, vPairNZ, $v2[2h]      // VN Z * lookat 1 dir Z
    vxor    $v4, $v3, $v31[5]           // v4 has 0x4000 in opposite pattern as v3, normally 11101110
    vmulf   $v28, vPairNX, $v20[0h]     // VN XYZ * lookat 0 dir XYZ
    vmacf   $v28, vPairNY, $v20[1h]     // Y
    vmacf   $v28, vPairNZ, $v20[2h]     // Z
    lqv     $v2[0], (linearGenerateCoefficients)($zero)
    vmudh   vPairST, vOne, $v31[5]      // S, T init to 0x4000 each
    vmacf   vPairST, $v3, $v21[0h]      // Add dot product with lookat 1 to T (elems 3, 7)
    beqz    $12, vertices_store
     vmacf  vPairST, $v4, $v28[0h]      // Add dot product with lookat 0 to S (elems 2, 6)
// Texgen Linear--not sure what formula this is implementing
    vmadh   vPairST, vOne, $v2[0]       // ST + Coefficient 0xC000
    vmulf   $v4, vPairST, vPairST       // ST squared
    vmulf   $v3, vPairST, $v31[7]       // Move to accumulator
    vmacf   $v3, vPairST, $v2[2]        // + ST * coefficient 0x6CB3
.if BUG_TEXGEN_LINEAR_CLOBBER_S_T
    vmudh   vPairST, vOne, $v31[5]      // Clobber S, T with 0x4000 each
.else
    vmudh   $v21, vOne, $v31[5]         // Initialize accumulator with 0x4000 each (v21 discarded)
.endif
    vmacf   vPairST, vPairST, $v2[1]    // + ST * coefficient 0x44D3
    j       vertices_store
     vmacf  vPairST, $v4, $v3           // + ST squared * (ST + ST * coeff)

lights_finishone:
    vmrg    ltColor, ltColor, vPairRGBA // select orig alpha
    vmrg    $v4, $v4, vZero[0]          // clear alpha component of color
    vand    $v21, $v21, $v31[7]         // 0x7FFF; vmulu/vmacu produces 0xFFFF when 0x8000*0x8000, change this to 0x7FFF
    veq     $v3, $v31, $v31[3h]         // set VCC to 00010001, opposite of 2 light case
    lpv     $v2[0], (ltBufOfs - 2 * lightSize + 0x10)(curLight) // Load second dir down, lookat 0, for texgen
    vmrg    $v3, vZero, $v31[5]         // INSTR 3 OPPOSITE: Setup for texgen: 0x4000 in 0,1,2,4,5,6
    llv     vPairST[4], (inputVtxSize + 8)(inputVtxPos)  // INSTR 2: load the texture coords of the 2nd vertex into v22[4-7]
    vmulf   ltColor, ltColor, $v31[7]   // Move cur color to accumulator
    j       lights_texgenpre
     vmacf  ltColor, $v4, $v21[0h]      // + light color * dot product

.align 8
ovl2_end:

.close // CODE_FILE
