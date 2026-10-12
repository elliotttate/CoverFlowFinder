# RAR regression fixtures

The RAR fixtures are decoded from the `.uu` reference files in the primary libarchive repository's `libarchive/test` directory, fetched on 2026-10-11. Source: https://github.com/libarchive/libarchive/tree/master/libarchive/test. The accompanying `libarchive-COPYING` preserves the upstream license notice.

- RAR4 `test_read_format_rar.rar`: 20-byte `test.txt`, a relative symbolic link, directories.
- RAR5 `test_read_format_rar5_compressed.rar`: 1,200-byte `test.bin`, per `test_read_format_rar5.c`.
- Encrypted RAR5 fixtures: `b.txt` is `This is from b.txt`, password `password`, per `test_read_format_rar_encryption.c`. The non-solid fixture also has an independently encrypted `d.txt` with password `password2`.
- Multipart RAR: three volumes, one 20,111-byte `LibarchiveAddingTest.html`.

SHA-256 of the decoded files:

- `test_rar_multivolume_single_file.part1.rar`: `54769cdaa6aeac494b9ba580804598369ba240f61550620434e08350e4428ec2`
- `test_rar_multivolume_single_file.part2.rar`: `9dd6b28d2fdf0d012390259548cc86be9535ee6eb5ec630c99fbb5dc8d037ed1`
- `test_rar_multivolume_single_file.part3.rar`: `7d72ef6e876e98e6a317b7e534c0285615a2953543e68135a8a0dcc94b41cf21`
- `test_read_format_rar.rar`: `d421b86f6290aefad61b2a36737253b2b30fe27c156bd95abfc230f24fe0307e`
- `test_read_format_rar5_compressed.rar`: `68f9d7e2662cd5bc5607ba9c6bf1edbf121cf3b08011a7d8643091791750a7c8`
- `test_read_format_rar5_encrypted.rar`: `72b69a1d5f5757511e683a9207166c60e91ce0846ae446b8b332b085f9e0ba48`
- `test_read_format_rar5_encrypted_filenames.rar`: `b2b98004c9cbf4f2a4000380ad47a16dea99f2d50835b1602c40d724eb82c300`
