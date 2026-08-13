/*
 * Adapted from LibRaw 0.21.4 src/demosaic/xtrans_demosaic.cpp.
 * Copyright 2019-2021 LibRaw LLC; incorporates dcraw work by Dave Coffin.
 * Licensed by LibRaw under LGPL-2.1-only or CDDL-1.0. Film Scan Converter
 * keeps the original pixel arithmetic and serial tile/interpolation order,
 * with bounded row parallelism only where each output range is independent.
 */

  int cstat[4] = {0, 0, 0, 0};
  int ndir;
  static const short orth[12] = {1, 0, 0, 1, -1, 0, 0, -1, 1, 0, 0, 1},
                     patt[2][16] = {{0, 1, 0, -1, 2, 0, -1, 0, 1, 1, 1, -1, 0,
                                     0, 0, 0},
                                    {0, 1, 0, -2, 1, 0, -2, 0, 1, 1, -2, -2, 1,
                                     -1, -1, 1}},
                     dir[4] = {1, LIBRAW_AHD_TILE, LIBRAW_AHD_TILE + 1,
                               LIBRAW_AHD_TILE - 1};
  short allhex[3][3][2][8];
  ushort sgrow = 0, sgcol = 0;

  if (width < LIBRAW_AHD_TILE || height < LIBRAW_AHD_TILE)
    throw LIBRAW_EXCEPTION_IO_CORRUPT; // too small image
                                       /* Check against right pattern */
  for (int row = 0; row < 6; row++)
    for (int col = 0; col < 6; col++)
      cstat[(unsigned)fcol(row, col)]++;

  if (cstat[0] < 6 || cstat[0] > 10 || cstat[1] < 16 || cstat[1] > 24 ||
      cstat[2] < 6 || cstat[2] > 10 || cstat[3])
    throw LIBRAW_EXCEPTION_IO_CORRUPT;

  // Init allhex table to unreasonable values
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      for (int k = 0; k < 2; k++)
        for (int l = 0; l < 8; l++)
          allhex[i][j][k][l] = 32700;

  cielab(0, 0);
  ndir = 4 << int(passes > 1);

  int minv = 0, maxv = 0, minh = 0, maxh = 0;
  /* Map a green hexagon around each non-green pixel and vice versa:	*/
  for (int row = 0; row < 3; row++)
    for (int col = 0; col < 3; col++)
      for (int ng = 0, d = 0; d < 10; d += 2)
      {
        int g = fcol(row, col) == 1;
        if (fcol(row + orth[d], col + orth[d + 2]) == 1)
          ng = 0;
        else
          ng++;
        if (ng == 4)
        {
          sgrow = row;
          sgcol = col;
        }
        if (ng == g + 1)
        {
            int c;
            FORC(8)
            {
                int v = orth[d] * patt[g][c * 2] + orth[d + 1] * patt[g][c * 2 + 1];
                int h = orth[d + 2] * patt[g][c * 2] + orth[d + 3] * patt[g][c * 2 + 1];
                minv = MIN(v, minv);
                maxv = MAX(v, maxv);
                minh = MIN(v, minh);
                maxh = MAX(v, maxh);
                allhex[row][col][0][c ^ (g * 2 & d)] = h + v * width;
                allhex[row][col][1][c ^ (g * 2 & d)] = h + v * LIBRAW_AHD_TILE;
            }
        }
      }

  // Check allhex table initialization
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      for (int k = 0; k < 2; k++)
        for (int l = 0; l < 8; l++)
          if (allhex[i][j][k][l] > maxh + maxv * width + 1 ||
              allhex[i][j][k][l] < minh + minv * width - 1)
            throw LIBRAW_EXCEPTION_IO_CORRUPT;
  int retrycount = 0;

  /* Set green1 and green3 to the minimum and maximum allowed values:	*/
  for (int row = 2; row < height - 2; row++)
  {
      int col;
      ushort min, max;
      for (col = 2, max = 0u, min = 0xffffu; col < int(width) - 2; col++)
      {
          if (fcol(row, col) == 1 && (min = ~(max = 0)))
              continue;
          ushort(*pix)[4];
          pix = image + row * width + col;
          short* hex = allhex[row % 3][col % 3][0];
          if (!max)
          {
              int c;
              FORC(6)
              {
                  int val = pix[hex[c]][1];
                  if (min > val)
                      min = val;
                  if (max < val)
                      max = val;
              }
          }
          pix[0][1] = min;
          pix[0][3] = max;
          switch ((row - sgrow) % 3)
          {
          case 1:
              if (row < height - 3)
              {
                  row++;
                  col--;
              }
              break;
          case 2:
              if ((min = ~(max = 0)) && (col += 2) < width - 3 && row > 2)
              {
                  row--;
                  if (retrycount++ > width * height)
                      throw LIBRAW_EXCEPTION_IO_CORRUPT;
              }
          }
      }
  }

  for (int row = 3; row < 9 && row < height - 3; row++)
	  for (int col = 3; col < 9 && col < width - 3; col++)
	  {
		  if ((fcol(row, col)) == 1)
			  continue;
          short* hex = allhex[row % 3][col % 3][0];
          int c;
		  FORC(2)
		  {
			  int idx3 = 3 * hex[4 + c] + row * width + col;
			  int idx4 = -3 * hex[4 + c] + row * width + col;
			  int maxidx = width * height;
			  if (idx3 < 0 || idx3 >= maxidx)
				  throw LIBRAW_EXCEPTION_IO_CORRUPT;
			  if (idx4 < 0 || idx4 >= maxidx)
				  throw LIBRAW_EXCEPTION_IO_CORRUPT;
		  }
	  }

  int buffer_count = 1;

  size_t buffer_size = LIBRAW_AHD_TILE * LIBRAW_AHD_TILE * (ndir * 11 + 6);
  char** buffers = malloc_omp_buffers(buffer_count, buffer_size);

    for (int top = 3; top < height - 19; top += LIBRAW_AHD_TILE - 16)
    {
        char* buffer = buffers[0];

        ushort(*rgb)[LIBRAW_AHD_TILE][LIBRAW_AHD_TILE][3], (*rix)[3];
        short(*lab)[LIBRAW_AHD_TILE][3], (*lix)[3];
        float(*drv)[LIBRAW_AHD_TILE][LIBRAW_AHD_TILE];
        char(*homo)[LIBRAW_AHD_TILE][LIBRAW_AHD_TILE];

        rgb = (ushort(*)[LIBRAW_AHD_TILE][LIBRAW_AHD_TILE][3])buffer;
        lab = (short(*)[LIBRAW_AHD_TILE][3])(
            buffer + LIBRAW_AHD_TILE * LIBRAW_AHD_TILE * (ndir * 6));
        drv = (float(*)[LIBRAW_AHD_TILE][LIBRAW_AHD_TILE])(
            buffer + LIBRAW_AHD_TILE * LIBRAW_AHD_TILE * (ndir * 6 + 6));
        homo = (char(*)[LIBRAW_AHD_TILE][LIBRAW_AHD_TILE])(
            buffer + LIBRAW_AHD_TILE * LIBRAW_AHD_TILE * (ndir * 10 + 6));

        for (int left = 3; left < width - 19; left += LIBRAW_AHD_TILE - 16)
        {
            int mrow = MIN(top + LIBRAW_AHD_TILE, height - 3);
            int mcol = MIN(left + LIBRAW_AHD_TILE, width - 3);
            for (int row = top; row < mrow; row++)
                for (int col = left; col < mcol; col++)
                    memcpy(rgb[0][row - top][col - left], image[row * width + col], 6);
            int c;
            FORC3 memcpy(rgb[c + 1], rgb[0], sizeof * rgb);

            /* Interpolate green horizontally, vertically, and along both diagonals:
             */
            int color[3][8];
            for (int row = top; row < mrow; row++)
                for (int col = left; col < mcol; col++)
                {
                    int f;
                    if ((f = fcol(row, col)) == 1)
                        continue;
                    ushort (*pix)[4] = image + row * width + col;
                    short* hex = allhex[row % 3][col % 3][0];
                    color[1][0] = 174 * (pix[hex[1]][1] + pix[hex[0]][1]) -
                        46 * (pix[2 * hex[1]][1] + pix[2 * hex[0]][1]);
                    color[1][1] = 223 * pix[hex[3]][1] + pix[hex[2]][1] * 33 +
                        92 * (pix[0][f] - pix[-hex[2]][f]);
                    FORC(2)
                        color[1][2 + c] = 164 * pix[hex[4 + c]][1] +
                        92 * pix[-2 * hex[4 + c]][1] +
                        33 * (2 * pix[0][f] - pix[3 * hex[4 + c]][f] -
                            pix[-3 * hex[4 + c]][f]);
                    FORC4 rgb[c ^ !((row - sgrow) % 3)][row - top][col - left][1] =
                        LIM(color[1][c] >> 8, pix[0][1], pix[0][3]);
                }

            for (int pass = 0; pass < passes; pass++)
            {
                if (pass == 1)
                    memcpy(rgb += 4, buffer, 4 * sizeof * rgb);

                /* Recalculate green from interpolated values of closer pixels:	*/
                if (pass)
                {
                    for (int row = top + 2; row < mrow - 2; row++)
                        for (int col = left + 2; col < mcol - 2; col++)
                        {
                            int f;
                            if ((f = fcol(row, col)) == 1)
                                continue;
                            ushort(*pix)[4] = image + row * width + col;
                            short* hex = allhex[row % 3][col % 3][1];
                            for (int d = 3; d < 6; d++)
                            {
                                rix =
                                    &rgb[(d - 2) ^ !((row - sgrow) % 3)][row - top][col - left];
                                int val = rix[-2 * hex[d]][1] + 2 * rix[hex[d]][1] -
                                    rix[-2 * hex[d]][f] - 2 * rix[hex[d]][f] + 3 * rix[0][f];
                                rix[0][1] = LIM(val / 3, pix[0][1], pix[0][3]);
                            }
                        }
                }

                /* Interpolate red and blue values for solitary green pixels:	*/
                for (int row = (top - sgrow + 4) / 3 * 3 + sgrow; row < mrow - 2; row += 3)
                    for (int col = (left - sgcol + 4) / 3 * 3 + sgcol; col < mcol - 2; col += 3)
                {
                    rix = &rgb[0][row - top][col - left];
                    int h = fcol(row, col + 1);

					if (h == 1) // Incorrect pattern
                      break;

                    float diff[6];
                    memset(diff, 0, sizeof diff);
                    for (int i = 1, d = 0; d < 6; d++, i ^= LIBRAW_AHD_TILE ^ 1, h ^= 2)
                    {
                        for (c = 0; c < 2; c++, h ^= 2)
                        {
                            int g = 2 * rix[0][1] - rix[i << c][1] - rix[-i << c][1];
                            color[h][d] = g + rix[i << c][h] + rix[-i << c][h];
                            if (d > 1)
                                diff[d] += SQR((float)rix[i << c][1] - (float)rix[-i << c][1] -
                                    (float)rix[i << c][h] + (float)rix[-i << c][h]) + SQR((float)g);
                        }
                        if (d > 1 && (d & 1))
                            if (diff[d - 1] < diff[d])
                                FORC(2) color[c * 2][d] = color[c * 2][d - 1];
                        if (d < 2 || (d & 1))
                        {
                            FORC(2) rix[0][c * 2] = CLIP(color[c * 2][d] / 2);
                            rix += LIBRAW_AHD_TILE * LIBRAW_AHD_TILE;
                        }
                    }
                }

                /* Interpolate red for blue pixels and vice versa:		*/
                for (int row = top + 3; row < mrow - 3; row++)
                    for (int col = left + 3; col < mcol - 3; col++)
                    {
                        int f;
                        if ((f = 2 - fcol(row, col)) == 1)
                            continue;
                        rix = &rgb[0][row - top][col - left];
                        c = (row - sgrow) % 3 ? LIBRAW_AHD_TILE : 1;
                        int h = 3 * (c ^ LIBRAW_AHD_TILE ^ 1);
                        for (int d = 0; d < 4; d++, rix += LIBRAW_AHD_TILE * LIBRAW_AHD_TILE)
                        {
                            int i = d > 1 || ((d ^ c) & 1) ||
                                ((ABS(rix[0][1] - rix[c][1]) +
                                    ABS(rix[0][1] - rix[-c][1])) <
                                    2 * (ABS(rix[0][1] - rix[h][1]) +
                                        ABS(rix[0][1] - rix[-h][1])))
                                ? c
                                : h;
                            rix[0][f] = CLIP((rix[i][f] + rix[-i][f] + 2 * rix[0][1] -
                                rix[i][1] - rix[-i][1]) /
                                2);
                        }
                    }

                /* Fill in red and blue for 2x2 blocks of green:		*/
                for (int row = top + 2; row < mrow - 2; row++)
                    if ((row - sgrow) % 3)
                        for (int col = left + 2; col < mcol - 2; col++)
                            if ((col - sgcol) % 3)
                            {
                                rix = &rgb[0][row - top][col - left];
                                short* hex = allhex[row % 3][col % 3][1];
                                for (int d = 0; d < 8;
                                    d += 2, rix += LIBRAW_AHD_TILE * LIBRAW_AHD_TILE)
                                    if (hex[d] + hex[d + 1])
                                    {
                                        int g = 3 * rix[0][1] - 2 * rix[hex[d]][1] - rix[hex[d + 1]][1];
                                        for (c = 0; c < 4; c += 2)
                                            rix[0][c] = CLIP(
                                                (g + 2 * rix[hex[d]][c] + rix[hex[d + 1]][c]) / 3);
                                    }
                                    else
                                    {
                                        int g = 2 * rix[0][1] - rix[hex[d]][1] - rix[hex[d + 1]][1];
                                        for (c = 0; c < 4; c += 2)
                                            rix[0][c] =
                                            CLIP((g + rix[hex[d]][c] + rix[hex[d + 1]][c]) / 2);
                                    }
                            }
            }
            rgb = (ushort(*)[LIBRAW_AHD_TILE][LIBRAW_AHD_TILE][3])buffer;
            mrow -= top;
            mcol -= left;

            /* Convert to CIELab and differentiate in all directions:	*/
            // no effect
            for (int d = 0; d < ndir; d++)
            {
                parallelXTransRows(2, mrow - 2, [&](int row) {
                    for (int col = 2; col < mcol - 2; col++)
                        cielab(rgb[d][row][col], lab[row][col]);
                });
                const int f = dir[d & 3];
                parallelXTransRows(3, mrow - 3, [&](int row) {
                    for (int col = 3; col < mcol - 3; col++)
                    {
                        short (*local_lix)[3] = &lab[row][col];
                        int g = 2 * local_lix[0][0] - local_lix[f][0] - local_lix[-f][0];
                        drv[d][row][col] =
                            SQR(g) +
                            SQR((2 * local_lix[0][1] - local_lix[f][1]
                                - local_lix[-f][1] + g * 500 / 232)) +
                            SQR((2 * local_lix[0][2] - local_lix[f][2]
                                - local_lix[-f][2] - g * 500 / 580));
                    }
                });
            }

            /* Build homogeneity maps from the derivatives:			*/
            memset(homo, 0, ndir * LIBRAW_AHD_TILE * LIBRAW_AHD_TILE);
            parallelXTransRows(4, mrow - 4, [&](int row) {
                for (int col = 4; col < mcol - 4; col++)
                {
                    int d;
                    float tr;
                    for (tr = FLT_MAX, d = 0; d < ndir; d++)
                        if (tr > drv[d][row][col])
                            tr = drv[d][row][col];
                    tr *= 8;
                    for (int dd = 0; dd < ndir; dd++)
                        for (int v = -1; v <= 1; v++)
                            for (int h = -1; h <= 1; h++)
                                if (drv[dd][row + v][col + h] <= tr)
                                    homo[dd][row][col]++;
                }
            });

            /* Average the most homogeneous pixels for the final result:	*/
            if (height - top < LIBRAW_AHD_TILE + 4)
                mrow = height - top + 2;
            if (width - left < LIBRAW_AHD_TILE + 4)
                mcol = width - left + 2;
            parallelXTransRows(MIN(top, 8), mrow - 8, [&](int row) {
                for (int col = MIN(left, 8); col < mcol - 8; col++)
                {
                    int v;
                    int hm[8];
                    for (int d = 0; d < ndir; d++)
                        for (v = -2, hm[d] = 0; v <= 2; v++)
                            for (int h = -2; h <= 2; h++)
                                hm[d] += homo[d][row + v][col + h];
                    for (int d = 0; d < ndir - 4; d++)
                        if (hm[d] < hm[d + 4])
                            hm[d] = 0;
                        else if (hm[d] > hm[d + 4])
                            hm[d + 4] = 0;
                    ushort max;
                    int d;
                    for (d = 1, max = hm[0]; d < ndir; d++)
                        if (max < hm[d])
                            max = hm[d];
                    max -= max >> 3;

                    int avg[4];
                    memset(avg, 0, sizeof avg);
                    for (int dd = 0; dd < ndir; dd++)
                        if (hm[dd] >= max)
                        {
                            for (int channel = 0; channel < 3; channel++)
                                avg[channel] += rgb[dd][row][col][channel];
                            avg[3]++;
                        }
                    for (int channel = 0; channel < 3; channel++)
                        image[(row + top) * width + col + left][channel]
                            = avg[channel] / avg[3];
                }
            });
        }
    }
  
    free_omp_buffers(buffers, buffer_count);

    border_interpolate(8);
