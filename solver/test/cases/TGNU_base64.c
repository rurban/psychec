void
usage (int status)
{
  if (status != EXIT_SUCCESS)
    emit_try_help ();
  else
    {
      printf (_("\
Usage: %s [OPTION]... [FILE]\n\
Base%d encode or decode FILE, or standard input, to standard output.\n\
"), program_name, BASE_TYPE);

      emit_stdin_note ();
      emit_mandatory_arg_note ();

      fputs (_("\
  -d, --decode          decode data\n\
  -i, --ignore-garbage  when decoding, ignore non-alphabet characters\n\
  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).\n\
                          Use 0 to disable line wrapping\n\
\n\
"), stdout);
      fputs (HELP_OPTION_DESCRIPTION, stdout);
      fputs (VERSION_OPTION_DESCRIPTION, stdout);
      printf (_("\
\n\
The data are encoded as described for the %s alphabet in RFC 4648.\n\
When decoding, the input may contain newlines in addition to the bytes of\n\
the formal %s alphabet.  Use --ignore-garbage to attempt to recover\n\
from any other non-alphabet bytes in the encoded stream.\n"),
              PROGRAM_NAME, PROGRAM_NAME);
      emit_ancillary_info (PROGRAM_NAME);
    }

  exit (status);
}

static void
wrap_write (const char *buffer, size_t len,
            uintmax_t wrap_column, size_t *current_column, FILE *out)
{
  size_t written;

  if (wrap_column == 0)
    {
      /* Simple write. */
      if (fwrite (buffer, 1, len, stdout) < len)
        error (EXIT_FAILURE, errno, _("write error"));
    }
  else
    for (written = 0; written < len;)
      {
        uintmax_t cols_remaining = wrap_column - *current_column;
        size_t to_write = MIN (cols_remaining, SIZE_MAX);
        to_write = MIN (to_write, len - written);

        if (to_write == 0)
          {
            if (fputc ('\n', out) == EOF)
              error (EXIT_FAILURE, errno, _("write error"));
            *current_column = 0;
          }
        else
          {
            if (fwrite (buffer + written, 1, to_write, stdout) < to_write)
              error (EXIT_FAILURE, errno, _("write error"));
            *current_column += to_write;
            written += to_write;
          }
      }
}

static void
do_encode (FILE *in, FILE *out, uintmax_t wrap_column)
{
  size_t current_column = 0;
  char inbuf[ENC_BLOCKSIZE];
  char outbuf[BASE_LENGTH (ENC_BLOCKSIZE)];
  size_t sum;

  do
    {
      size_t n;

      sum = 0;
      do
        {
          n = fread (inbuf + sum, 1, ENC_BLOCKSIZE - sum, in);
          sum += n;
        }
      while (!feof (in) && !ferror (in) && sum < ENC_BLOCKSIZE);

      if (sum > 0)
        {
          /* Process input one block at a time.  Note that ENC_BLOCKSIZE
             is sized so that no pad chars will appear in output. */
          base_encode (inbuf, sum, outbuf, BASE_LENGTH (sum));

          wrap_write (outbuf, BASE_LENGTH (sum), wrap_column,
                      &current_column, out);
        }
    }
  while (!feof (in) && !ferror (in) && sum == ENC_BLOCKSIZE);

  /* When wrapping, terminate last line. */
  if (wrap_column && current_column > 0 && fputc ('\n', out) == EOF)
    error (EXIT_FAILURE, errno, _("write error"));

  if (ferror (in))
    error (EXIT_FAILURE, errno, _("read error"));
}

static void
do_decode (FILE *in, FILE *out, bool ignore_garbage)
{
  char inbuf[BASE_LENGTH (DEC_BLOCKSIZE)];
  char outbuf[DEC_BLOCKSIZE];
  size_t sum;
  struct base_decode_context ctx;

  base_decode_ctx_init (&ctx);

  do
    {
      bool ok;
      size_t n;
      unsigned int k;

      sum = 0;
      do
        {
          n = fread (inbuf + sum, 1, BASE_LENGTH (DEC_BLOCKSIZE) - sum, in);

          if (ignore_garbage)
            {
              size_t i;
              for (i = 0; n > 0 && i < n;)
                if (isbase (inbuf[sum + i]) || inbuf[sum + i] == '=')
                  i++;
                else
                  memmove (inbuf + sum + i, inbuf + sum + i + 1, --n - i);
            }

          sum += n;

          if (ferror (in))
            error (EXIT_FAILURE, errno, _("read error"));
        }
      while (sum < BASE_LENGTH (DEC_BLOCKSIZE) && !feof (in));

      /* The following "loop" is usually iterated just once.
         However, when it processes the final input buffer, we want
         to iterate it one additional time, but with an indicator
         telling it to flush what is in CTX.  */
      for (k = 0; k < 1 + !!feof (in); k++)
        {
          if (k == 1 && ctx.i == 0)
            break;
          n = DEC_BLOCKSIZE;
          ok = base_decode_ctx (&ctx, inbuf, (k == 0 ? sum : 0), outbuf, &n);

          if (fwrite (outbuf, 1, n, out) < n)
            error (EXIT_FAILURE, errno, _("write error"));

          if (!ok)
            error (EXIT_FAILURE, 0, _("invalid input"));
        }
    }
  while (!feof (in));
}

int
main (int argc, char **argv)
{
  int opt;
  FILE *input_fh;
  const char *infile;

  /* True if --decode has been given and we should decode data. */
  bool decode = false;
  /* True if we should ignore non-base-alphabetic characters. */
  bool ignore_garbage = false;
  /* Wrap encoded data around the 76:th column, by default. */
  uintmax_t wrap_column = 76;

  initialize_main (&argc, &argv);
  set_program_name (argv[0]);
  setlocale (LC_ALL, "");
  bindtextdomain (PACKAGE, LOCALEDIR);
  textdomain (PACKAGE);

  atexit (close_stdout);

  while ((opt = getopt_long (argc, argv, "diw:", long_options, NULL)) != -1)
    switch (opt)
      {
      case 'd':
        decode = true;
        break;

      case 'w':
        wrap_column = xdectoumax (optarg, 0, UINTMAX_MAX, "",
                                  _("invalid wrap size"), 0);
        break;

      case 'i':
        ignore_garbage = true;
        break;

      case_GETOPT_HELP_CHAR;

      case_GETOPT_VERSION_CHAR (PROGRAM_NAME, AUTHORS);

      default:
        usage (EXIT_FAILURE);
        break;
      }

  if (argc - optind > 1)
    {
      error (0, 0, _("extra operand %s"), quote (argv[optind]));
      usage (EXIT_FAILURE);
    }

  if (optind < argc)
    infile = argv[optind];
  else
    infile = "-";

  if (STREQ (infile, "-"))
    {
      if (O_BINARY)
        xfreopen (NULL, "rb", stdin);
      input_fh = stdin;
    }
  else
    {
      input_fh = fopen (infile, "rb");
      if (input_fh == NULL)
        error (EXIT_FAILURE, errno, "%s", quotef (infile));
    }

  fadvise (input_fh, FADVISE_SEQUENTIAL);

  if (decode)
    do_decode (input_fh, stdout, ignore_garbage);
  else
    do_encode (input_fh, stdout, wrap_column);

  if (fclose (input_fh) == EOF)
    {
      if (STREQ (infile, "-"))
        error (EXIT_FAILURE, errno, _("closing standard input"));
      else
        error (EXIT_FAILURE, errno, "%s", quotef (infile));
    }

  return EXIT_SUCCESS;
}
