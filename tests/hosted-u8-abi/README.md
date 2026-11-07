# Hosted narrow-integer ABI contract

The macOS arm64 calling convention requires the caller to zero-extend the hosted `U8` argument. This fixture verifies that the C host receives the expected value in the speed, dev, and interpreter backends.

Run `./run.sh` from this directory, optionally setting `ROC_BIN` to a compiler executable. All three backends must exit zero and receive `0`, `1`, `2`, `3`, `1`. CI runs this gate on macOS arm64.
