const crc32_polynomial_full = 0x01_04_C1_1D_B7;
const crc32_polynomial: u32 = @truncate(crc32_polynomial_full);

pub fn calcHash(input: []const u8) u32 {
    _ = input;
}

test "crc32 simple" {}
