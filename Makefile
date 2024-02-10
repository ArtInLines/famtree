# MODE: DEBUG (default), RELEASE
CC      = gcc
MODE   ?= DEBUG
CFLAGS ?=

FILES = deps/libraylib.a

CFLAGS += -lopengl32 -lgdi32 -lwinmm -lpthread
CFLAGS += -Wall -Wextra -Wpedantic -Wno-unused-function -std=c99
CFLAGS += -I./deps/raylib/src -I./deps/ail

ifeq ($(MODE), DEBUG)
export RAYLIB_BUILD_MODE = DEBUG
CFLAGS += -ggdb -D_DEBUG
else
export RAYLIB_BUILD_MODE = RELEASE
CFLAGS += -O2
endif


.PHONY: clean all raylib

all: main

clean:
	rm -f *.o deps/*.a deps/raylib/src/*.o

main: main.c raylib
	$(CC) -o main main.c $(FILES) $(CFLAGS)


export RAYLIB_RELEASE_PATH=../../
export RAYLIB_LIBTYPE=STATIC
export RAYLIB_LIB_NAME=raylib
raylib:
	$(MAKE) -C deps/raylib/src