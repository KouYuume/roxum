# Instruction-count profiling for bench/m13/instructions.py. Extends the Linux
# test image (tools/linux/Dockerfile), which bench/m13/profile/run.sh builds first.
FROM roxum-linux
RUN apt-get update \
    && apt-get install -y --no-install-recommends linux-perf strace valgrind \
    && rm -rf /var/lib/apt/lists/*
