#!/bin/sh
# Written by `velo build web` next to the build: V runs this as its C compiler (it must be called emcc,
# V picks its Emscripten mode from the name). It patches what V 0.5.2 generates, then runs the real emcc.
for a in "$@"; do
  case "$a" in
    @*)
      rsp="${a#@}"
      # 1) Emscripten's musl declares the stdio streams `FILE *const`: give V's declarations an Emscripten branch.
      for c in $(grep -o '[^" ]*\.tmp\.c' "$rsp"); do
        [ -f "$c" ] && perl -0pi -e 's/\t#else\ntypedef struct _IO_FILE FILE;\nextern FILE\* stdin;/\t#elif defined(__EMSCRIPTEN__)\ntypedef struct _IO_FILE FILE;\nextern FILE* const stdin;\nextern FILE* const stdout;\nextern FILE* const stderr;\n$&/' "$c"
      done
      # 2) V 0.5.2's bundled sokol_app.h went through a C formatter, which broke JavaScript operators in
      #    its EM_JS blocks (`(x) = >`, `!= =`, `== =`): use a fixed copy, found first on the include path.
      sokol=$(grep -o '\-I"[^"]*thirdparty/sokol"' "$rsp" | head -1 | sed 's/^-I"//; s/"$//')
      if [ -n "$sokol" ] && grep -qE '\) = >|!= =|== =' "$sokol/sokol_app.h"; then
        fixed="$(dirname "$0")/sokol-fixed"
        mkdir -p "$fixed"
        sed -e 's/) = >/) =>/g' -e 's/!= =/!==/g' -e 's/== =/===/g' "$sokol/sokol_app.h" > "$fixed/sokol_app.h"
        grep -q "sokol-fixed" "$rsp" || perl -pi -e 's|^|-I"'"$fixed"'" | if $. == 1' "$rsp"
      fi
      # 3) gg embeds a font from V's examples/, which some V installs (e.g. Homebrew) do not ship: drop
      #    --embed-file entries whose source is missing (the game's own font comes from assets/fonts/).
      perl -pi -e 's/--embed-file\s+(\S+?)@(\S+)/-e $1 ? $& : ""/ge' "$rsp"
      ;;
  esac
done
exec "$VELO_REAL_EMCC" "$@"
