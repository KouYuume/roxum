import HeaderValue
import PercentEncoding

# Internal construction of a response Content-Disposition value (RFC 6266/8187).
ContentDisposition :: [].{
	attachment : Str -> Try(HeaderValue, [InvalidFilename])
	attachment = |filename| {
		bytes = filename.to_utf8()
		if filename.is_empty() or filename == "." or filename == ".." or bytes.any(|b| b < 32 or b == 127 or b == '/' or b == '\\') {
			return Err(InvalidFilename)
		}
		# Avoid quoted-pair and percent-unescaping differences in old clients.
		# Modern clients use filename*, which preserves the exact UTF-8 name.
		fallback = if bytes.any(|b| b >= 128 or b == '"' or b == '%') {
			"download"
		} else {
			filename
		}
		value = "attachment; filename=\"${fallback}\"; filename*=UTF-8''${PercentEncoding.encode(filename)}"
		match HeaderValue.from_str(value) {
			Ok(header) => Ok(header)
			Err(_) => Err(InvalidFilename)
		}
	}
}

# Empty/special path names and separators cannot be download basenames.
expect ContentDisposition.attachment("") == Err(InvalidFilename)
expect ContentDisposition.attachment(".") == Err(InvalidFilename)
expect ContentDisposition.attachment("..") == Err(InvalidFilename)
expect ContentDisposition.attachment("a/b") == Err(InvalidFilename)
expect ContentDisposition.attachment("a\\b") == Err(InvalidFilename)
# C0/visible boundary 31/32/33, DEL boundary 126/127/128 (Unicode U+0080).
expect ContentDisposition.attachment("\u(1F)") == Err(InvalidFilename)
expect match ContentDisposition.attachment(" ") {
	Ok(_) => Bool.True
	Err(_) => Bool.False
}
expect match ContentDisposition.attachment("!") {
	Ok(_) => Bool.True
	Err(_) => Bool.False
}
expect match ContentDisposition.attachment("~") {
	Ok(_) => Bool.True
	Err(_) => Bool.False
}
expect ContentDisposition.attachment("\u(7F)") == Err(InvalidFilename)
expect match ContentDisposition.attachment("\u(80)") {
	Ok(_) => Bool.True
	Err(_) => Bool.False
}
expect ContentDisposition.attachment("a\r\nx: injected") == Err(InvalidFilename)
expect match ContentDisposition.attachment("report.csv") {
	Ok(value) => HeaderValue.inner(value) == "attachment; filename=\"report.csv\"; filename*=UTF-8''report.csv"
	Err(_) => Bool.False
}
expect match ContentDisposition.attachment("鵬.txt") {
	Ok(value) => HeaderValue.inner(value) == "attachment; filename=\"download\"; filename*=UTF-8''%E9%B5%AC.txt"
	Err(_) => Bool.False
}
