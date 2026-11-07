import pf.Random
import pf.Time

UserId := [].{
	generate! : {} => Str
	generate! = |{}| {
		milliseconds = Time.Timestamp.to_unix_milliseconds(Time.now!({})).to_u64_wrap()
		UserId.format(milliseconds, Random.u64!({}), Random.u64!({}))
	}

	## UUIDv7: 48 timestamp bits, version 7, random payload, RFC variant 10.
	format : U64, U64, U64 -> Str
	format = |milliseconds, high, low| {
		time = hex(milliseconds, 12)
		random_a = hex(high % 4096, 3)
		random_b = hex(low % 4611686018427387904 + 9223372036854775808, 16)
		bytes = time.to_utf8().concat(['7']).concat(random_a.to_utf8()).concat(random_b.to_utf8())
		var $output = []
		var $index = 0
		for byte in bytes {
			if $index == 8 or $index == 12 or $index == 16 or $index == 20 {
				$output = $output.append('-')
			}
			$output = $output.append(byte)
			$index = $index + 1
		}
		Str.from_utf8_lossy($output)
	}
}

hex : U64, U64 -> Str
hex = |value, width| {
	var $n = value
	var $digits = []
	for _ in List.repeat({}, width) {
		digit = ($n % 16).to_u8_wrap()
		$digits = [
			if digit < 10 {
				'0' + digit
			} else {
				'a' + digit - 10
			},
		].concat($digits)
		$n = $n // 16
	}
	Str.from_utf8_lossy($digits)
}

expect UserId.format(0, 0, 0) == "00000000-0000-7000-8000-000000000000"

expect UserId.format(281474976710655, 4095, 4611686018427387903) == "ffffffff-ffff-7fff-bfff-ffffffffffff"
expect UserId.format(1, 4096, 4611686018427387904) == "00000000-0001-7000-8000-000000000000"
