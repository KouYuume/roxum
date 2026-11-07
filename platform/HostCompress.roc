## Compression of response bodies and decompression of the HTTP
## client's. Platform code only: apps use `Compression`.
HostCompress := [].{
	## The bytes gzip-compressed; empty when they could not be.
	gzip! : List(U8) => List(U8)

	## The result of `decompress!`.
	Decompressed := [Decompressed(List(U8)), TooLarge, Invalid]

	## The bytes decompressed (coding 0 is gzip, 1 Zstandard), when they are
	## at most the limit long.
	decompress! : List(U8), U8, U64 => HostCompress.Decompressed
}
