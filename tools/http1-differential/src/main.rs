use std::env;
use std::fs;
use std::process::ExitCode;

enum HttparseResult {
    Complete(usize),
    Partial,
    Reject,
}

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    if args.next().as_deref() == Some("--explore") {
        // Default under the user's temporary directory ($TMPDIR on macOS),
        // not a fixed name in a world-writable /tmp.
        let path = args.next().unwrap_or_else(|| {
            env::temp_dir()
                .join("roxum-http1-differential.tsv")
                .to_string_lossy()
                .into_owned()
        });
        return match write_exploration(&path) {
            Ok(count) => {
                println!("generated {count} differential mutations");
                ExitCode::SUCCESS
            }
            Err(message) => {
                eprintln!("{message}");
                ExitCode::FAILURE
            }
        };
    }

    let path = env::args()
        .nth(1)
        .unwrap_or_else(|| "tests/zig/fixtures/http1_differential.tsv".to_owned());

    match verify(&path) {
        Ok(count) => {
            println!("verified {count} httparse outcomes");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn write_exploration(path: &str) -> Result<usize, String> {
    const BASES: &[&[u8]] = &[
        b"GET / HTTP/1.1\r\nHost: example.test\r\n\r\n",
        b"GET http://example.test/a HTTP/1.1\r\nHost: example.test\r\n\r\n",
        b"CONNECT [::1]:443 HTTP/1.1\r\nHost: example.test\r\n\r\n",
        b"POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n",
    ];
    const REPLACEMENTS: &[u8] = &[
        0x00, b'\t', b'\n', b'\r', b' ', b':', b'%', b'0', b'A', b'a', 0x7f, 0x80, 0xff,
    ];

    let mut output = String::from("# httparse-outcome\thex-encoded-request\n");
    let mut count = 0;

    for base in BASES {
        for prefix_length in 0..=base.len() {
            push_exploration(&mut output, &base[..prefix_length]);
            count += 1;
        }

        for index in 0..base.len() {
            for replacement in REPLACEMENTS {
                if base[index] == *replacement {
                    continue;
                }
                let mut mutated = base.to_vec();
                mutated[index] = *replacement;
                push_exploration(&mut output, &mutated);
                count += 1;
            }
        }

        for index in 0..base.len() {
            let mut mutated = base.to_vec();
            mutated.remove(index);
            push_exploration(&mut output, &mutated);
            count += 1;
        }

        for index in 0..=base.len() {
            for replacement in REPLACEMENTS {
                let mut mutated = Vec::with_capacity(base.len() + 1);
                mutated.extend_from_slice(&base[..index]);
                mutated.push(*replacement);
                mutated.extend_from_slice(&base[index..]);
                push_exploration(&mut output, &mutated);
                count += 1;
            }
        }

        count += push_header_line_duplications(&mut output, base);

        let mut pipelined = base.to_vec();
        pipelined.extend_from_slice(b"GET /next HTTP/1.1\r\nHost: next.test\r\n\r\n");
        push_exploration(&mut output, &pipelined);
        count += 1;
    }

    fs::write(path, output).map_err(|error| format!("failed to write {path}: {error}"))?;
    Ok(count)
}

fn push_exploration(output: &mut String, input: &[u8]) {
    use std::fmt::Write;

    match httparse_result(input) {
        HttparseResult::Complete(consumed) => {
            write!(output, "complete:{consumed}").expect("writing to String cannot fail");
        }
        HttparseResult::Partial => output.push_str("partial"),
        HttparseResult::Reject => output.push_str("reject"),
    }
    output.push('\t');
    for byte in input {
        write!(output, "{byte:02x}").expect("writing to String cannot fail");
    }
    output.push('\n');
}

fn push_header_line_duplications(output: &mut String, input: &[u8]) -> usize {
    let Some(request_line_end) = find_crlf(input, 0) else {
        return 0;
    };

    let mut count = 0;
    let mut line_start = request_line_end + 2;
    while let Some(line_end) = find_crlf(input, line_start) {
        if line_end == line_start {
            break;
        }

        let mut mutated = Vec::with_capacity(input.len() + line_end + 2 - line_start);
        mutated.extend_from_slice(&input[..line_start]);
        mutated.extend_from_slice(&input[line_start..line_end + 2]);
        mutated.extend_from_slice(&input[line_start..]);
        push_exploration(output, &mutated);
        count += 1;
        line_start = line_end + 2;
    }
    count
}

fn find_crlf(input: &[u8], start: usize) -> Option<usize> {
    input[start..]
        .windows(2)
        .position(|bytes| bytes == b"\r\n")
        .map(|position| start + position)
}

fn verify(path: &str) -> Result<usize, String> {
    let fixture =
        fs::read_to_string(path).map_err(|error| format!("failed to read {path}: {error}"))?;
    let mut verified = 0;

    for (index, line) in fixture.lines().enumerate() {
        let line_number = index + 1;
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let columns: Vec<_> = line.split('\t').collect();
        if columns.len() != 5 {
            return Err(format!("line {line_number}: expected 5 columns"));
        }

        let name = columns[0];
        let expected = columns[1];
        let input = decode_hex(columns[4])
            .map_err(|error| format!("line {line_number} ({name}): {error}"))?;
        let actual = httparse_outcome(&input);

        if actual != expected {
            return Err(format!(
                "line {line_number} ({name}): expected {expected}, got {actual}",
            ));
        }
        verified += 1;
    }

    Ok(verified)
}

fn httparse_outcome(input: &[u8]) -> &'static str {
    match httparse_result(input) {
        HttparseResult::Complete(_) => "complete",
        HttparseResult::Partial => "partial",
        HttparseResult::Reject => "reject",
    }
}

fn httparse_result(input: &[u8]) -> HttparseResult {
    let mut headers = [httparse::EMPTY_HEADER; 128];
    let mut request = httparse::Request::new(&mut headers);

    match request.parse(input) {
        Ok(httparse::Status::Complete(consumed)) => HttparseResult::Complete(consumed),
        Ok(httparse::Status::Partial) => HttparseResult::Partial,
        Err(_) => HttparseResult::Reject,
    }
}

fn decode_hex(encoded: &str) -> Result<Vec<u8>, String> {
    if !encoded.len().is_multiple_of(2) {
        return Err("hex input has odd length".to_owned());
    }

    encoded
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let pair = std::str::from_utf8(pair).expect("ASCII hex pair");
            u8::from_str_radix(pair, 16).map_err(|_| format!("invalid hex pair {pair:?}"))
        })
        .collect()
}
