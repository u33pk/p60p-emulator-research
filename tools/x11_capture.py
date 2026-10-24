import ctypes
import sys
from PIL import Image

x = ctypes.CDLL('libX11.so.6')
x.XOpenDisplay.argtypes = [ctypes.c_char_p]
x.XOpenDisplay.restype = ctypes.c_void_p
x.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                        ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
x.XGetImage.restype = ctypes.c_void_p
x.XGetPixel.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
x.XGetPixel.restype = ctypes.c_ulong
x.XDestroyImage.argtypes = [ctypes.c_void_p]
x.XCloseDisplay.argtypes = [ctypes.c_void_p]

window = int(sys.argv[1], 0)
width, height, output = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
display = x.XOpenDisplay(b':0')
if not display:
    raise RuntimeError('cannot open display')
image = x.XGetImage(display, window, 0, 0, width, height, 0xffffffffffffffff, 2)
if not image:
    raise RuntimeError('XGetImage failed')
pixels = []
for y in range(height):
    for px in range(width):
        value = x.XGetPixel(image, px, y)
        pixels.append((value >> 16 & 255, value >> 8 & 255, value & 255))
x.XDestroyImage(image)
x.XCloseDisplay(display)
result = Image.new('RGB', (width, height))
result.putdata(pixels)
result.save(output)
