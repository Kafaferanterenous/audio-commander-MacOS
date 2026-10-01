/* Fixture generator: writes the reference tone complex as Ogg FLAC (.oga),
 * native FLAC (.flac) or RIFF/WAVE (.wav, so a third-party encoder can be
 * pointed at the very same signal). Deterministic - re-running it reproduces
 * the committed fixtures byte for byte.
 *
 *   flacgen <path> <rate> <channels> <bps> <seconds> [level]
 */
#include "flaclib.h"

int main(int argc, char **argv) {
    if (argc < 6) {
        fprintf(stderr,
                "usage: %s <path> <rate> <ch> <bps> <seconds> [level]\n"
                "  .oga/.flac -> Ogg FLAC / native FLAC, .wav -> RIFF/WAVE,\n"
                "  .raw -> headerless interleaved PCM (for piping into another encoder)\n"
                "  e.g. %s tools/fixtures/s16_44100.oga 44100 2 16 2.0 5\n",
                argv[0], argv[0]);
        return 2;
    }
    {
        const char *path = argv[1];
        unsigned rate = (unsigned)strtoul(argv[2], NULL, 10);
        int ch = atoi(argv[3]);
        unsigned bps = (unsigned)strtoul(argv[4], NULL, 10);
        long frames = test_frames(rate, atof(argv[5]));
        int level = (argc > 6) ? atoi(argv[6]) : 5;

        if (rate < 8000 || rate > 1048575 || ch < 1 || ch > 8
            || (bps != 8 && bps != 16 && bps != 24 && bps != 32)) {
            fprintf(stderr, "flacgen: unsupported spec %u Hz %d ch %u bps\n", rate, ch, bps);
            return 2;
        }
        {
            size_t plen = strlen(path);
            int is_wav = plen > 4 && strcmp(path + plen - 4, ".wav") == 0;
            int is_raw = plen > 4 && strcmp(path + plen - 4, ".raw") == 0;
            int is_ogg = !(plen > 5 && strcmp(path + plen - 5, ".flac") == 0);
            int ok = is_wav ? wav_write(path, rate, ch, bps, frames)
                : is_raw ? raw_write(path, rate, ch, bps, frames)
                         : flac_write(path, rate, ch, bps, frames, level, is_ogg);
            if (!ok) return 1;
            printf("wrote %s: %u Hz, %d ch, %u bps, %ld frames (%.3f s)%s\n",
                   path, rate, ch, bps, frames, (double)frames / rate,
                   is_wav ? ", RIFF/WAVE"
                          : (is_raw ? ", raw PCM"
                                    : (is_ogg ? ", Ogg FLAC" : ", native FLAC")));
        }
    }
    return 0;
}
