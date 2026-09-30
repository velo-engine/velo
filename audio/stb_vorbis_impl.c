// stb_vorbis (from V's thirdparty directory) compiled into the game, so .ogg decoding also works where
// V's prebuilt object file cannot be linked (iOS, Android, the web). Guarded: V can emit a #include more than once.
#ifndef VELO_STB_VORBIS_C
#define VELO_STB_VORBIS_C
#include "stb_vorbis.c"
// stb_vorbis leaves its internal macros defined (even `L`, `C`, `R`), which breaks headers included after it
// in the same C file (Box2D's `b2Transform C;`). Undefine them (standard names such as NULL, malloc or
// TRUE stay: stb_vorbis only defines those when they are missing, and later code may rely on them).
#undef ADDEND
#undef C
#undef CHECK
#undef CODEBOOK_ELEMENT
#undef CODEBOOK_ELEMENT_BASE
#undef CODEBOOK_ELEMENT_FAST
#undef CRC32_POLY
#undef DECODE
#undef DECODE_RAW
#undef DECODE_VQ
#undef DIVTAB_DENOM
#undef DIVTAB_NUMER
#undef EOP
#undef FASTDEF
#undef FAST_HUFFMAN_TABLE_MASK
#undef FAST_HUFFMAN_TABLE_SIZE
#undef FAST_SCALED_FLOAT_TO_INT
#undef INVALID_BITS
#undef IS_PUSH_MODE
#undef L
#undef LIBVORBIS_MDCT
#undef LINE_OP
#undef MAGIC
#undef MAX_BLOCKSIZE
#undef MAX_BLOCKSIZE_LOG
#undef NO_CODE
#undef PAGEFLAG_continued_packet
#undef PAGEFLAG_first_page
#undef PAGEFLAG_last_page
#undef PLAYBACK_LEFT
#undef PLAYBACK_MONO
#undef PLAYBACK_RIGHT
#undef R
#undef SAMPLE_unknown
#undef USE_MEMORY
#undef array_size_required
#undef check_endianness
#undef temp_alloc
#undef temp_alloc_restore
#undef temp_alloc_save
#undef temp_block_array
#undef temp_free
#endif
