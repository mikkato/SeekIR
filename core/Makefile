# SeekIR core — C11, libc-only. seekd (демо-стрим) требует libusb (brew).
CC      ?= clang
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -Wconversion -Wno-sign-conversion -ffp-contract=off -Iinclude
LDFLAGS ?=
LDLIBS  ?= -lm

LIBUSB_CFLAGS := $(shell pkg-config --cflags libusb-1.0 2>/dev/null || echo -I/opt/homebrew/include)
LIBUSB_LIBS   := $(shell pkg-config --libs libusb-1.0 2>/dev/null || echo -L/opt/homebrew/lib -lusb-1.0)

SRCS   := src/frame.c src/denoise.c src/tonemap.c src/palettes.c src/radiometric.c
OBJS   := $(SRCS:.c=.o)
LIB    := libseekcore.a

.PHONY: all usb clean test
all: $(LIB) build/seekproc

$(LIB): $(OBJS)
	ar rcs $@ $^

build/seekproc: tools/seekproc.c $(LIB)
	@mkdir -p build
	$(CC) $(CFLAGS) $< $(LIB) -o $@ $(LDFLAGS) $(LDLIBS)

# Асинхронный libusb-транспорт: библиотека seekcap + CLI seekd
usb: libseekcap.a build/seekd
libseekcap.a: usb/seekcap.c $(LIB)
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) -Iusb -c usb/seekcap.c -o usb/seekcap.o
	ar rcs $@ usb/seekcap.o
build/seekd: usb/seekd.c libseekcap.a $(LIB)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) -Iusb $< libseekcap.a $(LIB) -o $@ $(LDFLAGS) $(LDLIBS) $(LIBUSB_LIBS)

clean:
	rm -f $(OBJS) usb/seekcap.o $(LIB) libseekcap.a build/*

test: all
	@PYTHONPATH="" python3 tests/run_golden.py
