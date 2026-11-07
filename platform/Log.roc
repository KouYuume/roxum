import HostLog

## Writes log lines to the standard error stream of the process. Each call
## writes one line, `[LEVEL] message`, where `LEVEL` is `DEBUG`, `INFO`,
## `WARN`, or `ERROR`. Every level is written; there is no level filter.
## Control bytes in the message (below 0x20 except tab, and 0x7F) are written
## as `\xNN`, so a message containing request data cannot start a line of its
## own or send terminal escape sequences; other bytes are written unchanged.
## A line of up to 4 KiB after escaping, including the prefix and the final
## newline, is written with a single write. Within one process lines never
## mix; across processes a single write is kept whole by the operating
## system up to `PIPE_BUF` bytes (512 on macOS, 4096 on Linux), and a longer
## line can interleave with another process's output. A write error is
## ignored.
Log := [].{
	## The severity of a log line.
	Level := [Debug, Info, Warn, Error].{
		is_eq : _
	}

	## Writes `message` at `level`.
	write! : Level, Str => {}
	write! = |level, message| HostLog.write!(level_code(level), message)

	## Writes `message` at the `Debug` level.
	debug! : Str => {}
	debug! = |message| write!(Debug, message)

	## Writes `message` at the `Info` level.
	info! : Str => {}
	info! = |message| write!(Info, message)

	## Writes `message` at the `Warn` level.
	warn! : Str => {}
	warn! = |message| write!(Warn, message)

	## Writes `message` at the `Error` level.
	error! : Str => {}
	error! = |message| write!(Error, message)
}

level_code : Log.Level -> U8
level_code = |level|
	match level {
		Debug => 0
		Info => 1
		Warn => 2
		Error => 3
	}
