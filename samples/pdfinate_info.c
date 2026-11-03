/*
 * pdfinate_info <file.pdf> [out.ppm]
 *
 * Prints the page count and the size of the first page. Given a second argument, renders the first
 * page at 72 dpi into that file as a binary PPM.
 */
#include <fpdfview.h>
#include <stdio.h>

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s file.pdf [out.ppm]\n", argv[0]);
    return 2;
  }

  FPDF_InitLibrary();
  int status = 1;
  FPDF_DOCUMENT doc = FPDF_LoadDocument(argv[1], NULL);
  if (!doc) {
    fprintf(stderr, "%s: cannot open (error %lu)\n", argv[1], FPDF_GetLastError());
    goto done;
  }
  printf("%d pages\n", FPDF_GetPageCount(doc));

  FPDF_PAGE page = FPDF_LoadPage(doc, 0);
  if (!page) {
    fprintf(stderr, "%s: cannot load page 1\n", argv[1]);
    FPDF_CloseDocument(doc);
    goto done;
  }
  int width = (int)FPDF_GetPageWidthF(page);
  int height = (int)FPDF_GetPageHeightF(page);
  printf("page 1: %d x %d points\n", width, height);
  status = 0;

  if (argc > 2) {
    FPDF_BITMAP bitmap = FPDFBitmap_Create(width, height, 0);
    FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);
    FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, FPDF_ANNOT);
    const unsigned char* pixels = FPDFBitmap_GetBuffer(bitmap);
    int stride = FPDFBitmap_GetStride(bitmap);
    FILE* out = fopen(argv[2], "wb");
    if (!out) {
      fprintf(stderr, "%s: cannot write\n", argv[2]);
      status = 1;
    } else {
      fprintf(out, "P6\n%d %d\n255\n", width, height);
      for (int y = 0; y < height; ++y) {
        const unsigned char* row = pixels + y * stride;
        for (int x = 0; x < width; ++x) {
          unsigned char rgb[3] = {row[x * 4 + 2], row[x * 4 + 1], row[x * 4]};  // BGRA
          fwrite(rgb, 1, 3, out);
        }
      }
      fclose(out);
      printf("rendered page 1 into %s\n", argv[2]);
    }
    FPDFBitmap_Destroy(bitmap);
  }

  FPDF_ClosePage(page);
  FPDF_CloseDocument(doc);
done:
  FPDF_DestroyLibrary();
  return status;
}
