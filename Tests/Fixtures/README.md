# Synthetic encrypted HLS fixture

`ClearHLS` contains an original three-second test-pattern video and sine-wave audio generated for this project's offline playback test. H.264 baseline / AAC in MPEG-TS, encrypted with HLS AES-128. The public fixed test key is `ffeeddccbbaa99887766554433221100`; it is not a provider or user credential. The test server deliberately refuses the original key URL; the configured-key relay must provide it for AVPlayer to decode a frame.

Generated with FFmpeg 7.1 using `testsrc=size=160x90:rate=10`, `sine=frequency=440:sample_rate=44100`, `-t 3 -c:v libx264 -profile:v baseline -pix_fmt yuv420p -g 10 -c:a aac -f hls -hls_time 1 -hls_list_size 0 -hls_key_info_file keyinfo.txt`.

These files are test resources only. They are not bundled in the device IPA.
