# Gamut

Gamut (DUB package: `gamut`) is an image decoding/encoding library for D.

It's design is inspired by the FreeImage design, where the Image concept is monomorphic and can do it all.

Gamut tries to have the fastest and most memory-conscious image decoders available in pure D code.
It is `nothrow @nogc @safe` for usage in -betterC and in disabled-runtime D.


## Decoding

- PNG: 8-bit and 16-bit, L/LA/RGB/RGBA
- JPEG: 8-bit, L/RGB/RGBA, baseline and progressive
- QOI: 8-bit, RGB/RGBA
- QOIX: 8-bit, 10-bit, L/LA/RGB/RGBA. _This is still an evolving format, specific to Gamut, that embeds some developments in the QOI family of formats._

## Encoding

- PNG. 8-bit, RGB/RGBA
- JPEG: 8-bit, greyscale/RGB, baseline
- QOI: 8-bit, RGB/RGBA
- QOIX: 8-bit, 10-bit, L/LA/RGB/RGBA
- DDS: BC7 encoded, 8-bit, RGB/RGBA


## Why QOIX?

Our benchmark results for 8-bit color images:

| Codec | decode mpps | encode mpps | bit-per-pixel |
|-------|-------------|-------------|---------------|
| PNG (stb) | 89.73   | 14.34       | 10.29693      |
| QOI   | 204.70      | 150.42      | 10.35162      |
| QOIX  | 177.5       | 103.35      | 8.30963       |


- QOIX and QOI generally outperforms PNG in decoding speed and encoding speed.
- QOIX outperforms QOI in compression efficiency at the cost of speed:
  * because it's based upon qoi2avg, a better QOI variant for RGB and RGBA images
  * because it is followed by LZ4, which removes some of the QOI worst cases.
- QOIX adds support for 8-bit greyscale and greyscale + alpha images, with a "QOI-plane" custom codec.
- QOIX adds support for 10-bit images, with a "QOI-10b" custom codec. It is lossy but outperform PNG 16-bit in everyway apart from being lossless.


&nbsp;


----


&nbsp;



# Gamut API documentation

## 1. `Image` basics

> **Key concept:**
> The `Image` struct is where most of the public API resides.

### **1.1 Get the dimensions of an image:**
  ```d
  Image image = Image(800, 600);
  int w = image.width();
  int h = image.height();
  assert(w == 800 && h == 600);
  ```

### **1.2 Get the pixel format of an image:**
  ```d
  Image image = Image(800, 600);
  ImageType type = image.type();
  assert(type == ImageType.rgba8); // rgba8 is default if not provided
  ```

  > **Key concept:** `ImageType` completely describes the pixel format, for example `Imagetype.rgb8` is a 24-bit format with one byte for red, green and blue components each (in that order).

  Here are the possible `ImageType`:


  ```d
  enum ImageType
  {
      uint8,
      uint16,
      f32,
      la8,
      la16,
      laf32,
      rgb8, 
      rgb16,
      rgbf32,
      rgba8,
      rgba16,   
      rgbaf32
  }
  ```

  For now, all pixels format have one to four components:
  - 1 component is implicitely Greyscale
  - 2 components is implicitely Greyscale + alpha
  - 3 components is implicitely Red + Green + Blue
  - 4 components is implicitely Red + Green + Blue + Alpha

  _**Bit-depth:** Each of these components can be represented in 8-bit, 16-bit, or 32-bit floating-point (0.0f to 1.0f range)._



### **1.3 Create an uninitialized image:**
  ```d
  Image image;
  image.setSize(640, 480, ImageType.rgba8);
  ```


## 2. Loading and saving an image

### **2.1 Load an `Image` from a file:**

  ```d
  Image image;
  image.loadFromFile("logo.png");
  if (image.errored)
      throw new Exception(image.errorMessage);
  ```

  You can then read `width()`, `height()`, `type()`, etc...

  > **There is no exceptions in Gamut.** Instead the Image itself has an error API:
  > - `bool errored()` return `true` if the `Image` is in an error state. In an error state, the image can't be used anymore until recreated (for example, loading another file).
  > - `const(char)[] errorMessage()` is then available, and is guaranteed to be zero-terminated.


### **2.2 Load an image from memory:**
  ```d
  auto pngBytes = cast(const(ubyte)[]) import("logo.png"); 
  Image image;
  image.loadFromMemory(pngBytes);
  ```
  > **Key concept:** You can force the loaded image to be a certain type using `LoadFlags`.

  Here are the possible `LoadFlags`:
  ```d
  LOAD_NORMAL      // Default: preserve type from original.
  
  LOAD_ALPHA       // Force one alpha channel.
  LOAD_NO_ALPHA    // Force zero alpha channel.
  
  LOAD_GREYSCALE   // Force greyscale.
  LOAD_RGB         // Force RGB values.
  
  LOAD_8BIT        // Force 8-bit `ubyte` per component.
  LOAD_16BIT       // Force 16-bit `ushort` per component.
  LOAD_FP32        // Force 32-bit `float` per component.
  ```

  Example:
  ```d
  Image image;  
  image.loadFromMemory(pngBytes, LOAD_RGB | LOAD_ALPHA | LOAD_8BIT);  // force ImageType.rgba8 
  ```
  Not all load flags are compatible, for example `LOAD_8BIT` and `LOAD_16BIT`.
    

### **2.3 Save an image to a file:**

  ```d
  Image image;
  if (!image.saveToFile("output.png"))
      throw new Exception("Writing output.png failed");
  ```

  > **Key concept:** `ImageFormat` is simply the codecs/containers files Gamut encode and decodes to.

  ```d
  enum ImageFormat
  {
      unknown,
      JPEG,
      PNG,
      QOI,
      QOIX,
      DDS
  }
  ```

  This can be used to avoid inferring the output format from the filename:
  ```d
  Image image;
  if (!image.saveToFile(ImageFormat.PNG, "output.png"))
      throw new Exception("Writing output.png failed");
  ```

### **2.4 Save an image to memory:**

  ```d
  Image image;
  ubyte[] qoixEncoded = image.saveToMemory(ImageFormat.QOIX);
  scope(exit) free(qoix_encoded.ptr);
  ```

  The returned slice must be freed up with `core.stdc.stdlib.free`.



## 3. Accessing image pixels

### **3.1 Get the row pitch, in bytes:**
  ```d
  int pitch = image.pitchInBytes();
  ```

  > **Key concept:** The image `pitch` is the distance between the start of two consecutive scanlines, in bytes.
  **This pitch can be negative.**

### **3.2 Access a row of pixels:**
  ```d
  ubyte* scan = image.scanline(y);
  ```
  > **Key concept:** The scanline is `ubyte*` but the type it points to depends upon the `ImageType`. In a given scanline, the bytes `scan[0..abs(pitchInBytes())]` are all accessible, even if they may be outside of the image.


### **3.3 Iterate on pixels:**
  ```d
  assert(image.type == ImageType.rgba16);
  assert(image.hasData());
  for (int y = 0; y < image.height(); ++y)
  {
      ushort* scan = cast(ushort*) image.scanline(y);               
      for (int x = 0; x < image.width(); ++x)
      {
          ushort r = scanline[4*x + 0];
          ushort g = scanline[4*x + 1];
          ushort b = scanline[4*x + 2];
          ushort a = scanline[4*x + 3];        
      }
  }
  ```
  > **Key concept:** You cannot access pixels in a contiguous manner in all cases. You can if `image.isGapless()` returns `true`, but there is no constraints to guarantee being gapless.


