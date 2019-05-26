dnl Process this file with autoconf to produce a configure script.
AC_INIT

dnl Check for SDL
SDL_VERSION=2.0.6
AM_PATH_SDL2($SDL_VERSION,,
	    AC_MSG_ERROR([*** SDL version $SDL_VERSION not found!])
)

dnl Check for SDL_ttf
AC_CHECK_LIB(SDL2_ttf, TTF_Init, [
  SDL_LIBS+=" -lSDL2_ttf"
  SDL_CFLAGS+=" -DHAVE_SDL2_TTF"
], [
  AC_MSG_WARN([SDL TTF development package not installed])
])

dnl Check for fontconfig
AC_CHECK_LIB(fontconfig, FcInit, [
  SDL_LIBS+=" -lfontconfig"
  SDL_CFLAGS+=" -DHAVE_FONTCONFIG"
], [
  AC_MSG_WARN([Fontconfig development package not installed])
])

AC_CONFIG_FILES([Makefile.conf])

AC_OUTPUT
