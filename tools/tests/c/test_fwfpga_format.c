/* Host-compiled check that the generated C header parses what the Python packer writes.
 *
 *   gcc -std=c11 -Wall -Wextra -Werror -I firmware/generated tools/tests/c/test_fwfpga_format.c -o t
 *   ./t file.fwfpga
 *
 * Prints one "key=value" per line; tools/tests/test_fwfpga_format_c.py asserts them against the
 * values it packed. Exit 0 whenever the file could be read; the Python side judges the fields.
 */
#include <stdio.h>
#include <stdlib.h>

#include "fw2_fwfpga_format.h"

static uint32_t crc32_via_pointer(uint32_t crc, const uint8_t *data, size_t len) {
    /* Stands in for the firmware's own CRC routine: must agree with the built-in. */
    return fw2_crc32_update(crc, data, len);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s file.fwfpga\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("fopen"); return 2; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *blob = (uint8_t *)malloc(size > 0 ? (size_t)size : 1);
    if (fread(blob, 1, (size_t)size, f) != (size_t)size) { perror("fread"); return 2; }
    fclose(f);

    printf("file_len=%ld\n", size);
    printf("sizeof_header=%u\n", (unsigned)sizeof(fw2_fwfpga_header_t));
    if (size < (long)FW2_FWFPGA_HEADER_LEN) { printf("valid=0\nreason=short\n"); return 0; }

    bool valid_builtin = fw2_fwfpga_header_valid(blob, NULL);
    bool valid_fnptr = fw2_fwfpga_header_valid(blob, crc32_via_pointer);
    printf("valid=%d\n", valid_builtin && valid_fnptr ? 1 : 0);
    printf("valid_fnptr_agrees=%d\n", valid_builtin == valid_fnptr ? 1 : 0);

    fw2_fwfpga_header_t h;
    fw2_fwfpga_header_parse(blob, &h);
    const char *reason = fw2_fwfpga_header_check_fields(&h);
    printf("fields_ok=%d\n", reason == NULL ? 1 : 0);
    printf("reason=%s\n", reason ? reason : "-");
    printf("format_version=%u\n", h.format_version);
    printf("contract_version=%u\n", h.contract_version);
    printf("header_len=%u\n", h.header_len);
    printf("manifest_len=%u\n", (unsigned)h.manifest_len);
    printf("bitstream_len=%u\n", (unsigned)h.bitstream_len);
    printf("bitstream_crc32=%08X\n", (unsigned)h.bitstream_crc32);
    printf("name=%.31s\n", h.name);
    printf("description=%.127s\n", h.description);
    printf("design_id=%u\n", h.design_id);
    printf("design_version=%u\n", h.design_version);
    printf("capabilities=%u\n", h.capabilities);
    printf("clock_code=%u\n", h.clock_code);
    printf("clock_hz=%u\n", h.clock_code < FW2_CLOCK_CODE_COUNT ? (unsigned)FW2_CLOCK_CODE_HZ[h.clock_code] : 0u);
    printf("io_profile=%08X\n", (unsigned)h.io_profile);
    printf("kind=%u\n", h.kind);
    printf("header_crc32=%08X\n", (unsigned)h.header_crc32);
    printf("sha256_first=%02X\n", h.bitstream_sha256[0]);
    printf("mode_gpio26=%u\n", (unsigned)FW2_IOP_MODE(h.io_profile, FW2_SIG_GPIO26));
    printf("mode_spi_miso=%u\n", (unsigned)FW2_IOP_MODE(h.io_profile, FW2_SIG_SPI_MISO));

    long payload = size - (long)FW2_FWFPGA_HEADER_LEN;
    int lengths_ok = payload == (long)h.manifest_len + (long)h.bitstream_len;
    printf("lengths_ok=%d\n", lengths_ok);
    if (lengths_ok) {
        const uint8_t *bits = blob + FW2_FWFPGA_HEADER_LEN + h.manifest_len;
        uint32_t crc = 0;
        /* chunked, as the firmware streams it from SD */
        for (uint32_t off = 0; off < h.bitstream_len; off += 4096) {
            uint32_t n = h.bitstream_len - off < 4096 ? h.bitstream_len - off : 4096;
            crc = fw2_crc32_update(crc, bits + off, n);
        }
        printf("bitstream_crc_ok=%d\n", crc == h.bitstream_crc32 ? 1 : 0);
        printf("preamble_ok=%d\n", fw2_ice40_has_preamble(bits, h.bitstream_len) ? 1 : 0);
    }

    uint8_t idblk[FW2_IDBLK_LEN];
    fw2_idblk_from_header(&h, idblk);
    printf("idblk=");
    for (int i = 0; i < (int)FW2_IDBLK_LEN; i++) printf("%02x", idblk[i]);
    printf("\n");
    printf("idblk_match=%d\n", (int)fw2_idblk_compare(idblk, &h));
    idblk[FW2_IDBLK_OFF_IO_PROFILE] ^= 0x01;
    idblk[FW2_IDBLK_OFF_CHECKSUM] = fw2_idblk_checksum(idblk);
    printf("idblk_profile_mismatch=%d\n", (int)fw2_idblk_compare(idblk, &h));
    idblk[FW2_IDBLK_OFF_CHECKSUM] ^= 0xFF;
    printf("idblk_bad_checksum=%d\n", (int)fw2_idblk_compare(idblk, &h));
    free(blob);
    return 0;
}
